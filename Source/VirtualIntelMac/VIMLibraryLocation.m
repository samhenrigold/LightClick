#import "VIMLibraryLocation.h"
#import "VIMAlerts.h"

@implementation VIMLibraryLocation (Interface)
+ (NSImage *)folderIcon {
    return [NSWorkspace.sharedWorkspace iconForFile:self.rootURL.path].copy;
}
+ (void)chooseFromWindow:(NSWindow *)window completion:(void (^)(BOOL))completion {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.canCreateDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.directoryURL = self.rootURL;
    panel.prompt = @"Use This Folder";
    panel.message = @"This folder will contain Machines, Downloads and Installers. An external drive can save space on "
                    @"this Mac. Macs in other libraries stay where they are.";
    void (^selected)(NSModalResponse) = ^(NSModalResponse response) {
      if (response != NSModalResponseOK) {
          completion(NO);
          return;
      }
      NSError *error = nil;
      BOOL changed = [self setURL:panel.URL error:&error];
      if (!changed)
          VIMPresentError(error, window);
      completion(changed);
    };
    if (window)
        [panel beginSheetModalForWindow:window completionHandler:selected];
    else
        [panel beginWithCompletionHandler:selected];
}
@end
