// Disposable-guest FCP10.1 only. new-private-library presses the measured New…
// button once and inventories dialogs. Explicit create-private-library additionally
// permits one guest-targeted Go-to-Folder chord and a verified private-path Save.
// Neither mode selects existing libraries, launches apps, posts global input or requests trust.
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>
#import <libproc.h>
#import <mach/mach_time.h>
#import <sys/stat.h>
#import <signal.h>
#import <unistd.h>
#import <errno.h>
#import <dlfcn.h>

static double deadline;
static NSUInteger nodes, failures;
static BOOL expired, truncated, surgicalCreation;
static double clockNow(void) { mach_timebase_info_data_t info; mach_timebase_info(&info); return (double)mach_absolute_time()*info.numer/info.denom/1e9; }
static BOOL room(void) { if(clockNow()>=deadline){expired=YES;return NO;} if(nodes>=224){truncated=YES;return NO;} return YES; }
static CFTypeRef attribute(AXUIElementRef element,CFStringRef key) {
    if(!room())return NULL;
    AXUIElementSetMessagingTimeout(element,.15);
    CFTypeRef value=NULL; AXError error=AXUIElementCopyAttributeValue(element,key,&value);
    if(error!=kAXErrorSuccess && error!=kAXErrorNoValue && error!=kAXErrorAttributeUnsupported)failures++;
    return value;
}
static id scalar(CFTypeRef value) {
    if(!value)return nil;
    if(CFGetTypeID(value)==CFStringGetTypeID()){
        NSString *text=(__bridge NSString *)value;
        if(text.length>512){truncated=YES;return [text substringToIndex:512];} return text;
    }
    if(CFGetTypeID(value)==CFBooleanGetTypeID() || CFGetTypeID(value)==CFNumberGetTypeID())return (__bridge id)value;
    if(CFGetTypeID(value)==CFURLGetTypeID())return (__bridge NSString *)CFURLGetString(value);
    return nil;
}
static BOOL equals(AXUIElementRef element,CFStringRef key,NSString *text) {
    CFTypeRef value=attribute(element,key);
    BOOL result=value && CFGetTypeID(value)==CFStringGetTypeID() && [(__bridge NSString *)value isEqualToString:text];
    if(value)CFRelease(value);return result;
}
static BOOL enabled(AXUIElementRef element,BOOL expected) {
    CFTypeRef value=attribute(element,kAXEnabledAttribute);
    BOOL result=value && CFGetTypeID(value)==CFBooleanGetTypeID() && CFBooleanGetValue(value)==expected;
    if(value)CFRelease(value);return result;
}
static BOOL pressAvailable(AXUIElementRef element) {
    CFArrayRef actions=NULL; AXError error=AXUIElementCopyActionNames(element,&actions);
    BOOL result=error==kAXErrorSuccess && actions && CFArrayContainsValue(actions,CFRangeMake(0,CFArrayGetCount(actions)),kAXPressAction);
    if(actions)CFRelease(actions);return result;
}
static BOOL identity(pid_t pid) {
    const char *expected="/Applications/Final Cut Pro.app/Contents/MacOS/Final Cut Pro";
    char path[PROC_PIDPATHINFO_MAXSIZE]={0},canonical[PATH_MAX]={0};
    return proc_pidpath(pid,path,sizeof(path))>0 && realpath(path,canonical) && !strcmp(path,canonical) && !strcmp(path,expected);
}
static BOOL privateFixture(NSString *directory,BOOL requireAbsent) {
    NSRegularExpression *pattern=[NSRegularExpression regularExpressionWithPattern:@"^/private/var/tmp/LightClickFCPFixture\\.[A-Za-z0-9_-]{6,16}$" options:0 error:NULL];
    NSTextCheckingResult *match=[pattern firstMatchInString:directory options:0 range:NSMakeRange(0,directory.length)];
    if(!match || match.range.location!=0 || match.range.length!=directory.length)return NO;
    struct stat info; char canonical[PATH_MAX]={0};const char *path=directory.fileSystemRepresentation;
    if(!realpath(path,canonical) || strcmp(path,canonical) || lstat(path,&info) || !S_ISDIR(info.st_mode) || info.st_uid!=getuid() || (info.st_mode&0777)!=0700)return NO;
    for(NSString *name in @[@"generated.fcpxml",@"input-prores422.mov"]){
        NSString *file=[directory stringByAppendingPathComponent:name];path=file.fileSystemRepresentation;
        if(!realpath(path,canonical) || strcmp(path,canonical) || lstat(path,&info) || !S_ISREG(info.st_mode) || info.st_uid!=getuid())return NO;
        if([name isEqualToString:@"generated.fcpxml"] ? !(info.st_size>0 && info.st_size<=16384) : info.st_size!=58747744)return NO;
    }
    NSString *destination=[directory stringByAppendingPathComponent:@"private.fcpbundle"];
    if(!requireAbsent)return YES;
    errno=0;return lstat(destination.fileSystemRepresentation,&info)==-1 && errno==ENOENT;
}
static AXUIElementRef verifiedNewButton(AXUIElementRef dialog,pid_t expectedPID) {
    pid_t pid=0;if(AXUIElementGetPid(dialog,&pid)!=kAXErrorSuccess || pid!=expectedPID)return NULL;
    if(!equals(dialog,kAXRoleAttribute,@"AXWindow") || !equals(dialog,kAXSubroleAttribute,@"AXDialog") || !equals(dialog,kAXTitleAttribute,@"Open Library"))return NULL;
    CFTypeRef children=attribute(dialog,kAXChildrenAttribute);
    if(!children || CFGetTypeID(children)!=CFArrayGetTypeID()){if(children)CFRelease(children);return NULL;}
    CFIndex count=CFArrayGetCount(children);NSUInteger questions=0,news=0,chooses=0,cancels=0,locates=0;AXUIElementRef button=NULL;
    if(count>32){CFRelease(children);return NULL;}
    for(CFIndex i=0;i<count && room();i++){
        CFTypeRef item=CFArrayGetValueAtIndex(children,i);if(!item || CFGetTypeID(item)!=AXUIElementGetTypeID())continue;
        AXUIElementRef element=(AXUIElementRef)item;
        if(equals(element,kAXRoleAttribute,@"AXStaticText") && equals(element,kAXValueAttribute,@"Which library do you want to import generated.fcpxml into?"))questions++;
        if(equals(element,kAXRoleAttribute,@"AXButton")){
            if(equals(element,kAXTitleAttribute,@"New…") && enabled(element,YES) && pressAvailable(element)){news++;button=element;}
            if(equals(element,kAXTitleAttribute,@"Choose") && enabled(element,NO))chooses++;
            if(equals(element,kAXTitleAttribute,@"Cancel") && enabled(element,YES))cancels++;
            if(equals(element,kAXTitleAttribute,@"Locate…") && enabled(element,YES))locates++;
        }
    }
    BOOL exact=questions==1 && news==1 && chooses==1 && cancels==1 && locates==1 && !expired;
    if(exact && button){pid=0;if(AXUIElementGetPid(button,&pid)==kAXErrorSuccess && pid==expectedPID)CFRetain(button);else button=NULL;}else button=NULL;
    CFRelease(children);return button;
}
static NSMutableDictionary *snapshot(AXUIElementRef element,NSUInteger depth) {
    NSMutableDictionary *result=[NSMutableDictionary dictionary];if(!room())return result;nodes++;
    NSMutableDictionary *settable=[NSMutableDictionary dictionary];
    for(NSString *key in @[@"AXRole",@"AXSubrole",@"AXTitle",@"AXDescription",@"AXValue",@"AXEnabled",@"AXIdentifier",@"AXFilename",@"AXURL"]){
        if(surgicalCreation && [key isEqualToString:@"AXValue"] && [result[@"AXRole"]isEqualToString:@"AXImage"])continue;
        CFTypeRef value=attribute(element,(__bridge CFStringRef)key);id text=scalar(value);if(text)result[key]=text;if(value)CFRelease(value);
        Boolean flag=false;AXError error=AXUIElementIsAttributeSettable(element,(__bridge CFStringRef)key,&flag);
        if(error==kAXErrorSuccess)settable[key]=@(flag);
    }
    result[@"settableAttributes"]=settable;
    CFArrayRef names=NULL;
    if(room() && AXUIElementCopyAttributeNames(element,&names)==kAXErrorSuccess && names){
        NSMutableArray *list=[NSMutableArray array];CFIndex count=CFArrayGetCount(names);
        for(CFIndex i=0;i<MIN(count,64);i++){id value=scalar(CFArrayGetValueAtIndex(names,i));if(value)[list addObject:value];}
        if(count>64)truncated=YES;result[@"attributeNames"]=list;CFRelease(names);
    }
    CFTypeRef children=attribute(element,kAXChildrenAttribute);
    if(children && CFGetTypeID(children)==CFArrayGetTypeID()){
        CFIndex count=CFArrayGetCount(children);result[@"childCount"]=@(count);
        if(surgicalCreation && [@[@"AXTable",@"AXBrowser",@"AXOutline",@"AXList",@"AXRow",@"AXColumn"]containsObject:result[@"AXRole"]]){
            result[@"childrenNotExpanded"]=@"listing container omitted; controls only";CFRelease(children);return result;
        }
        if(depth>=6){if(count)truncated=YES;CFRelease(children);return result;}
        NSMutableArray *items=[NSMutableArray array];
        for(CFIndex i=0;i<MIN(count,32) && room();i++){
            CFTypeRef child=CFArrayGetValueAtIndex(children,i);if(child && CFGetTypeID(child)==AXUIElementGetTypeID()){
                NSMutableDictionary *item=snapshot((AXUIElementRef)child,depth+1);item[@"childIndex"]=@(i);[items addObject:item];
            }
        }
        if(count>32 || (CFIndex)items.count<count)truncated=YES;result[@"children"]=items;
    }
    if(children)CFRelease(children);return result;
}
static NSArray *panels(AXUIElementRef application) {
    NSMutableArray *result=[NSMutableArray array];CFTypeRef windows=attribute(application,kAXWindowsAttribute);
    if(windows && CFGetTypeID(windows)==CFArrayGetTypeID()){
        CFIndex count=CFArrayGetCount(windows);if(count>8)truncated=YES;
        for(CFIndex i=0;i<MIN(count,8) && room();i++){
            CFTypeRef item=CFArrayGetValueAtIndex(windows,i);if(!item || CFGetTypeID(item)!=AXUIElementGetTypeID())continue;
            AXUIElementRef window=(AXUIElementRef)item;
            if(equals(window,kAXSubroleAttribute,@"AXDialog") || equals(window,kAXRoleAttribute,@"AXSheet") || equals(window,kAXRoleAttribute,@"AXAlert")) [result addObject:snapshot(window,0)];
            else {
                CFTypeRef children=attribute(window,kAXChildrenAttribute);
                if(children && CFGetTypeID(children)==CFArrayGetTypeID())for(CFIndex j=0;j<MIN(CFArrayGetCount(children),32) && room();j++){
                    CFTypeRef child=CFArrayGetValueAtIndex(children,j);
                    if(child && CFGetTypeID(child)==AXUIElementGetTypeID() && equals((AXUIElementRef)child,kAXRoleAttribute,@"AXSheet"))[result addObject:snapshot((AXUIElementRef)child,0)];
                }
                if(children)CFRelease(children);
            }
        }
    }
    if(windows)CFRelease(windows);return result;
}
typedef struct { AXUIElementRef window,name,button,where; } SaveControls;
typedef struct { AXUIElementRef panel,field,button; } GoControls;
static void releaseSave(SaveControls *x){if(x->window)CFRelease(x->window);if(x->name)CFRelease(x->name);if(x->button)CFRelease(x->button);if(x->where)CFRelease(x->where);memset(x,0,sizeof(*x));}
static void releaseGo(GoControls *x){if(x->panel)CFRelease(x->panel);if(x->field)CFRelease(x->field);if(x->button)CFRelease(x->button);memset(x,0,sizeof(*x));}
static BOOL writable(AXUIElementRef element,CFStringRef key){Boolean flag=false;return AXUIElementIsAttributeSettable(element,key,&flag)==kAXErrorSuccess && flag;}
static BOOL ownedElement(AXUIElementRef element,pid_t pid){pid_t actual=0;return AXUIElementGetPid(element,&actual)==kAXErrorSuccess && actual==pid;}
static SaveControls findSave(AXUIElementRef application,pid_t pid){
    SaveControls result={0};NSUInteger matches=0;CFTypeRef windows=attribute(application,kAXWindowsAttribute);
    if(windows && CFGetTypeID(windows)==CFArrayGetTypeID() && CFArrayGetCount(windows)<=8)for(CFIndex i=0;i<CFArrayGetCount(windows) && room();i++){
        CFTypeRef value=CFArrayGetValueAtIndex(windows,i);if(!value || CFGetTypeID(value)!=AXUIElementGetTypeID())continue;
        AXUIElementRef window=(AXUIElementRef)value;
        if(!ownedElement(window,pid) || !equals(window,kAXRoleAttribute,@"AXWindow") || !equals(window,kAXSubroleAttribute,@"AXDialog") || !equals(window,kAXTitleAttribute,@"Save"))continue;
        CFTypeRef children=attribute(window,kAXChildrenAttribute);NSUInteger names=0,saves=0,cancels=0,wheres=0,labels=0;SaveControls candidate={0};
        if(children && CFGetTypeID(children)==CFArrayGetTypeID() && CFArrayGetCount(children)<=32)for(CFIndex j=0;j<CFArrayGetCount(children) && room();j++){
            CFTypeRef child=CFArrayGetValueAtIndex(children,j);if(!child || CFGetTypeID(child)!=AXUIElementGetTypeID())continue;AXUIElementRef element=(AXUIElementRef)child;
            if(equals(element,kAXRoleAttribute,@"AXTextField") && equals(element,CFSTR("AXIdentifier"),@"_NS:135") && enabled(element,YES) && writable(element,kAXValueAttribute)){names++;candidate.name=element;}
            if(equals(element,kAXRoleAttribute,@"AXButton") && equals(element,kAXTitleAttribute,@"Save") && equals(element,CFSTR("AXIdentifier"),@"_NS:55") && enabled(element,YES) && pressAvailable(element)){saves++;candidate.button=element;}
            if(equals(element,kAXRoleAttribute,@"AXButton") && equals(element,kAXTitleAttribute,@"Cancel") && equals(element,CFSTR("AXIdentifier"),@"_NS:53") && enabled(element,YES))cancels++;
            if(equals(element,kAXRoleAttribute,@"AXStaticText") && equals(element,kAXValueAttribute,@"Save As:"))labels++;
            if(equals(element,kAXRoleAttribute,@"AXPopUpButton") && enabled(element,YES)){wheres++;candidate.where=element;}
        }
        if(names==1 && saves==1 && cancels==1 && wheres==1 && labels==1){
            matches++;releaseSave(&result);result.window=(AXUIElementRef)CFRetain(window);result.name=(AXUIElementRef)CFRetain(candidate.name);result.button=(AXUIElementRef)CFRetain(candidate.button);result.where=(AXUIElementRef)CFRetain(candidate.where);
        }
        if(children)CFRelease(children);
    }
    if(windows)CFRelease(windows);if(matches!=1)releaseSave(&result);return result;
}
static BOOL focusedSave(AXUIElementRef application,SaveControls *save,pid_t pid){
    if(!save->window || !identity(pid) || !ownedElement(save->window,pid))return NO;
    CFTypeRef focused=attribute(application,kAXFocusedWindowAttribute);BOOL same=focused && CFGetTypeID(focused)==AXUIElementGetTypeID() && CFEqual(focused,save->window);
    if(focused)CFRelease(focused);return same;
}
static void descendants(AXUIElementRef element,CFMutableArrayRef result,NSUInteger depth){
    if(!room() || CFArrayGetCount(result)>=64 || depth>3)return;
    CFArrayAppendValue(result,element);
    if(equals(element,kAXRoleAttribute,@"AXTable") || equals(element,kAXRoleAttribute,@"AXBrowser") || equals(element,kAXRoleAttribute,@"AXOutline"))return;
    CFTypeRef children=attribute(element,kAXChildrenAttribute);
    if(children && CFGetTypeID(children)==CFArrayGetTypeID())for(CFIndex i=0;i<MIN(CFArrayGetCount(children),32) && room();i++){
        CFTypeRef child=CFArrayGetValueAtIndex(children,i);if(child && CFGetTypeID(child)==AXUIElementGetTypeID())descendants((AXUIElementRef)child,result,depth+1);
    }
    if(children)CFRelease(children);
}
static GoControls findGo(AXUIElementRef application,SaveControls *save,pid_t pid){
    GoControls result={0};NSUInteger matches=0;CFMutableArrayRef candidates=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);
    CFTypeRef children=attribute(save->window,kAXChildrenAttribute);
    if(children && CFGetTypeID(children)==CFArrayGetTypeID())for(CFIndex i=0;i<MIN(CFArrayGetCount(children),32);i++){
        CFTypeRef child=CFArrayGetValueAtIndex(children,i);if(child && CFGetTypeID(child)==AXUIElementGetTypeID() && equals((AXUIElementRef)child,kAXRoleAttribute,@"AXSheet"))CFArrayAppendValue(candidates,child);
    }
    if(children)CFRelease(children);
    CFTypeRef windows=attribute(application,kAXWindowsAttribute);
    if(windows && CFGetTypeID(windows)==CFArrayGetTypeID())for(CFIndex i=0;i<MIN(CFArrayGetCount(windows),8);i++){
        CFTypeRef value=CFArrayGetValueAtIndex(windows,i);if(value && CFGetTypeID(value)==AXUIElementGetTypeID() && !CFEqual(value,save->window) && equals((AXUIElementRef)value,kAXSubroleAttribute,@"AXDialog"))if(!CFArrayContainsValue(candidates,CFRangeMake(0,CFArrayGetCount(candidates)),value))CFArrayAppendValue(candidates,value);
    }
    if(windows)CFRelease(windows);
    for(CFIndex i=0;i<CFArrayGetCount(candidates) && room();i++){
        AXUIElementRef panel=(AXUIElementRef)CFArrayGetValueAtIndex(candidates,i);if(!ownedElement(panel,pid))continue;
        CFMutableArrayRef flat=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);descendants(panel,flat,0);
        NSUInteger questions=0,fields=0,gos=0,cancels=0;AXUIElementRef field=NULL,button=NULL;
        for(CFIndex j=0;j<CFArrayGetCount(flat) && room();j++){
            AXUIElementRef element=(AXUIElementRef)CFArrayGetValueAtIndex(flat,j);
            if(equals(element,kAXRoleAttribute,@"AXStaticText") && equals(element,kAXValueAttribute,@"Go to the folder:"))questions++;
            if(equals(element,kAXRoleAttribute,@"AXTextField") && !equals(element,CFSTR("AXDescription"),@"tag editor") && enabled(element,YES) && writable(element,kAXValueAttribute)){fields++;field=element;}
            if(equals(element,kAXRoleAttribute,@"AXButton") && equals(element,kAXTitleAttribute,@"Go") && pressAvailable(element)){gos++;button=element;}
            if(equals(element,kAXRoleAttribute,@"AXButton") && equals(element,kAXTitleAttribute,@"Cancel") && enabled(element,YES))cancels++;
        }
        if(questions==1 && fields==1 && gos==1 && cancels==1){matches++;releaseGo(&result);result.panel=(AXUIElementRef)CFRetain(panel);result.field=(AXUIElementRef)CFRetain(field);result.button=(AXUIElementRef)CFRetain(button);}
        CFRelease(flat);
    }
    CFRelease(candidates);if(matches!=1)releaseGo(&result);return result;
}
static BOOL stillListed(AXUIElementRef application,AXUIElementRef save,AXUIElementRef target){
    for(int which=0;which<2;which++){
        CFTypeRef list=attribute(which?save:application,which?kAXChildrenAttribute:kAXWindowsAttribute);
        BOOL found=list && CFGetTypeID(list)==CFArrayGetTypeID() && CFArrayContainsValue(list,CFRangeMake(0,CFArrayGetCount(list)),target);
        if(list)CFRelease(list);if(found)return YES;
    }
    return NO;
}
static void actionResult(NSMutableArray *actions,NSString *action,NSString *target,AXError status){[actions addObject:@{@"action":action,@"target":target,@"status":@(status)}];}
static void createPrivate(AXUIElementRef application,pid_t pid,NSString *directory,NSMutableDictionary *report){
    NSMutableArray *actions=report[@"actionsPerformed"];SaveControls save=findSave(application,pid);GoControls go={0};AXUIElementRef submittedGoPanel=NULL;
    report[@"result"]=@"CREATE_PRIVATE_LIBRARY_INCONCLUSIVE";
    if(!save.window || !focusedSave(application,&save,pid) || !privateFixture(directory,YES))goto done;
    report[@"saveControlsBeforeNavigation"]=snapshot(save.window,0);
    if(!focusedSave(application,&save,pid) || !room())goto done;
    {
        CGEventRef down=CGEventCreateKeyboardEvent(NULL,(CGKeyCode)kVK_ANSI_G,true),up=CGEventCreateKeyboardEvent(NULL,(CGKeyCode)kVK_ANSI_G,false);
        if(!down || !up){if(down)CFRelease(down);if(up)CFRelease(up);goto done;}
        CGEventSetFlags(down,kCGEventFlagMaskCommand|kCGEventFlagMaskShift);CGEventSetFlags(up,kCGEventFlagMaskCommand|kCGEventFlagMaskShift);
        // CGEventPostToPid became public in10.11. Mavericks has the older PSN-targeted API.
        typedef void (*PostToPID)(pid_t,CGEventRef);
        PostToPID post=(PostToPID)dlsym(RTLD_DEFAULT,"CGEventPostToPid");
        ProcessSerialNumber psn={0,0};pid_t mapped=0;
        OSStatus psnStatus=post?noErr:GetProcessForPID(pid,&psn);
        OSStatus mappedStatus=post?noErr:GetProcessPID(&psn,&mapped);
        if((!post && (psnStatus!=noErr || mappedStatus!=noErr || mapped!=pid)) || !focusedSave(application,&save,pid) || !privateFixture(directory,YES)){
            CFRelease(down);CFRelease(up);report[@"eventTargetStatus"]=@(psnStatus);goto done;
        }
        if(post){post(pid,down);post(pid,up);}else{CGEventPostToPSN(&psn,down);CGEventPostToPSN(&psn,up);}
        CFRelease(down);CFRelease(up);
        [actions addObject:@{@"action":post?@"CGEventPostToPid":@"CGEventPostToPSN",@"targetPID":@(pid),@"chord":@"Cmd-Shift-G",
            @"psnHigh":@(psn.highLongOfPSN),@"psnLow":@(psn.lowLongOfPSN),@"status":@"posted; unconfirmed"}];
    }
    {double until=clockNow()+3;do{usleep(200000);go=findGo(application,&save,pid);}while(!go.panel && room() && identity(pid) && clockNow()<until);}
    report[@"panelsAfterGoChord"]=panels(application);
    if(!go.panel || !identity(pid) || !privateFixture(directory,YES)){report[@"result"]=@"GO_TO_FOLDER_CONTROLS_REQUIRE_REVIEW";goto done;}
    report[@"goToFolderControls"]=snapshot(go.panel,0);
    {
        AXError error=AXUIElementSetAttributeValue(go.field,kAXValueAttribute,(__bridge CFStringRef)directory);
        actionResult(actions,@"AXSetAttributeValue",@"verified Go-to-Folder text field",error);
        report[@"absoluteGoPathReadbackMatches"]=@(equals(go.field,kAXValueAttribute,directory));
        if(![report[@"absoluteGoPathReadbackMatches"]boolValue] || !identity(pid) || !privateFixture(directory,YES) || !enabled(go.button,YES) || !ownedElement(go.button,pid))goto done;
        submittedGoPanel=(AXUIElementRef)CFRetain(go.panel);
        error=AXUIElementPerformAction(go.button,kAXPressAction);actionResult(actions,@"AXPress",@"verified Go-to-Folder Go button",error);
    }
    usleep(500000);releaseGo(&go);releaseSave(&save);save=findSave(application,pid);
    if(!save.window || !identity(pid) || !privateFixture(directory,YES))goto done;
    go=findGo(application,&save,pid);
    report[@"goSheetDismissed"]=@(go.panel==NULL && submittedGoPanel && !stillListed(application,save.window,submittedGoPanel));report[@"whereMatchesPrivateDirectory"]=@(equals(save.where,kAXValueAttribute,directory.lastPathComponent));
    report[@"saveControlsAfterNavigation"]=snapshot(save.window,0);
    if(![report[@"goSheetDismissed"]boolValue] || ![report[@"whereMatchesPrivateDirectory"]boolValue] || !focusedSave(application,&save,pid))goto done;
    {
        AXError error=AXUIElementSetAttributeValue(save.name,kAXValueAttribute,CFSTR("private.fcpbundle"));
        actionResult(actions,@"AXSetAttributeValue",@"verified Save name field _NS:135",error);
        report[@"privateNameReadbackMatches"]=@(equals(save.name,kAXValueAttribute,@"private.fcpbundle"));
        if(![report[@"privateNameReadbackMatches"]boolValue] || !privateFixture(directory,YES) || !focusedSave(application,&save,pid) || !equals(save.where,kAXValueAttribute,directory.lastPathComponent) || !enabled(save.button,YES))goto done;
        report[@"libraryCreationAttempted"]=@YES;
        error=AXUIElementPerformAction(save.button,kAXPressAction);actionResult(actions,@"AXPress",@"verified Save button _NS:55",error);report[@"saveActionConfirmed"]=@(error==kAXErrorSuccess);
    }
    {
        NSString *path=[directory stringByAppendingPathComponent:@"private.fcpbundle"];struct stat info;BOOL created=NO;double until=clockNow()+4;
        while(room() && clockNow()<until && identity(pid)){
            char canonical[PATH_MAX]={0};
            if(!lstat(path.fileSystemRepresentation,&info) && S_ISDIR(info.st_mode) && info.st_uid==getuid() && realpath(path.fileSystemRepresentation,canonical) && !strcmp(path.fileSystemRepresentation,canonical)){created=YES;break;}
            usleep(200000);
        }
        report[@"privateLibraryVerified"]=@(created);
        if(created){report[@"result"]=@"PRIVATE_LIBRARY_CREATED_REQUIRES_IMPORT_REVIEW";NSArray *entries=[[NSFileManager defaultManager]contentsOfDirectoryAtPath:directory error:NULL];if(entries.count<=16)report[@"privateDirectoryEntries"]=entries;}
    }
 done:
    if(identity(pid) && privateFixture(directory,NO) && room())report[@"panelsAfterCreateMode"]=panels(application);
    if(submittedGoPanel)CFRelease(submittedGoPanel);releaseGo(&go);releaseSave(&save);
}

