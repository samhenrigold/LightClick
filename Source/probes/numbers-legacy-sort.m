/* Guest-only Numbers 2.3 qualification, not a timing benchmark.
 * Root compiles for x86_64/min10.9; NEVER execute this helper on the host.
 * Wire declarations: Numbers.scriptSuite f5bff41c70f87ca9473880d457f134fdf4aaae21d9d602e4d26fe9e78b41022e.
 * NSCoreSuite declares document fileName as ppth. No UI scripting, activation,
 * launch, header adjustment, guessed properties, or alternate-table fallback.
 */
#import <Foundation/Foundation.h>
#import <AppKit/NSRunningApplication.h>
#import <Carbon/Carbon.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <mach/mach_time.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *kNumbers = "/Applications/Numbers.app/Contents/MacOS/Numbers";
static NSMutableDictionary *report;
static NSString *phase = @"arguments";
static pid_t targetPID;
static uid_t targetUID;
static struct proc_bsdinfo initialIdentity;
static NSAppleEventDescriptor *target;
static mach_timebase_info_data_t timebase;
static uint64_t started;
static unsigned sends, sortSends;

static NSString *fourcc(OSType code) {
    char b[5] = {(char)(code >> 24), (char)(code >> 16), (char)(code >> 8), (char)code, 0};
    for (int i = 0; i < 4; ++i) if ((unsigned char)b[i] < 32 || (unsigned char)b[i] > 126) b[i] = '?';
    return [NSString stringWithUTF8String:b];
}

static double elapsed(void) {
    if (!timebase.numer || !timebase.denom) return 0;
    return (double)(mach_absolute_time() - started) * timebase.numer / timebase.denom / 1e9;
}

static void emit(int code) {
    [report setObject:phase forKey:@"phase"];
    [report setObject:@(sends) forKey:@"send_count"];
    [report setObject:@(sortSends) forKey:@"sort_send_count"];
    [report setObject:@(elapsed()) forKey:@"helper_seconds"];
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:0 error:&error];
    if (!data || [data length] > 16384) {
        static const char fail[] = "{\"schema\":1,\"result\":\"NUMBERS_LEGACY_SORT_UNQUALIFIED\",\"phase\":\"report\",\"reason\":\"report_bound\"}\n";
        (void)write(STDOUT_FILENO, fail, sizeof(fail) - 1);
        _exit(2);
    }
    const uint8_t *p = [data bytes]; size_t left = [data length];
    while (left) {
        ssize_t n = write(STDOUT_FILENO, p, left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) _exit(2);
        p += n; left -= (size_t)n;
    }
    (void)write(STDOUT_FILENO, "\n", 1);
    exit(code);
}

static void refuse(NSString *reason, OSStatus status, NSAppleEventDescriptor *reply) {
    [report setObject:@"NUMBERS_LEGACY_SORT_UNQUALIFIED" forKey:@"result"];
    [report setObject:reason forKey:@"reason"];
    [report setObject:@(status) forKey:@"status"];
    if (reply) {
        [report setObject:fourcc([reply descriptorType]) forKey:@"reply_type"];
        [report setObject:@(AEGetDescDataSize([reply aeDesc])) forKey:@"reply_bytes"];
        if ([reply descriptorType] == typeAEList)
            [report setObject:@([reply numberOfItems]) forKey:@"reply_items"];
    }
    emit(1);
}

static void timedOut(int sig) {
    (void)sig;
    static const char s[] = "{\"schema\":1,\"result\":\"NUMBERS_LEGACY_SORT_UNQUALIFIED\",\"phase\":\"watchdog\",\"reason\":\"sixty_second_limit\"}\n";
    (void)write(STDOUT_FILENO, s, sizeof(s) - 1);
    _exit(124);
}

