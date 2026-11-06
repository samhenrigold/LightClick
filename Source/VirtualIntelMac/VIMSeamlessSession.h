#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One guest app as a host app, started by its proxy: the app runs the machine with no window and no Dock tile, next to
/// the session process that shows the guest's windows through the proxy. See probes/seamless-apps-design.md.
@interface VIMSeamlessSession : NSObject
/// Before the Dock has seen this app, if `--seamless-session` asked for this.
+ (void)prepareIfRequested;
/// Starts the session process. `finished` runs when it has ended, which is when the machine should shut down.
+ (void)startIfRequested:(void (^)(void))finished;
@end

NS_ASSUME_NONNULL_END
