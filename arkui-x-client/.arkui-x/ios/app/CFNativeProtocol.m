#import "CFNativeProtocol.h"
#import <CoreFoundation/CoreFoundation.h>
#import <math.h>

BOOL CFNativeIdentifier(id value, NSUInteger maximum) {
    if (![value isKindOfClass:NSString.class] || [value length] == 0 || [value length] > maximum) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static BOOL CFNativeNumber(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID();
}

BOOL CFNativeReminderBatch(id items, NSTimeInterval nowMS) {
    if (![items isKindOfClass:NSArray.class] || [items count] > 60) return NO;
    NSMutableSet *ids = [NSMutableSet set];
    for (id item in items) {
        if (![item isKindOfClass:NSDictionary.class] || !CFNativeIdentifier(item[@"id"], 180)) return NO;
        id time = item[@"fire_at_ms"];
        if (!CFNativeNumber(time)) return NO;
        double value = [time doubleValue];
        if (!isfinite(value) || floor(value) != value || value <= nowMS ||
            value > nowMS + 366.0 * 24 * 60 * 60 * 1000 || [ids containsObject:item[@"id"]]) return NO;
        [ids addObject:item[@"id"]];
    }
    return YES;
}

NSDictionary *CFNativeCommand(NSString *json, NSTimeInterval nowMS) {
    if (![json isKindOfClass:NSString.class] || json.length > 100000) return nil;
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    id command = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![command isKindOfClass:NSDictionary.class] || !CFNativeNumber(command[@"v"]) ||
        [command[@"v"] doubleValue] != 1 || !CFNativeIdentifier(command[@"request_id"], 128)) return nil;
    NSString *op = command[@"op"];
    NSSet *ops = [NSSet setWithArray:@[@"capabilities", @"recognition.start", @"recognition.finish",
        @"recognition.cancel", @"speech.start", @"speech.stop", @"voice.dispose", @"reminders.status",
        @"reminders.authorize", @"reminders.replace", @"reminders.clear"]];
    if (![op isKindOfClass:NSString.class] || ![ops containsObject:op]) return nil;
    if ([op hasPrefix:@"recognition."] || [op isEqualToString:@"speech.start"]) {
        if (!CFNativeIdentifier(command[@"operation_id"], 128)) return nil;
    } else if (command[@"operation_id"] && !CFNativeIdentifier(command[@"operation_id"], 128)) return nil;
    if ([op isEqualToString:@"speech.start"]) {
        id text = command[@"text"];
        if (![text isKindOfClass:NSString.class] || [text length] > 32000 ||
            [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length] == 0) return nil;
    }
    if ([op hasPrefix:@"reminders."] && ![op isEqualToString:@"reminders.status"]) {
        id scope = command[@"scope"];
        if (![scope isKindOfClass:NSString.class] || [scope length] == 0 || [scope length] > 512 ||
            [scope rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    }
    if ([op isEqualToString:@"reminders.replace"] && !CFNativeReminderBatch(command[@"reminders"], nowMS)) return nil;
    return command;
}
