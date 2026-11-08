// Inspect rendering selectors and encodings in the installed AppKit. No patching or GUI session needed.
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
int main(void){@autoreleasepool{NSMutableDictionary *report=[NSMutableDictionary dictionary];
for(NSString *name in @[@"NSButtonCell",@"NSCell",@"NSSegmentedCell",@"NSSegmentedControl",@"NSProgressIndicator",@"NSTextFieldCell",@"NSThemeFrame"]){
 Class cls=NSClassFromString(name);NSMutableArray *items=[NSMutableArray array];unsigned count=0;Method *methods=class_copyMethodList(cls,&count);
 for(unsigned i=0;i<count;i++){NSString *sel=NSStringFromSelector(method_getName(methods[i]));BOOL include=NO;
 for(NSString *part in @[@"egment",@"draw",@"Draw",@"ocus",@"egacy",@"ize",@"tyle",@"olor",@"itle",@"Height",@"idth",@"adio",@"heck",@"ype",@"mage"])if([sel rangeOfString:part].location!=NSNotFound)include=YES;
 if(include)[items addObject:@{@"selector":sel,@"encoding":@(method_getTypeEncoding(methods[i]))}];}
 free(methods);report[name]=items;
}
NSMutableDictionary *fonts=[NSMutableDictionary dictionary];
for(NSString *name in @[@"systemFontOfSize:",@"boldSystemFontOfSize:",@"menuFontOfSize:",@"menuBarFontOfSize:",@"messageFontOfSize:",@"labelFontOfSize:",@"titleBarFontOfSize:",@"controlContentFontOfSize:",@"toolTipsFontOfSize:",@"paletteFontOfSize:",@"userFontOfSize:",@"userFixedPitchFontOfSize:"]) {
    SEL selector=NSSelectorFromString(name);
    if([NSFont respondsToSelector:selector]) {
        NSFont *font=((id(*)(id,SEL,CGFloat))[NSFont methodForSelector:selector])([NSFont class],selector,0);
        fonts[name]=@{@"name":font.fontName,@"size":@(font.pointSize)};
    }
}
report[@"FontDefaults"]=fonts;
NSMutableDictionary *colors=[NSMutableDictionary dictionary];
for(NSString *name in @[@"controlTextColor",@"disabledControlTextColor",@"selectedControlTextColor",@"keyboardFocusIndicatorColor"]){
 SEL selector=NSSelectorFromString(name);NSColor *c=((id(*)(id,SEL))[NSColor methodForSelector:selector])([NSColor class],selector);
 NSColor *srgb=[c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
 colors[name]=@{@"description":c.description,@"sRGB":@[@(srgb.redComponent),@(srgb.greenComponent),@(srgb.blueComponent),@(srgb.alphaComponent)]};
}
report[@"ColorDefaults"]=colors;
puts([[[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL] encoding:NSUTF8StringEncoding]autorelease]UTF8String]);}}
