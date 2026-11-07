#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

// FILE keeps the original 256x256 diagnostic. The opt-in experiment emits one JSON record on stdout:
//   image-decode --full-resolution FILE [--index N] [--raw NEW_FILE] [--timeout SECONDS]
//                [--max-output-bytes N] [--output-color-space srgb|source]
// Compile the same source for an arm64 host and an x86_64/macOS 10.14 guest. No AppKit or display is used.
// Timings are individual phases, not a claim about Preview or native decoder hardware use.
enum { INPUT_LIMIT = 512 * 1024 * 1024, OUTPUT_LIMIT = 512 * 1024 * 1024, DEFAULT_OUTPUT_LIMIT = 256 * 1024 * 1024 };

static double seconds(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (double)value.tv_sec + (double)value.tv_nsec / 1e9;
}

static NSString *sha256(const void *bytes, size_t count) {
    // All inputs are bounded below UINT32_MAX, CommonCrypto's length type.
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, (CC_LONG)count, digest);
    NSMutableString *result = [NSMutableString string];
    for (size_t i = 0; i < sizeof(digest); i++)
        [result appendFormat:@"%02x", digest[i]];
    return result;
}

static int number(const char *text, uint64_t *out) {
    if (!text[0])
        return 0;
    for (const char *p = text; *p; p++)
        if (*p < '0' || *p > '9')
            return 0;
    errno = 0;
    unsigned long long value = strtoull(text, NULL, 10);
    if (errno)
        return 0;
    *out = value;
    return 1;
}

static NSDictionary *profile(CGColorSpaceRef space) {
    CFDataRef data = space ? CGColorSpaceCopyICCData(space) : NULL;
    CFIndex length = data ? CFDataGetLength(data) : 0;
    // An empty profile is absent. Never truncate CFIndex into CommonCrypto's CC_LONG.
    if (length < 0 || length > INPUT_LIMIT) {
        if (data)
            CFRelease(data);
        return nil;
    }
    NSDictionary *result = @{@"bytes" : @(length),
                             @"sha256" : length > 0
                                 ? (id)sha256(CFDataGetBytePtr(data), (size_t)length) : NSNull.null};
    if (data)
        CFRelease(data);
    return result;
}

static int write_raw(const char *path, const void *bytes, size_t count) {
    // A measurement never replaces an existing artifact or follows an output symlink.
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0)
        return 0;
    const unsigned char *p = bytes;
    size_t left = count;
    while (left) {
        ssize_t wrote = write(fd, p, left);
        if (wrote < 0 && errno == EINTR)
            continue;
        if (wrote <= 0)
            break;
        p += wrote;
        left -= (size_t)wrote;
    }
    int closed = close(fd);
    if (left || closed) {
        unlink(path);
        return 0;
    }
    return 1;
}

