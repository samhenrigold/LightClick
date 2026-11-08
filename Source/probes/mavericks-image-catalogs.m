// Inspect native image-catalog ABIs without opening a fixture window.
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
int main(void){@autoreleasepool{
    [NSApplication sharedApplication];
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    for(NSString *name in @[@"CUICatalog",@"CUINamedImage",@"CUIThemeRendition",@"NSImage"]){
        Class cls=NSClassFromString(name);NSMutableArray *methods=[NSMutableArray array];
        for(int meta=0;meta<2;meta++){
            unsigned count=0;Method *all=class_copyMethodList(meta?object_getClass(cls):cls,&count);
            for(unsigned i=0;i<count;i++){
                NSString *selector=NSStringFromSelector(method_getName(all[i]));
                if([name isEqual:@"NSImage"]&&[selector rangeOfString:@"catalog"options:NSCaseInsensitiveSearch].location==NSNotFound&&[selector rangeOfString:@"bundle"options:NSCaseInsensitiveSearch].location==NSNotFound)continue;
                [methods addObject:@{@"selector":selector,@"encoding":@(method_getTypeEncoding(all[i])),@"classMethod":@(meta)}];
            }free(all);
        }result[name]=methods;
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];fwrite(data.bytes,1,data.length,stdout);return 0;
}}
