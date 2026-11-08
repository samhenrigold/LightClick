// Apply the new process environment to existing GUI apps using their normal quit path.
#import <Cocoa/Cocoa.h>
#include <unistd.h>
int main(void){@autoreleasepool {
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];[NSApp finishLaunching];
    NSWorkspace *workspace=[NSWorkspace sharedWorkspace];NSString *front=workspace.frontmostApplication.bundleIdentifier;
    NSArray *apps=[[workspace.runningApplications copy] autorelease];NSMutableArray *reopened=[NSMutableArray array],*pending=[NSMutableArray array];
    for(NSRunningApplication *app in apps) {
        if(app.processIdentifier==getpid() || app.activationPolicy!=NSApplicationActivationPolicyRegular || !app.bundleURL || [app.bundleIdentifier isEqual:@"com.apple.finder"])continue;
        NSURL *url=app.bundleURL;NSString *identifier=app.bundleIdentifier?:app.localizedName;
        // A normal quit leaves document/save/download decisions with the application; never force it.
        if(![app terminate]){[pending addObject:identifier];continue;}
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
        while(!app.isTerminated && [deadline timeIntervalSinceNow]>0)[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
        if(!app.isTerminated){[pending addObject:identifier];continue;}
        NSRunningApplication *replacement=[workspace launchApplicationAtURL:url options:NSWorkspaceLaunchWithoutActivation configuration:@{} error:NULL];
        if(replacement){[reopened addObject:identifier];if([identifier isEqual:front])[replacement activateWithOptions:NSApplicationActivateIgnoringOtherApps];}
    }
    puts([[[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:@{@"reopened":reopened,@"pendingApplicationQuit":pending} options:0 error:NULL] encoding:NSUTF8StringEncoding] autorelease] UTF8String]);return 0;
}}
