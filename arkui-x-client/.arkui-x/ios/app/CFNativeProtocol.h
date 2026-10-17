#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Wire v1 validation is shared by dispatch and delayed reminder queue execution.
FOUNDATION_EXPORT BOOL CFNativeIdentifier(id value, NSUInteger maximum);
FOUNDATION_EXPORT NSDictionary * _Nullable CFNativeCommand(NSString *json, NSTimeInterval nowMS);
FOUNDATION_EXPORT BOOL CFNativeReminderBatch(id items, NSTimeInterval nowMS);
NS_ASSUME_NONNULL_END
