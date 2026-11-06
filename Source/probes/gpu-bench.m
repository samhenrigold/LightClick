// LightClick GPU workload for guests: OpenGL on 10.9 and later, and Metal on 10.14 and later. Prints `name value unit`
// lines like probes/lc-bench.c, so scripts/lc-bench-compare reads them; `#` lines are comments. It needs no
// interaction.
//
//   xcrun clang -arch x86_64 -mmacosx-version-min=10.9 -O2 -fno-objc-arc -Wno-deprecated-declarations \
//       -framework Cocoa -framework OpenGL -weak_framework Metal Source/probes/gpu-bench.m -o Build/bench/gpu-bench
//   scripts/guest-bench <app> <machine> <tag> --program Build/bench/gpu-bench
//
// Run: gpu-bench [-t SECONDS]. SECONDS is the measuring time per test (default 2). A test always runs at least 4
// frames.
//
// The guest agent runs programs as root in the system session, where AppKit can't reach the window server. So as root
// this waits for the desktop, copies itself out of the agent's private staging folder and re-enters the console user's
// session: launchctl asuser from 10.10, as tools/guest-progress.m does, and joining their Finder's session before that,
// as seamless-session-join.h explains. Run by a logged-in user, it just runs.
//
// Each test prints <name>_fps in frames/s, <name>_p50, _p95 and _p99 in ms over all frames but the first, <name>_first
// in ms (allocation and first import), and <name> in MB/s if it moves pixels. Tests suffixed _present show each frame;
// the others wait for the GPU instead, so the display's rate can't cap them. A wrong pixel or GL error exits nonzero,
// so a broken path can't report a flattering number.
//
// What moves under VIM_PVG_SLAB, _GATHER and _SCATTER, on guests using the PVG path: metal_shared_* (gather and scatter
// of a whole buffer), metal_gpuwrite_* (all bytes change), metal_touch_* (the per-submission cost, independent of how
// much was used) and metal_upload_*.
#define GL_SILENCE_DEPRECATION
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <OpenGL/gl.h>
#include <copyfile.h>
#include "seamless-session-join.h"
#include <mach-o/dyld.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

// Everything newer than 10.9 is weak: Metal by -weak_framework, CAMetalLayer by NSClassFromString, and all of it runs
// only after the version check in main.
#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

#define MAX_FRAMES (1 << 20)
#define OVERDRAW 8
// The largest upload is a 64 MB texture.
static const int upload_sizes[] = {256, 1024, 4096};
// The centre of each pattern is a block of this colour, which is what the pixel checks look for.
static const uint32_t block_colors[2] = {0xFF2060A0, 0xFFA06020};

static double budget = 2;
static int failures;
static double frames[MAX_FRAMES];

static double now(void) {
    struct timeval t;
    gettimeofday(&t, NULL);
    return t.tv_sec + t.tv_usec / 1e6;
}

static void fail(const char *name, const char *why) {
    failures++;
    printf("# FAIL %s: %s\n", name, why);
}

static BOOL close_to(uint32_t a, uint32_t b) {
    for (int shift = 0; shift < 24; shift += 8)
        if (abs((int)(a >> shift & 255) - (int)(b >> shift & 255)) > 2)
            return NO;
    return YES;
}

static void check_pixel(const char *name, uint32_t got, uint32_t want) {
    if (close_to(got, want))
        return;
    char why[64];
    snprintf(why, sizeof(why), "pixel is %08x, wanted %08x", got, want);
    fail(name, why);
}

// Noise, so nothing can compress or dedupe it, around a block that survives scaling. BGRA.
typedef struct {
    uint32_t *pixels[2];
} Patterns;

static uint32_t *make_pattern(int width, int height, int which) {
    uint32_t *pixels = malloc((size_t)width * height * 4);
    if (!pixels) {
        perror("pattern");
        exit(1);
    }
    uint64_t state = UINT64_C(0x9E3779B97F4A7C15) * (which + 1);
    for (size_t i = 0; i < (size_t)width * height; i += 2) {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        memcpy(&pixels[i], &state, MIN(8, ((size_t)width * height - i) * 4));
    }
    for (int y = height / 2 - 32; y < height / 2 + 32; y++)
        for (int x = width / 2 - 32; x < width / 2 + 32; x++)
            pixels[(size_t)y * width + x] = block_colors[which];
    return pixels;
}

