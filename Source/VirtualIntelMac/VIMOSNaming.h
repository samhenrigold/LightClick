#import <Foundation/Foundation.h>
#import "VIMGuestProfile.h"
NS_INLINE BOOL VIMGuestUsesOpenGLDesktop(NSString *guest) {
    return VIMGuestHasTrait(guest, VIMGuestTraitOpenGLDesktop);
}
NS_INLINE NSString *VIMOperatingSystemName(NSString *guest) {
    const VIMGuestProfile *profile = VIMGuestProfileFor(guest);
    return profile ? profile->family : @"macOS";
}
