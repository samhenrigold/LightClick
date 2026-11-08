// Guest-only disposable FCP10.1 diagnostic. Capture can materialize GPU backing
// or synchronize composition and repair the defect: preserve host texture FIRST.
// Invoke in the existing joined console audit/bootstrap context, never on host.
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#import <libproc.h>
#import <sys/proc_info.h>
#import <sys/stat.h>
#import <sys/utsname.h>
#import <mach/mach_time.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <math.h>

static const size_t rawLimit=64*1024*1024, pngLimit=16*1024*1024;
static double deadline;
static double clockNow(void){mach_timebase_info_data_t i;mach_timebase_info(&i);return (double)mach_absolute_time()*i.numer/i.denom/1e9;}
static void timeout(int sig){(void)sig;const char text[]="{\"result\":\"CAPTURE_HARD_TIMEOUT\"}\n";write(STDOUT_FILENO,text,sizeof(text)-1);_exit(124);}
static BOOL room(void){return clockNow()<deadline;}
static BOOL integer(id n,uint64_t low,uint64_t high){return [n isKindOfClass:[NSNumber class]] && CFGetTypeID((__bridge CFTypeRef)n)!=CFBooleanGetTypeID() && isfinite([n doubleValue]) && [n doubleValue]>=low && [n doubleValue]<=high && floor([n doubleValue])==[n doubleValue];}
static BOOL rectangle(NSDictionary *row,CGRect *out){
    if(![row isKindOfClass:[NSDictionary class]])return NO;
    for(NSString *key in @[@"x",@"y",@"width",@"height"])if(![row[key]isKindOfClass:[NSNumber class]] || !isfinite([row[key]doubleValue]))return NO;
    *out=CGRectMake([row[@"x"]doubleValue],[row[@"y"]doubleValue],[row[@"width"]doubleValue],[row[@"height"]doubleValue]);
    return fabs(out->origin.x)<=1000000 && fabs(out->origin.y)<=1000000 && out->size.width>0 && out->size.height>0 && out->size.width<=8192 && out->size.height<=8192;
}
static NSDictionary *boundsJSON(CGRect b){return @{@"x":@(b.origin.x),@"y":@(b.origin.y),@"width":@(b.size.width),@"height":@(b.size.height)};}
static BOOL fixture(NSString *directory,struct stat *result){
    if(![directory isKindOfClass:[NSString class]])return NO;
    NSRegularExpression *pattern=[NSRegularExpression regularExpressionWithPattern:@"\\A/private/var/tmp/LightClickFCPFixture\\.[A-Za-z0-9_-]{6,16}\\z" options:0 error:NULL];
    if([pattern numberOfMatchesInString:directory options:0 range:NSMakeRange(0,directory.length)]!=1)return NO;
    const char *path=directory.fileSystemRepresentation;char canonical[PATH_MAX];struct stat info;
    if(!realpath(path,canonical) || strcmp(path,canonical) || lstat(path,&info) || !S_ISDIR(info.st_mode) || info.st_uid!=getuid() || (info.st_mode&0777)!=0700)return NO;
    if(result)*result=info;
    for(NSString *name in @[@"generated.fcpxml",@"input-prores422.mov",@"private.fcpbundle"]){
        path=[directory stringByAppendingPathComponent:name].fileSystemRepresentation;
        if(!realpath(path,canonical) || strcmp(path,canonical) || lstat(path,&info) || info.st_uid!=getuid())return NO;
        if([name isEqualToString:@"private.fcpbundle"]){if(!S_ISDIR(info.st_mode))return NO;}
        else if(!S_ISREG(info.st_mode) || info.st_nlink!=1 || ([name isEqualToString:@"generated.fcpxml"] ? !(info.st_size>0 && info.st_size<=16384) : info.st_size!=58747744))return NO;
    }
    return YES;
}
typedef struct {uint64_t startSec,startUSec;ProcessSerialNumber psn;} Identity;
static BOOL identity(pid_t pid,NSDictionary *expected,Identity *out){
    char path[PROC_PIDPATHINFO_MAXSIZE]={0},canonical[PATH_MAX];struct proc_bsdinfo info;struct stat console;
    if(getuid()==0 || stat("/dev/console",&console) || console.st_uid!=getuid() || !integer(expected[@"console_uid"],1,UINT32_MAX) || [expected[@"console_uid"]unsignedIntValue]!=getuid())return NO;
    if(proc_pidpath(pid,path,sizeof(path))<=0 || strcmp(path,"/Applications/Final Cut Pro.app/Contents/MacOS/Final Cut Pro") || !realpath(path,canonical) || strcmp(path,canonical))return NO;
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info) || info.pbi_pid!=(uint32_t)pid || info.pbi_uid!=getuid() || info.pbi_ruid!=getuid())return NO;
    NSDictionary *saved=expected[@"psn"];if(![saved isKindOfClass:[NSDictionary class]] || !integer(saved[@"high"],0,UINT32_MAX) || !integer(saved[@"low"],0,UINT32_MAX))return NO;
    ProcessSerialNumber target={0},front={0};pid_t mapped=0,frontPID=0;
    if(GetProcessForPID(pid,&target) || GetProcessPID(&target,&mapped) || GetFrontProcess(&front) || GetProcessPID(&front,&frontPID) || mapped!=pid || frontPID!=pid || target.highLongOfPSN!=front.highLongOfPSN || target.lowLongOfPSN!=front.lowLongOfPSN || target.highLongOfPSN!=[saved[@"high"]unsignedIntValue] || target.lowLongOfPSN!=[saved[@"low"]unsignedIntValue] || !(target.highLongOfPSN|target.lowLongOfPSN))return NO;
    if(out)*out=(Identity){info.pbi_start_tvsec,info.pbi_start_tvusec,target};return room();
}
static int windowCandidate(pid_t expectedPID,pid_t actualPID,int layer,int onScreen,uint32_t windowID,CGRect actual,CGRect saved){
    return expectedPID>1 && actualPID==expectedPID && layer==0 && onScreen==1 && windowID>0 && CGRectEqualToRect(actual,saved);
}
static NSDictionary *windowRecord(pid_t pid,CGRect saved,NSMutableArray *records){
    CFArrayRef raw=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID);NSDictionary *match=nil;NSUInteger matches=0;
    if(!raw)return nil;
    NSArray *list=(__bridge NSArray *)raw;
    if(list.count<=2048)for(NSDictionary *row in list){
        if(!room() || ![row isKindOfClass:[NSDictionary class]])break;
        if(!integer(row[(__bridge NSString *)kCGWindowOwnerPID],2,INT_MAX) || [row[(__bridge NSString *)kCGWindowOwnerPID]intValue]!=pid)continue;
        if(records.count>=16){matches=2;break;}
        id bounds=row[(__bridge NSString *)kCGWindowBounds];CGRect actual;BOOL valid=[bounds isKindOfClass:[NSDictionary class]] && CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds,&actual);
        id idNumber=row[(__bridge NSString *)kCGWindowNumber],layer=row[(__bridge NSString *)kCGWindowLayer],visible=row[(__bridge NSString *)kCGWindowIsOnscreen];
        if(!valid || !integer(idNumber,1,UINT32_MAX) || ![layer isKindOfClass:[NSNumber class]] || ![visible isKindOfClass:[NSNumber class]]){matches=2;break;}
        NSString *name=row[(__bridge NSString *)kCGWindowName],*owner=row[(__bridge NSString *)kCGWindowOwnerName];
        NSMutableDictionary *record=[@{@"pid":@(pid),@"windowID":idNumber,@"layer":layer,@"onScreen":visible,@"bounds":boundsJSON(actual)}mutableCopy];
        if([name isKindOfClass:[NSString class]])record[@"name"]=[name substringToIndex:MIN(name.length,512)];
        if([owner isKindOfClass:[NSString class]])record[@"ownerName"]=[owner substringToIndex:MIN(owner.length,512)];
        [records addObject:record];
        if(windowCandidate(pid,pid,[layer intValue],[visible intValue],[idNumber unsignedIntValue],actual,saved)){matches++;match=record;}
    }
    if(list.count>2048 || !room())matches=2;
    if(matches==1)[match retain];CFRelease(raw);return matches==1?[match autorelease]:nil;
}
typedef struct {int fd;size_t bytes;BOOL failed;CC_SHA256_CTX sha;} Output;
static size_t pngWrite(void *opaque,const void *bytes,size_t count){
    Output *out=opaque;if(out->failed || !room() || count>pngLimit-out->bytes){out->failed=YES;return 0;}
    size_t offset=0;while(offset<count){ssize_t n=write(out->fd,(const char *)bytes+offset,count-offset);if(n<0 && errno==EINTR)continue;if(n<=0){out->failed=YES;return offset;}offset+=(size_t)n;}
    CC_SHA256_Update(&out->sha,bytes,(CC_LONG)count);out->bytes+=count;return count;
}
int main(int argc,const char **argv){@autoreleasepool{
    if(argc!=5 || strcmp(argv[1],"10.1")){fputs("usage: fcp-window-capture 10.1 ownedPID ownFixtureDirectory expectedJSON(windowRectangle,psn,console_uid)\n",stderr);return 2;}
    signal(SIGALRM,timeout);alarm(12);double began=clockNow();deadline=began+10;
    NSMutableDictionary *report=[@{@"result":@"CAPTURE_INCONCLUSIVE",@"mayMaterializeGPUOrPerturbComposition":@YES,@"inputOrActivationRequested":@NO,@"softDeadlineSeconds":@10,@"hardDeadlineSeconds":@12}mutableCopy];
    CGImageRef image=NULL,frozen=NULL;CFDataRef pixels=NULL;CGDataProviderRef provider=NULL;CGDataConsumerRef consumer=NULL;CGImageDestinationRef destination=NULL;int fd=-1;char outputPath[PATH_MAX]={0};BOOL keep=NO;struct stat fileIdentity={0};
    @try{
        char *end=NULL;long value=strtol(argv[2],&end,10);if(!argv[2][0] || *end || value<=1 || value>INT_MAX || strlen(argv[4])>8192)@throw @"invalid bounded PID/expected JSON";pid_t pid=(pid_t)value;
        NSString *directory=[NSString stringWithUTF8String:argv[3]];NSData *json=[[NSString stringWithUTF8String:argv[4]]dataUsingEncoding:NSUTF8StringEncoding];id expected=[NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];CGRect saved;
        if(![expected isKindOfClass:[NSDictionary class]] || !rectangle(expected[@"windowRectangle"],&saved))@throw @"expected saved window rectangle invalid";
        struct utsname system;if(uname(&system) || strcmp(system.sysname,"Darwin") || strncmp(system.release,"13.",3))@throw @"requires guest Darwin13";
        Identity before={0},after={0};struct stat parent,again;
        if(!identity(pid,expected,&before) || !fixture(directory,&parent))@throw @"owned console FCP identity/private fixture unavailable";
        NSMutableArray *rows=[NSMutableArray array];NSDictionary *window=windowRecord(pid,saved,rows);report[@"windowCandidatesBefore"]=rows;
        if(!window)@throw @"owned layer-zero on-screen window not unique at exact saved bounds";
        report[@"windowBefore"]=window;report[@"pid"]=@(pid);report[@"console_uid"]=@(getuid());report[@"windowID"]=window[@"windowID"];report[@"bounds"]=window[@"bounds"];
        if(!identity(pid,expected,&after) || before.startSec!=after.startSec || before.startUSec!=after.startUSec || !room())@throw @"owned process changed before capture";
        image=CGWindowListCreateImage(CGRectNull,kCGWindowListOptionIncludingWindow,[window[@"windowID"]unsignedIntValue],kCGWindowImageBoundsIgnoreFraming|kCGWindowImageNominalResolution);
        if(!image)@throw @"no exact guest window image";
        size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image),row=CGImageGetBytesPerRow(image);
        if(!room() || !width || !height || width>8192 || height>8192 || !row || row>rawLimit/height)@throw @"image dimensions/raw allocation outside budget";
        pixels=CGDataProviderCopyData(CGImageGetDataProvider(image));
        if(!pixels || CFDataGetLength(pixels)<=0 || (size_t)CFDataGetLength(pixels)>rawLimit || (size_t)CFDataGetLength(pixels)<row*height || !room())@throw @"forced pixel read outside budget";
        provider=CGDataProviderCreateWithCFData(pixels);frozen=provider?CGImageCreate(width,height,CGImageGetBitsPerComponent(image),CGImageGetBitsPerPixel(image),row,CGImageGetColorSpace(image),CGImageGetBitmapInfo(image),provider,CGImageGetDecode(image),CGImageGetShouldInterpolate(image),CGImageGetRenderingIntent(image)):NULL;
        if(!frozen || !fixture(directory,&again) || parent.st_dev!=again.st_dev || parent.st_ino!=again.st_ino)@throw @"private fixture changed before PNG output";
        NSString *format=[directory stringByAppendingPathComponent:@".fcp-window-XXXXXX.png"];if(![format getFileSystemRepresentation:outputPath maxLength:sizeof(outputPath)])@throw @"output path invalid";
        fd=mkstemps(outputPath,4);if(fd<0 || fchmod(fd,0600) || fstat(fd,&fileIdentity) || !S_ISREG(fileIdentity.st_mode) || fileIdentity.st_uid!=getuid() || fileIdentity.st_nlink!=1)@throw @"exclusive output unavailable";
        Output output={.fd=fd};CC_SHA256_Init(&output.sha);CGDataConsumerCallbacks callbacks={pngWrite,NULL};consumer=CGDataConsumerCreate(&output,&callbacks);
        destination=consumer?CGImageDestinationCreateWithDataConsumer(consumer,CFSTR("public.png"),1,NULL):NULL;
        if(!destination)@throw @"PNG destination unavailable";
        CGImageDestinationAddImage(destination,frozen,NULL);BOOL encoded=CGImageDestinationFinalize(destination);
        CFRelease(destination);destination=NULL;CGDataConsumerRelease(consumer);consumer=NULL;
        if(!encoded || output.failed || !output.bytes || !room())@throw @"PNG completion failed or exceeded budget";
        rows=[NSMutableArray array];NSDictionary *windowAfter=windowRecord(pid,saved,rows);report[@"windowCandidatesAfter"]=rows;
        if(!windowAfter || ![windowAfter isEqualToDictionary:window] || !identity(pid,expected,&after) || before.startSec!=after.startSec || before.startUSec!=after.startUSec || !fixture(directory,&again) || parent.st_dev!=again.st_dev || parent.st_ino!=again.st_ino)@throw @"window/process/private fixture changed during capture";
        struct stat actual,pathInfo;if(fstat(fd,&actual) || lstat(outputPath,&pathInfo) || actual.st_size!=(off_t)output.bytes || actual.st_ino!=fileIdentity.st_ino || actual.st_dev!=fileIdentity.st_dev || pathInfo.st_ino!=actual.st_ino || pathInfo.st_dev!=actual.st_dev || !S_ISREG(pathInfo.st_mode) || pathInfo.st_nlink!=1)@throw @"output file identity changed";
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(digest,&output.sha);NSMutableString *hex=[NSMutableString string];for(unsigned i=0;i<sizeof(digest);i++)[hex appendFormat:@"%02x",digest[i]];
        report[@"result"]=@"GUEST_WINDOW_CAPTURED_REQUIRES_COMPARISON";report[@"path"]=[NSString stringWithUTF8String:outputPath];report[@"bytes"]=@(output.bytes);report[@"sha256"]=hex;report[@"width"]=@(width);report[@"height"]=@(height);report[@"rawBytes"]=@(CFDataGetLength(pixels));report[@"windowAfter"]=windowAfter;keep=YES;
    }@catch(id error){report[@"error"]=[error description];}
    if(destination)CFRelease(destination);if(consumer)CGDataConsumerRelease(consumer);if(provider)CGDataProviderRelease(provider);if(pixels)CFRelease(pixels);if(frozen)CGImageRelease(frozen);if(image)CGImageRelease(image);
    if(fd>=0)close(fd);if(!keep && outputPath[0]){struct stat info;if(!lstat(outputPath,&info) && info.st_dev==fileIdentity.st_dev && info.st_ino==fileIdentity.st_ino)unlink(outputPath);}
    alarm(0);report[@"elapsedSeconds"]=@(clockNow()-began);NSData *encoded=[NSJSONSerialization dataWithJSONObject:report options:0 error:NULL];if(encoded){fwrite(encoded.bytes,1,encoded.length,stdout);fputc('\n',stdout);}return keep?0:1;
}}