static Patterns make_patterns(int width, int height) {
    return (Patterns){{make_pattern(width, height, 0), make_pattern(width, height, 1)}};
}

static void free_patterns(Patterns patterns) {
    free(patterns.pixels[0]);
    free(patterns.pixels[1]);
}

static void pump_events(void) {
    NSEvent *event;
    while ((event = [NSApp nextEventMatchingMask:NSUIntegerMax untilDate:nil inMode:NSDefaultRunLoopMode dequeue:YES]))
        [NSApp sendEvent:event];
}

static int compare_doubles(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static void measure(const char *name, double bytes_per_frame, void (^frame)(int index)) {
    int count = 0;
    double start = now(), measured = 0;
    while (count < MAX_FRAMES && (count < 4 || measured < budget)) {
        @autoreleasepool {
            double begin = now();
            frame(count);
            pump_events();
            frames[count] = now() - begin;
        }
        if (count++ == 0)
            start = now();
        measured = now() - start;
    }
    printf("%s_first %.3f ms\n", name, frames[0] * 1e3);
    if (bytes_per_frame)
        printf("%s %.3f MB/s\n", name, bytes_per_frame * (count - 1) / measured / 1e6);
    printf("%s_fps %.3f frames/s\n", name, (count - 1) / measured);
    qsort(frames + 1, count - 1, sizeof(*frames), compare_doubles);
    static const int percentiles[] = {50, 95, 99};
    for (int i = 0; i < 3; i++)
        printf("%s_p%d %.3f ms\n", name, percentiles[i], frames[1 + (count - 2) * percentiles[i] / 100] * 1e3);
}

static NSWindow *open_window(void) {
    NSRect frame = NSIntersectionRect(NSMakeRect(0, 0, 1280, 720), [[NSScreen mainScreen] visibleFrame]);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [window setReleasedWhenClosed:NO];
    [window setLevel:NSFloatingWindowLevel];
    [window orderFrontRegardless];
    double deadline = now() + 3;
    while (now() < deadline && !([window occlusionState] & NSWindowOcclusionStateVisible)) {
        pump_events();
        usleep(50000);
    }
    NSSize size = [[window contentView] bounds].size;
    printf("# window %.0fx%.0f %s\n", size.width, size.height,
           [window occlusionState] & NSWindowOcclusionStateVisible ? "visible"
                                                                   : "NOT VISIBLE: presents may be skipped");
    return window;
}

// MARK: OpenGL

static int gl_width, gl_height;
static GLuint gl_quad_buffer;

static GLuint gl_texture(int size, const void *pixels) {
    GLuint texture;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, size, size, 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, pixels);
    return texture;
}

static void gl_quad(void) { glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); }

static void gl_check(const char *name, uint32_t want) {
    uint32_t got = 0;
    glReadPixels(gl_width / 2, gl_height / 2, 1, 1, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, &got);
    check_pixel(name, got, want);
    GLenum error = glGetError();
    if (error != GL_NO_ERROR) {
        char why[32];
        snprintf(why, sizeof(why), "GL error 0x%x", error);
        fail(name, why);
    }
}

static void gl_upload_test(NSOpenGLContext *context, int size, BOOL present, BOOL pbo) {
    char name[64];
    snprintf(name, sizeof(name), "gl_upload%s_%d%s", pbo ? "_pbo" : "", size, present ? "_present" : "");
    Patterns patterns = make_patterns(size, size);
    GLuint texture = gl_texture(size, NULL);
    size_t bytes = (size_t)size * size * 4;
    GLuint unpack = 0;
    if (pbo)
        glGenBuffers(1, &unpack);
    void (^upload)(int) = ^(int which) {
      if (pbo) {
          glBindBuffer(GL_PIXEL_UNPACK_BUFFER, unpack);
          glBufferData(GL_PIXEL_UNPACK_BUFFER, bytes, NULL, GL_STREAM_DRAW);
          glBufferSubData(GL_PIXEL_UNPACK_BUFFER, 0, bytes, patterns.pixels[which]);
      }
      glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, size, size, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV,
                      pbo ? NULL : patterns.pixels[which]);
      if (pbo)
          glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    };
    measure(name, bytes, ^(int index) {
      upload(index & 1);
      gl_quad();
      if (present)
          [context flushBuffer];
      else
          glFinish();
    });
    upload(0);
    gl_quad();
    gl_check(name, block_colors[0]);
    glDeleteTextures(1, &texture);
    if (pbo)
        glDeleteBuffers(1, &unpack);
    free_patterns(patterns);
}

