#pragma once
// Whose desktop lets --finish-first-login end. A person can finish Setup
// Assistant with their own account while automatic setup prepares its own, so
// the created account may never be the one at the desktop.
#include <stdbool.h>
#include <string.h>
#include <sys/types.h>

typedef enum { VIMFirstDesktopWaiting, VIMFirstDesktopCreatedAccount, VIMFirstDesktopOtherUser } VIMFirstDesktopOwner;

static inline VIMFirstDesktopOwner VIMFirstDesktopOwnerFor(uid_t createdUID, const char *createdName, uid_t consoleUID,
                                                           const char *consoleName, const char *directoryName,
                                                           bool handoffArmed, bool desktopRunning) {
    if (!desktopRunning || !consoleName)
        return VIMFirstDesktopWaiting;
    bool sameUID = consoleUID == createdUID, sameName = !strcmp(consoleName, createdName);
    if (sameUID || sameName)
        return sameUID && sameName ? VIMFirstDesktopCreatedAccount : VIMFirstDesktopWaiting;
    // Only a real local user, and only once the whole handoff was written, so
    // an interrupted account transaction can't be declared finished here.
    bool realUser = consoleUID >= 501 && directoryName && !strcmp(consoleName, directoryName);
    return realUser && handoffArmed ? VIMFirstDesktopOtherUser : VIMFirstDesktopWaiting;
}