static int full_resolution(int argc, char **argv) {
    const char *path = NULL, *raw = NULL;
    const char *output_space = "srgb";
    BOOL space_set = NO;
    uint64_t item = 0, timeout = 30, max_output = DEFAULT_OUTPUT_LIMIT;
    for (int i = 2; i < argc; i++) {
        const char *argument = argv[i];
        if (!strcmp(argument, "--raw") && i + 1 < argc && !raw)
            raw = argv[++i];
        else if (!strcmp(argument, "--output-color-space") && i + 1 < argc && !space_set) {
            output_space = argv[++i];
            if (strcmp(output_space, "srgb") && strcmp(output_space, "source"))
                return 64;
            space_set = YES;
        } else if ((!strcmp(argument, "--index") || !strcmp(argument, "--timeout") ||
                  !strcmp(argument, "--max-output-bytes")) && i + 1 < argc) {
            uint64_t value;
            if (!number(argv[++i], &value))
                return 64;
            if (!strcmp(argument, "--index"))
                item = value;
            else if (!strcmp(argument, "--timeout"))
                timeout = value;
            else
                max_output = value;
        } else if (argument[0] != '-' && !path)
            path = argument;
        else
            return 64;
    }
    if (!path || !timeout || timeout > 120 || !max_output || max_output > OUTPUT_LIMIT || item > SIZE_MAX)
        return 64;
    alarm((unsigned)timeout);
    struct stat st;
    if (stat(path, &st) || !S_ISREG(st.st_mode) || st.st_size <= 0 || st.st_size > INPUT_LIMIT) {
        fputs("FAIL input must be a nonempty regular file of at most 512 MiB\n", stderr);
        return 3;
    }

    double began = seconds(), phase = began;
    NSError *error = nil;
    NSData *encoded = [NSData dataWithContentsOfFile:@(path) options:NSDataReadingMappedIfSafe error:&error];
    if (!encoded || !encoded.length || encoded.length > INPUT_LIMIT) {
        fprintf(stderr, "FAIL reading encoded bytes: %s\n", error.description.UTF8String ?: "size changed");
        return 3;
    }
    double read_ms = (seconds() - phase) * 1000;
    phase = seconds();
    NSString *input_hash = sha256(encoded.bytes, encoded.length);
    double input_hash_ms = (seconds() - phase) * 1000;
    NSDictionary *options = @{(id)kCGImageSourceShouldCache : @NO};
    phase = seconds();
    CGImageSourceRef source = CGImageSourceCreateWithData((CFDataRef)encoded, (CFDictionaryRef)options);
    double source_ms = (seconds() - phase) * 1000;
    if (!source) {
        fputs("FAIL ImageIO source creation\n", stderr);
        return 4;
    }
    int status = 0;
    CGImageRef image = NULL;
    CGColorSpaceRef space = NULL;
    CGContextRef context = NULL;
    CFDictionaryRef properties = NULL;
    CFStringRef source_space_name = NULL;
    CFStringRef output_space_name = NULL;
    unsigned char *pixels = NULL;
    size_t count = CGImageSourceGetCount(source), width = 0, height = 0, row = 0, length = 0;
    if (item >= count) {
        fputs("FAIL item index outside ImageIO source\n", stderr);
        status = 4;
        goto done;
    }
    phase = seconds();
    properties = CGImageSourceCopyPropertiesAtIndex(source, (size_t)item, (CFDictionaryRef)options);
    double metadata_ms = (seconds() - phase) * 1000;
    // Refuse implausible metadata before image construction as well as checking the actual image afterward.
    if (properties) {
        NSNumber *w = [(NSDictionary *)properties objectForKey:(id)kCGImagePropertyPixelWidth];
        NSNumber *h = [(NSDictionary *)properties objectForKey:(id)kCGImagePropertyPixelHeight];
        uint64_t mw = [w unsignedLongLongValue], mh = [h unsignedLongLongValue];
        if ((mw && mw > max_output / 4) || (mw && mh && mh > max_output / (mw * 4))) {
            fputs("FAIL declared image exceeds output budget\n", stderr);
            status = 6;
            goto done;
        }
    }
    phase = seconds();
    image = CGImageSourceCreateImageAtIndex(source, (size_t)item, (CFDictionaryRef)options);
    double image_ms = (seconds() - phase) * 1000;
    if (!image) {
        fputs("FAIL ImageIO image creation\n", stderr);
        status = 5;
        goto done;
    }
    width = CGImageGetWidth(image);
    height = CGImageGetHeight(image);
    if (!width || !height || width > max_output / 4 || height > max_output / (width * 4)) {
        fputs("FAIL actual image exceeds output budget\n", stderr);
        status = 6;
        goto done;
    }
    row = width * 4;
    length = row * height;
    phase = seconds();
    pixels = calloc(1, length);
    if (!strcmp(output_space, "source")) {
        CGColorSpaceRef original = CGImageGetColorSpace(image);
        if (!original || CGColorSpaceGetModel(original) != kCGColorSpaceModelRGB ||
            CGColorSpaceGetNumberOfComponents(original) != 3) {
            fputs("FAIL source output requires a three-component RGB color space\n", stderr);
            status = 7;
            goto done;
        }
        space = CGColorSpaceRetain(original);
    } else
        space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (pixels && space)
        context = CGBitmapContextCreate(pixels, width, height, 8, row, space,
                                       kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
    if (!context) {
        fputs("FAIL output allocation or bitmap context\n", stderr);
        status = 7;
        goto done;
    }
    double allocation_ms = (seconds() - phase) * 1000;
    CGContextSetRenderingIntent(context, kCGRenderingIntentRelativeColorimetric);
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    // An untransformed bitmap draw stores the CGImage's first row first. The independent 2x2 PNG check covers this
    // layout and premultiplication; a flipped CTM reverses these rows. EXIF orientation is deliberately not applied.
    phase = seconds();
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextFlush(context);
    double decode_ms = (seconds() - phase) * 1000;
    phase = seconds();
    NSString *pixel_hash = sha256(pixels, length);
    double pixel_hash_ms = (seconds() - phase) * 1000;
    phase = seconds();
    if (raw && !write_raw(raw, pixels, length)) {
        fputs("FAIL raw output must be a writable new file\n", stderr);
        status = 8;
        goto done;
    }
    double raw_ms = (seconds() - phase) * 1000;
    CGColorSpaceRef source_space = CGImageGetColorSpace(image);
    if (source_space)
        source_space_name = CGColorSpaceCopyName(source_space);
    output_space_name = CGColorSpaceCopyName(space);
    NSDictionary *source_profile = profile(source_space), *output_profile = profile(space);
    if (!source_profile || !output_profile) {
        fputs("FAIL ICC profile exceeds the 512 MiB inspection budget\n", stderr);
        status = 9;
        goto done;
    }
    id orientation = properties ? [(NSDictionary *)properties objectForKey:(id)kCGImagePropertyOrientation] : nil;
    NSDictionary *report = @{
        @"format_version" : @1,
        @"mode" : @"full-resolution",
        @"input_bytes" : @(encoded.length), @"input_sha256" : input_hash,
        @"source_type" : (id)CGImageSourceGetType(source) ?: (id)NSNull.null,
        @"item_index" : @(item), @"item_count" : @(count),
        @"orientation" : orientation ?: (id)NSNull.null, @"orientation_applied" : @NO,
        @"presentation_time" : NSNull.null, @"time_semantics" : @"still-image item; no video PTS",
        @"width" : @(width), @"height" : @(height), @"row_bytes" : @(row), @"output_bytes" : @(length),
        @"source_bits_per_component" : @(CGImageGetBitsPerComponent(image)),
        @"source_bits_per_pixel" : @(CGImageGetBitsPerPixel(image)),
        @"source_alpha_info" : @(CGImageGetAlphaInfo(image)),
        @"source_color_space" : (id)source_space_name ?: (id)NSNull.null,
        @"source_icc_bytes" : source_profile[@"bytes"], @"source_icc_sha256" : source_profile[@"sha256"],
        @"output_icc_bytes" : output_profile[@"bytes"], @"output_icc_sha256" : output_profile[@"sha256"],
        @"requested_output_color_space" : @(output_space),
        @"output_color_space" : (id)output_space_name ?: (id)NSNull.null, @"pixel_format" : @"RGBA8-premultiplied",
        @"row_order" : @"top-to-bottom", @"rendering_intent" : @"relative-colorimetric",
        @"pixel_sha256" : pixel_hash, @"raw_output" : raw ? @(raw) : (id)NSNull.null,
        @"timeout_seconds" : @(timeout), @"max_output_bytes" : @(max_output),
        @"timings_ms" : @{
            @"input_read" : @(read_ms), @"input_hash" : @(input_hash_ms),
            @"source_create" : @(source_ms), @"metadata_read" : @(metadata_ms), @"image_create" : @(image_ms),
            @"output_allocation" : @(allocation_ms), @"forced_draw" : @(decode_ms),
            @"pixel_hash" : @(pixel_hash_ms), @"raw_write" : @(raw_ms),
            @"total_before_report" : @((seconds() - began) * 1000)
        }
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:&error];
    if (!json || fwrite(json.bytes, 1, json.length, stdout) != json.length || fputc('\n', stdout) == EOF) {
        fputs("FAIL JSON report\n", stderr);
        status = 9;
    }
done:
    if (output_space_name)
        CFRelease(output_space_name);
    if (source_space_name)
        CFRelease(source_space_name);
    if (properties)
        CFRelease(properties);
    if (context)
        CGContextRelease(context);
    if (space)
        CGColorSpaceRelease(space);
    free(pixels);
    if (image)
        CGImageRelease(image);
    CFRelease(source);
    return status;
}

static int legacy(int argc, char **argv) {
    @autoreleasepool {
        alarm(20);
        if (argc != 2)
            return 2;
        NSURL *url = [NSURL fileURLWithPath:@(argv[1])];
        CGImageSourceRef source = CGImageSourceCreateWithURL((CFURLRef)url, NULL);
        if (!source)
            return 3;
        fprintf(stderr, "source count=%zu\n", CGImageSourceGetCount(source));
        CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        if (!image)
            return 4;
        fprintf(stderr, "image %zux%zu; decoding\n", CGImageGetWidth(image), CGImageGetHeight(image));
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx =
            CGBitmapContextCreate(NULL, 256, 256, 8, 1024, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        if (!ctx)
            return 5;
        CGContextDrawImage(ctx, CGRectMake(0, 0, 256, 256), image);
        unsigned char *bytes = CGBitmapContextGetData(ctx);
        unsigned long long sum = 0;
        for (size_t i = 0; i < 256 * 1024; i++)
            sum += bytes[i];
        fprintf(stderr, "PASS decoded checksum=%llu\n", sum);
        CGContextRelease(ctx);
        CGColorSpaceRelease(cs);
        CGImageRelease(image);
        CFRelease(source);
        return 0;
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && !strcmp(argv[1], "--full-resolution"))
            return full_resolution(argc, argv);
        return legacy(argc, argv);
    }
}
