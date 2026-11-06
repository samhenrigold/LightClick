// The Objective-C the app's Swift calls. Not VIMLibraryLocation.h or the other headers that import a package's
// generated header: Swift gets those classes from the package itself, under their Swift names.
#import "VIMAlerts.h"
#import "VIMAutomaticSetup.h"
#import "VIMGuestFiles.h"
#import "VIMHostAudio.h"
#import "VIMHostSupport.h"
#import "VIMHostUSB.h"
#import "VIMImageSlots.h"
#import "VIMInstallerAssembly.h"
#import "VIMMachine.h"
#import "VIMNetworkDefaults.h"
#import "VIMSMBService.h"
#import "VIMSessionPrivate.h"
#import "VIMSettingsIcon.h"
#import "VIMUSBClient.h"

@interface NSTextField (VIMGuestPasswordAutofill)
- (void)_setPasswordAutofillEnabled:(BOOL)enabled;
@end
