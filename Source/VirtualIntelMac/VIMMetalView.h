#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>
NS_ASSUME_NONNULL_BEGIN
/// Shared PVG frame consumer. Caller retains frame ownership until completion.
@interface VIMMetalView : NSView
@property(nonatomic, copy, nullable) void (^inputHandler)(NSArray<NSDictionary *> *events);
/// Explicit diagnostic only; the session reports the normal QMP input reply.
@property(nonatomic, copy, nullable) void (^diagnosticInputObserver)(CFTimeInterval queued, NSError *_Nullable error);
@property(nonatomic) BOOL displaySleeping;
/// PVG display power is independent of the emulator's system run state.
@property(nonatomic) BOOL guestDisplaySleeping;
@property(nonatomic) BOOL softwareCursor;
/// Compositor sampling only; no guest mode, pixel copy or extra render pass.
@property(nonatomic) BOOL nearestNeighborScaling;
@property(nonatomic, readonly) BOOL inputCaptured;
- (void)releaseInputCapture;
- (void)capturePNG:(void (^)(NSData *_Nullable png))completion;
- (void)releasePressedKeys;
/// After disconnecting the producer, retire shared frame storage. Submitted
/// Metal commands retain their resources until GPU completion.
- (void)discardFrameStorage;
/// Hide the old source and reject its in-flight completion, retaining CPU
/// fallback storage and the current guest/system power state.
- (void)invalidatePresentation;
- (void)setGuestCursorVisible:(BOOL)visible;
- (void)setGuestCursorPixels:(NSData *)pixels
                       width:(NSUInteger)width
                      height:(NSUInteger)height
                     hotspot:(NSPoint)hotspot;
/// Read-only development snapshot; no guest calls or screen capture.
- (NSDictionary *)cursorDiagnostics;
/// Geometry only; no GPU readback, pixel copies or guest calls.
- (NSDictionary *)frameDiagnostics;
/// Explicit developer experiment. Valid Metal swap-queue depths are 2 or 3;
/// no frame contents, producer ownership, VSync or guest mode are changed.
- (BOOL)setPresentationDrawableCount:(NSUInteger)count;
/// Wait for a swap drawable away from the input thread, selecting the newest
/// immutable source before encoding. On unless VIM_DISPLAY_LEGACY_QUEUE=1.
@property(nonatomic) BOOL asynchronousDrawableAcquisition;
/// Explicit developer-only measurement; GPU fingerprints, not full-image CPU
/// readback. Off in normal launches. No guest or input connection is touched.
- (void)setFingerprintMeasurementEnabled:(BOOL)enabled;
/// Bounded diagnostic trace and optional red-title-button marker search in
/// guest backing pixels. Empty rect disables the marker. Never normal input.
- (void)setFingerprintTraceEnabled:(BOOL)enabled;
- (void)setFingerprintMarkerRect:(NSRect)rect;
/// With VIM_INPUT_LATENCY=1, marks the QMP reply of the input being timed. Otherwise a flag check.
- (void)noteInputReply;
/// Takes ownership of fd on every path; never copies the shared frame pixels.
- (BOOL)installFrameDescriptor:(int)fd length:(NSUInteger)length error:(NSError **)error;
/// Main-thread only. Completion fires once, after GPU use or a skipped frame.
- (void)presentWidth:(NSUInteger)width
              height:(NSUInteger)height
              stride:(NSUInteger)stride
          completion:(void (^)(BOOL presented))completion;
/// GPU-only source path. Producer must finish writes before calling and must
/// not mutate/recycle the surface until completion. Retains storage through
/// Metal use; completion is a resource-release signal, not scanout evidence.
/// Every frame the guest's display path delivers, before anything decides whether to show it. Either a surface, or
/// bytes valid only for the call.
@property(nullable, copy) void (^frameObserver)(IOSurfaceRef _Nullable surface, const void *_Nullable bytes,
                                                NSUInteger width, NSUInteger height, NSUInteger stride);
@property(readonly) NSUInteger arrivedFrames;
/// Of those, how many differed from the last on a sample of their rows, if VIM_COUNT_DISTINCT_FRAMES is set.
@property(readonly) NSUInteger differentFrames;
- (void)presentSurface:(IOSurfaceRef)surface
                 width:(NSUInteger)width
                height:(NSUInteger)height
            completion:(void (^)(BOOL presented))completion;
@end
NS_ASSUME_NONNULL_END
