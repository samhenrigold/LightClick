// Deterministic pasteboard ownership/data publication race, private board only.
#define main VIMEmbeddedClipboardMain
#include "../tools/guest-clipboard.m"
#undef main
@interface PublicationFixture : ClipboardAgent
@property NSPasteboard *board;
@property NSMutableArray *messages;
@property NSInteger lock;
@end
@implementation PublicationFixture
- (NSInteger)consoleLockState {
    return self.lock;
}
- (NSPasteboard *)pasteboard {
    return self.board;
}
- (void)send:(NSDictionary *)message {
    [self.messages addObject:message];
}
@end
int main(void) {
    @autoreleasepool {
        PublicationFixture *agent = [PublicationFixture new];
        agent.board = [NSPasteboard pasteboardWithUniqueName];
        agent.messages = [NSMutableArray new];
        @try {
            [agent.board clearContents];
            [agent.board setString:@"before" forType:NSPasteboardTypeString];
            [agent receive:@{@"type" : @"ready", @"protocol" : @2}];
            NSInteger cleared = [agent.board clearContents];
            [agent tick:nil]; // The owner has not provided its content yet.
            [agent.board addTypes:@[ NSPasteboardTypeString ] owner:nil];
            [agent.board setString:@"after" forType:NSPasteboardTypeString];
            printf("clear_count=%ld completed_count=%ld\n", (long)cleared, (long)agent.board.changeCount);
            usleep(250000); // A single normal 200ms sampling interval, not a data deadline.
            [agent tick:nil];
            BOOL delivered = agent.messages.count == 1 && [agent.messages[0][@"text"] isEqual:@"after"];
            printf("deferred publication delivered=%d\n", delivered);
            if (!delivered)
                return 1;
            [agent.board clearContents];
            [agent tick:nil];
            agent.lock = 1;
            [agent tick:nil]; // Lock during the pending-read backoff.
            [agent.board setString:@"behind lock" forType:NSPasteboardTypeString];
            agent.lock = 0;
            usleep(250000);
            [agent tick:nil];
            if (agent.messages.count != 1) {
                fprintf(stderr, "FAIL: pending content escaped the lock boundary\n");
                return 1;
            }
            [agent.board clearContents];
            [agent.board setData:[NSData dataWithBytes:"x" length:1] forType:@"public.png"];
            [agent tick:nil];
            if (agent.observedChange != agent.board.changeCount || agent.publication.delay) {
                fprintf(stderr, "FAIL: unsupported content retained a pending read\n");
                return 1;
            }
            NSPasteboard *board = agent.board;
            agent = [PublicationFixture new];
            agent.board = board;
            agent.messages = [NSMutableArray new];

            // Rich frames, once the host has answered the offer. A real TIFF becomes a real PNG, both ways.
            NSBitmapImageRep *pixel = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                              pixelsWide:2
                                                                              pixelsHigh:2
                                                                           bitsPerSample:8
                                                                         samplesPerPixel:4
                                                                                hasAlpha:YES
                                                                                isPlanar:NO
                                                                          colorSpaceName:NSDeviceRGBColorSpace
                                                                             bytesPerRow:0
                                                                            bitsPerPixel:0];
            NSData *rtf = [@"{\\rtf1 hello}" dataUsingEncoding:NSASCIIStringEncoding];
            [agent receive:@{@"type" : @"ready", @"protocol" : @2, @"rich" : @(1 << 30)}];
            NSCAssert(agent.richLimit == RichOffer, @"the host can't raise the guest's limit");
            [agent.board clearContents];
            [agent.board setString:@"hello" forType:NSPasteboardTypeString];
            [agent.board setData:rtf forType:NSPasteboardTypeRTF];
            [agent.board setData:pixel.TIFFRepresentation forType:NSPasteboardTypeTIFF];
            usleep(250000);
            [agent tick:nil];
            NSDictionary *frame = agent.messages.lastObject;
            NSCAssert([frame[@"type"] isEqual:@"rich"] && [frame[@"text"] isEqual:@"hello"] && frame[@"rtf"] &&
                          frame[@"image"],
                      @"everything the copy held went in one frame");
            NSMutableDictionary *back = [frame mutableCopy];
            back[@"sequence"] = @1;
            [agent receive:back];
            NSCAssert([[agent.board dataForType:NSPasteboardTypeRTF] isEqual:rtf] &&
                          [agent.board dataForType:NSPasteboardTypeTIFF] &&
                          VIMClipboardIsPNG([agent.board dataForType:NSPasteboardTypePNG]) &&
                          [[agent.board stringForType:NSPasteboardTypeString] isEqual:@"hello"],
                      @"received frame published");
            NSUInteger sent = agent.messages.count;
            usleep(250000);
            [agent tick:nil];
            NSCAssert(agent.messages.count == sent, @"our own write isn't reflected back");

            // An image with no text still travels, and a corrupt one doesn't wedge a pending read.
            [agent.board clearContents];
            [agent.board setData:pixel.TIFFRepresentation forType:NSPasteboardTypeTIFF];
            usleep(250000);
            [agent tick:nil];
            NSCAssert([agent.messages.lastObject[@"image"] length] && !agent.messages.lastObject[@"text"],
                      @"image only");
            sent = agent.messages.count;
            [agent.board clearContents];
            [agent.board setData:[NSData dataWithBytes:"x" length:1] forType:NSPasteboardTypePNG];
            usleep(250000);
            [agent tick:nil];
            NSCAssert(agent.messages.count == sent && agent.observedChange == agent.board.changeCount &&
                          !agent.publication.delay,
                      @"corrupt image dropped, not retried");

            // Limits and degrading: the image is what gives way, then the frame, and the text goes on alone.
            NSData *big = [NSMutableData dataWithLength:100];
            NSCAssert(!VIMClipboardRichFrame(@"t", big, nil, 99), @"over the limit");
            NSDictionary *partial = VIMClipboardRichFrame(@"t", rtf, big, 50);
            NSCAssert(partial[@"rtf"] && !partial[@"image"], @"RTF first");
            NSString *longText = [@"" stringByPaddingToLength:VIMClipboardRichTextLimit + 1
                                                   withString:@"x"
                                              startingAtIndex:0];
            NSCAssert(!VIMClipboardRichFrame(longText, rtf, nil, 1024), @"long text degrades to a text frame");
            NSCAssert(6 * VIMClipboardRichTextLimit + VIMClipboardRichLimitVirtio / 3 * 4 + 64 < WireLimit,
                      @"a rich frame fits the wire limit at JSON's worst case");

            // A hostile peer: every one of these must refuse the frame.
            NSString *text = nil;
            NSData *outRTF = nil, *outPNG = nil;
            NSDictionary *hostile[] = {
                @{},
                @{@"text" : @"no payload"},
                @{@"rtf" : @1},
                @{@"rtf" : @"not base64!"},
                @{@"image" : @"eA=="}, // not a PNG
                @{@"rtf" : [big base64EncodedStringWithOptions:0], @"text" : @3},
                @{@"rtf" : [[NSMutableData dataWithLength:100000] base64EncodedStringWithOptions:0]},
            };
            for (NSUInteger i = 0; i < sizeof(hostile) / sizeof(*hostile); i++)
                NSCAssert(!VIMClipboardReadRichFrame(hostile[i], 1024, &text, &outRTF, &outPNG), @"hostile frame %lu",
                          (unsigned long)i);
            NSCAssert(!VIMClipboardReadRichFrame(frame, 0, &text, &outRTF, &outPNG),
                      @"no rich frames without the offer");
            puts("PASS: deferred publication, lock boundary, unsupported content, rich round trip, limits and hostile "
                 "frames; private pasteboard only");
            return 0;
        } @finally {
            [agent.board releaseGlobally];
        }
    }
}
