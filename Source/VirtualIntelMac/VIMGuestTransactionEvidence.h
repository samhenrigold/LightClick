#import <Foundation/Foundation.h>
#import "MachineKit-Swift.h"

// The evidence checks live in the MachineKit package. An old *verified* transaction is not an uncertain new write
// merely because a macOS update removed its legacy /var/tmp verifier. Never replay that write.
static inline BOOL VIMVerifiedInstallationSuperseded(NSDictionary *state, NSDictionary *report) {
    return [VIMMachineModel verifiedInstallationSuperseded:state report:report];
}
