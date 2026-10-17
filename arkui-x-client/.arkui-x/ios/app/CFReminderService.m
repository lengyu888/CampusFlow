#import "CFReminderService.h"
#import "CFNativeProtocol.h"
#import <UserNotifications/UserNotifications.h>
#import <CommonCrypto/CommonDigest.h>

@interface CFReminderJob : NSObject
@property(nonatomic, copy) NSDictionary *command;
@property(nonatomic, copy) CFReminderReply completion;
@property(nonatomic) NSUInteger epoch;
@property(nonatomic) BOOL replied;
@property(nonatomic) BOOL cancelled;
@end
@implementation CFReminderJob
@end

@interface CFReminderService ()
@property(nonatomic, strong) UNUserNotificationCenter *center;
@property(nonatomic, strong) NSMutableArray<CFReminderJob *> *jobs;
@property(nonatomic, strong) CFReminderJob *current;
@property(nonatomic, copy) NSDictionary *ledger;
@property(nonatomic, strong) NSURL *ledgerURL;
@property(nonatomic) NSUInteger epoch;
@property(nonatomic) BOOL storageFailed;
@end

@implementation CFReminderService
+ (instancetype)sharedService {
    static CFReminderService *service;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ service = [[self alloc] init]; });
    return service;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _center = UNUserNotificationCenter.currentNotificationCenter;
        _jobs = [NSMutableArray array];
        _ledger = @{@"scope": @"", @"consent": @NO, @"items": @{}, @"recovery": @NO};
        NSURL *directory = [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
            inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"CampusFlow" isDirectory:YES];
        NSError *error = nil;
        if (!directory || ![NSFileManager.defaultManager createDirectoryAtURL:directory
            withIntermediateDirectories:YES attributes:nil error:&error]) _storageFailed = YES;
        if (!_storageFailed && ![directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&error])
            _storageFailed = YES;
        _ledgerURL = [directory URLByAppendingPathComponent:@"reminders-v1.plist"];
        if (_ledgerURL && [NSFileManager.defaultManager fileExistsAtPath:_ledgerURL.path]) {
            NSData *data = [NSData dataWithContentsOfURL:_ledgerURL];
            id stored = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil] : nil;
            if ([self validLedger:stored]) _ledger = stored;
            else _storageFailed = YES; // Never overwrite an unreadable cleanup ledger.
        }
    }
    return self;
}

- (BOOL)validLedger:(id)value {
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"scope"] isKindOfClass:NSString.class] ||
        ![value[@"consent"] isKindOfClass:NSNumber.class] || ![value[@"items"] isKindOfClass:NSDictionary.class] ||
        ![value[@"recovery"] isKindOfClass:NSNumber.class]) return NO;
    if ([value[@"scope"] length] > 512) return NO;
    for (id key in value[@"items"]) {
        if (![key isKindOfClass:NSString.class] || ![key hasPrefix:@"campusflow."] ||
            ![value[@"items"][key] isKindOfClass:NSNumber.class]) return NO;
    }
    return YES;
}

- (BOOL)saveLedger:(NSDictionary *)ledger {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:ledger
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    if (!data || ![data writeToURL:self.ledgerURL options:NSDataWritingAtomic |
        NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:&error]) return NO;
    self.ledger = ledger;
    return YES;
}

- (void)handle:(NSDictionary *)command completion:(CFReminderReply)completion {
    NSAssert(NSThread.isMainThread, @"Reminder queue runs on main");
    NSString *op = command[@"op"];
    NSString *scope = command[@"scope"];
    // Invalidate at receipt, before the queued clear waits for an in-flight OS add callback.
    if ([op isEqualToString:@"reminders.clear"] &&
        ([scope isEqualToString:self.ledger[@"scope"]] ||
         [scope isEqualToString:self.current.command[@"scope"]])) {
        self.epoch += 1;
        if ([self.current.command[@"op"] isEqualToString:@"reminders.authorize"]) {
            self.current.cancelled = YES;
            [self finish:self.current ok:NO code:@"OPERATION_CANCELLED" result:nil];
        }
    }
    CFReminderJob *job = [CFReminderJob new];
    job.command = command;
    job.completion = completion;
    job.epoch = self.epoch;
    [self.jobs addObject:job];
    // OS calls have no cancellation/timeout primitive. A timed-out add retains the ledger
    // and queue barrier until its callback can be cleaned up; no newer replace can race it.
    NSTimeInterval timeout = [op isEqualToString:@"reminders.authorize"] ? 55 : 12;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (job.replied) return;
        job.cancelled = YES;
        if (self.current == job) self.epoch += 1;
        [self reply:job ok:NO code:@"SYSTEM_ERROR" result:nil];
        if ([job.command[@"op"] isEqualToString:@"reminders.authorize"] && self.current == job) {
            [self finish:job ok:NO code:@"SYSTEM_ERROR" result:nil];
        }
    });
    [self drain];
}

