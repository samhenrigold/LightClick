// Lives in Dock. Reads commands from /var/tmp/ex/cmd on the main queue and calls the server's window transform.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
static int (*Main)(void);
static int (*SetT)(int, uint32_t, CGAffineTransform);
static int (*GetT)(int, uint32_t, CGAffineTransform *);
static int (*Move)(int, uint32_t, CGPoint *);
static int (*Other)(int, int, int);
static void say(const char *f, ...) {
    FILE *o = fopen("/var/tmp/ex/out", "a"); if (!o) return;
    va_list a; va_start(a, f); vfprintf(o, f, a); va_end(a); fclose(o);
}
static void step(void) {
    FILE *c = fopen("/var/tmp/ex/cmd", "r"); if (!c) return;
    char l[256]; int cid = Main();
    while (fgets(l, sizeof l, c)) {
        unsigned w; double a,b,cc,d,x,y;
        if (sscanf(l, "T %u %lf %lf %lf %lf %lf %lf", &w,&a,&b,&cc,&d,&x,&y) == 7) {
            int e = SetT(cid, w, CGAffineTransformMake(a,b,cc,d,x,y)); say("T %u -> %d\n", w, e);
        } else if (sscanf(l, "G %u", &w) == 1) {
            CGAffineTransform t = {0}; int e = GetT(cid, w, &t);
            say("G %u -> %d [%g %g %g %g %g %g]\n", w, e, t.a,t.b,t.c,t.d,t.tx,t.ty);
        } else if (sscanf(l, "M %u %lf %lf", &w,&x,&y) == 3) {
            CGPoint p = {x,y}; int e = Move(cid, w, &p); say("M %u -> %d\n", w, e);
        }
    }
    fclose(c); unlink("/var/tmp/ex/cmd");
}
__attribute__((constructor)) static void start(void) {
    void *s = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    Main = dlsym(s, "SLSMainConnectionID"); SetT = dlsym(s, "SLSSetWindowTransform");
    GetT = dlsym(s, "SLSGetWindowTransform"); Move = dlsym(s, "SLSMoveWindow"); Other = dlsym(s, "SLSSetOtherUniversalConnection");
    say("loaded in %d main=%p set=%p\n", getpid(), Main, SetT);
    dispatch_async(dispatch_get_main_queue(), ^{
        static dispatch_source_t t; t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(t, DISPATCH_TIME_NOW, 30*NSEC_PER_MSEC, 5*NSEC_PER_MSEC);
        dispatch_source_set_event_handler(t, ^{ step(); });
        dispatch_resume(t);
        say("timer on main, cid %d\n", Main());
    });
}
