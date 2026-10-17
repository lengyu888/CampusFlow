#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef void (^CFReminderReply)(BOOL ok, NSString *code, NSDictionary * _Nullable result);
// One process-wide ledger / queue, even if another ArkUI-X ability is opened.
@interface CFReminderService : NSObject
+ (instancetype)sharedService;
- (void)handle:(NSDictionary *)command completion:(CFReminderReply)completion;
@end
NS_ASSUME_NONNULL_END
