// Passive inspection of the native Mavericks shell in a disposable reference.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <sys/sysctl.h>
extern int CUIDraw(void *,CGRect,CGContextRef,CFDictionaryRef,CFDictionaryRef *);
static NSMutableArray *menuDraws;
static __thread BOOL inside;
static NSString *directory(void){return @"/tmp/MavericksReferenceInspector";}
static void png(CGImageRef image,NSString *path){NSBitmapImageRep *rep=[[[NSBitmapImageRep alloc]initWithCGImage:image]autorelease];[[rep representationUsingType:NSPNGFileType properties:@{}]writeToFile:path atomically:YES];}
static int inspectDraw(void *renderer,CGRect rect,CGContextRef context,CFDictionaryRef options,CFDictionaryRef *result){
    int status=CUIDraw(renderer,rect,context,options,result);
    if(inside)return status;inside=YES;
    @try{
        NSDictionary *p=(NSDictionary *)options;NSString *description=p.description;
        if([description rangeOfString:@"Menu"options:NSCaseInsensitiveSearch].location!=NSNotFound||[description rangeOfString:@"Apple"options:NSCaseInsensitiveSearch].location!=NSNotFound){
            if(!menuDraws)menuDraws=[NSMutableArray new];
            if(menuDraws.count<64){NSMutableDictionary *row=[NSMutableDictionary dictionaryWithDictionary:@{@"parameters":description,@"rect":NSStringFromRect(NSRectFromCGRect(rect))}];
                for(id key in p){id value=p[key];if(value&&CFGetTypeID((CFTypeRef)value)==CGImageGetTypeID()){
                    NSString *name=[NSString stringWithFormat:@"%@-image-%lu.png",[NSProcessInfo processInfo].processName,(unsigned long)menuDraws.count];png((CGImageRef)value,[directory()stringByAppendingPathComponent:name]);row[@"image"]=name;
                }}[menuDraws addObject:row];
            }
        }
    }@catch(id exception){}@finally{inside=NO;}return status;
}
static NSDictionary *fontInfo(NSFont *font){return font?@{@"name":font.fontName,@"size":@(font.pointSize)}:@{};}
static NSDictionary *tree(NSView *view,int depth){
    if(!view||depth>15)return @{};NSMutableDictionary *r=[NSMutableDictionary dictionaryWithDictionary:@{@"class":NSStringFromClass(view.class),@"frame":NSStringFromRect(view.frame)}];
    if([view isKindOfClass:[NSTextField class]]){r[@"font"]=fontInfo([(NSTextField *)view font]);r[@"color"]=[[(NSTextField *)view textColor]description]?:@"";}
    if([view isKindOfClass:[NSTableView class]]){NSTableView *table=(NSTableView *)view;r[@"table"]=@{@"rowHeight":@(table.rowHeight),@"rowSizeStyle":@(table.rowSizeStyle),@"selectionStyle":@(table.selectionHighlightStyle),@"intercell":NSStringFromSize(table.intercellSpacing)};}
    if([view isKindOfClass:[NSScroller class]]){NSScroller *s=(NSScroller *)view;r[@"scroller"]=@{@"style":@(s.scrollerStyle),@"controlSize":@(s.controlSize),@"knobStyle":@(s.knobStyle)};}
    NSMutableArray *children=[NSMutableArray array];for(NSView *child in view.subviews)[children addObject:tree(child,depth+1)];r[@"children"]=children;return r;
}
static void report(void){
    NSMutableArray *windows=[NSMutableArray array];for(NSWindow *window in NSApp.windows){if([NSStringFromClass(window.class)isEqual:@"TDesktopWindow"])continue;[windows addObject:@{@"class":NSStringFromClass(window.class),@"frame":NSStringFromRect(window.frame),@"view":tree(window.contentView.superview,0)}];}
    NSDictionary *report=@{@"process":[NSProcessInfo processInfo].processName,@"systemFont":fontInfo([NSFont systemFontOfSize:0]),@"menuFont":fontInfo([NSFont menuBarFontOfSize:0]),@"windows":windows,@"menuDraws":menuDraws?:@[]};
    [[NSJSONSerialization dataWithJSONObject:report options:0 error:NULL]writeToFile:[directory()stringByAppendingPathComponent:[[NSProcessInfo processInfo].processName stringByAppendingString:@".json"]]atomically:YES];
}
__attribute__((constructor))static void initializeInspector(void){char release[32]={0};size_t size=sizeof(release);sysctlbyname("kern.osrelease",release,&size,NULL,0);if(atoi(release)!=13)return;
    NSString *name=[NSProcessInfo processInfo].processName;if(![@[@"Finder",@"SystemUIServer",@"System Preferences",@"Spotlight"]containsObject:name])return;
    [[NSFileManager defaultManager]createDirectoryAtPath:directory()withIntermediateDirectories:YES attributes:nil error:NULL];
    for(int second=3;second<=63;second+=20)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,second*NSEC_PER_SEC),dispatch_get_main_queue(),^{report();});
}
__attribute__((used))static struct{const void *replacement,*original;} interpose __attribute__((section("__DATA,__interpose")))={(const void *)inspectDraw,(const void *)CUIDraw};
