// Pins VIMGuestProfile.h to the literal lists it replaced in the app.
#import "VIMOSNaming.h"
#import "VIMImageSlots.h"
#import "VIMLegacyTabletPolicy.h"
static int failures;
static void check(const char *label, VIMGuestTraits trait, NSArray *expected) {
    NSMutableArray *candidates = [VIMGuestIdentifiers() mutableCopy];
    [candidates addObjectsFromArray:@[ @"snowleopard ", @"Tiger", @"" ]];
    for (id guest in candidates)
        if (VIMGuestHasTrait(guest, trait) != [expected containsObject:guest]) {
            printf("FAIL: %s for %s\n", label, [guest UTF8String]);
            failures++;
        }
}
int main(void) {
    @autoreleasepool {
        NSArray *classic = @[ @"tiger", @"leopard", @"snowleopard" ], *metal = @[ @"mojave", @"catalina", @"bigsur" ];
        NSArray *all = @[
            @"tiger", @"leopard", @"snowleopard", @"lion", @"mountainlion", @"mavericks", @"yosemite", @"elcapitan",
            @"sierra", @"highsierra", @"mojave", @"catalina", @"bigsur"
        ];
        if (![VIMGuestIdentifiers() isEqual:all]) {
            puts("FAIL: identifiers or their order");
            failures++;
        }
        check("OpenGL desktop", VIMGuestTraitOpenGLDesktop, [all subarrayWithRange:NSMakeRange(0, 10)]);
        check("paravirtualized graphics", VIMGuestTraitParavirtualizedGraphics, metal);
        check("restore DVD", VIMGuestTraitRestoreDVD, classic);
        check("no backing scale", VIMGuestTraitNoBackingScale, classic);
        check("Windows file sharing", VIMGuestTraitWindowsFileSharing, classic);
        check("USB2 storage", VIMGuestTraitUSB2StoragePassthrough, classic);
        check("no roundel", VIMGuestTraitNoRoundelArtwork, classic);
        check("USB3 images", VIMGuestTraitUSB3Images,
              @[ @"elcapitan", @"sierra", @"highsierra", @"mojave", @"catalina", @"bigsur" ]);
        check("legacy tablet", VIMGuestTraitLegacyTabletCalibration,
              @[ @"tiger", @"leopard", @"snowleopard", @"lion", @"mountainlion", @"mavericks" ]);
        NSDictionary *systems = @{
            @"tiger" : @"Mac OS X Tiger 10.4",
            @"leopard" : @"Mac OS X Leopard 10.5",
            @"snowleopard" : @"Mac OS X Snow Leopard 10.6",
            @"lion" : @"Mac OS X Lion 10.7",
            @"mountainlion" : @"OS X Mountain Lion 10.8",
            @"mavericks" : @"OS X Mavericks 10.9",
            @"yosemite" : @"OS X Yosemite 10.10",
            @"elcapitan" : @"OS X El Capitan 10.11",
            @"sierra" : @"macOS Sierra 10.12",
            @"highsierra" : @"macOS High Sierra 10.13",
            @"mojave" : @"macOS Mojave 10.14",
            @"catalina" : @"macOS Catalina 10.15",
            @"bigsur" : @"macOS Big Sur 11"
        };
        NSDictionary *versions = @{
            @"tiger" : @"10.4",
            @"leopard" : @"10.5",
            @"snowleopard" : @"10.6",
            @"lion" : @"10.7",
            @"mountainlion" : @"10.8",
            @"mavericks" : @"10.9",
            @"yosemite" : @"10.10",
            @"elcapitan" : @"10.11",
            @"sierra" : @"10.12",
            @"highsierra" : @"10.13",
            @"mojave" : @"10.14",
            @"catalina" : @"10.15",
            @"bigsur" : @"11"
        };
        NSArray *macOSX = @[ @"tiger", @"leopard", @"snowleopard", @"lion" ],
                *osX = @[ @"mountainlion", @"mavericks", @"yosemite", @"elcapitan" ];
        for (NSString *guest in all) {
            NSString *family = [macOSX containsObject:guest] ? @"Mac OS X"
                               : [osX containsObject:guest]  ? @"OS X"
                                                             : @"macOS";
            if (![VIMGuestSystemName(guest) isEqual:systems[guest]] ||
                ![VIMGuestVersion(guest) isEqual:versions[guest]] || ![VIMOperatingSystemName(guest) isEqual:family]) {
                printf("FAIL: names for %s\n", guest.UTF8String);
                failures++;
            }
        }
        // Reports are untrusted: anything that isn't a known identifier is simply unsupported.
        for (id odd in @[ @1, @[], @{}, @"windows" ])
            if (VIMGuestIsSupported(odd) || VIMGuestSystemName(odd) || VIMGuestHasTrait(odd, VIMGuestTraitRestoreDVD)) {
                puts("FAIL: odd value accepted");
                failures++;
            }
        if (VIMGuestIsSupported(nil) || VIMGuestUsesOpenGLDesktop(nil)) {
            puts("FAIL: nil accepted");
            failures++;
        }
        if (![VIMOperatingSystemName(nil) isEqual:@"macOS"]) {
            puts("FAIL: unknown family");
            failures++;
        }
        if (![VIMImageUSBBus(@"sierra") isEqual:@"xhci.0"] || VIMImageUSBPort(@"lion", 0) != 3 ||
            !VIMUsesLegacyTabletCalibration(@"mavericks") || VIMUsesLegacyTabletCalibration(@"yosemite")) {
            puts("FAIL: wrappers");
            failures++;
        }
        puts(failures ? "FAIL: guest profile" : "PASS: guest profile matches every list it replaced");
        return failures ? 1 : 0;
    }
}
