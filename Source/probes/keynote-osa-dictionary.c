// Fixed guest iWork dictionary extraction: keynote/numbers/pages and direct/iwork09 enums, never arbitrary apps.
// The original output-only invocation still selects direct Keynote for existing collectors.
// Verified SDK: OpenScripting/ASDebugging.h declares
// OSAError OSACopyScriptingDefinitionFromURL(CFURLRef,SInt32,CFDataRef*), macOS10.5+, modeFlags=0.
#include <Carbon/Carbon.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define APP "/Applications/Keynote.app"
#define PREFIX "/private/var/tmp/LightClickKeynote."
static const char *application(const char *name,const char *location) {
    if (strcmp(location,"direct") && strcmp(location,"iwork09")) return NULL;
    int legacy=!strcmp(location,"iwork09");
    if (!strcmp(name,"keynote")) return legacy ? "/Applications/iWork '09/Keynote.app" : APP;
    if (!strcmp(name,"numbers")) return legacy ? "/Applications/iWork '09/Numbers.app" : "/Applications/Numbers.app";
    if (!strcmp(name,"pages")) return legacy ? "/Applications/iWork '09/Pages.app" : "/Applications/Pages.app";
    return NULL;
}
static int destination(const char *path) {
    if (strncmp(path,PREFIX,strlen(PREFIX))) return 0;
    const char *token=path+strlen(PREFIX), *end=token;
    while ((*end>='a'&&*end<='z')||(*end>='A'&&*end<='Z')||(*end>='0'&&*end<='9')||*end=='_'||*end=='-') end++;
    if (end-token<6 || end-token>16 || strcmp(end,"/sdef.native")) return 0;
    size_t length=(size_t)(end-path);
    char parent[PATH_MAX], actual[PATH_MAX];
    if (length>=sizeof parent) return 0;
    memcpy(parent,path,length);parent[length]=0;
    struct stat info;
    return !lstat(parent,&info) && S_ISDIR(info.st_mode) && info.st_uid==0 && !(info.st_mode&077) &&
           realpath(parent,actual) && !strcmp(parent,actual);
}

int main(int argc,char **argv) {
    const char *app=argc==2 ? APP : argc==4 ? application(argv[1],argv[2]) : NULL;
    const char *output=argc==2 ? argv[1] : argc==4 ? argv[3] : "";
    if (!app || !destination(output)) {
        fputs("FAIL expected this collector's canonical private root-owned sdef.native output\n",stderr);
        return 64;
    }
    alarm(12);
    char actual[PATH_MAX];
    struct stat info;
    if (!realpath(app,actual) || strcmp(actual,app) || lstat(app,&info) || !S_ISDIR(info.st_mode)) {
        fputs("FAIL fixed iWork app absent or noncanonical\n",stderr);
        return 3;
    }
    CFURLRef url=CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,(const UInt8 *)app,strlen(app),true);
    CFDataRef data=NULL;
    OSAError status=url ? OSACopyScriptingDefinitionFromURL(url,0,&data) : paramErr;
    if (url) CFRelease(url);
    CFIndex length=data ? CFDataGetLength(data) : 0;
    if (status!=noErr || length<=0 || length>2*1024*1024) {
        fprintf(stderr,"FAIL OSACopyScriptingDefinitionFromURL status=%d bytes=%ld (cap2097152)\n",(int)status,(long)length);
        if (data) CFRelease(data);
        return 4;
    }
    int fd=open(output,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_NONBLOCK,0600);
    if (fd<0) {
        perror("FAIL exclusive dictionary output");CFRelease(data);return 5;
    }
    const UInt8 *bytes=CFDataGetBytePtr(data);
    size_t left=(size_t)length;
    while (left) {
        ssize_t count=write(fd,bytes,left);
        if (count<0 && errno==EINTR) continue;
        if (count<=0) break;
        bytes+=count;left-=(size_t)count;
    }
    int closed=close(fd);
    CFRelease(data);
    if (left || closed) {
        unlink(output);fputs("FAIL incomplete dictionary output\n",stderr);return 6;
    }
    printf("PASS fixed iWork OSA dictionary bytes=%ld app=%s\n",(long)length,app);
    return 0;
}
