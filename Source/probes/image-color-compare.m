#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <math.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

// Offscreen diagnostic only. WIDTH HEIGHT GUEST.rgba HOST.rgba GUEST.icc HOST.icc
// Raw inputs: tightly packed, top-first RGBA8 premultiplied, with no orientation transform.
// Each comparison uses this host's single CGContext implementation and two reusable float buffers.
enum { RAW_CAP = 128 * 1024 * 1024, ICC_CAP = 4 * 1024 * 1024, MEMORY_CAP = 640 * 1024 * 1024 };
typedef struct { void *bytes; size_t length; } Mapping;
static BOOL map_file(const char *path, size_t expected, size_t cap, Mapping *out) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    struct stat st;
    if (fd < 0) return NO;
    BOOL valid = !fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_size > 0 &&
        (uint64_t)st.st_size <= cap && (!expected || (uint64_t)st.st_size == expected);
    if (valid) {
        out->length = (size_t)st.st_size;
        out->bytes = mmap(NULL, out->length, PROT_READ, MAP_PRIVATE, fd, 0);
        valid = out->bytes != MAP_FAILED;
        if (!valid) out->bytes = NULL;
    }
    close(fd);
    return valid;
}
static NSString *hash(Mapping data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *value = [NSMutableString string];
    for (size_t i = 0; i < sizeof digest; i++) [value appendFormat:@"%02x", digest[i]];
    return value;
}
static BOOL dimension(const char *text, size_t *out) {
    if (!*text) return NO;
    size_t n = 0;
    for (const char *p = text; *p; p++) {
        if (*p < '0' || *p > '9' || n > RAW_CAP / 10) return NO;
        n = n * 10 + (unsigned)(*p - '0');
        if (n > RAW_CAP) return NO;
    }
    *out = n;
    return n > 0;
}
static BOOL transform(Mapping raw, CGColorSpaceRef source, CGColorSpaceRef destination,
                      size_t width, size_t height, float *out) {
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, raw.bytes, raw.length, NULL);
    CGImageRef image = provider ? CGImageCreate(width, height, 8, 32, width * 4, source,
        kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast, provider, NULL, false,
        kCGRenderingIntentRelativeColorimetric) : NULL;
    CGContextRef context = CGBitmapContextCreate(out, width, height, 32, width * 4 * sizeof(float), destination,
        kCGBitmapByteOrder32Little | kCGBitmapFloatComponents | kCGImageAlphaPremultipliedLast);
    if (image && context) {
        CGContextSetRenderingIntent(context, kCGRenderingIntentRelativeColorimetric);
        CGContextSetBlendMode(context, kCGBlendModeCopy);
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
        CGContextFlush(context);
    }
    BOOL okay = image && context;
    if (context) CGContextRelease(context);
    if (image) CGImageRelease(image);
    if (provider) CGDataProviderRelease(provider);
    return okay;
}
static NSDictionary *statistics(const float *a, const float *b, size_t width, size_t height) {
    double sum[4] = {0}, squares[4] = {0}, maximum[4] = {0};
    size_t coordinates[4] = {0}, bins[6] = {0};
    const double edges[] = {0, 1e-6, .001, .01, .05};
    for (size_t pixel = 0; pixel < width * height; pixel++) {
        for (size_t channel = 0; channel < 4; channel++) {
            double av = a[pixel * 4 + channel], bv = b[pixel * 4 + channel];
            if (!isfinite(av) || !isfinite(bv)) return nil;
            double error = fabs(av - bv);
            sum[channel] += error;
            squares[channel] += error * error;
            if (error > maximum[channel]) { maximum[channel] = error; coordinates[channel] = pixel; }
            if (channel < 3) {
                size_t bin = 0;
                while (bin < 5 && error > edges[bin]) bin++;
                bins[bin]++;
            }
        }
    }
    NSMutableArray *mean = [NSMutableArray array], *rms = [NSMutableArray array];
    NSMutableArray *max = [NSMutableArray array], *xy = [NSMutableArray array], *counts = [NSMutableArray array];
    for (size_t c = 0; c < 4; c++) {
        [mean addObject:@(sum[c] / (width * height))];
        [rms addObject:@(sqrt(squares[c] / (width * height)))];
        [max addObject:@(maximum[c])];
        [xy addObject:@[@(coordinates[c] % width), @(coordinates[c] / width)]];
    }
    for (size_t i = 0; i < 6; i++) [counts addObject:@(bins[i])];
    return @{@"mean_absolute_rgba": mean, @"rms_rgba": rms, @"max_absolute_rgba": max,
             @"max_xy_rgba": xy, @"rgb_component_error_bins": counts,
             @"bin_intervals": @[@"=0", @"(0,1e-6]", @"(1e-6,.001]", @"(.001,.01]", @"(.01,.05]", @">.05"]};
}
int main(int argc, char **argv) {
    @autoreleasepool {
        alarm(120);
        size_t width, height;
        if (argc != 7 || !dimension(argv[1], &width) || !dimension(argv[2], &height) ||
            width > RAW_CAP / 4 || height > RAW_CAP / (width * 4)) {
            fputs("usage: image-color-compare WIDTH HEIGHT GUEST.rgba HOST.rgba GUEST.icc HOST.icc\n", stderr);
            return 64;
        }
        size_t bytes = width * height * 4, float_bytes = bytes * sizeof(float);
        if (bytes > (MEMORY_CAP - 4 * ICC_CAP) / 10) { fputs("FAIL allocation budget\n", stderr); return 65; }
        Mapping maps[4] = {0};
        CGColorSpaceRef spaces[2] = {NULL}, destination = NULL;
        float *a = NULL, *b = NULL;
        int status = 1;
        for (size_t i = 0; i < 4; i++) {
            if (!map_file(argv[i + 3], i < 2 ? bytes : 0, i < 2 ? RAW_CAP : ICC_CAP, &maps[i])) {
                fputs("FAIL regular input file, size or mapping\n", stderr); goto done;
            }
        }
        for (size_t i = 0; i < 2; i++) {
            CFDataRef data = CFDataCreate(kCFAllocatorDefault, maps[i + 2].bytes, maps[i + 2].length);
            spaces[i] = data ? CGColorSpaceCreateWithICCData(data) : NULL;
            if (data) CFRelease(data);
            if (!spaces[i] || CGColorSpaceGetModel(spaces[i]) != kCGColorSpaceModelRGB ||
                CGColorSpaceGetNumberOfComponents(spaces[i]) != 3) { fputs("FAIL RGB ICC profile\n", stderr); goto done; }
        }
        destination = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
        a = calloc(1, float_bytes); b = calloc(1, float_bytes);
        if (!destination || !a || !b) { fputs("FAIL float buffer allocation\n", stderr); goto done; }
        // {raw A, profile A, raw B, profile B}; controls never imply a valid reinterpretation of original media.
        const int pairs[5][4] = {{0,0,1,1}, {0,0,1,0}, {0,1,1,1}, {0,0,0,1}, {1,0,1,1}};
        NSArray *names = @[@"own_profiles", @"same_guest_profile_counterfactual", @"same_host_profile_counterfactual",
                           @"guest_raw_profile_swap_counterfactual", @"host_raw_profile_swap_counterfactual"];
        NSMutableDictionary *comparisons = [NSMutableDictionary dictionary];
        for (size_t i = 0; i < 5; i++) {
            const int *p = pairs[i];
            if (!transform(maps[p[0]], spaces[p[1]], destination, width, height, a) ||
                !transform(maps[p[2]], spaces[p[3]], destination, width, height, b)) {
                fputs("FAIL color transform\n", stderr); goto done;
            }
            NSDictionary *stats = statistics(a, b, width, height);
            if (!stats) { fputs("FAIL nonfinite float output\n", stderr); goto done; }
            comparisons[names[i]] = stats;
        }
        NSDictionary *report = @{@"format_version": @1, @"width": @(width), @"height": @(height),
            @"destination": @"kCGColorSpaceExtendedLinearSRGB", @"format": @"RGBA32Float-premultiplied-native-little-endian",
            @"intent": @"relative-colorimetric", @"row_order": @"top-to-bottom", @"comparisons": comparisons,
            @"guest_raw_sha256": hash(maps[0]), @"host_raw_sha256": hash(maps[1]),
            @"guest_icc_sha256": hash(maps[2]), @"host_icc_sha256": hash(maps[3]),
            @"icc_bytes_equal": @((bool)(maps[2].length == maps[3].length && !memcmp(maps[2].bytes, maps[3].bytes, maps[2].length))),
            @"cf_equal_color_spaces": @((bool)CFEqual(spaces[0], spaces[1])),
            @"note": @"Diagnostic measurements only; no acceptance threshold. CFEqual is an object equality predicate, not universal proof of colorimetric equivalence. Counterfactual profile assignments do not represent valid source interpretation. Inputs are already quantized RGBA8."};
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL];
        if (!json || fwrite(json.bytes, 1, json.length, stdout) != json.length || fputc('\n', stdout) == EOF) {
            fputs("FAIL JSON report\n", stderr); goto done;
        }
        status = 0;
    done:
        free(a); free(b);
        if (destination) CGColorSpaceRelease(destination);
        for (size_t i = 0; i < 2; i++) if (spaces[i]) CGColorSpaceRelease(spaces[i]);
        for (size_t i = 0; i < 4; i++) if (maps[i].bytes) munmap(maps[i].bytes, maps[i].length);
        return status;
    }
}