int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc!=5 || strcmp(argv[1],"10.1") || (strcmp(argv[3],"new-private-library") && strcmp(argv[3],"create-private-library"))){fprintf(stderr,"usage: fcp-ax-actions 10.1 ownedPID new-private-library|create-private-library ownFixtureDirectory\n");return 2;}
        char *end=NULL;long number=strtol(argv[2],&end,10);if(!argv[2][0] || *end || number<=1 || number>INT_MAX)return 2;
        pid_t pid=(pid_t)number;NSString *directory=[NSString stringWithUTF8String:argv[4]];if(!directory)return 2;
        BOOL createMode=!strcmp(argv[3],"create-private-library");surgicalCreation=createMode;
        alarm(createMode?55:16);deadline=clockNow()+(createMode?48:12);
        NSMutableArray *actions=[NSMutableArray array];
        NSMutableDictionary *report=[@{@"result":@"INCONCLUSIVE",@"variant":@"10.1",@"pid":@(pid),@"mode":[NSString stringWithUTF8String:argv[3]],@"directory":directory,
            @"intendedLibraryPath":[directory stringByAppendingPathComponent:@"private.fcpbundle"],@"actionsPerformed":actions,@"libraryCreationAttempted":@NO,
            @"trustRequested":@NO,@"axTrusted":@(AXIsProcessTrusted()),@"identityMatched":@(identity(pid)),@"privateFixtureValid":@(privateFixture(directory,YES))}mutableCopy];
        AXUIElementRef application=NULL,dialog=NULL,button=NULL;
        if([report[@"identityMatched"]boolValue] && [report[@"axTrusted"]boolValue] && [report[@"privateFixtureValid"]boolValue]){
            application=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(application,.15);
            CFTypeRef windows=attribute(application,kAXWindowsAttribute);NSUInteger matches=0;
            if(windows && CFGetTypeID(windows)==CFArrayGetTypeID() && CFArrayGetCount(windows)<=8)for(CFIndex i=0;i<CFArrayGetCount(windows) && room();i++){
                CFTypeRef value=CFArrayGetValueAtIndex(windows,i);if(!value || CFGetTypeID(value)!=AXUIElementGetTypeID())continue;
                AXUIElementRef candidate=verifiedNewButton((AXUIElementRef)value,pid);
                if(candidate){matches++;if(button)CFRelease(button);button=candidate;if(dialog)CFRelease(dialog);dialog=(AXUIElementRef)CFRetain(value);}
            }
            if(windows)CFRelease(windows);report[@"matchingImportDialogs"]=@(matches);
            if(matches==1 && dialog && button && identity(pid) && privateFixture(directory,YES)){
                // Re-read the exact dialog and its unique enabled New button immediately before one action.
                CFRelease(button);button=verifiedNewButton(dialog,pid);
                if(button && identity(pid) && room()){
                    AXError error=AXUIElementPerformAction(button,kAXPressAction);
                    [actions addObject:@{@"action":@"AXPress",@"targetRole":@"AXButton",@"targetTitle":@"New…",@"status":@(error)}];
                    report[@"actionConfirmed"]=@(error==kAXErrorSuccess);
                    // AX timeout/CannotComplete can arrive after a modal panel appeared.
                    // Never resend. Observe the same owned process even after a nonzero status.
                    usleep(500000);
                    BOOL samePID=identity(pid),sameFixture=privateFixture(directory,NO);
                    report[@"identityAfterAction"]=@(samePID);report[@"privateFixtureValidAfterAction"]=@(sameFixture);
                    NSArray *observed=@[];
                    if(samePID && sameFixture && room())observed=panels(application);
                    else report[@"panelObservationSkipped"]=@"identity, fixture or observation deadline changed";
                    report[@"panelsAfterNew"]=observed;
                    if(error==kAXErrorSuccess)report[@"result"]=observed.count ? @"NEW_LIBRARY_PANEL_OBSERVED_REQUIRES_REVIEW" : @"NEW_BUTTON_PRESSED_PANEL_NOT_OBSERVED";
                    else report[@"result"]=observed.count ? @"NEW_BUTTON_ACTION_UNCONFIRMED_PANEL_OBSERVED" : @"NEW_BUTTON_ACTION_UNCONFIRMED";
                    if(createMode && samePID && sameFixture && room())createPrivate(application,pid,directory,report);
                }
            }else report[@"result"]=@"IMPORT_DIALOG_NOT_UNIQUE_OR_CHANGED";
        }
        report[@"identityStillMatched"]=@(identity(pid));report[@"nodes"]=@(nodes);report[@"attributeFailures"]=@(failures);
        report[@"truncated"]=@(truncated);report[@"deadlineExceeded"]=@(expired);
        struct stat info;BOOL exists=lstat([report[@"intendedLibraryPath"]fileSystemRepresentation],&info)==0;report[@"intendedLibraryExists"]=@(exists);
        report[@"qualification"]=createMode ? @"Explicit private-library creation attempt only; all input targets the owned guest FCP. No existing library selection or import/render/export qualification." : @"One verified New-button press only. Save-panel controls are inventoried; no path entered, Save pressed or existing library selected.";
        if(button)CFRelease(button);if(dialog)CFRelease(dialog);if(application)CFRelease(application);
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:NULL];if(!json || json.length>1048576)return 3;
        fwrite(json.bytes,1,json.length,stdout);putchar('\n');alarm(0);return 0;
    }
}
