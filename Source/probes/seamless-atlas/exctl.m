// In the console session: lists windows, posts events, reads the pointer.
#import <Cocoa/Cocoa.h>
#include "/Users/shg/Developer/LightClick/Source/probes/seamless-session-join.h"
#include <libproc.h>
static pid_t finder(void){ pid_t p[4096]; int n=proc_listallpids(p,sizeof p); for(int i=0;i<n;i++){char s[64]; if(proc_name(p[i],s,sizeof s)>0&&!strcmp(s,"Finder"))return p[i];} return 0; }
static void post(CGEventType t, CGPoint p, int clicks){ CGEventRef e=CGEventCreateMouseEvent(NULL,t,p,kCGMouseButtonLeft); CGEventSetIntegerValueField(e,kCGMouseEventClickState,clicks); CGEventPost(kCGHIDEventTap,e); CFRelease(e); usleep(30000);}
int main(int argc,char**argv){ @autoreleasepool{
 if(geteuid()==0 && join_session_of(finder())) puts("join failed");
 if(argc<2) return 2; const char*c=argv[1];
 if(!strcmp(c,"list")){ NSArray *a=CFBridgingRelease(CGWindowListCopyWindowInfo(argc>2?kCGWindowListOptionAll:kCGWindowListOptionOnScreenOnly,0));
  for(NSDictionary*d in a){ NSDictionary*b=d[(id)kCGWindowBounds]; printf("%u pid=%d %s \"%s\" layer=%d alpha=%.2f on=%d %.0f,%.0f %.0fx%.0f\n",[d[(id)kCGWindowNumber] unsignedIntValue],[d[(id)kCGWindowOwnerPID] intValue],[d[(id)kCGWindowOwnerName] UTF8String],[d[(id)kCGWindowName] UTF8String]?:"",[d[(id)kCGWindowLayer] intValue],[d[(id)kCGWindowAlpha] doubleValue],[d[(id)kCGWindowIsOnscreen] intValue],[b[@"X"] doubleValue],[b[@"Y"] doubleValue],[b[@"Width"] doubleValue],[b[@"Height"] doubleValue]);} return 0; }
 if(!strcmp(c,"at")){ CGEventRef e=CGEventCreate(NULL); CGPoint p=CGEventGetLocation(e); printf("pointer %.1f,%.1f\n",p.x,p.y); return 0; }
 if(!strcmp(c,"screens")){ uint32_t n=0; CGDirectDisplayID d[8]; CGGetActiveDisplayList(8,d,&n); for(uint32_t i=0;i<n;i++){CGRect r=CGDisplayBounds(d[i]); printf("display %u %.0f,%.0f %.0fx%.0f pixels %zux%zu\n",d[i],r.origin.x,r.origin.y,r.size.width,r.size.height,CGDisplayPixelsWide(d[i]),CGDisplayPixelsHigh(d[i]));} return 0;}
 CGPoint p=CGPointMake(argc>2?atof(argv[2]):0,argc>3?atof(argv[3]):0);
 if(!strcmp(c,"move")){ post(kCGEventMouseMoved,p,0); return 0; }
 if(!strcmp(c,"click")){ post(kCGEventMouseMoved,p,0); usleep(200000); post(kCGEventLeftMouseDown,p,1); usleep(80000); post(kCGEventLeftMouseUp,p,1); return 0; }
 if(!strcmp(c,"down")){ post(kCGEventMouseMoved,p,0); post(kCGEventLeftMouseDown,p,1); return 0; }
 if(!strcmp(c,"up")){ post(kCGEventLeftMouseUp,p,1); return 0; }
 if(!strcmp(c,"drag")){ post(kCGEventLeftMouseDragged,p,1); return 0; }
 if(!strcmp(c,"key")){ int k=atoi(argv[2]); uint64_t f=argc>3?strtoull(argv[3],0,0):0; for(int i=0;i<2;i++){ CGEventRef e=CGEventCreateKeyboardEvent(NULL,k,i==0); CGEventSetFlags(e,f); CGEventPost(kCGHIDEventTap,e); CFRelease(e); usleep(30000);} return 0; }
 if(!strcmp(c,"type")){ const char*t=argv[2]; for(;*t;t++){ UniChar u=*t; for(int i=0;i<2;i++){ CGEventRef e=CGEventCreateKeyboardEvent(NULL,0,i==0); CGEventKeyboardSetUnicodeString(e,1,&u); CGEventPost(kCGHIDEventTap,e); CFRelease(e); usleep(15000);} } return 0; }
 if(!strcmp(c,"warp")){ CGWarpMouseCursorPosition(p); CGAssociateMouseAndMouseCursorPosition(true); return 0; }
 if(!strcmp(c,"pidclick")){ pid_t pid=atoi(argv[4]); int64_t w=atoll(argv[5]); for(int i=0;i<2;i++){ CGEventRef e=CGEventCreateMouseEvent(NULL,i?kCGEventLeftMouseUp:kCGEventLeftMouseDown,p,kCGMouseButtonLeft); CGEventSetIntegerValueField(e,kCGMouseEventClickState,1); CGEventSetIntegerValueField(e,kCGMouseEventWindowUnderMousePointer,w); CGEventSetIntegerValueField(e,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent,w); CGEventPostToPid(pid,e); CFRelease(e); usleep(80000);} return 0; }
 return 2; } }