static void gl_tests(void) {
    NSWindow *window = open_window();
    NSOpenGLPixelFormatAttribute attributes[] = {
        NSOpenGLPFADoubleBuffer, NSOpenGLPFAColorSize, 24, NSOpenGLPFAAlphaSize, 8, 0};
    NSOpenGLPixelFormat *format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
    NSOpenGLContext *context = format ? [[NSOpenGLContext alloc] initWithFormat:format shareContext:nil] : nil;
    if (!context) {
        fail("gl", "no context");
        [window close];
        return;
    }
    [context setView:[window contentView]];
    [context makeCurrentContext];
    [context update];
    GLint noVsync = 0;
    [context setValues:&noVsync forParameter:NSOpenGLCPSwapInterval];
    NSSize size = [[window contentView] bounds].size;
    gl_width = size.width;
    gl_height = size.height;
    glViewport(0, 0, gl_width, gl_height);
    printf("# gl %s / %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));
    GLint limit = 0;
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &limit);

    static const GLfloat quad[] = {-1, -1, 0, 0, 1, -1, 1, 0, -1, 1, 0, 1, 1, 1, 1, 1};
    glGenBuffers(1, &gl_quad_buffer);
    glBindBuffer(GL_ARRAY_BUFFER, gl_quad_buffer);
    glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
    glEnableClientState(GL_VERTEX_ARRAY);
    glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glVertexPointer(2, GL_FLOAT, 4 * sizeof(GLfloat), (void *)0);
    glTexCoordPointer(2, GL_FLOAT, 4 * sizeof(GLfloat), (void *)(2 * sizeof(GLfloat)));
    glEnable(GL_TEXTURE_2D);

    uint32_t *pattern = make_pattern(1024, 1024, 0);
    GLuint texture = gl_texture(1024, pattern);
    measure("gl_quad_present", 0, ^(int index) {
      gl_quad();
      [context flushBuffer];
    });
    gl_quad();
    gl_check("gl_quad_present", block_colors[0]);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    measure("gl_fullwin_present", 0, ^(int index) {
      for (int layer = 0; layer < OVERDRAW; layer++)
          gl_quad();
      [context flushBuffer];
    });
    glDisable(GL_BLEND);

    // Back-buffer reads; a quad each frame so no driver can answer from an idle context.
    int read_sizes[][2] = {{MIN(256, gl_width), MIN(256, gl_height)}, {gl_width, gl_height}};
    const char *read_names[] = {"gl_readback_256", "gl_readback_full"};
    uint32_t *pixels = malloc((size_t)gl_width * gl_height * 4);
    for (int i = 0; i < 2 && pixels; i++) {
        int width = read_sizes[i][0], height = read_sizes[i][1];
        measure(read_names[i], (double)width * height * 4, ^(int index) {
          gl_quad();
          glReadPixels((gl_width - width) / 2, (gl_height - height) / 2, width, height, GL_BGRA,
                       GL_UNSIGNED_INT_8_8_8_8_REV, pixels);
        });
        check_pixel(read_names[i], pixels[(size_t)(height / 2) * width + width / 2], block_colors[0]);
    }
    free(pixels);
    free(pattern);
    glDeleteTextures(1, &texture);

    for (unsigned i = 0; i < sizeof(upload_sizes) / sizeof(*upload_sizes); i++) {
        if (upload_sizes[i] > limit) {
            printf("# skip gl_upload_%d: texture limit %d\n", upload_sizes[i], limit);
            continue;
        }
        gl_upload_test(context, upload_sizes[i], NO, NO);
        gl_upload_test(context, upload_sizes[i], YES, NO);
    }
    gl_upload_test(context, 1024, NO, YES);
    [NSOpenGLContext clearCurrentContext];
    [context clearDrawable];
    [window close];
}

// MARK: Metal

static NSString *const metal_shaders =
    @"#include <metal_stdlib>\nusing namespace metal;\n"
     "struct V { float4 p [[position]]; float2 t; };\n"
     "vertex V vs(uint i [[vertex_id]]) {\n"
     "  float2 q[4] = {float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1)};\n"
     "  V o; o.p = float4(q[i], 0, 1); o.t = float2((q[i].x + 1) / 2, (1 - q[i].y) / 2); return o; }\n"
     "fragment float4 fs(V i [[stage_in]], texture2d<float> t [[texture(0)]]) {\n"
     "  constexpr sampler s(filter::nearest); return t.sample(s, i.t); }\n";

