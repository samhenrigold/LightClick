#import <Foundation/Foundation.h>
#import "../tools/modern-first-login.h"
static VIMFirstDesktopOwner Owner(uid_t uid, const char *name, const char *directory, bool armed, bool desktop) {
    return VIMFirstDesktopOwnerFor(502, "tester", uid, name, directory, armed, desktop);
}
int main(void) {
    @autoreleasepool {
        NSCAssert(Owner(502, "tester", "tester", true, true) == VIMFirstDesktopCreatedAccount, @"Created account");
        NSCAssert(Owner(502, "tester", "tester", false, true) == VIMFirstDesktopCreatedAccount,
                  @"The created account's own desktop never needed the armed phase");
        NSCAssert(Owner(501, "person", "person", true, true) == VIMFirstDesktopOtherUser,
                  @"Another real user's desktop doesn't block setup");
        NSCAssert(Owner(501, "person", "person", false, true) == VIMFirstDesktopWaiting,
                  @"An unfinished account transaction isn't finished by someone else's desktop");
        NSCAssert(Owner(501, "person", "person", true, false) == VIMFirstDesktopWaiting,
                  @"Setup Assistant or a half-started desktop isn't a desktop");
        NSCAssert(Owner(502, "person", "person", true, true) == VIMFirstDesktopWaiting,
                  @"A name change on the created UID is neither account");
        NSCAssert(Owner(501, "tester", "tester", true, true) == VIMFirstDesktopWaiting,
                  @"The created name on another UID is neither account");
        NSCAssert(Owner(501, "person", "other", true, true) == VIMFirstDesktopWaiting,
                  @"The console name must match the directory");
        NSCAssert(Owner(501, "person", NULL, true, true) == VIMFirstDesktopWaiting, @"Unknown to the directory");
        NSCAssert(Owner(0, "root", "root", true, true) == VIMFirstDesktopWaiting, @"Root isn't a person's desktop");
        NSCAssert(Owner(0, "loginwindow", NULL, true, true) == VIMFirstDesktopWaiting, @"Nobody is signed in");
        NSCAssert(Owner(248, "_mbsetupuser", "_mbsetupuser", true, true) == VIMFirstDesktopWaiting,
                  @"Setup Assistant's service user isn't a person");
        NSCAssert(Owner(0, NULL, NULL, true, true) == VIMFirstDesktopWaiting, @"No console session");
        puts("PASS: first desktop ownership");
    }
    return 0;
}
