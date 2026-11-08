// PROBE ONLY. Compile x86_64/macOS10.14; NEVER execute on the host or inject into FCP.
// This tests whether appending an explicit OpenCL dialect reaches the old frontend.
// It does not repair source request serialization or OpenCL pipeline semantics.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <CommonCrypto/CommonDigest.h>
#include "opencl-diagnostic-options.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <fcntl.h>

static Class optionsClass;
static char languageKey, sourceKey;
static BOOL standardKernel, standardHeader;
static NSString *diagnosticMode;
static __thread unsigned nativeLibraryDepth;
static NSString *const requiredSourceSHA = @LC_OPENCL_DIAGNOSTIC_SOURCE_SHA;
static id (*nativeArguments)(id, SEL);
static id (*nativeLibrary)(id, SEL, id, id, NSError **);
static unsigned events;

static void emit(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
    if (!data || data.length > 24576 || __sync_fetch_and_add(&events, 1) >= 32) return;
    fputs("LC_OPENCL_DIALECT ", stderr);
    fwrite(data.bytes, 1, data.length, stderr);
    fputc('\n', stderr); fflush(stderr);
}
static void refuse(NSString *reason) {
    emit(@{@"event":@"refused", @"reason":reason});
    _exit(78);
}
static BOOL hasType(Method method, unsigned argument, const char *expected) {
    if (!method) return NO;
    char *type = argument == UINT_MAX ? method_copyReturnType(method) : method_copyArgumentType(method, argument);
    BOOL match = type && !strcmp(type, expected);
    free(type); return match;
}
static NSString *bounded(id value) {
    if (!value) return @"";
    if (![value isKindOfClass:[NSString class]] || [value length] > 8192) refuse(@"native arguments are not a bounded NSString");
    return value;
}
static NSString *diagnosticText(NSString *text) {
    return text.length > 8192 ? [[text substringToIndex:8192] stringByAppendingString:@" [truncated]"] : (text ?: @"");
}
static void setSourceLanguage(id self, SEL selector, NSUInteger value) {
    if (![self isKindOfClass:optionsClass] || value != 1) refuse(@"only sourceLanguage=1 on actual compile options is authorized");
    objc_setAssociatedObject(self, &languageKey, @1, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    emit(@{@"event":@"sourceLanguage", @"selector":NSStringFromSelector(selector), @"value":@(value), @"encoding":@"v@:Q"});
}
static id additionalArguments(id self, SEL selector) {
    id original = nativeArguments(self, selector);
    NSNumber *language = objc_getAssociatedObject(self, &languageKey);
    if (!language) return original;
    if (![language isEqual:@1]) refuse(@"associated source language changed");
    NSString *caller = bounded(original);
    if (standardKernel && ![objc_getAssociatedObject(self,&sourceKey) isEqual:requiredSourceSHA]) refuse(@"standard mode requires exact synthetic source identity");
    char transformed[32768];
    if (!lc_opencl_diagnostic_options_with_header(caller.UTF8String,standardKernel,standardHeader,transformed,sizeof(transformed))) refuse(@"transformed arguments exceed budget");
    NSString *actual = [NSString stringWithUTF8String:transformed];
    Dl_info site = {0};
    void *returnAddress = __builtin_return_address(0);
    BOOL identified = dladdr(returnAddress,&site) != 0 && site.dli_fname && site.dli_fbase;
    NSString *image = identified ? [NSString stringWithUTF8String:site.dli_fname] : @"";
    uintptr_t offset = identified ? (uintptr_t)returnAddress-(uintptr_t)site.dli_fbase : 0;
    emit(@{@"event":@"arguments", @"selector":NSStringFromSelector(selector), @"callerArguments":caller,
           @"actualArguments":actual, @"mode":diagnosticMode,
           @"nativeLibraryScope":@(nativeLibraryDepth > 0), @"callerImage":image, @"callerImageOffset":@(offset),
           @"sourceSHA256":objc_getAssociatedObject(self,&sourceKey) ?: @"", @"languageVersion":@([(MTLCompileOptions *)self languageVersion]),
           @"note":@"Mojave still emits its native Metal standard; this is a dialect experiment only"});
    return actual;
}
static id newLibrary(id self, SEL selector, id source, id options, NSError **error) {
    BOOL diagnostic = objc_getAssociatedObject(options, &languageKey) != nil;
    if (!diagnostic) return nativeLibrary(self, selector, source, options, error);
    if (![options isKindOfClass:optionsClass] || ![source isKindOfClass:[NSString class]]) refuse(@"unexpected library input classes");
    NSData *bytes = [source dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes || bytes.length > UINT32_MAX) refuse(@"source cannot be hashed within budget");
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,digest);
    NSMutableString *hash = [NSMutableString stringWithCapacity:64];
    for (unsigned i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [hash appendFormat:@"%02x",digest[i]];
    if (standardKernel && !lc_opencl_diagnostic_source_allowed(hash.UTF8String,bytes.length)) refuse(@"standard mode refuses non-fixture source");
    if (standardHeader) {
        char canonical[4096];
        const char *path = LC_OPENCL_DIAGNOSTIC_HEADER_PATH;
        if (!realpath(path,canonical) || strcmp(path,canonical)) refuse(@"OpenCL header path is not canonical");
        int fd = open(path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK);
        if (fd < 0) refuse(@"supplied OpenCL header unavailable");
        struct stat info;
        if (fstat(fd,&info) || !S_ISREG(info.st_mode) || info.st_uid != 0 || info.st_size != 805181) { close(fd); refuse(@"OpenCL header metadata differs from supplied resource"); }
        CC_SHA256_CTX context; CC_SHA256_Init(&context);
        unsigned char block[16384], headerDigest[CC_SHA256_DIGEST_LENGTH]; ssize_t count; size_t total=0;
        while ((count=read(fd,block,sizeof(block))) > 0) { total+=(size_t)count; if(total>805181) break; CC_SHA256_Update(&context,block,(CC_LONG)count); }
        struct stat after;
        BOOL stable = !fstat(fd,&after) && info.st_dev==after.st_dev && info.st_ino==after.st_ino && info.st_size==after.st_size && info.st_mtime==after.st_mtime && info.st_ctime==after.st_ctime;
        close(fd); CC_SHA256_Final(headerDigest,&context);
        NSMutableString *headerHash=[NSMutableString stringWithCapacity:64];
        for(unsigned i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [headerHash appendFormat:@"%02x",headerDigest[i]];
        if (!stable || count < 0 || total != 805181 || ![headerHash isEqual:@LC_OPENCL_DIAGNOSTIC_HEADER_SHA]) refuse(@"OpenCL header bytes differ from supplied resource");
        emit(@{@"event":@"headerVerified",@"path":@LC_OPENCL_DIAGNOSTIC_HEADER_PATH,@"bytes":@(total),@"sha256":headerHash,@"device":@(info.st_dev),@"inode":@(info.st_ino),@"uid":@(info.st_uid)});
    }
    objc_setAssociatedObject(options,&sourceKey,hash,OBJC_ASSOCIATION_COPY_NONATOMIC);
    emit(@{@"event":@"libraryBegin", @"sourceCharacters":@([source length]), @"sourceBytes":@(bytes.length),
           @"sourceSHA256":hash, @"languageVersion":@([(MTLCompileOptions *)options languageVersion]),
           @"mode":diagnosticMode});
    NSError *local = nil;
    @try {
        nativeLibraryDepth++;
        id library = nativeLibrary(self, selector, source, options, error ?: &local);
        NSError *failure = library ? nil : (error ? *error : local);
        emit(@{@"event":@"libraryReturn", @"libraryCreated":@(library != nil),
               @"errorDomain":failure.domain ?: @"", @"errorCode":@(failure ? failure.code : 0),
               @"errorDescription":diagnosticText(failure.localizedDescription), @"errorDescriptionTruncated":@(failure.localizedDescription.length > 8192),
               @"note":@"Compilation progress is not semantic or FCP success; pipeline mode remains untouched"});
        return library;
    } @catch (NSException *exception) {
        emit(@{@"event":@"libraryException", @"name":diagnosticText(exception.name), @"reason":diagnosticText(exception.reason), @"reasonTruncated":@(exception.reason.length > 8192)});
        @throw;
    } @finally {
        if (nativeLibraryDepth) nativeLibraryDepth--;
    }
}
__attribute__((constructor)) static void installDiagnostic(void) {
    @autoreleasepool {
        const char *enabled = getenv("LC_OPENCL_SOURCE_LANGUAGE_DIAGNOSTIC");
        if (!enabled || strcmp(enabled, "1")) return;
        const char *mode = getenv("LC_OPENCL_DIAGNOSTIC_MODE");
        if (mode && strcmp(mode,"dialect-only") && strcmp(mode,"standard-kernel") && strcmp(mode,"standard-header")) refuse(@"unknown diagnostic mode");
        standardHeader = mode && !strcmp(mode,"standard-header");
        standardKernel = standardHeader || (mode && !strcmp(mode,"standard-kernel"));
        diagnosticMode = standardHeader ? @"standard-header" : (standardKernel ? @"standard-kernel" : @"dialect-only");
        NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
        if (os.majorVersion != 10 || os.minorVersion != 14) refuse(@"diagnostic requires Mojave10.14");
        optionsClass = objc_getClass("MTLCompileOptionsInternal");
        Class device = objc_getClass("_MTLDevice");
        Method getter = class_getInstanceMethod(optionsClass, @selector(additionalCompilerArguments));
        Method setter = class_getInstanceMethod(optionsClass, @selector(setAdditionalCompilerArguments:));
        Method library = class_getInstanceMethod(device, @selector(newLibraryWithSource:options:error:));
        Method version = class_getInstanceMethod(optionsClass, @selector(languageVersion));
        if (!optionsClass || !device || !hasType(getter, UINT_MAX, "@") || method_getNumberOfArguments(getter) != 2 ||
            !hasType(setter, UINT_MAX, "v") || method_getNumberOfArguments(setter) != 3 || !hasType(setter, 2, "@") ||
            !hasType(version, UINT_MAX, "Q") || !hasType(library, UINT_MAX, "@") || method_getNumberOfArguments(library) != 5 ||
            !hasType(library, 2, "@") || !hasType(library, 3, "@") || !hasType(library, 4, "^@")) refuse(@"native method ABI missing or unexpected");
        if (class_getInstanceMethod(optionsClass, sel_registerName("setSourceLanguage:"))) refuse(@"native sourceLanguage already exists; refuse to replace it");
        nativeArguments = (void *)method_getImplementation(getter);
        nativeLibrary = (void *)method_getImplementation(library);
        if (!class_addMethod(optionsClass, sel_registerName("setSourceLanguage:"), (IMP)setSourceLanguage, "v@:Q")) refuse(@"cannot install diagnostic sourceLanguage setter");
        method_setImplementation(getter, (IMP)additionalArguments);
        method_setImplementation(library, (IMP)newLibrary);
        emit(@{@"event":@"installed", @"pid":@(getpid()), @"class":NSStringFromClass(optionsClass),
               @"getterEncoding":@(method_getTypeEncoding(getter)), @"libraryEncoding":@(method_getTypeEncoding(library)),
               @"pipelineModeChanged":@NO, @"mode":diagnosticMode,
               @"requiredSourceSHA256":standardKernel ? requiredSourceSHA : @"", @"qualification":@"probe-only dialect diagnostic; never a compatibility fix"});
    }
}