static id<MTLTexture> metal_texture(id<MTLDevice> device, int width, int height, MTLTextureUsage usage) {
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:width
                                                                                         height:height
                                                                                      mipmapped:NO];
    descriptor.usage = usage;
    descriptor.storageMode = MTLStorageModeManaged;
    return [device newTextureWithDescriptor:descriptor];
}

static MTLRenderPassDescriptor *metal_pass(id<MTLTexture> target) {
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    return pass;
}

static void metal_draw(id<MTLCommandBuffer> commands, MTLRenderPassDescriptor *pass,
                       id<MTLRenderPipelineState> pipeline, id<MTLTexture> texture, int layers) {
    id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentTexture:texture atIndex:0];
    for (int layer = 0; layer < layers; layer++)
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
}

static uint32_t metal_read_centre(id<MTLCommandQueue> queue, id<MTLTexture> target) {
    id<MTLCommandBuffer> commands = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
    [blit synchronizeResource:target];
    [blit endEncoding];
    [commands commit];
    [commands waitUntilCompleted];
    uint32_t pixel = 0;
    [target getBytes:&pixel
         bytesPerRow:target.width * 4
          fromRegion:MTLRegionMake2D(target.width / 2, target.height / 2, 1, 1)
         mipmapLevel:0];
    return pixel;
}