- (void)reply:(CFReminderJob *)job ok:(BOOL)ok code:(NSString *)code result:(NSDictionary *)result {
    if (job.replied) return;
    job.replied = YES;
    job.completion(ok, code, result);
}

- (void)finish:(CFReminderJob *)job ok:(BOOL)ok code:(NSString *)code result:(NSDictionary *)result {
    [self reply:job ok:ok code:code result:result];
    if (self.current != job) return;
    self.current = nil;
    // Schedule the next command after the caller has completed all current state mutations.
    dispatch_async(dispatch_get_main_queue(), ^{ [self drain]; });
}

- (BOOL)isCurrent:(CFReminderJob *)job {
    return self.current == job && !job.cancelled && job.epoch == self.epoch;
}

- (void)drain {
    if (self.current || self.jobs.count == 0) return;
    CFReminderJob *job = self.jobs.firstObject;
    [self.jobs removeObjectAtIndex:0];
    self.current = job;
    if (job.cancelled || job.epoch != self.epoch) {
        [self finish:job ok:NO code:@"OPERATION_CANCELLED" result:nil]; return;
    }
    if (self.storageFailed) { [self finish:job ok:NO code:@"SYSTEM_ERROR" result:nil]; return; }
    NSString *op = job.command[@"op"];
    if ([op isEqualToString:@"reminders.status"]) [self status:job];
    else if ([op isEqualToString:@"reminders.authorize"]) [self authorize:job];
    else if ([op isEqualToString:@"reminders.replace"]) [self replace:job];
    else [self clear:job];
}

- (NSString *)permission:(UNNotificationSettings *)settings {
    if (settings.authorizationStatus == UNAuthorizationStatusAuthorized) return @"granted";
    if (settings.authorizationStatus == UNAuthorizationStatusDenied) return @"denied";
    // Provisional/ephemeral authorization is deliberately not treated as explicit consent.
    return @"unknown";
}

- (void)status:(CFReminderJob *)job {
    [self.center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isCurrent:job]) { [self finish:job ok:NO code:@"OPERATION_CANCELLED" result:nil]; return; }
            [self.center getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> *requests) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (![self isCurrent:job]) { [self finish:job ok:NO code:@"OPERATION_CANCELLED" result:nil]; return; }
                    NSUInteger count = 0;
                    NSDictionary *items = self.ledger[@"items"];
                    for (UNNotificationRequest *request in requests) if (items[request.identifier]) count++;
                    if ([self.ledger[@"recovery"] boolValue]) {
                        // Retain a readable scope so the shared coordinator can clear the correct owner.
                        // The coordinator must clear this owner before enabling or replacing again.
                        [self finish:job ok:YES code:@"OK" result:@{@"permission": [self permission:settings],
                            @"scope": self.ledger[@"scope"], @"scheduled": @(count), @"mode": @"system", @"limited": @NO,
                            @"cleanup_required": @YES}];
                        return;
                    }
                    [self finish:job ok:YES code:@"OK" result:@{@"permission": [self permission:settings],
                        @"scope": self.ledger[@"scope"], @"scheduled": @(count), @"mode": @"system", @"limited": @NO}];
                });
            }];
        });
    }];
}

