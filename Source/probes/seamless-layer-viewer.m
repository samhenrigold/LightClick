// Builds real host layers from a guest's render tree, as the hook's census printed it, for judging how close the host's
// Core Animation comes to the guest's. Offline: nothing here talks to a guest. Shows one window at the desktop's level,
// behind every other window and taking no clicks, over a plain window of the color asked for, writes it as read from
// the screen, and says what it didn't know.
//
//     xcrun clang -fobjc-arc -O2 -framework AppKit -framework QuartzCore -framework CoreImage \
//         probes/seamless-layer-viewer.m -o Build/seamless/seamless-layer-viewer
//     seamless-layer-viewer census.txt BLOB_DIRECTORY TREE_INDEX OUTPUT.png [r,g,b] [--animate SECONDS]
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>

// A list, or a word. Strings keep their quotes off.
@interface Node : NSObject
@property NSString *word;
@property NSMutableArray<Node *> *items;
@property BOOL square;
@end
@implementation Node
- (Node *)named:(NSString *)name {
    for (Node *n in self.items)
        if (n.items.count && [n.items[0].word isEqual:name])
            return n;
    return nil;
}
- (NSString *)wordAt:(NSUInteger)i {
    return i < self.items.count ? self.items[i].word : nil;
}
@end

static const char *cursor;
static Node *parse_one(void) {
    while (*cursor == ' ' || *cursor == '\n' || *cursor == '\t')
        cursor++;
    if (!*cursor)
        return nil;
    Node *node = [Node new];
    if (*cursor == '(' || *cursor == '[') {
        node.square = *cursor == '[';
        char close = node.square ? ']' : ')';
        cursor++;
        node.items = [NSMutableArray new];
        for (;;) {
            while (*cursor == ' ' || *cursor == '\n' || *cursor == '\t')
                cursor++;
            if (!*cursor)
                return node;
            if (*cursor == close) {
                cursor++;
                return node;
            }
            if (*cursor == ')' || *cursor == ']') { // A word with a bracket in it left one over.
                cursor++;
                continue;
            }
            Node *child = parse_one();
            if (child)
                [node.items addObject:child];
        }
    }
    if (*cursor == '"') {
        const char *start = ++cursor;
        while (*cursor && *cursor != '"')
            cursor++;
        node.word = [[NSString alloc] initWithBytes:start
                                             length:(NSUInteger)(cursor - start)
                                           encoding:NSUTF8StringEncoding];
        if (*cursor)
            cursor++;
        return node;
    }
    const char *start = cursor;
    while (*cursor && !strchr(" \n\t()[]", *cursor))
        cursor++;
    node.word = [[NSString alloc] initWithBytes:start
                                         length:(NSUInteger)(cursor - start)
                                       encoding:NSUTF8StringEncoding];
    return node;
}

static NSString *blobs;
static NSMutableDictionary<NSString *, NSNumber *> *unknown;
static NSSet *known;
static BOOL animate;

static CGImageRef blob_image(unsigned index) {
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:blobs error:NULL];
    NSString *prefix = [NSString stringWithFormat:@"blob-%u-", index];
    for (NSString *file in files) {
        if (![file hasPrefix:prefix])
            continue;
        unsigned i, w, h, row;
        if (sscanf(file.UTF8String, "blob-%u-%ux%u-%u.raw", &i, &w, &h, &row) != 4)
            continue;
        NSData *data = [NSData dataWithContentsOfFile:[blobs stringByAppendingPathComponent:file]];
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGImageRef image =
            CGImageCreate(w, h, 8, 32, row, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                          provider, NULL, NO, kCGRenderingIntentDefault);
        CGColorSpaceRelease(space);
        CGDataProviderRelease(provider);
        return image;
    }
    return NULL;
}

static CGFloat number(Node *n, NSUInteger i) { return [n wordAt:i].doubleValue; }

static CAMediaTimingFunction *timing(Node *vector) {
    return [CAMediaTimingFunction
        functionWithControlPoints:number(vector, 1):number(vector, 2):number(vector, 3):number(vector, 4)];
}

