// Export the original AppKit image catalog without creating a window.
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <copyfile.h>
#include <mach-o/dyld.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <objc/runtime.h>
#include "seamless-session-join.h"
#include "mavericks-named-images.h"
static BOOL referenceActive;
static BOOL appIsActive(id self,SEL cmd){return referenceActive;}
@interface LCReferenceSelectionRow : NSTableRowView
@property BOOL referenceEmphasis;
@end
@implementation LCReferenceSelectionRow
- (BOOL)isEmphasized{return self.referenceEmphasis;}
@end
@interface LCReferenceRows : NSObject <NSTableViewDataSource,NSTableViewDelegate> @end
@implementation LCReferenceRows
- (NSInteger)numberOfRowsInTableView:(NSTableView *)table{return 1;}
- (id)tableView:(NSTableView *)table objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row{return @" ";}
- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row{return [[[NSView alloc]initWithFrame:NSMakeRect(0,0,32,20)]autorelease];}
- (NSTableRowView *)tableView:(NSTableView *)table rowViewForRow:(NSInteger)row{return [[[LCReferenceSelectionRow alloc]initWithFrame:table.bounds]autorelease];}
@end
@interface LCReferenceAppearanceWindow : NSWindow
@property BOOL referenceKey;
@end
@implementation LCReferenceAppearanceWindow
- (BOOL)canBecomeKeyWindow{return YES;}
- (BOOL)canBecomeMainWindow{return YES;}
- (BOOL)isKeyWindow{return self.referenceKey;}
- (BOOL)isMainWindow{return self.referenceKey;}
- (BOOL)_hasKeyAppearance{return self.referenceKey;}
- (NSRect)constrainFrameRect:(NSRect)frame toScreen:(NSScreen *)screen{return frame;}
@end
int main(int argc,char **argv) {@autoreleasepool {
    if(argc!=2)return 64;
    if(geteuid()==0) {
        struct stat console;if(stat("/dev/console",&console)||console.st_uid<501)return 75;
        char command[96];snprintf(command,sizeof(command),"/usr/bin/pgrep -x -U %u Finder",console.st_uid);
        FILE *pipe=popen(command,"r");int finder=0;if(pipe){fscanf(pipe,"%d",&finder);pclose(pipe);}if(!finder)return 75;
        char self[4096],directory[]="/tmp/MavericksCatalog.XXXXXX",copy[4096],user[24];uint32_t length=sizeof(self);
        if(_NSGetExecutablePath(self,&length)||!mkdtemp(directory))return 74;chmod(directory,0755);snprintf(copy,sizeof(copy),"%s/export",directory);snprintf(user,sizeof(user),"#%u",console.st_uid);
        if(copyfile(self,copy,NULL,COPYFILE_DATA)||chmod(copy,0755))return 74;
        pid_t child=fork();if(child==0){if(join_session_of(finder))_exit(76);execl("/usr/bin/sudo","sudo","-n","-u",user,copy,argv[1],NULL);_exit(127);}
        int status=1;waitpid(child,&status,0);unlink(copy);rmdir(directory);return WIFEXITED(status)?WEXITSTATUS(status):77;
    }
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];[NSApp activateIgnoringOtherApps:YES];
    method_setImplementation(class_getInstanceMethod([NSApplication class],@selector(isActive)),(IMP)appIsActive);
    NSString *directory=@(argv[1]);
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    NSMutableArray *names=[[[NSJSONSerialization JSONObjectWithData:[sourceNamesJSON dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] mutableCopy] autorelease];
    [names addObject:@"NSAppleMenuImage"];
    NSMutableDictionary *additional=[NSMutableDictionary dictionary];
    NSMutableArray *windows=[NSMutableArray array];
    for(NSNumber *active in @[@YES,@NO]) {
        LCReferenceAppearanceWindow *window=[[[LCReferenceAppearanceWindow alloc] initWithContentRect:NSMakeRect(-10000,-10000,32,20) styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO] autorelease];window.referenceKey=active.boolValue;
        NSTableView *table=[[[NSTableView alloc] initWithFrame:NSMakeRect(0,0,32,20)] autorelease];table.headerView=nil;table.rowHeight=20;table.intercellSpacing=NSZeroSize;
        NSTableColumn *column=[[[NSTableColumn alloc] initWithIdentifier:@"reference"] autorelease];column.width=32;[table addTableColumn:column];
        LCReferenceRows *rows=[LCReferenceRows new];table.dataSource=rows;table.delegate=rows;table.selectionHighlightStyle=NSTableViewSelectionHighlightStyleSourceList;
        [window.contentView addSubview:table];[windows addObject:window];[table reloadData];[table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [window orderFront:nil];[window makeKeyWindow];[window makeMainWindow];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.2]];
        NSTableRowView *row=[table rowViewAtRow:0 makeIfNecessary:YES];if(!row){fputs("Reference source-list row was not created\n",stderr);return 78;}row.selectionHighlightStyle=NSTableViewSelectionHighlightStyleSourceList;row.selected=YES;row.emphasized=active.boolValue;
        NSString *name=active.boolValue?@"LCMavericksSourceListActive":@"LCMavericksSourceListInactive";
        NSImage *image=[NSImage imageWithSize:NSMakeSize(32,20) flipped:YES drawingHandler:^BOOL(NSRect rect){referenceActive=active.boolValue;if(active.boolValue){[window makeKeyWindow];[window makeMainWindow];[window makeFirstResponder:table];}else [window resignKeyWindow];row.emphasized=active.boolValue;[(LCReferenceSelectionRow *)row setReferenceEmphasis:active.boolValue];[row drawSelectionInRect:rect];return YES;}];
        additional[name]=image;[names addObject:name];
    }
    NSMutableArray *manifest=[NSMutableArray array],*missing=[NSMutableArray array];
    for(NSString *fallback in names) {
        NSString *symbol=[@"NSImageName" stringByAppendingString:[fallback substringFromIndex:2]];
        NSString **constant=(NSString **)dlsym(RTLD_DEFAULT,symbol.UTF8String);NSString *name=constant?*constant:fallback;
        NSImage *image=additional[name]?:[NSImage imageNamed:name];if(!image){[missing addObject:name];continue;}
        NSSize logical=image.size;if(logical.width<=0 || logical.height<=0 || logical.width>1024 || logical.height>1024){[missing addObject:name];continue;}
        NSMutableArray *files=[NSMutableArray array];
        for(int scale=1;scale<=2;scale++) {
            size_t width=ceil(logical.width*scale),height=ceil(logical.height*scale);
            CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef context=CGBitmapContextCreate(NULL,width,height,8,width*4,cs,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);CGColorSpaceRelease(cs);
            CGContextScaleCTM(context,scale,scale);
            [NSGraphicsContext saveGraphicsState];[NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithGraphicsPort:context flipped:NO]];
            [image drawInRect:NSMakeRect(0,0,logical.width,logical.height) fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1 respectFlipped:NO hints:nil];
            [NSGraphicsContext restoreGraphicsState];CGImageRef cg=CGBitmapContextCreateImage(context);
            if([name hasPrefix:@"LCMavericksSourceList"]){unsigned char *pixels=CGBitmapContextGetData(context);BOOL visible=NO;for(size_t i=0;i<width*height;i++)if(pixels[i*4+3]){visible=YES;break;}if(!visible){fputs("Reference source-list selection rendered empty\n",stderr);return 79;}}
            NSBitmapImageRep *rep=[[[NSBitmapImageRep alloc] initWithCGImage:cg] autorelease];rep.size=logical;
            NSString *file=[name stringByAppendingString:scale==1?@".png":@"@2x.png"];
            [[rep representationUsingType:NSPNGFileType properties:@{}] writeToFile:[directory stringByAppendingPathComponent:file] atomically:YES];
            [files addObject:file];CGImageRelease(cg);CGContextRelease(context);
        }
        [manifest addObject:@{@"name":name,@"template":@(image.isTemplate),@"width":@(logical.width),@"height":@(logical.height),@"files":files}];
    }
    [[NSJSONSerialization dataWithJSONObject:@{@"images":manifest,@"missing":missing} options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:[directory stringByAppendingPathComponent:@"manifest.json"] atomically:YES];
    puts([[NSString stringWithFormat:@"{\"images\":%lu,\"missing\":%lu}",(unsigned long)manifest.count,(unsigned long)missing.count] UTF8String]);
    return 0;
}}