- (void)authorize:(CFReminderJob *)job {
    NSString *scope = job.command[@"scope"];
    NSString *oldScope = self.ledger[@"scope"];
    if ([self.ledger[@"recovery"] boolValue]) {
        [self finish:job ok:NO code:@"SYSTEM_ERROR" result:nil]; return;
    }
    if (oldScope.length && ![oldScope isEqualToString:scope]) {
        [self finish:job ok:NO code:@"INVALID_REQUEST" result:nil]; return;
    }
    [self.center requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
        completionHandler:^(BOOL granted, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isCurrent:job]) { [self finish:job ok:NO code:@"OPERATION_CANCELLED" result:nil]; return; }
            if (error || !granted) {
                [self finish:job ok:NO code:error ? @"SYSTEM_ERROR" : @"PERMISSION_DENIED" result:nil]; return;
            }
            if (![self saveLedger:@{@"scope": scope, @"consent": @YES, @"items": self.ledger[@"items"], @"recovery": @NO}]) {
                [self finish:job ok:NO code:@"SYSTEM_ERROR" result:nil]; return;
            }
            [self status:job];
        });
    }];
}

- (NSString *)identifier:(NSString *)itemID scope:(NSString *)scope {
    NSData *bytes = [scope dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    NSMutableString *hash = [NSMutableString string];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hash appendFormat:@"%02x", digest[i]];
    return [NSString stringWithFormat:@"campusflow.%@.%@", hash, itemID];
}

// Removal APIs have no completion handler. Read back both queues before reporting success.
- (void)removeIDs:(NSArray<NSString *> *)ids completion:(void (^)(BOOL))completion {
    if (!ids.count) { completion(YES); return; }
    [self.center removePendingNotificationRequestsWithIdentifiers:ids];
    [self.center removeDeliveredNotificationsWithIdentifiers:ids];
    [self verifyRemoved:ids attempts:3 completion:completion];
}

- (void)verifyRemoved:(NSArray<NSString *> *)ids attempts:(NSUInteger)attempts completion:(void (^)(BOOL))completion {
    NSSet *owned = [NSSet setWithArray:ids];
    [self.center getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> *requests) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *delivered) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    BOOL remains = NO;
                    for (UNNotificationRequest *request in requests) if ([owned containsObject:request.identifier]) remains = YES;
                    for (UNNotification *notice in delivered) if ([owned containsObject:notice.request.identifier]) remains = YES;
                    if (remains && attempts > 1) {
                        [self.center removePendingNotificationRequestsWithIdentifiers:ids];
                        [self.center removeDeliveredNotificationsWithIdentifiers:ids];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                            [self verifyRemoved:ids attempts:attempts - 1 completion:completion];
                        });
                    } else completion(!remains);
                });
            }];
        });
    }];
}

- (void)removeDeliveredIDs:(NSArray<NSString *> *)ids attempts:(NSUInteger)attempts completion:(void (^)(BOOL))completion {
    if (!ids.count) { completion(YES); return; }
    [self.center removeDeliveredNotificationsWithIdentifiers:ids];
    NSSet *owned = [NSSet setWithArray:ids];
    [self.center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *delivered) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL remains = NO;
            for (UNNotification *notice in delivered) if ([owned containsObject:notice.request.identifier]) remains = YES;
            if (remains && attempts > 1) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    [self removeDeliveredIDs:ids attempts:attempts - 1 completion:completion];
                });
            } else completion(!remains);
        });
    }];
}

- (void)clear:(CFReminderJob *)job {
    NSString *scope = job.command[@"scope"];
    NSString *oldScope = self.ledger[@"scope"];
    if (oldScope.length && ![oldScope isEqualToString:scope]) { [self status:job]; return; }
    NSArray *ids = [self.ledger[@"items"] allKeys];
    if (!oldScope.length && ids.count == 0) { [self status:job]; return; }
    // A crash or failed readback during cleanup cannot leave apparently normal reusable consent.
    if (![self saveLedger:@{@"scope": oldScope, @"consent": self.ledger[@"consent"],
        @"items": self.ledger[@"items"], @"recovery": @YES}]) {
        [self finish:job ok:NO code:@"SYSTEM_ERROR" result:nil]; return;
    }
    [self removeIDs:ids completion:^(BOOL removed) {
        if (![self isCurrent:job]) { [self finish:job ok:NO code:@"OPERATION_CANCELLED" result:nil]; return; }
        if (!removed || ![self saveLedger:@{@"scope": @"", @"consent": @NO, @"items": @{}, @"recovery": @NO}]) {
            [self finish:job ok:NO code:@"SYSTEM_ERROR" result:nil]; return;
        }
        [self status:job];
    }];
}