static void identity(BOOL first) {
    struct proc_bsdinfo b; char path[PROC_PIDPATHINFO_MAXSIZE];
    memset(&b, 0, sizeof(b)); memset(path, 0, sizeof(path));
    int n = proc_pidinfo(targetPID, PROC_PIDTBSDINFO, 0, &b, sizeof(b));
    int m = proc_pidpath(targetPID, path, sizeof(path));
    if (n != (int)sizeof(b) || m <= 0 || strcmp(path, kNumbers) || b.pbi_pid != (uint32_t)targetPID ||
        b.pbi_uid != targetUID || b.pbi_ruid != targetUID || !b.pbi_start_tvsec)
        refuse(@"owned_process_identity", 0, nil);
    if (first) {
        initialIdentity = b;
        [report setObject:@(b.pbi_start_tvsec) forKey:@"pid_start_sec"];
        [report setObject:@(b.pbi_start_tvusec) forKey:@"pid_start_usec"];
    } else if (b.pbi_start_tvsec != initialIdentity.pbi_start_tvsec ||
               b.pbi_start_tvusec != initialIdentity.pbi_start_tvusec) {
        refuse(@"process_start_changed", 0, nil);
    }
    if (elapsed() >= 58.0) refuse(@"deadline", 0, nil);
}

static void waitForApplicationLaunch(void) {
    double until = fmin(58.0, elapsed() + 10.0);
    for (;;) {
        identity(NO);
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:targetPID];
        if (app && [app processIdentifier] == targetPID && ![app isTerminated] && [app isFinishedLaunching]) {
            identity(NO);
            [report setObject:@{ @"method":@"NSRunningApplication.finishedLaunching", @"finished_launching":@YES,
                                @"before_first_send":(sends == 0 ? @YES : @NO), @"helper_seconds":@(elapsed()) }
                       forKey:@"readiness"];
            return;
        }
        if (elapsed() >= until) refuse(@"finished_launching_deadline", 0, nil);
        /* These metadata snapshots persist until a main-run-loop turn. Pump
         * only the helper's default loop; no NSApplication, activation, input,
         * or AppleEvent is created/sent here. The sleep bounds polling rate. */
        (void)CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.001, true);
        usleep(50000);
    }
}

