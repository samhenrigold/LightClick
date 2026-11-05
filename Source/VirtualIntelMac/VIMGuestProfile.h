#pragma once
#import <Foundation/Foundation.h>

// One row per supported guest, oldest first, so adding or correcting a guest is
// one edit. Plain C and Foundation: standalone test probes compile these callers
// with clang alone, without the app's Swift. Guest-specific workarounds with a
// single caller stay with that caller.
typedef NS_OPTIONS(uint32_t, VIMGuestTraits) {
    /// Desktop graphics architecture, deliberately independent of whether the
    /// account/installer automation backend supports this guest version.
    VIMGuestTraitOpenGLDesktop = 1<<0,
    VIMGuestTraitParavirtualizedGraphics = 1<<1,
    /// Installs from a whole restore DVD, not an Install app.
    VIMGuestTraitRestoreDVD = 1<<2,
    /// These systems have no distinct backing-pixel/logical-point mode.
    VIMGuestTraitNoBackingScale = 1<<3,
    /// Reaches host files over SMB1, which macOS only offers as Windows File Sharing.
    VIMGuestTraitWindowsFileSharing = 1<<4,
    VIMGuestTraitUSB2StoragePassthrough = 1<<5,
    /// El Capitan introduced the native USBHost xHCI driver used for extra images.
    VIMGuestTraitUSB3Images = 1<<6,
    VIMGuestTraitLegacyTabletCalibration = 1<<7,
    VIMGuestTraitNoRoundelArtwork = 1<<8,
};

typedef struct {
    NSString *__unsafe_unretained identifier,*__unsafe_unretained family,*__unsafe_unretained name,*__unsafe_unretained version;
    VIMGuestTraits traits;
} VIMGuestProfile;

#define VIM_GUEST_CLASSIC (VIMGuestTraitOpenGLDesktop|VIMGuestTraitRestoreDVD|VIMGuestTraitNoBackingScale|VIMGuestTraitWindowsFileSharing|VIMGuestTraitUSB2StoragePassthrough|VIMGuestTraitLegacyTabletCalibration|VIMGuestTraitNoRoundelArtwork)
static const VIMGuestProfile VIMGuestProfiles[]={
    {@"tiger",@"Mac OS X",@"Tiger",@"10.4",VIM_GUEST_CLASSIC},
    {@"leopard",@"Mac OS X",@"Leopard",@"10.5",VIM_GUEST_CLASSIC},
    {@"snowleopard",@"Mac OS X",@"Snow Leopard",@"10.6",VIM_GUEST_CLASSIC},
    {@"lion",@"Mac OS X",@"Lion",@"10.7",VIMGuestTraitOpenGLDesktop|VIMGuestTraitLegacyTabletCalibration},
    {@"mountainlion",@"OS X",@"Mountain Lion",@"10.8",VIMGuestTraitOpenGLDesktop|VIMGuestTraitLegacyTabletCalibration},
    {@"mavericks",@"OS X",@"Mavericks",@"10.9",VIMGuestTraitOpenGLDesktop|VIMGuestTraitLegacyTabletCalibration},
    {@"yosemite",@"OS X",@"Yosemite",@"10.10",VIMGuestTraitOpenGLDesktop},
    {@"elcapitan",@"OS X",@"El Capitan",@"10.11",VIMGuestTraitOpenGLDesktop|VIMGuestTraitUSB3Images},
    {@"sierra",@"macOS",@"Sierra",@"10.12",VIMGuestTraitOpenGLDesktop|VIMGuestTraitUSB3Images},
    {@"highsierra",@"macOS",@"High Sierra",@"10.13",VIMGuestTraitOpenGLDesktop|VIMGuestTraitUSB3Images},
    {@"mojave",@"macOS",@"Mojave",@"10.14",VIMGuestTraitParavirtualizedGraphics|VIMGuestTraitUSB3Images},
    {@"catalina",@"macOS",@"Catalina",@"10.15",VIMGuestTraitParavirtualizedGraphics|VIMGuestTraitUSB3Images},
    {@"bigsur",@"macOS",@"Big Sur",@"11",VIMGuestTraitParavirtualizedGraphics|VIMGuestTraitUSB3Images},
};
#undef VIM_GUEST_CLASSIC

/// Reports and saved plists are untrusted, so `guest` may be nil or not a string.
NS_INLINE const VIMGuestProfile *VIMGuestProfileFor(id guest) {
    for(size_t index=0;index<sizeof(VIMGuestProfiles)/sizeof(VIMGuestProfiles[0]);index++)
        if([VIMGuestProfiles[index].identifier isEqual:guest])return &VIMGuestProfiles[index];
    return NULL;
}
NS_INLINE NSArray<NSString *> *VIMGuestIdentifiers(void) {
    NSMutableArray *identifiers=[NSMutableArray new];
    for(size_t index=0;index<sizeof(VIMGuestProfiles)/sizeof(VIMGuestProfiles[0]);index++)[identifiers addObject:VIMGuestProfiles[index].identifier];
    return identifiers;
}
NS_INLINE BOOL VIMGuestIsSupported(id guest) {return VIMGuestProfileFor(guest)!=NULL;}
NS_INLINE BOOL VIMGuestHasTrait(id guest,VIMGuestTraits trait) {
    const VIMGuestProfile *profile=VIMGuestProfileFor(guest);
    return profile&&(profile->traits&trait);
}
NS_INLINE NSString *VIMGuestVersion(id guest) {
    const VIMGuestProfile *profile=VIMGuestProfileFor(guest);
    return profile?profile->version:nil;
}
/// "OS X Mavericks 10.9"
NS_INLINE NSString *VIMGuestSystemName(id guest) {
    const VIMGuestProfile *profile=VIMGuestProfileFor(guest);
    return profile?[NSString stringWithFormat:@"%@ %@ %@",profile->family,profile->name,profile->version]:nil;
}
