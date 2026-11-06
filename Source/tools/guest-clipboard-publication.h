#pragma once
// clearContents/declareTypes publish ownership before the owner supplies data;
// setString need not advance changeCount again. Never commit that empty gap as
// the final copy. Back off only pending reads, without a deadline that discards
// a slow owner's eventual content. A new generation is always tried at once.
typedef struct {
    NSInteger change;
    NSTimeInterval nextRead, delay;
} VIMClipboardPendingPublication;
static inline BOOL VIMClipboardPublicationDue(VIMClipboardPendingPublication *state, NSInteger change,
                                              NSTimeInterval now) {
    if (!state->delay || state->change != change) {
        state->change = change;
        state->nextRead = 0;
        state->delay = .2;
    }
    return now >= state->nextRead;
}
static inline void VIMClipboardPublicationPending(VIMClipboardPendingPublication *state, NSTimeInterval now) {
    state->nextRead = now + state->delay;
    state->delay = MIN(1, state->delay * 2);
}

// Rich frames: RTF and PNG next to the text, shared by the guest tool and the host bridge. Protocol 2 and its token are
// unchanged. The guest offers "rich" in hello and the host answers with the same field in ready, so a tool or a host
// that predates this never sees anything but text frames.
#if __ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ < 1060
#define NSPasteboardTypeString NSStringPboardType
#define NSPasteboardTypeRTF NSRTFPboardType
#define NSPasteboardTypeTIFF NSTIFFPboardType
#endif
#ifdef VIM_OPENGL_GUEST
#define NSBitmapImageFileTypePNG NSPNGFileType // period SDKs predate the new spelling
#endif
#define VIMClipboardRichLimitSerial (1024u * 1024u) // COM1 is nominally 115200 baud: about 2 minutes for this
#define VIMClipboardRichLimitVirtio (4u * 1024u * 1024u)
// With the limits above, a frame fits the 8 MiB wire limit even at JSON's worst case of six bytes per text byte.
#define VIMClipboardRichTextLimit (256u * 1024u)
#define VIMClipboardImageSourceLimit (64u * 1024u * 1024u) // the largest TIFF we'll decode to get its PNG
#define VIMClipboardImagePixelLimit 33554432.0 // about 128 MB as an uncompressed guest TIFF
static inline NSArray *VIMClipboardRichTypes(void) {
    NSMutableArray *types = [NSMutableArray arrayWithObjects:NSPasteboardTypeRTF, NSPasteboardTypeTIFF, nil];
#if __ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ >= 1060
    [types addObject:NSPasteboardTypePNG];
#endif
    return types;
}
static inline BOOL VIMClipboardIsPNG(NSData *data) {
    return data.length > 8 && !memcmp(data.bytes, "\x89PNG\r\n\x1a\n", 8);
}
// Takes the formats worth sending. Returns whether the board held any of their bytes, usable or not: only an owner
// that hasn't supplied its data yet is worth reading again.
static inline BOOL VIMClipboardReadRich(NSPasteboard *board, NSData **rtf, NSData **png) {
    *rtf = [board dataForType:NSPasteboardTypeRTF];
    NSData *tiff = nil, *source = nil;
#if __ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ >= 1060
    source = [board dataForType:NSPasteboardTypePNG];
#endif
    *png = VIMClipboardIsPNG(source) ? source : nil;
    if (!*png)
        tiff = [board dataForType:NSPasteboardTypeTIFF];
    if (tiff.length && tiff.length <= VIMClipboardImageSourceLimit) {
        NSBitmapImageRep *image = [NSBitmapImageRep imageRepWithData:tiff];
        *png = [image representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    }
    return *rtf || source || tiff;
}
// Nil when nothing rich fits, so the caller falls back to a text frame. RTF goes first: it's small and it's the copy's
// own text, where the image may only be a picture of it. The caller adds the sequence.
static inline NSMutableDictionary *VIMClipboardRichFrame(NSString *text, NSData *rtf, NSData *png, NSUInteger limit) {
    if ([text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > VIMClipboardRichTextLimit)
        return nil;
    NSMutableDictionary *frame = [NSMutableDictionary dictionary];
    NSUInteger used = 0;
    NSArray *keys = [NSArray arrayWithObjects:@"rtf", @"image", nil];
    NSData *payloads[] = {rtf, png};
    for (NSUInteger i = 0; i < 2; i++) {
        NSData *payload = payloads[i];
        if (!payload.length || payload.length > limit - used)
            continue;
        used += payload.length;
#if __ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ >= 1090
        [frame setObject:[payload base64EncodedStringWithOptions:0] forKey:[keys objectAtIndex:i]];
#else
        [frame setObject:[payload base64Encoding] forKey:[keys objectAtIndex:i]];
#endif
    }
    if (!frame.count)
        return nil;
    [frame setObject:@"rich" forKey:@"type"];
    if (text)
        [frame setObject:text forKey:@"text"];
    return frame;
}
static inline NSData *VIMClipboardDecodePayload(id value, NSUInteger limit) {
    if (![value isKindOfClass:[NSString class]] || [value length] / 4 > limit / 3 + 1)
        return nil;
#if __ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ >= 1090
    NSData *data = [[NSData alloc] initWithBase64EncodedString:value options:0];
#else
    NSData *data = [[NSData alloc] initWithBase64Encoding:value];
#endif
#if !__has_feature(objc_arc)
    [data autorelease];
#endif
    return data;
}
// The peer is untrusted: NO stops the connection, as any other malformed frame does. The bytes aren't parsed here.
static inline BOOL VIMClipboardReadRichFrame(NSDictionary *message, NSUInteger limit, NSString **text, NSData **rtf,
                                             NSData **png) {
    id encodedRTF = [message objectForKey:@"rtf"], encodedPNG = [message objectForKey:@"image"];
    *text = [message objectForKey:@"text"];
    if (*text && ![*text isKindOfClass:[NSString class]])
        return NO;
    *rtf = encodedRTF ? VIMClipboardDecodePayload(encodedRTF, limit) : nil;
    *png = encodedPNG ? VIMClipboardDecodePayload(encodedPNG, limit) : nil;
    if (!limit || (encodedRTF && !*rtf) || (encodedPNG && !VIMClipboardIsPNG(*png)) || (!encodedRTF && !encodedPNG))
        return NO;
    return (*rtf).length <= limit && (*png).length <= limit - (*rtf).length;
}
// `tiff`: also offer a decoded TIFF, which is all an older guest's apps read. The host passes NO, so it never decodes a
// guest's image itself. Leaves the board alone if there turns out to be nothing to write.
static inline void VIMClipboardPublishRich(NSPasteboard *board, NSString *text, NSData *rtf, NSData *png, BOOL tiff) {
    NSData *converted = nil;
    if (tiff && png) {
        NSBitmapImageRep *image = [NSBitmapImageRep imageRepWithData:png];
        if ((double)image.pixelsWide * (double)image.pixelsHigh <= VIMClipboardImagePixelLimit)
            converted = image.TIFFRepresentation;
    }
    NSMutableArray *types = [NSMutableArray array];
    if (text)
        [types addObject:NSPasteboardTypeString];
    if (rtf)
        [types addObject:NSPasteboardTypeRTF];
    if (converted)
        [types addObject:NSPasteboardTypeTIFF];
#if __ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ >= 1060
    if (png)
        [types addObject:NSPasteboardTypePNG];
#endif
    if (!types.count)
        return;
    [board declareTypes:types owner:nil];
    if (text)
        [board setString:text forType:NSPasteboardTypeString];
    if (rtf)
        [board setData:rtf forType:NSPasteboardTypeRTF];
    if (converted)
        [board setData:converted forType:NSPasteboardTypeTIFF];
#if __ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ >= 1060
    if (png)
        [board setData:png forType:NSPasteboardTypePNG];
#endif
}