// A list's first word is its kind, and the rest of a layer's list is what it has.
static CALayer *make_layer(Node *n, CFTimeInterval renderNow) {
    Node *position = n.items.count > 1 ? n.items[1] : nil, *bounds = n.items.count > 2 ? n.items[2] : nil,
         *anchor = n.items.count > 3 ? n.items[3] : nil;
    Node *subclass = [n named:@"subclass"];
    NSString *kind = subclass.items.count > 1 ? [subclass.items[1] wordAt:0] : nil;
    Node *inner = subclass.items.count > 1 ? subclass.items[1] : nil;
    CALayer *layer;
    if ([kind isEqual:@"gradient-layer"]) {
        CAGradientLayer *gradient = [CAGradientLayer layer];
        Node *start = [inner named:@"startPoint"].items[1], *end = [inner named:@"endPoint"].items[1];
        if (start.items.count == 2)
            gradient.startPoint = CGPointMake(number(start, 0), number(start, 1));
        if (end.items.count == 2)
            gradient.endPoint = CGPointMake(number(end, 0), number(end, 1));
        layer = gradient;
    } else if ([kind isEqual:@"backdrop-layer"]) {
        Class backdrop = NSClassFromString(@"CABackdropLayer");
        layer = backdrop ? [backdrop layer] : [CALayer layer];
        if (backdrop) {
            [layer setValue:[[inner named:@"group"] wordAt:1] forKey:@"groupName"];
            [layer setValue:@([inner named:@"scale"] ? [[inner named:@"scale"] wordAt:1].doubleValue : 1)
                     forKey:@"scale"];
            [layer setValue:@YES forKey:@"windowServerAware"];
        }
    } else
        layer = [CALayer layer];
    layer.anchorPoint = CGPointMake(number(anchor, 0), number(anchor, 1));
    layer.bounds = CGRectMake(number(bounds, 0), number(bounds, 1), number(bounds, 2), number(bounds, 3));
    layer.position = CGPointMake(number(position, 0), number(position, 1));
    layer.zPosition = number(position, 2);
    for (NSUInteger i = 4; i < n.items.count; i++) {
        Node *item = n.items[i];
        NSString *name = [item wordAt:0];
        if (!name)
            continue;
        if ([name isEqual:@"name"])
            layer.name = [item wordAt:1];
        else if ([name isEqual:@"masksToBounds"])
            layer.masksToBounds = YES;
        else if ([name isEqual:@"geometryFlipped"])
            layer.geometryFlipped = YES;
        else if ([name isEqual:@"hidden"])
            layer.hidden = YES;
        else if ([name isEqual:@"opacity"])
            layer.opacity = (float)number(item, 1);
        else if ([name isEqual:@"cornerRadius"])
            layer.cornerRadius = number(item, 1);
        else if ([name isEqual:@"contentsScale"])
            layer.contentsScale = number(item, 1);
        else if ([name isEqual:@"contentsGravity"]) {
            NSDictionary *names = @{
                @"bottomLeft" : kCAGravityBottomLeft,
                @"topLeft" : kCAGravityTopLeft,
                @"center" : kCAGravityCenter,
                @"resize" : kCAGravityResize,
                @"resizeAspect" : kCAGravityResizeAspect,
                @"left" : kCAGravityLeft,
                @"right" : kCAGravityRight,
                @"top" : kCAGravityTop,
                @"bottom" : kCAGravityBottom,
                @"topRight" : kCAGravityTopRight,
                @"bottomRight" : kCAGravityBottomRight
            };
            if (names[[item wordAt:1]])
                layer.contentsGravity = names[[item wordAt:1]];
        } else if ([name isEqual:@"backgroundColor"]) {
            Node *c = item.items[1];
            CGColorRef color = CGColorCreateSRGB(number(c, 0), number(c, 1), number(c, 2), number(c, 3));
            layer.backgroundColor = color;
            CGColorRelease(color);
        } else if ([name isEqual:@"contentsCenter"]) {
            Node *v = item.items[1];
            layer.contentsCenter = CGRectMake(number(v, 1), number(v, 2), number(v, 3), number(v, 4));
        } else if ([name isEqual:@"compositingFilter"]) {
            Node *f = item.items[1];
            // A host filter by the guest's name: that they mean the same is what's being looked at.
            layer.compositingFilter = [f wordAt:1];
        } else if ([name isEqual:@"blob"]) {
            // Before its contents. Its layer's next item is the contents, which says no more than this does.
        } else if ([name isEqual:@"contents"]) {
            Node *blob = nil;
            for (Node *part in item.items)
                if ([[part wordAt:0] isEqual:@"blob"])
                    blob = part;
            if (blob) {
                CGImageRef image = blob_image((unsigned)[blob wordAt:1].intValue);
                layer.contents = (__bridge id)image;
                if (image)
                    CGImageRelease(image);
            }
        } else if ([name isEqual:@"animations"] && animate) {
            Node *array = item.items[1];
            for (NSUInteger a = 1; a < array.items.count; a++) {
                Node *basic = array.items[a];
                if (![[basic wordAt:0] isEqual:@"basic-animation"]) {
                    unknown[[basic wordAt:0] ?: @"?"] = @(unknown[[basic wordAt:0] ?: @"?"].intValue + 1);
                    continue;
                }
                NSString *keyPath = [[basic named:@"keyPath"] wordAt:1];
                Node *from = [basic named:@"from"].items[1], *to = [basic named:@"to"].items[1];
                if ([keyPath isEqual:@"transform"] &&
                    [[[basic named:@"function"].items[1] wordAt:1] isEqual:@"translate"]) {
                    keyPath = @"transform.translation";
                    CABasicAnimation *move = [CABasicAnimation animationWithKeyPath:keyPath];
                    move.fromValue = [NSValue valueWithSize:NSMakeSize(number(from, 1), number(from, 2))];
                    move.toValue = [NSValue valueWithSize:NSMakeSize(number(to, 1), number(to, 2))];
                    move.duration = [[basic named:@"duration"] wordAt:1].doubleValue;
                    move.autoreverses = [[[basic named:@"autoreverses"] wordAt:1] isEqual:@"true"];
                    move.repeatCount = HUGE_VALF;
                    move.removedOnCompletion = NO;
                    Node *function = [basic named:@"timingFunction"].items[1];
                    if (function.items.count == 5)
                        move.timingFunction = timing(function);
                    [layer addAnimation:move forKey:@"guest"];
                } else
                    unknown[[NSString stringWithFormat:@"animation %@", keyPath]] = @1;
            }
        } else if ([name isEqual:@"filters"]) {
            Class filterClass = NSClassFromString(@"CAFilter");
            NSMutableArray *filters = [NSMutableArray new];
            Node *array = item.items[1];
            for (NSUInteger a = 1; a < array.items.count; a++) {
                Node *f = array.items[a];
                id filter = [filterClass filterWithName:[f wordAt:1]];
                Node *inputs = [f named:@"inputs"].items[1];
                for (NSUInteger k = 1; k < inputs.items.count; k++) {
                    Node *input = inputs.items[k];
                    Node *v = input.items[1];
                    if (filter && v.items.count == 2)
                        [filter setValue:@(number(v, 1)) forKey:[input wordAt:0]];
                }
                if (filter)
                    [filters addObject:filter];
            }
            layer.filters = filters;
        } else if (![name isEqual:@"sublayers"] && ![name isEqual:@"subclass"] && ![known containsObject:name])
            unknown[name] = @(unknown[name].intValue + 1);
    }
    if ([kind isEqual:@"layer-host"]) {
        // Another process's tree, printed in place.
        for (NSUInteger i = 2; i < inner.items.count; i++)
            if ([[inner.items[i] wordAt:0] isEqual:@"layer"])
                [layer addSublayer:make_layer(inner.items[i], renderNow)];
    } else if (kind && ![kind isEqual:@"gradient-layer"] && ![kind isEqual:@"backdrop-layer"])
        unknown[kind] = @(unknown[kind].intValue + 1);
    Node *sublayers = [n named:@"sublayers"];
    if (sublayers.items.count > 1) {
        Node *array = sublayers.items[1];
        for (NSUInteger i = 1; i < array.items.count; i++)
            [layer addSublayer:make_layer(array.items[i], renderNow)];
    }
    return layer;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 5)
            return 2;
        NSString *all = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:NULL];
        blobs = @(argv[2]);
        int index = atoi(argv[3]);
        NSString *output = @(argv[4]);
        CGFloat r = 1, g = 0, b = 0;
        if (argc > 5)
            sscanf(argv[5], "%lf,%lf,%lf", &r, &g, &b);
        double animateSeconds = argc > 7 && !strcmp(argv[6], "--animate") ? atof(argv[7]) : 0;
        animate = animateSeconds > 0;
        known = [NSSet setWithArray:@[
            @"allowsGroupBlending", @"hitTestsAsOpaque", @"allowsEdgeAntialiasing", @"edgeAntialiasingMask",
            @"hitTestsContentsAlphaChannel", @"allowsHitTesting", @"minificationFilter", @"contentsScaling",
            @"cornerContents", @"cornerContentsCenter"
        ]];
        unknown = [NSMutableDictionary new];
        NSArray<NSString *> *trees = [all componentsSeparatedByString:@"== census"];
        if (index + 1 >= (int)trees.count)
            return 3;
        NSString *tree = trees[(NSUInteger)index + 1];
        NSRange start = [tree rangeOfString:@"(layer ["];
        if (start.location == NSNotFound)
            return 4;
        // "(blob N)(image ..." comes in as two items in the same list.
        NSString *text = [tree substringFromIndex:start.location];
        cursor = text.UTF8String;
        Node *root = parse_one();
        [NSApplication sharedApplication];
        NSApp.activationPolicy = NSApplicationActivationPolicyProhibited;
        CALayer *rootLayer = make_layer(root, 0);
        CGRect box = CGRectZero;
        for (CALayer *sub in rootLayer.sublayers)
            box = CGRectUnion(box, sub.frame);
        if (box.size.width < 1)
            return 5;
        CGFloat height = NSScreen.screens[0].frame.size.height;
        NSRect frame = NSMakeRect(100, height - box.size.height - 100, box.size.width, box.size.height);
        NSWindow *behind = [[NSWindow alloc] initWithContentRect:NSInsetRect(frame, -40, -40)
                                                       styleMask:NSWindowStyleMaskBorderless
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        behind.level = kCGDesktopWindowLevel;
        behind.ignoresMouseEvents = YES;
        behind.backgroundColor = [NSColor colorWithSRGBRed:r green:g blue:b alpha:1];
        [behind orderBack:nil];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                       styleMask:NSWindowStyleMaskBorderless
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        window.level = kCGDesktopWindowLevel;
        window.ignoresMouseEvents = YES;
        window.opaque = NO;
        window.backgroundColor = NSColor.clearColor;
        window.hasShadow = NO;
        window.contentView.wantsLayer = YES;
        CALayer *hostRoot = window.contentView.layer;
        hostRoot.geometryFlipped = YES;
        rootLayer.position = CGPointZero;
        rootLayer.anchorPoint = CGPointZero;
        [hostRoot addSublayer:rootLayer];
        [window orderFront:nil];
        for (NSString *key in unknown)
            printf("unknown %s: %d\n", key.UTF8String, unknown[key].intValue);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((animate ? animateSeconds : 2) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                         typedef CGImageRef (*Create)(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption);
                         Create create = (Create)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
                         CGRect rect = CGRectMake(frame.origin.x - 40, height - frame.origin.y - frame.size.height - 40,
                                                  frame.size.width + 80, frame.size.height + 80);
                         CGImageRef image =
                             create
                                 ? create(rect,
                                          kCGWindowListOptionIncludingWindow | kCGWindowListOptionOnScreenBelowWindow,
                                          (CGWindowID)window.windowNumber, kCGWindowImageBestResolution)
                                 : NULL;
                         if (image) {
                             NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
                             [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:output
                                                                                                     atomically:YES];
                         }
                         exit(image ? 0 : 6);
                       });
        [NSApp run];
    }
    return 0;
}