static void metal_buffer_tests(id<MTLDevice> device, id<MTLCommandQueue> queue, size_t megabytes) {
    size_t bytes = megabytes << 20;
    char name[64];
    // The shared buffer is what the guest shadows; its pages are as scattered as the guest's allocator left them.
    id<MTLBuffer> shared = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    id<MTLBuffer> target = [device newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
    Patterns noise = make_patterns(1024, (int)(bytes / 4096));
    id<MTLBuffer> source0 = [device newBufferWithBytes:noise.pixels[0]
                                                length:bytes
                                               options:MTLResourceStorageModeManaged];
    id<MTLBuffer> source1 = [device newBufferWithBytes:noise.pixels[1]
                                                length:bytes
                                               options:MTLResourceStorageModeManaged];
    if (!shared || !target || !source0 || !source1) {
        printf("# skip metal buffers %zu MB: no memory\n", megabytes);
        return;
    }
    void (^copy)(id<MTLBuffer>, id<MTLBuffer>, size_t) = ^(id<MTLBuffer> from, id<MTLBuffer> to, size_t size) {
      id<MTLCommandBuffer> commands = [queue commandBuffer];
      id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
      [blit copyFromBuffer:from sourceOffset:0 toBuffer:to destinationOffset:0 size:size];
      [blit endEncoding];
      [commands commit];
      [commands waitUntilCompleted];
    };
    memcpy(shared.contents, noise.pixels[0], bytes);

    // GPU reads the buffer. The CPU touches one page, so the guest's copy can't be taken as clean.
    snprintf(name, sizeof(name), "metal_shared_%zumb", megabytes);
    measure(name, bytes, ^(int index) {
      ((volatile uint32_t *)shared.contents)[0] = index;
      copy(shared, target, bytes);
    });

    // GPU writes all of it, and the CPU reads it back: every byte has to reach guest memory.
    size_t middle = (size_t)(bytes / 8192) * 1024 + 512;
    snprintf(name, sizeof(name), "metal_gpuwrite_%zumb", megabytes);
    measure(name, bytes, ^(int index) {
      copy(index & 1 ? source1 : source0, shared, bytes);
      if (((volatile uint32_t *)shared.contents)[middle] != block_colors[index & 1])
          fail("metal_gpuwrite", "the CPU didn't see the GPU's write");
    });

    // A big buffer used for one page: what each submission costs whatever it uses.
    snprintf(name, sizeof(name), "metal_touch_%zumb", megabytes);
    measure(name, 0, ^(int index) {
      copy(shared, target, 4096);
    });
    free_patterns(noise);
    [shared release];
    [target release];
    [source0 release];
    [source1 release];
}

static void metal_tests(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    Class layerClass = NSClassFromString(@"CAMetalLayer");
    if (!device || !layerClass) {
        printf("# skip metal: no device\n");
        return;
    }
    printf("# metal %s\n", device.name.UTF8String);
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:metal_shaders options:nil error:&error];
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"vs"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"fs"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> pipeline =
        library ? [device newRenderPipelineStateWithDescriptor:descriptor error:&error] : nil;
    if (!pipeline) {
        fail("metal", error.localizedDescription.UTF8String ?: "no pipeline");
        return;
    }
    id<MTLCommandQueue> queue = [device newCommandQueue];

    // Offscreen, so nothing but the GPU paces these. The target is managed so its result can be checked.
    id<MTLTexture> offscreen = metal_texture(device, 256, 256, MTLTextureUsageRenderTarget);
    for (unsigned i = 0; i < sizeof(upload_sizes) / sizeof(*upload_sizes); i++) {
        int size = upload_sizes[i];
        size_t bytes = (size_t)size * size * 4;
        Patterns patterns = make_patterns(size, size);
        id<MTLTexture> texture = metal_texture(device, size, size, MTLTextureUsageShaderRead);
        char name[64];
        snprintf(name, sizeof(name), "metal_upload_%d", size);
        void (^draw)(int) = ^(int which) {
          [texture replaceRegion:MTLRegionMake2D(0, 0, size, size)
                     mipmapLevel:0
                       withBytes:patterns.pixels[which]
                     bytesPerRow:size * 4];
          id<MTLCommandBuffer> commands = [queue commandBuffer];
          metal_draw(commands, metal_pass(offscreen), pipeline, texture, 1);
          [commands commit];
          [commands waitUntilCompleted];
        };
        measure(name, bytes, ^(int index) {
          draw(index & 1);
        });
        draw(0);
        check_pixel(name, metal_read_centre(queue, offscreen), block_colors[0]);
        [texture release];
        free_patterns(patterns);
    }

    int read_sizes[] = {256, 1024};
    for (int i = 0; i < 2; i++) {
        int size = read_sizes[i];
        uint32_t *pixels = malloc((size_t)size * size * 4);
        id<MTLTexture> target = metal_texture(device, size, size, MTLTextureUsageRenderTarget);
        char name[64];
        snprintf(name, sizeof(name), "metal_readback_%d", size);
        measure(name, (double)size * size * 4, ^(int index) {
          MTLRenderPassDescriptor *pass = metal_pass(target);
          pass.colorAttachments[0].loadAction = MTLLoadActionClear;
          pass.colorAttachments[0].clearColor = MTLClearColorMake(0.25, 0.5, 0.75, 1);
          id<MTLCommandBuffer> commands = [queue commandBuffer];
          [[commands renderCommandEncoderWithDescriptor:pass] endEncoding];
          id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
          [blit synchronizeResource:target];
          [blit endEncoding];
          [commands commit];
          [commands waitUntilCompleted];
          [target getBytes:pixels bytesPerRow:size * 4 fromRegion:MTLRegionMake2D(0, 0, size, size) mipmapLevel:0];
        });
        check_pixel(name, pixels[(size_t)(size / 2) * size + size / 2], 0xFF4080BF);
        [target release];
        free(pixels);
    }

    metal_buffer_tests(device, queue, 16);
    metal_buffer_tests(device, queue, 64);

    NSWindow *window = open_window();
    CAMetalLayer *layer = [layerClass layer];
    layer.device = device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    if ([layer respondsToSelector:@selector(setDisplaySyncEnabled:)])
        [layer setDisplaySyncEnabled:NO];
    NSView *view = [window contentView];
    [view setLayer:layer];
    [view setWantsLayer:YES];
    layer.drawableSize = view.bounds.size;

    Patterns patterns = make_patterns(1024, 1024);
    id<MTLTexture> texture = metal_texture(device, 1024, 1024, MTLTextureUsageShaderRead);
    MTLRegion whole = MTLRegionMake2D(0, 0, 1024, 1024);
    [texture replaceRegion:whole mipmapLevel:0 withBytes:patterns.pixels[0] bytesPerRow:1024 * 4];
    void (^present)(int) = ^(int layers) {
      id<CAMetalDrawable> drawable = [layer nextDrawable];
      if (!drawable) {
          fail("metal_present", "no drawable");
          return;
      }
      id<MTLCommandBuffer> commands = [queue commandBuffer];
      metal_draw(commands, metal_pass(drawable.texture), pipeline, texture, layers);
      [commands presentDrawable:drawable];
      [commands commit];
      [commands waitUntilCompleted];
    };
    measure("metal_quad_present", 0, ^(int index) {
      present(1);
    });
    measure("metal_fullwin_present", 0, ^(int index) {
      present(OVERDRAW);
    });
    measure("metal_upload_1024_present", 1024.0 * 1024 * 4, ^(int index) {
      [texture replaceRegion:whole mipmapLevel:0 withBytes:patterns.pixels[index & 1] bytesPerRow:1024 * 4];
      present(1);
    });
    free_patterns(patterns);
    [window close];
}

