// Original scrollbars and source-list styling across native AppKit applications.
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include <sys/sysctl.h>
extern NSImage *MavericksAppearanceImage(NSString *name);
static void stretch(NSImage *image,NSRect rect,BOOL vertical,CGFloat cap,BOOL flipped) {
    CGFloat length=vertical?image.size.height:image.size.width,total=vertical?rect.size.height:rect.size.width;
    if(length<=cap*2 || total<=cap*2)return;
    CGFloat src[3]={0,cap,length-cap},sizes[3]={cap,length-cap*2,cap};
    CGFloat dst[3]={0,cap,total-cap},lengths[3]={cap,total-cap*2,cap};
    for(int i=0;i<3;i++) {
        NSRect source=vertical?NSMakeRect(0,src[i],image.size.width,sizes[i]):NSMakeRect(src[i],0,sizes[i],image.size.height);
        NSRect target=vertical?NSMakeRect(rect.origin.x,rect.origin.y+dst[i],rect.size.width,lengths[i]):NSMakeRect(rect.origin.x+dst[i],rect.origin.y,lengths[i],rect.size.height);
        [image drawInRect:target fromRect:source operation:NSCompositeSourceOver fraction:1 respectFlipped:flipped hints:nil];
    }
}
@interface LCClassicScroller : NSScroller @end
@implementation LCClassicScroller
- (BOOL)wantsUpdateLayer {return NO;}
- (void)setDoubleValue:(double)value {[super setDoubleValue:value];[self setNeedsDisplay:YES];}
- (void)setKnobProportion:(CGFloat)value {[super setKnobProportion:value];[self setNeedsDisplay:YES];}
- (void)drawRect:(NSRect)dirty {
    if(self.controlSize!=NSRegularControlSize){[super drawRect:dirty];return;}
    BOOL vertical=self.bounds.size.height>self.bounds.size.width;
    NSImage *track=MavericksAppearanceImage(vertical?@"1756.png":@"1746.png");
    NSImage *thumb=MavericksAppearanceImage(vertical?(self.hitPart==NSScrollerKnob?@"1754.png":@"1753.png"):@"1745.png");
    if(!track || !thumb){[super drawRect:dirty];return;}
    [track drawInRect:self.bounds fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1 respectFlipped:self.isFlipped hints:nil];
    if(self.enabled && self.knobProportion<1) {
        NSRect knob=[self rectForPart:NSScrollerKnob];
        if(vertical){knob.origin.x=floor(NSMidX(self.bounds)-5);knob.size.width=10;}
        else {knob.origin.y=floor(NSMidY(self.bounds)-5);knob.size.height=10;}
        stretch(thumb,knob,vertical,5,self.isFlipped);
    }
}
@end
static IMP scrollerFrame,scrollerCoder,scrollerSetStyle;
static id finishScroller(id object) {
    if(object_getClass(object)==[NSScroller class]){object_setClass(object,[LCClassicScroller class]);[object setWantsLayer:NO];((void(*)(id,SEL,NSInteger))scrollerSetStyle)(object,@selector(setScrollerStyle:),NSScrollerStyleLegacy);}
    return object;
}
static id initScrollerFrame(id self,SEL cmd,NSRect frame){return finishScroller(((id(*)(id,SEL,NSRect))scrollerFrame)(self,cmd,frame));}
static id initScrollerCoder(id self,SEL cmd,id coder){return finishScroller(((id(*)(id,SEL,id))scrollerCoder)(self,cmd,coder));}
static NSScrollerStyle preferredStyle(id cls,SEL cmd){return NSScrollerStyleLegacy;}
static IMP scrollViewSetStyle;
static void classicScrollViewStyle(id view,SEL cmd,NSScrollerStyle style){((void(*)(id,SEL,NSScrollerStyle))scrollViewSetStyle)(view,cmd,NSScrollerStyleLegacy);}
static char sourceListKey;
static char sourceSelectionKey;
static BOOL sourceRowSelected(NSTableRowView *row){return row.isSelected||[objc_getAssociatedObject(row,&sourceSelectionKey)boolValue];}
static BOOL sourceListEmphasized(NSTableRowView *row){return NSApp.isActive&&(row.window.isMainWindow||row.window.isKeyWindow);}
static BOOL sourceRow(NSView *view) {
    for(NSView *parent=view.superview;parent;parent=parent.superview)
        if([parent isKindOfClass:[NSTableView class]])return objc_getAssociatedObject(parent,&sourceListKey)!=nil || [(NSTableView *)parent selectionHighlightStyle]==NSTableViewSelectionHighlightStyleSourceList;
    return NO;
}
static void drawClassicSelection(NSTableRowView *row,SEL cmd,NSRect dirty) {
    if(!sourceRow(row)) {
        IMP native=class_getMethodImplementation(class_getSuperclass(object_getClass(row)),cmd);
        ((void(*)(id,SEL,NSRect))native)(row,cmd,dirty);return;
    }
    NSImage *image=[NSImage imageNamed:sourceListEmphasized(row)?@"LCMavericksSourceListActive":@"LCMavericksSourceListInactive"];
    if(image)[image drawInRect:row.bounds fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1 respectFlipped:row.isFlipped hints:nil];
    else {IMP native=class_getMethodImplementation(class_getSuperclass(object_getClass(row)),cmd);((void(*)(id,SEL,NSRect))native)(row,cmd,dirty);}
}
static void setClassicRowStyle(NSTableRowView *row,SEL cmd,NSTableViewSelectionHighlightStyle style) {
    IMP native=class_getMethodImplementation(class_getSuperclass(object_getClass(row)),cmd);
    ((void(*)(id,SEL,NSTableViewSelectionHighlightStyle))native)(row,cmd,sourceRow(row)?NSTableViewSelectionHighlightStyleSourceList:style);
}
static NSBackgroundStyle classicRowInterior(NSTableRowView *row,SEL cmd) {
    if(sourceRow(row))return sourceRowSelected(row)&&sourceListEmphasized(row)?NSBackgroundStyleDark:NSBackgroundStyleLight;
    IMP native=class_getMethodImplementation(class_getSuperclass(object_getClass(row)),cmd);return ((NSBackgroundStyle(*)(id,SEL))native)(row,cmd);
}
static void headerText(NSView *view) {
    if([view isKindOfClass:[NSTextField class]]) {
        NSTextField *text=(NSTextField *)view;NSString *upper=text.stringValue.uppercaseString;
        if(![text.stringValue isEqual:upper])text.stringValue=upper;
        NSFont *font=[NSFont boldSystemFontOfSize:11];if(![text.font.fontName isEqual:font.fontName] || text.font.pointSize!=11)text.font=font;
        NSColor *color=[NSColor colorWithSRGBRed:.43 green:.47 blue:.51 alpha:1];if(![text.textColor isEqual:color])text.textColor=color;
    }
    for(NSView *child in view.subviews)headerText(child);
}
static void styleLists(NSView *view,BOOL sidebar) {
    sidebar=sidebar||[NSStringFromClass(view.class)rangeOfString:@"sidebar" options:NSCaseInsensitiveSearch].location!=NSNotFound;
    if([view isKindOfClass:[NSVisualEffectView class]] && [(NSVisualEffectView *)view material]==7)sidebar=YES;
    if(sidebar && [view isKindOfClass:[NSScrollView class]])[(NSScrollView *)view setDrawsBackground:NO];
    if([view isKindOfClass:[NSTableView class]]) {
        NSTableView *table=(NSTableView *)view;
        if(sidebar || table.selectionHighlightStyle==NSTableViewSelectionHighlightStyleSourceList) {
            objc_setAssociatedObject(table,&sourceListKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if(table.selectionHighlightStyle!=NSTableViewSelectionHighlightStyleSourceList)table.selectionHighlightStyle=NSTableViewSelectionHighlightStyleSourceList;
            if(![table.backgroundColor isEqual:[NSColor clearColor]])table.backgroundColor=[NSColor clearColor];
            [table enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *row,NSInteger index){
                BOOL selected=row.isSelected||[table.selectedRowIndexes containsIndex:index];objc_setAssociatedObject(row,&sourceSelectionKey,@(selected),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if(![NSStringFromClass(row.class) hasPrefix:@"LCMavericksRow_"]) {
                    Class original=object_getClass(row);NSString *name=[@"LCMavericksRow_" stringByAppendingString:NSStringFromClass(original)];
                    Class replacement=NSClassFromString(name);
                    if(!replacement){replacement=objc_allocateClassPair(original,name.UTF8String,0);class_addMethod(replacement,@selector(drawSelectionInRect:),(IMP)drawClassicSelection,"v@:{CGRect={CGPoint=dd}{CGSize=dd}}");class_addMethod(replacement,@selector(interiorBackgroundStyle),(IMP)classicRowInterior,"q@:");class_addMethod(replacement,@selector(setSelectionHighlightStyle:),(IMP)setClassicRowStyle,"v@:q");objc_registerClassPair(replacement);}
                    object_setClass(row,replacement);
                }
                // Retain source-list group and focus semantics. The shared
                // material path supplies the original selection artwork.
                if(row.selectionHighlightStyle!=NSTableViewSelectionHighlightStyleSourceList){row.selectionHighlightStyle=NSTableViewSelectionHighlightStyleSourceList;[row setNeedsDisplay:YES];}
                if(row.isGroupRowStyle)headerText(row);
            }];
        }
    }
    for(NSView *child in view.subviews)styleLists(child,sidebar);
}
@interface LCSourceListAppearance : NSObject @end
@implementation LCSourceListAppearance
- (void)windowUpdated:(NSNotification *)note {NSWindow *window=note.object;if([window isKindOfClass:[NSWindow class]])styleLists(window.contentView,NO);}
@end
__attribute__((constructor)) static void initializeWidgets(void) {
    char release[32]={0};size_t length=sizeof(release);sysctlbyname("kern.osrelease",release,&length,NULL,0);if(atoi(release)!=18)return;
    Class cls=[NSScroller class];SEL frame=@selector(initWithFrame:),coder=@selector(initWithCoder:);
    scrollerFrame=class_getMethodImplementation(cls,frame);scrollerCoder=class_getMethodImplementation(cls,coder);scrollerSetStyle=class_getMethodImplementation(cls,@selector(setScrollerStyle:));
    class_addMethod(cls,frame,(IMP)initScrollerFrame,"@@:{CGRect={CGPoint=dd}{CGSize=dd}}");method_setImplementation(class_getInstanceMethod(cls,frame),(IMP)initScrollerFrame);
    class_addMethod(cls,coder,(IMP)initScrollerCoder,"@@:@");method_setImplementation(class_getInstanceMethod(cls,coder),(IMP)initScrollerCoder);
    method_setImplementation(class_getClassMethod(cls,@selector(preferredScrollerStyle)),(IMP)preferredStyle);
    Method style=class_getInstanceMethod([NSScrollView class],@selector(setScrollerStyle:));scrollViewSetStyle=method_getImplementation(style);method_setImplementation(style,(IMP)classicScrollViewStyle);
    LCSourceListAppearance *controller=[LCSourceListAppearance new];[[NSNotificationCenter defaultCenter] addObserver:controller selector:@selector(windowUpdated:) name:NSWindowDidUpdateNotification object:nil];
}