/* Classic CreateObjSpecifier is the actual 10.9 API name. Inputs are borrowed. */
static NSAppleEventDescriptor *object(DescType cls, NSAppleEventDescriptor *container,
                                     DescType form, NSAppleEventDescriptor *key) {
    if (!container) container = [NSAppleEventDescriptor nullDescriptor];
    if (!key) refuse(@"object_key_missing", 0, nil);
    AEDesc result = {typeNull, NULL};
    OSStatus e = CreateObjSpecifier(cls, (AEDesc *)[container aeDesc], form,
                                   (AEDesc *)[key aeDesc], false, &result);
    if (e) refuse(@"object_specifier", e, nil);
    NSAppleEventDescriptor *d = [[[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&result] autorelease];
    if (!d) { AEDisposeDesc(&result); refuse(@"object_allocation", 0, nil); }
    return d;
}

static NSAppleEventDescriptor *all(DescType cls, NSAppleEventDescriptor *container) {
    OSType ordinal = kAEAll;
    return object(cls, container, formAbsolutePosition,
                  [NSAppleEventDescriptor descriptorWithDescriptorType:typeAbsoluteOrdinal bytes:&ordinal length:sizeof(ordinal)]);
}

static NSAppleEventDescriptor *at(DescType cls, NSAppleEventDescriptor *container, int index) {
    return object(cls, container, formAbsolutePosition, [NSAppleEventDescriptor descriptorWithInt32:index]);
}

static NSAppleEventDescriptor *property(OSType prop, NSAppleEventDescriptor *container) {
    return object(typeProperty, container, formPropertyID, [NSAppleEventDescriptor descriptorWithTypeCode:prop]);
}

static NSAppleEventDescriptor *sendLegacyEvent(OSType eventClass, OSType eventID,
                                    NSAppleEventDescriptor *direct,
                                    NSAppleEventDescriptor *by, BOOL requireResult) {
    identity(NO);
    if (++sends > 128) refuse(@"send_bound", 0, nil);
    AppleEvent event = {typeNull, NULL}, reply = {typeNull, NULL};
    OSStatus e = AECreateAppleEvent(eventClass, eventID, [target aeDesc], kAutoGenerateReturnID,
                                    kAnyTransactionID, &event);
    if (!e) e = AEPutParamDesc(&event, keyDirectObject, [direct aeDesc]);
    if (!e && by) {
        e = AEPutParamDesc(&event, 'NMsb', [by aeDesc]);
        if (!e) {
            OSType ascending = 'ascn'; AEDesc d = {typeNull, NULL};
            e = AECreateDesc(typeEnumerated, &ascending, sizeof(ascending), &d);
            if (!e) e = AEPutParamDesc(&event, 'NMsd', &d);
            AEDisposeDesc(&d);
        }
    }
    if (e) { AEDisposeDesc(&event); refuse(@"event_construction", e, nil); }
    double remain = 58.0 - elapsed();
    double messageLimit = eventClass == 'aevt' && eventID == 'odoc' ? 15.0 : 2.0;
    long ticks = (long)floor(fmin(messageLimit, remain) * 60.0);
    if (ticks < 1) { AEDisposeDesc(&event); refuse(@"deadline", 0, nil); }
    if (eventClass == 'NmTb' && eventID == 'SORT') {
        if (++sortSends != 1) { AEDisposeDesc(&event); refuse(@"sort_repeat_refused", 0, nil); }
    }
    e = AESendMessage(&event, &reply,
                     kAEWaitReply | kAENeverInteract | kAEDontRecord | kAEDontReconnect, ticks);
    AEDisposeDesc(&event);
    identity(NO);
    if (e) { AEDisposeDesc(&reply); refuse(@"send_failed_no_retry", e, nil); }
    SInt32 appError = 0; DescType errorType = typeNull; Size errorSize = 0;
    e = AEGetParamPtr(&reply, keyErrorNumber, typeSInt32, &errorType, &appError, sizeof(appError), &errorSize);
    if (e != errAEDescNotFound && (e || errorSize != sizeof(appError))) {
        AEDisposeDesc(&reply); refuse(@"error_reply_shape", e, nil);
    }
    if (!e && appError) { AEDisposeDesc(&reply); refuse(@"application_error_no_retry", appError, nil); }
    AEDesc value = {typeNull, NULL};
    e = AEGetParamDesc(&reply, keyDirectObject, typeWildCard, &value);
    AEDisposeDesc(&reply);
    if (e == errAEDescNotFound && !requireResult) return [NSAppleEventDescriptor nullDescriptor];
    if (e) refuse(@"missing_result", e, nil);
    if (AEGetDescDataSize(&value) > 65536) { AEDisposeDesc(&value); refuse(@"reply_bound", 0, nil); }
    NSAppleEventDescriptor *d = [[[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&value] autorelease];
    if (!d) { AEDisposeDesc(&value); refuse(@"reply_allocation", 0, nil); }
    return d;
}

static NSAppleEventDescriptor *get(NSAppleEventDescriptor *specifier) {
    return sendLegacyEvent('core', 'getd', specifier, nil, YES);
}

static void listCount(NSAppleEventDescriptor *d, NSInteger expected, NSString *reason) {
    if ([d descriptorType] != typeAEList || [d numberOfItems] != expected) refuse(reason, 0, d);
}

/* Reject text, boolean, missing, and nested values before numeric coercion. */
static int number(NSAppleEventDescriptor *d) {
    DescType t = [d descriptorType];
    if (t != typeSInt16 && t != typeSInt32 && t != typeSInt64 && t != typeUInt32 &&
        t != typeUInt64 && t != typeIEEE32BitFloatingPoint && t != typeIEEE64BitFloatingPoint)
        refuse(@"non_numeric_value", 0, d);
    AEDesc converted = {typeNull, NULL}; double value = 0;
    OSStatus e = AECoerceDesc([d aeDesc], typeIEEE64BitFloatingPoint, &converted);
    if (!e && AEGetDescDataSize(&converted) != sizeof(value)) e = errAECoercionFail;
    if (!e) e = AEGetDescData(&converted, &value, sizeof(value));
    AEDisposeDesc(&converted);
    if (e || !isfinite(value) || value != floor(value) || value < INT_MIN || value > INT_MAX)
        refuse(@"numeric_shape", e, d);
    return (int)value;
}

static NSArray *pairs(NSAppleEventDescriptor *table, BOOL ascending) {
    NSAppleEventDescriptor *rows = get(property('NmTr', table));
    NSAppleEventDescriptor *cols = get(property('NmTc', table));
    int nr = number(rows), nc = number(cols);
    [report setObject:@(nr) forKey:@"row_count"];
    [report setObject:@(nc) forKey:@"column_count"];
    if (nr != 32 || nc != 2) refuse(@"table_shape_no_header_normalization", 0, nil);
    NSAppleEventDescriptor *a = get(property('NMCv', all('NmCl', at('NMCo', table, 1))));
    NSAppleEventDescriptor *b = get(property('NMCv', all('NmCl', at('NMCo', table, 2))));
    [report setObject:@{ @"row_count_type":fourcc([rows descriptorType]),
                        @"column_count_type":fourcc([cols descriptorType]),
                        @"column_value_types":@[fourcc([a descriptorType]), fourcc([b descriptorType])],
                        @"column_value_counts":@[@([a numberOfItems]), @([b numberOfItems])] }
               forKey:ascending ? @"after_shape" : @"before_shape"];
    listCount(a, 32, @"first_column_value_shape"); listCount(b, 32, @"second_column_value_shape");
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:32];
    NSMutableSet *types = [NSMutableSet set];
    for (int i = 0; i < 32; ++i) {
        NSAppleEventDescriptor *ka = [a descriptorAtIndex:i + 1], *vb = [b descriptorAtIndex:i + 1];
        int k = number(ka), v = number(vb), expected = ascending ? i + 1 : 32 - i;
        [types addObject:fourcc([ka descriptorType])]; [types addObject:fourcc([vb descriptorType])];
        [out addObject:@[@(k), @(v)]];
        if (k != expected || v != expected * 17 + 3) {
            [report setObject:out forKey:ascending ? @"after_pairs" : @"before_pairs"];
            refuse(ascending ? @"sorted_pairs_mismatch" : @"initial_pairs_mismatch", 0, nil);
        }
    }
    [report setObject:[[types allObjects] sortedArrayUsingSelector:@selector(compare:)] forKey:ascending ? @"after_numeric_types" : @"before_numeric_types"];
    return out;
}

static NSString *fixture(const char *arg) {
    char canonical[PATH_MAX], directory[PATH_MAX]; struct stat ds, fs, opened;
    if (!realpath(arg, canonical) || strcmp(arg, canonical)) refuse(@"csv_not_canonical", 0, nil);
    const char *prefix = "/private/var/tmp/LightClickNumbersSort.";
    size_t prefixLength = strlen(prefix), n = strlen(canonical);
    if (strncmp(canonical, prefix, prefixLength) || n <= prefixLength + 10 || n >= sizeof(directory))
        refuse(@"csv_path_scope", 0, nil);
    const char *suffix = strstr(canonical + prefixLength, "/input.csv");
    if (!suffix || strcmp(suffix, "/input.csv") || suffix == canonical + prefixLength || suffix - (canonical + prefixLength) > 64)
        refuse(@"csv_nonce_scope", 0, nil);
    for (const char *p = canonical + prefixLength; p < suffix; ++p)
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
              (*p >= '0' && *p <= '9') || *p == '-' || *p == '_')) refuse(@"csv_nonce_characters", 0, nil);
    size_t dlen = (size_t)(suffix - canonical); memcpy(directory, canonical, dlen); directory[dlen] = 0;
    if (lstat(directory, &ds) || !S_ISDIR(ds.st_mode) || ds.st_uid != targetUID || (ds.st_mode & 0777) != 0700 ||
        lstat(canonical, &fs) || !S_ISREG(fs.st_mode) || fs.st_uid != targetUID || (fs.st_mode & 0777) != 0600 || fs.st_nlink != 1)
        refuse(@"fixture_owner_mode", 0, nil);
    int fd = open(canonical, O_RDONLY | O_NOFOLLOW);
    if (fd < 0 || fstat(fd, &opened) || opened.st_dev != fs.st_dev || opened.st_ino != fs.st_ino || opened.st_size != fs.st_size) {
        if (fd >= 0) close(fd); refuse(@"fixture_open_identity", 0, nil);
    }
    char expected[1024], actual[1024]; size_t length = 0;
    for (int k = 32; k >= 1; --k) length += (size_t)snprintf(expected + length, sizeof(expected) - length, "%d,%d\n", k, k * 17 + 3);
    ssize_t got = 0;
    while (got < (ssize_t)sizeof(actual)) {
        ssize_t r = read(fd, actual + got, sizeof(actual) - (size_t)got);
        if (r < 0 && errno == EINTR) continue;
        if (r < 0) { close(fd); refuse(@"fixture_read", 0, nil); }
        if (!r) break; got += r;
    }
    if (close(fd) || got != (ssize_t)length || fs.st_size != (off_t)length || memcmp(actual, expected, length))
        refuse(@"fixture_bytes", 0, nil);
    return [NSString stringWithUTF8String:canonical];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        mach_timebase_info(&timebase); started = mach_absolute_time();
        report = [NSMutableDictionary dictionaryWithObjectsAndKeys:@1, @"schema",
                  @"NUMBERS_LEGACY_SORT_UNQUALIFIED", @"result", @YES, @"no_ui_input",
                  @NO, @"timing_qualified", @NO, @"document_owned", @"NmTb/SORT", @"sort_event",
                  @"ascn", @"sort_direction", @"two_column_bulk_values", @"readback_mode", nil];
        @try {
            char os[64] = {0}; size_t osSize = sizeof(os);
            if (sysctlbyname("kern.osrelease", os, &osSize, NULL, 0) || strncmp(os, "13.", 3))
                refuse(@"requires_guest_Darwin13", 0, nil);
            if (!timebase.numer || !timebase.denom) refuse(@"clock_timebase", 0, nil);
            if (argc != 7 || strcmp(argv[1], "--pid") || strcmp(argv[3], "--csv") || strcmp(argv[5], "--uid"))
                refuse(@"arguments", 0, nil);
            char *pEnd = NULL, *uEnd = NULL; errno = 0;
            long p = strtol(argv[2], &pEnd, 10), u = strtol(argv[6], &uEnd, 10);
            if (errno || !argv[2][0] || !argv[6][0] || *pEnd || *uEnd || p <= 1 || p > INT_MAX ||
                u <= 0 || (unsigned long)u > UINT_MAX || getuid() != (uid_t)u || geteuid() != (uid_t)u)
                refuse(@"pid_uid_arguments", 0, nil);
            targetPID = (pid_t)p; targetUID = (uid_t)u;
            [report setObject:@(targetPID) forKey:@"pid"]; [report setObject:@(targetUID) forKey:@"uid"];
            signal(SIGALRM, timedOut); alarm(60);
            phase = @"fixture"; NSString *csv = fixture(argv[4]); [report setObject:csv forKey:@"csv_path"];
            phase = @"identity"; identity(YES);
            phase = @"application_readiness"; waitForApplicationLaunch();
            target = [NSAppleEventDescriptor descriptorWithDescriptorType:typeKernelProcessID bytes:&targetPID length:sizeof(targetPID)];
            if (!target) refuse(@"pid_address", 0, nil);
            phase = @"initial_documents";
            NSAppleEventDescriptor *docs = get(all('docu', nil));
            listCount(docs, 0, @"initial_documents_must_be_empty");
            [report setObject:@0 forKey:@"initial_documents"];
            phase = @"open_private_csv";
            NSData *urlBytes = [[[[NSURL fileURLWithPath:csv] absoluteURL] absoluteString] dataUsingEncoding:NSUTF8StringEncoding];
            NSAppleEventDescriptor *file = [NSAppleEventDescriptor descriptorWithDescriptorType:typeFileURL data:urlBytes];
            NSAppleEventDescriptor *files = [NSAppleEventDescriptor listDescriptor]; [files insertDescriptor:file atIndex:1];
            (void)sendLegacyEvent('aevt', 'odoc', files, nil, NO);
            phase = @"opened_documents";
            double openDeadline = fmin(25.0, elapsed() + 15.0);
            do {
                docs = get(all('docu', nil));
                if ([docs descriptorType] != typeAEList || [docs numberOfItems] > 1) refuse(@"opened_document_shape", 0, docs);
                [report setObject:@([docs numberOfItems]) forKey:@"opened_documents_observed"];
                if ([docs numberOfItems] == 1) break;
                if (elapsed() >= openDeadline) refuse(@"opened_document_missing", 0, docs);
                usleep(100000);
            } while (1);
            NSAppleEventDescriptor *document = [docs descriptorAtIndex:1];
            if ([document descriptorType] != typeObjectSpecifier) refuse(@"document_not_object", 0, document);
            phase = @"document_path";
            /* A successful nil filename can omit the direct result for an imported untitled document. */
            NSAppleEventDescriptor *path = sendLegacyEvent('core', 'getd', property('ppth', document), nil, NO);
            DescType pt = [path descriptorType];
            NSString *pathState = nil;
            if (pt == typeUnicodeText || pt == typeUTF8Text || pt == typeChar) {
                NSString *pathString = [path stringValue];
                if (!pathString) refuse(@"document_path_decode", 0, path);
                if ([pathString isEqualToString:csv]) pathState = @"exact_csv";
                else if (![pathString length]) pathState = @"empty_import_path";
                else refuse(@"document_path_mismatch", 0, path);
            } else if (pt == typeNull) pathState = @"null_import_path";
            else if (pt == typeType && [path typeCodeValue] == 'msng') pathState = @"missing_import_path";
            else refuse(@"document_path_type", 0, path);
            [report setObject:fourcc(pt) forKey:@"document_path_type"];
            [report setObject:pathState forKey:@"document_path_state"];
            phase = @"document_shape";
            NSAppleEventDescriptor *sheets = get(all('NmSh', document)); listCount(sheets, 1, @"sheet_count");
            NSAppleEventDescriptor *sheet = [sheets descriptorAtIndex:1];
            if ([sheet descriptorType] != typeObjectSpecifier) refuse(@"sheet_not_object", 0, sheet);
            NSAppleEventDescriptor *tables = get(all('NmTb', sheet)); listCount(tables, 1, @"table_count");
            NSAppleEventDescriptor *table = [tables descriptorAtIndex:1];
            if ([table descriptorType] != typeObjectSpecifier) refuse(@"table_not_object", 0, table);
            [report setObject:@{ @"documents":fourcc([docs descriptorType]),
                                @"document":fourcc([document descriptorType]),
                                @"sheets":fourcc([sheets descriptorType]), @"sheet":fourcc([sheet descriptorType]),
                                @"tables":fourcc([tables descriptorType]), @"table":fourcc([table descriptorType]) }
                       forKey:@"object_shape"];
            [report setObject:@1 forKey:@"document_count"]; [report setObject:@1 forKey:@"sheet_count"];
            [report setObject:@1 forKey:@"table_count"];
            phase = @"before_readback"; [report setObject:pairs(table, NO) forKey:@"before_pairs"];
            /* Import may create an untitled document. Ownership then rests on the
             * same owned PID, zero initial documents, exactly one private open,
             * exactly one resulting document/table, and ALL fixture pairs. No
             * unrelated nonempty ppth or failed path query is tolerated. */
            [report setObject:@YES forKey:@"document_owned"];
            [report setObject:@"empty_to_one_private_open_and_full_fixture" forKey:@"document_ownership_basis"];
            phase = @"sort";
            (void)sendLegacyEvent('NmTb', 'SORT', table, at('NMCo', table, 1), NO);
            [report setObject:@0 forKey:@"sort_status"];
            phase = @"after_readback"; [report setObject:pairs(table, YES) forKey:@"after_pairs"];
            phase = @"complete"; identity(NO);
            [report setObject:@"NUMBERS_LEGACY_SORT_PASS" forKey:@"result"];
            alarm(0); emit(0);
        } @catch (NSException *exception) {
            [report setObject:[exception name] forKey:@"exception_class"];
            refuse(@"exception", 0, nil);
        }
    }
    return 1;
}