// MARK: Entry

static int darwin_major(void) {
    char release[32] = "";
    size_t size = sizeof(release);
    sysctlbyname("kern.osrelease", release, &size, NULL, 0);
    return atoi(release);
}

static pid_t console_finder(uid_t uid) {
    char command[64];
    snprintf(command, sizeof(command), "/usr/bin/pgrep -x -U %u Finder", uid);
    FILE *pipe = popen(command, "r");
    int pid = 0;
    if (pipe) {
        if (fscanf(pipe, "%d", &pid) != 1)
            pid = 0;
        pclose(pipe);
    }
    return pid;
}

// Runs this program again inside the console user's session, as that user, and returns its status.
static int run_in_console_session(char **argv) {
    struct stat console = {0};
    pid_t finder = 0;
    // Short of guest-bench's request timeout, with the time limit in main.
    double waited = now();
    while (now() - waited < 300) {
        if (!stat("/dev/console", &console) && console.st_uid >= 501 && (finder = console_finder(console.st_uid)))
            break;
        sleep(2);
    }
    if (!finder) {
        fprintf(stderr, "gpu-bench: no one logged in to the desktop after 300 s\n");
        return 75;
    }
    // Let a desktop that has only just come up settle, or the first tests measure Finder and Dock starting.
    if (now() - waited > 5)
        sleep(30);
    // The agent's staging folder is root's alone.
    char self[4096], directory[] = "/tmp/gpu-bench.XXXXXX", copy[64], account[32];
    uint32_t length = sizeof(self);
    if (_NSGetExecutablePath(self, &length) || !mkdtemp(directory))
        return 74;
    snprintf(copy, sizeof(copy), "%s/gpu-bench", directory);
    snprintf(account, sizeof(account), "#%u", console.st_uid);
    if (chmod(directory, 0755) || copyfile(self, copy, NULL, COPYFILE_DATA) || chmod(copy, 0755))
        return 74;
    BOOL modern = darwin_major() >= 14;
    char target[16];
    snprintf(target, sizeof(target), "%d", modern ? (int)console.st_uid : finder);
    char *arguments[16] = {"/bin/launchctl",
                           modern ? "asuser" : "bsexec",
                           target,
                           "/usr/bin/sudo",
                           "-S",
                           "-u",
                           account,
                           "/usr/bin/env",
                           "-i",
                           "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
                           copy};
    for (int i = 11, from = 1; i < 15 && argv[from]; i++, from++)
        arguments[i] = argv[from];
    fflush(NULL);
    pid_t child = fork();
    if (child == 0) {
        // -S with no input can't prompt.
        freopen("/dev/null", "r", stdin);
        if (modern) {
            execv(arguments[0], arguments);
        } else if (join_session_of(finder)) {
            printf("# ERROR couldn't join the session of Finder, pid %d: %s\n", finder, strerror(errno));
            fflush(stdout);
        } else {
            // Past launchctl: see seamless-session-join.h.
            execv(arguments[3], arguments + 3);
        }
        _exit(127);
    }
    int status = 1;
    if (child < 0 || waitpid(child, &status, 0) < 0)
        status = 1;
    unlink(copy);
    rmdir(directory);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "-t"))
        budget = atof(argv[2]);
    else if (argc != 1 || budget <= 0) {
        fprintf(stderr, "usage: %s [-t SECONDS_PER_TEST]\n", argv[0]);
        return 2;
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (geteuid() == 0)
        return run_in_console_session(argv);
    alarm(540); // Partial results beat the agent timing out and losing them all.
    printf("# gpu-bench arch=x86_64 t=%g darwin=%d\n", budget, darwin_major());
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];
        // App Nap and display sleep would otherwise change the numbers on an untouched desktop.
        [[[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityLatencyCritical | NSActivityUserInitiated |
                                                               NSActivityIdleDisplaySleepDisabled
                                                        reason:@"gpu-bench"] retain];
        gl_tests();
        if (darwin_major() >= 18)
            metal_tests();
    }
    printf("# failures %d\n", failures);
    return failures ? 1 : 0;
}
