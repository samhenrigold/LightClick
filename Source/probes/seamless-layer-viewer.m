// Builds real host layers from a guest's render tree, as the hook's census printed it, for judging how close the host's
// Core Animation comes to the guest's. Offline: nothing here talks to a guest, and nothing's shown. The host's
// CARenderer draws the layers into a texture over the color asked for, so the images are composed from pixels by host
// CA, with no window, and it works with the display off. What samples what's behind a window can't be seen this way: a
// backdrop layer comes out as what's in the destination. Says what it didn't know.
//
//     xcrun clang -fobjc-arc -O2 -framework AppKit -framework QuartzCore -framework Metal \
//         probes/seamless-layer-viewer.m -o Build/seamless/seamless-layer-viewer
//     seamless-layer-viewer census.txt BLOB_DIRECTORY TREE_INDEX OUTPUT.png [r,g,b] [--at SECONDS]
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

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
        // shortcut: blobs from before the hook used IOSurfaceGetBytesPerRow have a padded row, at this alignment.
        unsigned align = getenv("STRIDE_ALIGN") ? (unsigned)atoi(getenv("STRIDE_ALIGN")) : 0;
        unsigned stride = align ? ((w * 4 + align - 1) & ~(align - 1)) : row;
        CGImageRef image =
            CGImageCreate(w, h, 8, 32, stride, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
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
    Node *inner = subclass.items.lastObject;
    if (subclass.items.count < 2)
        inner = nil;
    NSString *kind = [inner wordAt:0];
    CALayer *layer;
    if ([kind isEqual:@"gradient-layer"]) {
        CAGradientLayer *gradient = [CAGradientLayer layer];
        Node *start = [inner named:@"startPoint"].items[1], *end = [inner named:@"endPoint"].items[1];
        if (start.items.count == 2)
            gradient.startPoint = CGPointMake(number(start, 0), number(start, 1));
        if (end.items.count == 2)
            gradient.endPoint = CGPointMake(number(end, 0), number(end, 1));
        Node *stops = [subclass named:@"gradient-colors"];
        NSMutableArray *colors = [NSMutableArray new], *locations = [NSMutableArray new];
        for (NSUInteger i = 1; i + 4 < stops.items.count; i += 5) {
            [locations addObject:@(number(stops, i))];
            CGColorRef color = CGColorCreateSRGB(number(stops, i + 1), number(stops, i + 2), number(stops, i + 3),
                                                 number(stops, i + 4));
            [colors addObject:(__bridge id)color];
            CGColorRelease(color);
        }
        gradient.colors = colors;
        gradient.locations = locations;
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
        if (!name || item.square)
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
        else if ([name isEqual:@"continuousCorners"]) {
            if (@available(macOS 10.15, *))
                layer.cornerCurve = kCACornerCurveContinuous;
        } else if ([name isEqual:@"borderWidth"])
            layer.borderWidth = number(item, 1);
        else if ([name isEqual:@"borderColor"]) {
            Node *c = item.items[1];
            CGColorRef color = CGColorCreateSRGB(number(c, 0), number(c, 1), number(c, 2), number(c, 3));
            layer.borderColor = color;
            CGColorRelease(color);
        } else if ([name isEqual:@"contentsRect"]) {
            Node *v = item.items[1];
            layer.contentsRect = CGRectMake(number(v, 1), number(v, 2), number(v, 3), number(v, 4));
        } else if ([name isEqual:@"minificationFilter"] || [name isEqual:@"magnificationFilter"]) {
            NSString *filter = [[item wordAt:1] isEqual:@"nearest"]     ? kCAFilterNearest
                               : [[item wordAt:1] isEqual:@"trilinear"] ? kCAFilterTrilinear
                                                                        : kCAFilterLinear;
            if ([name hasPrefix:@"min"])
                layer.minificationFilter = filter;
            else
                layer.magnificationFilter = filter;
        } else if ([name isEqual:@"contentsOpaque"])
            layer.opaque = YES;
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
            if ([[inner.items[i] wordAt:0] isEqual:@"layer"]) {
                // shortcut: a hosted context's root doesn't flip again, or Safari's page lands upside down. Read from
                // one tree's result, and CA's rule for this isn't read.
                CALayer *hosted = make_layer(inner.items[i], renderNow);
                hosted.geometryFlipped = NO;
                [layer addSublayer:hosted];
            }
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
        double r = 1, g = 0, b = 0;
        if (argc > 5)
            sscanf(argv[5], "%lf,%lf,%lf", &r, &g, &b);
        double animateSeconds = argc > 7 && !strcmp(argv[6], "--at") ? atof(argv[7]) : 0;
        animate = animateSeconds > 0;
        known = [NSSet setWithArray:@[
            @"allowsGroupBlending", @"hitTestsAsOpaque", @"allowsEdgeAntialiasing", @"edgeAntialiasingMask",
            @"hitTestsContentsAlphaChannel", @"allowsHitTesting", @"contentsScaling", @"cornerContents",
            @"cornerContentsCenter"
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
        CALayer *rootLayer = make_layer(root, 0);
        CGRect box = CGRectZero;
        for (CALayer *sub in rootLayer.sublayers)
            box = CGRectUnion(box, sub.frame);
        if (box.size.width < 1 || box.size.width > 4096 || box.size.height > 4096)
            return 5;
        for (NSString *key in unknown)
            printf("unknown %s: %d\n", key.UTF8String, unknown[key].intValue);
        size_t width = (size_t)box.size.width * 2, height = (size_t)box.size.height * 2;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:width
                                                              height:height
                                                           mipmapped:NO];
        descriptor.usage = MTLTextureUsageUnknown;
        descriptor.storageMode = MTLStorageModeShared;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CARenderer *renderer = [CARenderer rendererWithMTLTexture:texture
                                                          options:@{kCARendererColorSpace : (__bridge id)space}];
        CALayer *top = [CALayer layer];
        top.anchorPoint = CGPointZero;
        top.bounds = CGRectMake(0, 0, width, height);
        CGColorRef color = CGColorCreateSRGB(r, g, b, 1);
        top.backgroundColor = color;
        CGColorRelease(color);
        CALayer *scaled = [CALayer layer];
        scaled.anchorPoint = CGPointZero;
        scaled.bounds = CGRectMake(0, 0, box.size.width, box.size.height);
        scaled.transform = CATransform3DMakeScale(2, 2, 1);
        rootLayer.position = CGPointMake(-box.origin.x, -box.origin.y);
        [scaled addSublayer:rootLayer];
        [top addSublayer:scaled];
        renderer.layer = top;
        renderer.bounds = top.bounds;
        [CATransaction commit];
        [CATransaction flush];
        CFTimeInterval began = CACurrentMediaTime();
        [renderer beginFrameAtTime:began + animateSeconds timeStamp:NULL];
        [renderer addUpdateRect:top.bounds];
        CGRect update = renderer.updateBounds;
        fprintf(stderr, "update %g,%g %gx%g\n", update.origin.x, update.origin.y, update.size.width,
                update.size.height);
        [renderer render];
        [renderer endFrame];
        usleep(500000); // Its command buffer is its own, and nothing says when that's done.
        NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
        [texture getBytes:pixels.mutableBytes
              bytesPerRow:width * 4
               fromRegion:MTLRegionMake2D(0, 0, width, height)
              mipmapLevel:0];
        // The texture's first row is the layers' bottom.
        uint8_t *rows = pixels.mutableBytes;
        NSMutableData *line = [NSMutableData dataWithLength:width * 4];
        for (size_t y = 0; y < height / 2; y++) {
            memcpy(line.mutableBytes, rows + y * width * 4, width * 4);
            memcpy(rows + y * width * 4, rows + (height - 1 - y) * width * 4, width * 4);
            memcpy(rows + (height - 1 - y) * width * 4, line.mutableBytes, width * 4);
        }
        CGContextRef bitmap = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, width * 4, space,
                                                    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGImageRef image = CGBitmapContextCreateImage(bitmap);
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:output atomically:YES];
        printf("%zux%zu\n", width, height);
    }
    return 0;
}
