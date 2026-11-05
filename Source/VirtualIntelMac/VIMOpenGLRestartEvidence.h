#pragma once
#import <Foundation/Foundation.h>
#import "MachineKit-Swift.h"

// The evidence checks live in the MachineKit package.
static inline BOOL VIMOpenGLInitialGraphicsCanResume(NSDictionary *report, NSString *machine, NSString *volume,
                                                     BOOL installing, BOOL systemMatches) {
    return [VIMMachineModel openGLInitialGraphicsCanResumeWithReport:report
                                                             machine:machine
                                                              volume:volume
                                                          installing:installing
                                                       systemMatches:systemMatches];
}

static inline BOOL VIMOpenGLBundledSupportMatches(NSString *guest, NSDictionary *report, NSDictionary *expected) {
    return [VIMMachineModel openGLBundledSupportMatchesForGuest:guest report:report expected:expected];
}

static inline BOOL VIMOpenGLGraphicsNeedsRestart(NSDictionary *report, NSDictionary *restart, NSString *boot) {
    return [VIMMachineModel openGLGraphicsNeedsRestartWithReport:report restart:restart boot:boot];
}
