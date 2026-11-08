// Test the original renderer alongside modern AppKit in a separate process first.
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <CommonCrypto/CommonDigest.h>
typedef int (*Draw)(void *,CGRect,CGContextRef,CFDictionaryRef,CFDictionaryRef *);
static id constant(void *handle,const char *name) {id *value=dlsym(handle,name);return value?*value:nil;}
int main(int argc,char **argv) {@autoreleasepool {
    [NSApplication sharedApplication];
    if(argc>1&&!strcmp(argv[1],"--runtime")){
        NSMutableDictionary *report=[NSMutableDictionary dictionary];
        for(NSString *name in @[@"NSImage",@"NSCoreUIImageRep",@"NSAppearance",@"NSTableCellView",@"NSVisualEffectView"]){Class cls=NSClassFromString(name);if(!cls)continue;for(int meta=0;meta<2;meta++){unsigned count=0;Method *methods=class_copyMethodList(meta?object_getClass(cls):cls,&count);NSMutableArray *rows=[NSMutableArray array];for(unsigned i=0;i<count;i++)[rows addObject:@{@"selector":NSStringFromSelector(method_getName(methods[i])),@"encoding":@(method_getTypeEncoding(methods[i]))}];free(methods);report[[NSString stringWithFormat:@"%@%@",meta?@"+":@"-",name]]=rows;}}
        puts([[[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:report options:0 error:NULL]encoding:NSUTF8StringEncoding]autorelease]UTF8String]);return 0;
    }
    BOOL reference=argc>1&&!strcmp(argv[1],"--reference");
    void *handle=dlopen(reference?"/System/Library/PrivateFrameworks/CoreUI.framework/Versions/A/CoreUI":"/Library/Application Support/MavericksAppearance/LoreUI.framework/Versions/A/LoreUI",RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
    if(!handle){fprintf(stderr,"%s\n",dlerror());return 70;}
    Draw draw=dlsym(handle,"CUIDraw");
    if(!draw)return 71;
    NSMutableArray *results=[NSMutableArray array];
    for(NSString *widget in @[@"kCUIWidgetButtonPush",@"kCUIWidgetWindowFrame",@"kCUIWidgetButtonSegmented",@"kCUIWidgetButtonSegmentedToolbar",@"kCUIWidgetButtonSegmentedTextured",@"kCUIWidgetMenuBar",@"kCUIWidgetScrollBar",@"kCUIWidgetTab",@"kCUIWidgetButtonCheckBox"]) {
        id key=constant(handle,"kCUIWidgetKey"),value=constant(handle,widget.UTF8String);
        if(!key || !value){[results addObject:@{@"widget":widget,@"missing":@YES}];continue;}
        NSMutableDictionary *options=[NSMutableDictionary dictionaryWithObject:value forKey:key];
        for(NSArray *pair in @[@[@"kCUIStateKey",@"kCUIStateActive"],@[@"kCUISizeKey",@"kCUISizeRegular"],@[@"kCUIPresentationStateKey",@"kCUIPresentationStateActiveKey"]]) {
            id k=constant(handle,[pair[0] UTF8String]),v=constant(handle,[pair[1] UTF8String]);if(k&&v)options[k]=v;
        }
        NSUInteger width=300,height=80;CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context=CGBitmapContextCreate(NULL,width,height,8,width*4,cs,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);CGColorSpaceRelease(cs);
        options[@"value"]=@0;
        CFDictionaryRef result=NULL;int status=draw(NULL,CGRectMake(10,20,280,22),context,(CFDictionaryRef)options,&result);
        CGImageRef image=CGBitmapContextCreateImage(context);NSBitmapImageRep *rep=[[[NSBitmapImageRep alloc]initWithCGImage:image]autorelease];
        NSString *path=[@"/tmp/" stringByAppendingFormat:@"%@.png",widget];[[rep representationUsingType:NSPNGFileType properties:@{}]writeToFile:path atomically:YES];
        unsigned char *pixels=CGBitmapContextGetData(context);NSUInteger visible=0;for(NSUInteger i=0;i<width*height;i++)if(pixels[i*4+3])visible++;
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(pixels,(CC_LONG)(width*height*4),digest);NSMutableString *hash=[NSMutableString string];for(int i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[hash appendFormat:@"%02x",digest[i]];
        [results addObject:@{@"widget":widget,@"options":options,@"status":@(status),@"pixels":@(visible),@"pixelSHA256":hash,@"path":path,@"result":result?[(id)result description]:@""}];
        if(result)CFRelease(result);CGImageRelease(image);CGContextRelease(context);
    }
    puts([[[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted error:NULL]encoding:NSUTF8StringEncoding]autorelease]UTF8String]);
    return 0;
}}