- (void)replace:(CFReminderJob *)job {
    if ([self.ledger[@"recovery"] boolValue]) {
        [self finish:job ok:NO code:@"SYSTEM_ERROR" result:nil]; return;
    }
    if (![self.ledger[@"consent"] boolValue] || ![self.ledger[@"scope"] isEqualToString:job.command[@"scope"]]) {
        [self finish:job ok:NO code:@"PERMISSION_DENIED" result:nil]; return;
    }
    if (!CFNativeReminderBatch(job.command[@"reminders"], NSDate.date.timeIntervalSince1970 * 1000)) {
        [self finish:job ok:NO code:@"INVALID_REQUEST" result:nil]; return;
    }
    [self.center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isCurrent:job]) { [self finish:job ok:NO code:@"OPERATION_CANCELLED" result:nil]; return; }
            if (![[self permission:settings] isEqualToString:@"granted"]) {
                [self finish:job ok:NO code:@"PERMISSION_DENIED" result:nil]; return;
            }
            NSMutableDictionary *desired = [NSMutableDictionary dictionary];
            for (NSDictionary *item in job.command[@"reminders"]) {
                desired[[self identifier:item[@"id"] scope:job.command[@"scope"]]] = item[@"fire_at_ms"];
            }
            NSMutableDictionary *cleanup = [self.ledger[@"items"] mutableCopy];
            [cleanup addEntriesFromDictionary:desired];
            // Persist cleanup IDs BEFORE invoking an asynchronous system add, including partial failures.
            if (![self saveLedger:@{@"scope": job.command[@"scope"], @"consent": @YES, @"items": cleanup, @"recovery": @YES}]) {
                [self finish:job ok:NO code:@"SYSTEM_ERROR" result:nil]; return;
            }
            NSMutableArray *obsolete = [NSMutableArray array];
            for (NSString *key in cleanup) if (!desired[key]) [obsolete addObject:key];
            [self removeIDs:obsolete completion:^(BOOL removed) {
                if (!removed) { [self finish:job ok:NO code:@"SYSTEM_ERROR" result:nil]; return; }
                [self addItems:desired keys:[desired.allKeys sortedArrayUsingSelector:@selector(compare:)]
                    index:0 job:job];
            }];
        });
    }];
}

- (void)abortReplace:(CFReminderJob *)job {
    // No queued replacement starts until every earlier add has returned and these IDs are gone.
    [self removeIDs:[self.ledger[@"items"] allKeys] completion:^(BOOL removed) {
        // Keep the ledger on failure for explicit cleanup/retry; never claim a cleared schedule.
        if (removed) [self saveLedger:@{@"scope": self.ledger[@"scope"], @"consent": self.ledger[@"consent"], @"items": @{}, @"recovery": @NO}];
        [self finish:job ok:NO code:job.epoch != self.epoch || job.cancelled ? @"OPERATION_CANCELLED" : @"SYSTEM_ERROR" result:nil];
    }];
}

- (void)addItems:(NSDictionary *)desired keys:(NSArray<NSString *> *)keys index:(NSUInteger)index job:(CFReminderJob *)job {
    if (![self isCurrent:job]) { [self abortReplace:job]; return; }
    if (index == keys.count) {
        // Delivered CampusFlow notifications are removed when their task's schedule is replaced.
        [self removeDeliveredIDs:desired.allKeys attempts:3 completion:^(BOOL removed) {
            if (!removed || ![self isCurrent:job] ||
                ![self saveLedger:@{@"scope": job.command[@"scope"], @"consent": @YES, @"items": desired, @"recovery": @NO}]) {
                [self abortReplace:job]; return;
            }
            [self finish:job ok:YES code:@"OK" result:@{@"scheduled": @(keys.count), @"mode": @"system", @"limited": @NO}];
        }];
        return;
    }
    NSString *identifier = keys[index];
    NSTimeInterval delay = [desired[identifier] doubleValue] / 1000 - NSDate.date.timeIntervalSince1970;
    if (delay <= 0) { [self abortReplace:job]; return; }
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = @"行简提醒";
    content.body = @"你有一项安排即将开始，打开应用查看。";
    content.sound = UNNotificationSound.defaultSound;
    // No task title, account, endpoint, tokens, transcript or deep-link mutation in userInfo.
    UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:delay repeats:NO];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:trigger];
    [self.center addNotificationRequest:request withCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || ![self isCurrent:job]) { [self abortReplace:job]; return; }
            [self addItems:desired keys:keys index:index + 1 job:job];
        });
    }];
}
@end
