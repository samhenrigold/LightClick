// Runs the argument and environment assembly from VIMSession.m as it was before
// VIMLaunchPlan.swift replaced it, over tests/launch-plan/scenarios.json. Its output
// is tests/launch-plan/expected.json. See scripts/capture-launch-plan-baseline.
#import <Foundation/Foundation.h>
#import "VIMImageSlots.h"
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
static NSDictionary *scenario;
static NSString *VIMOptionPath(NSString *path) {
    return [path stringByReplacingOccurrencesOfString:@"," withString:@",,"];
}
static NSError *VIMSessionError(NSString *text) {
    return [NSError errorWithDomain:@"baseline" code:1 userInfo:@{NSLocalizedDescriptionKey : text}];
}
static NSError *VIMFriendlyDiscImageError(NSString *path, NSError *underlying) { return underlying; }
static NSString *VIMNetworkMACAddress(NSDictionary *c) { return @"52:54:00:11:22:33"; }
static NSString *VIMNetworkMode(NSDictionary *c) { return scenario[@"networkMode"] ?: @"shared"; }
static NSString *VIMAudioSelection(NSDictionary *c, BOOL input) {
    if (c[@"AudioEnabled"] && ![c[@"AudioEnabled"] boolValue])
        return @"disabled";
    return scenario[input ? @"audioIn" : @"audioOut"];
}
static NSUInteger VIMHostOutputSampleRate(NSString *uid) { return 48000; }
static NSUInteger VIMHostInputSampleRate(NSString *uid) { return 44100; }
static NSArray *VIMHostAudioDevices(BOOL input) {
    NSMutableArray *devices = [NSMutableArray new];
    [scenario[@"audioDevices"] enumerateKeysAndObjectsUsingBlock:^(id uid, id name, BOOL *stop) {
      [devices addObject:@{@"UID" : uid, @"Name" : name}];
    }];
    return devices;
}
static NSString *VIMOpticalImageFormat(NSString *path, NSError **error) {
    if ([path containsString:@"missing"]) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT userInfo:nil];
        return nil;
    }
    return [path hasSuffix:@".dmg"] ? @"dmg" : @"raw";
}
@interface FakeMachine : NSObject
@property NSString *name, *guest;
@property NSURL *URL;
@property BOOL preMetalGuest, openGLResearchGuest, passthroughOpenGLEnabled, hasPublishedGuestGraphics;
@end
@implementation FakeMachine
@end
@interface FakeSocketHolder : NSObject
@property id socket;
@property NSString *socketPath;
@property double backingScaleFactor;
@end
@implementation FakeSocketHolder
@end
@interface VIMGuestBootPolicy : NSObject
@end
@implementation VIMGuestBootPolicy
+ (BOOL)readyAtURL:(NSURL *)url guest:(NSString *)guest identifier:(NSString *)identifier {
    return [scenario[@"signatureOnly"] boolValue];
}
@end
@interface VIMAutomaticSetup : NSObject
@end
@implementation VIMAutomaticSetup
+ (NSURL *)configurationMediaForMachine:(id)machine error:(NSError **)error {
    return [scenario[@"setupMedia"] isKindOfClass:NSString.class] ? [NSURL fileURLWithPath:scenario[@"setupMedia"]]
                                                                  : nil;
}
@end
@interface Baseline : NSObject
@property FakeMachine *machine;
@property NSTask *task;
@property NSFileHandle *log;
@property FakeSocketHolder *networkClient, *displayConnection, *window;
@property NSString *runtimeDirectory, *displayMode, *insertedMediaPath, *insertedMediaFormat;
@property BOOL supportsRetinaDisplay, openGLSetupMediaAttached;
@property NSMutableDictionary *additionalMedia;
@property NSMutableSet *imageDevices;
@property NSArray *fakeArguments;
@property NSDictionary *fakeEnvironment;
@end
@implementation Baseline
- (void)cleanUp {
}
- (BOOL)assemble:(NSError **)error {
    NSDictionary *config = scenario[@"config"];
    BOOL appleSilicon = [scenario[@"appleSilicon"] boolValue],
         installerDisplay = [scenario[@"installerDisplay"] boolValue];
    id library = scenario[@"inprocessLibrary"];
    NSString *inprocessLibrary = [library isKindOfClass:NSString.class] ? library : nil;
    BOOL openGLInprocess = inprocessLibrary != nil;
    BOOL mojave = [self.machine.guest isEqual:@"mojave"];
    NSString *helper = @"/Fixture/Runtime/helper", *donor = @"/Fixture/Runtime/donor",
             *llvm = @"/Fixture/Runtime/libLLVM.dylib";
    NSString *bios = @"/Fixture/Runtime/pc-bios", *qemu = @"/usr/bin/true";
    NSString *firmwareCode = @"/Fixture/Runtime/CODE.fd", *firmwareEFI = @"/Fixture/Runtime/EFI.img";
    NSString *qmp = [self.runtimeDirectory stringByAppendingPathComponent:@"control"];
    BOOL packageResearchFirmware =
        self.machine.openGLResearchGuest && ![config[@"FirmwareSource"] isEqual:@"application"];
    NSSize initialPixels = NSMakeSize(1920, 1200);
#include "launch-plan-baseline-body.inc"
    return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool {
        NSArray *scenarios = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])]
                                                             options:0
                                                               error:NULL];
        NSMutableDictionary *output = [NSMutableDictionary new];
        for (NSDictionary *item in scenarios) {
            scenario = item;
            Baseline *b = [Baseline new];
            b.machine = [FakeMachine new];
            b.machine.name = item[@"machineName"];
            b.machine.guest = item[@"guest"];
            b.machine.URL = [NSURL fileURLWithPath:item[@"machinePath"]];
            b.machine.preMetalGuest = [@[
                @"tiger", @"leopard", @"snowleopard", @"lion", @"mountainlion", @"mavericks", @"yosemite", @"elcapitan",
                @"sierra", @"highsierra"
            ] containsObject:item[@"guest"]];
            b.machine.openGLResearchGuest = b.machine.preMetalGuest && [item[@"research"] boolValue];
            b.machine.passthroughOpenGLEnabled = [item[@"config"][@"PassthroughOpenGLEnabled"] boolValue];
            b.machine.hasPublishedGuestGraphics = [item[@"hasGraphics"] boolValue];
            b.runtimeDirectory = @"/Fixture/run";
            b.displayMode = item[@"displayMode"];
            b.supportsRetinaDisplay = [item[@"supportsRetina"] boolValue];
            b.window = [FakeSocketHolder new];
            b.window.backingScaleFactor = [item[@"backingScale"] doubleValue];
            b.displayConnection = [FakeSocketHolder new];
            b.displayConnection.socketPath = @"/Fixture/run/display";
            b.fakeArguments = [@[ @"app" ] arrayByAddingObjectsFromArray:item[@"argv"]];
            b.fakeEnvironment = item[@"inherited"];
            [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"VIMLegacyDisplayRefreshMS" : item[@"refreshMS"]}
                                                           forName:NSRegistrationDomain];
            NSError *error = nil;
            if (![b assemble:&error]) {
                fprintf(stderr, "%s: %s\n", [item[@"name"] UTF8String], error.localizedDescription.UTF8String);
                return 1;
            }
            output[item[@"name"]] = @{@"args" : b.task.arguments, @"env" : b.task.environment};
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:output
                                                       options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys |
                                                               NSJSONWritingWithoutEscapingSlashes
                                                         error:NULL];
        [json writeToFile:@(argv[2]) atomically:YES];
        printf("%lu scenarios\n", (unsigned long)output.count);
    }
    return 0;
}
