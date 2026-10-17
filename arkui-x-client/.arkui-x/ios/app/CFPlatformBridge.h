#import <libarkui_ios/BridgePlugin.h>

NS_ASSUME_NONNULL_BEGIN
@interface CFPlatformBridge : BridgePlugin
- (instancetype)initWithManager:(BridgePluginManager *)manager;
- (NSString *)dispatch:(NSString *)commandJSON;
- (void)stopVoiceForBackground;
@end
NS_ASSUME_NONNULL_END
