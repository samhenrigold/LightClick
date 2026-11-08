// Disposable-guest FCP10.1 only. new-private-library presses the measured New…
// button once and inventories dialogs. Explicit create-private-library additionally
// permits one guest-targeted Go-to-Folder chord and a verified private-path Save.
// Existing library modes never post global input. Explicit open-generated-project-hid
// posts one guest-global HID double-click only after Darwin13/private-fixture/frontmost guards.
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>
#import <libproc.h>
#import <mach/mach_time.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <signal.h>
#import <unistd.h>
#import <errno.h>
#import <dlfcn.h>
#import "fcp-ax-project-guard.h"

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

typedef struct { AXUIElementRef window,group,image; } ProjectTarget;
static void releaseProject(ProjectTarget *x){if(x->window)CFRelease(x->window);if(x->group)CFRelease(x->group);if(x->image)CFRelease(x->image);memset(x,0,sizeof(*x));}
static BOOL ownLibrary(NSString *directory){
    NSString *path=[directory stringByAppendingPathComponent:@"private.fcpbundle"];struct stat info;char canonical[PATH_MAX]={0};
    return privateFixture(directory,NO) && !lstat(path.fileSystemRepresentation,&info) && S_ISDIR(info.st_mode) && info.st_uid==getuid() && realpath(path.fileSystemRepresentation,canonical) && !strcmp(path.fileSystemRepresentation,canonical);
}
static BOOL plainFocusedWindow(AXUIElementRef application,AXUIElementRef window,pid_t pid){
    if(!identity(pid) || !ownedElement(window,pid))return NO;
    CFTypeRef windows=attribute(application,kAXWindowsAttribute),focused=attribute(application,kAXFocusedWindowAttribute);
    BOOL valid=windows && CFGetTypeID(windows)==CFArrayGetTypeID() && CFArrayGetCount(windows)==1 && CFEqual(CFArrayGetValueAtIndex(windows,0),window) && focused && CFEqual(focused,window) && equals(window,kAXSubroleAttribute,@"AXStandardWindow");
    if(windows)CFRelease(windows);if(focused)CFRelease(focused);
    CFTypeRef children=attribute(window,kAXChildrenAttribute);
    if(!children || CFGetTypeID(children)!=CFArrayGetTypeID() || CFArrayGetCount(children)>64)valid=NO;
    else for(CFIndex i=0;i<CFArrayGetCount(children) && room();i++){
        CFTypeRef child=CFArrayGetValueAtIndex(children,i);
        if(child && CFGetTypeID(child)==AXUIElementGetTypeID() && (equals((AXUIElementRef)child,kAXRoleAttribute,@"AXSheet") || equals((AXUIElementRef)child,kAXRoleAttribute,@"AXAlert")))valid=NO;
    }
    if(children)CFRelease(children);return valid && room();
}
static void organizers(AXUIElementRef element,CFMutableArrayRef found,NSUInteger depth,NSUInteger *scanned,BOOL *incomplete){
    if(!room() || ++*scanned>256){*incomplete=YES;return;}
    if(equals(element,kAXRoleAttribute,@"AXScrollArea") && equals(element,CFSTR("AXDescription"),@"organizer")){CFArrayAppendValue(found,element);return;}
    if(equals(element,CFSTR("AXDescription"),@"Display Area"))return;
    BOOL structural=equals(element,kAXRoleAttribute,@"AXWindow") || equals(element,kAXRoleAttribute,@"AXSplitGroup") || equals(element,kAXRoleAttribute,@"AXGroup") || equals(element,kAXRoleAttribute,@"AXScrollArea");
    if(!structural)return;
    CFTypeRef children=attribute(element,kAXChildrenAttribute);
    if(children && CFGetTypeID(children)==CFArrayGetTypeID()){
        CFIndex count=CFArrayGetCount(children);if(count>64 || (depth>=8 && count))*incomplete=YES;
        else for(CFIndex i=0;i<count && room();i++){CFTypeRef child=CFArrayGetValueAtIndex(children,i);if(child && CFGetTypeID(child)==AXUIElementGetTypeID())organizers((AXUIElementRef)child,found,depth+1,scanned,incomplete);}
    }
    if(children)CFRelease(children);
}
static ProjectTarget findProject(AXUIElementRef application,pid_t pid,NSMutableDictionary *evidence){
    ProjectTarget result={0};CFTypeRef windows=attribute(application,kAXWindowsAttribute);
    if(!windows || CFGetTypeID(windows)!=CFArrayGetTypeID() || CFArrayGetCount(windows)!=1){if(windows)CFRelease(windows);return result;}
    AXUIElementRef window=(AXUIElementRef)CFArrayGetValueAtIndex(windows,0);
    if(!plainFocusedWindow(application,window,pid)){CFRelease(windows);return result;}
    CFMutableArrayRef found=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);NSUInteger scanned=0;BOOL incomplete=NO;
    organizers(window,found,0,&scanned,&incomplete);evidence[@"organizersFound"]=@(CFArrayGetCount(found));evidence[@"structuralNodesScanned"]=@(scanned);evidence[@"structuralScanIncomplete"]=@(incomplete);
    if(CFArrayGetCount(found)==1 && !incomplete){
        CFTypeRef groups=attribute((AXUIElementRef)CFArrayGetValueAtIndex(found,0),kAXChildrenAttribute);NSUInteger eventMatches=0;AXUIElementRef events=NULL;
        if(groups && CFGetTypeID(groups)==CFArrayGetTypeID() && CFArrayGetCount(groups)<=32)for(CFIndex i=0;i<CFArrayGetCount(groups) && room();i++){
            CFTypeRef group=CFArrayGetValueAtIndex(groups,i);if(group && CFGetTypeID(group)==AXUIElementGetTypeID() && equals((AXUIElementRef)group,kAXRoleAttribute,@"AXGroup") && equals((AXUIElementRef)group,CFSTR("AXDescription"),@"events")){eventMatches++;events=(AXUIElementRef)group;}
        }
        evidence[@"eventGroupsFound"]=@(eventMatches);
        if(eventMatches==1){
            CFTypeRef items=attribute(events,kAXChildrenAttribute);NSUInteger labels=0,valid=0;
            if(items && CFGetTypeID(items)==CFArrayGetTypeID() && CFArrayGetCount(items)<=128)for(CFIndex i=0;i<CFArrayGetCount(items) && room();i++){
                CFTypeRef item=CFArrayGetValueAtIndex(items,i);if(!item || CFGetTypeID(item)!=AXUIElementGetTypeID())continue;AXUIElementRef group=(AXUIElementRef)item;
                if(!equals(group,kAXRoleAttribute,@"AXGroup") || !equals(group,CFSTR("AXDescription"),@"LC-generated-8s"))continue;
                labels++;CFTypeRef children=attribute(group,kAXChildrenAttribute);NSUInteger names=0,images=0,ranges=0;AXUIElementRef image=NULL;
                if(children && CFGetTypeID(children)==CFArrayGetTypeID() && CFArrayGetCount(children)==3)for(CFIndex j=0;j<3 && room();j++){
                    CFTypeRef value=CFArrayGetValueAtIndex(children,j);if(!value || CFGetTypeID(value)!=AXUIElementGetTypeID())continue;AXUIElementRef child=(AXUIElementRef)value;
                    if(equals(child,kAXRoleAttribute,@"AXTextField") && equals(child,CFSTR("AXDescription"),@"display name") && equals(child,kAXValueAttribute,@"LC-generated-8s") && enabled(child,YES))names++;
                    if(equals(child,kAXRoleAttribute,@"AXImage") && equals(child,kAXTitleAttribute,@"LC-generated-8s") && enabled(child,YES)){images++;image=child;}
                    if(equals(child,kAXRoleAttribute,@"AXLayoutItem") && equals(child,CFSTR("AXDescription"),@"range selection")){
                        CFTypeRef value=attribute(child,kAXValueAttribute);double seconds=0;
                        if(value && CFGetTypeID(value)==CFNumberGetTypeID() && CFNumberGetValue(value,kCFNumberDoubleType,&seconds) && seconds==8.0)ranges++;if(value)CFRelease(value);
                    }
                }
                if(names==1 && images==1 && ranges==1 && ownedElement(group,pid) && ownedElement(image,pid)){valid++;releaseProject(&result);result.window=(AXUIElementRef)CFRetain(window);result.group=(AXUIElementRef)CFRetain(group);result.image=(AXUIElementRef)CFRetain(image);}
                if(children)CFRelease(children);
            }
            evidence[@"projectLabelsFound"]=@(labels);evidence[@"validProjectTargets"]=@(valid);
            if(labels!=1 || valid!=1)releaseProject(&result);if(items)CFRelease(items);
        }
        if(groups)CFRelease(groups);
    }
    CFRelease(found);CFRelease(windows);return result;
}
static NSArray *projectActions(AXUIElementRef element,NSMutableDictionary *report,NSString *key){
    CFArrayRef actions=NULL;AXError error=AXUIElementCopyActionNames(element,&actions);report[[key stringByAppendingString:@"Status"]]=@(error);NSMutableArray *result=[NSMutableArray array];
    if(error==kAXErrorSuccess && actions && CFArrayGetCount(actions)<=16)for(CFIndex i=0;i<CFArrayGetCount(actions);i++){id name=scalar(CFArrayGetValueAtIndex(actions,i));if([name isKindOfClass:[NSString class]])[result addObject:name];}
    if(actions)CFRelease(actions);report[key]=result;return result;
}
static BOOL rectangle(AXUIElementRef element,CGRect *rect){
    CFTypeRef position=attribute(element,kAXPositionAttribute),size=attribute(element,kAXSizeAttribute);CGPoint point={0};CGSize extent={0};
    BOOL valid=position && size && CFGetTypeID(position)==AXValueGetTypeID() && CFGetTypeID(size)==AXValueGetTypeID() && AXValueGetValue(position,kAXValueCGPointType,&point) && AXValueGetValue(size,kAXValueCGSizeType,&extent);
    if(position)CFRelease(position);if(size)CFRelease(size);*rect=(CGRect){point,extent};return valid;
}
static NSDictionary *rectJSON(CGRect rect){return @{@"x":@(rect.origin.x),@"y":@(rect.origin.y),@"width":@(rect.size.width),@"height":@(rect.size.height)};}
/* Pure predicates are also compiled by the headless guard test; no event execution there. */
static BOOL darwin13Release(const char *release){
    if(!release || strncmp(release,"13.",3))return NO;
    const char *p=release+3;if(*p<'0' || *p>'9')return NO;
    for(;*p;p++)if((*p<'0' || *p>'9') && *p!='.')return NO;
    return p[-1]>='0' && p[-1]<='9';
}
static BOOL guestDarwin13(void){
    char release[64]={0};size_t size=sizeof(release);
    return sysctlbyname("kern.osrelease",release,&size,NULL,0)==0 && size>0 && size<=sizeof(release) && release[size-1]==0 && darwin13Release(release);
}
static BOOL frontmostOwned(pid_t pid,ProcessSerialNumber *out){
    ProcessSerialNumber front={0,0};pid_t actual=0;
    BOOL okay=GetFrontProcess(&front)==noErr && GetProcessPID(&front,&actual)==noErr && actual==pid && identity(pid);
    if(okay && out)*out=front;return okay;
}
static BOOL imageOnDisplay(CGRect image){
    CGDirectDisplayID displays[16];uint32_t count=0;
    if(CGGetActiveDisplayList(16,displays,&count)!=kCGErrorSuccess || !count || count>=16)return NO;
    for(uint32_t i=0;i<count;i++)if(CGRectContainsRect(CGDisplayBounds(displays[i]),image))return YES;
    return NO;
}
static uint64_t eventTimestamp(void){
    mach_timebase_info_data_t info;mach_timebase_info(&info);
    return (uint64_t)(((__uint128_t)mach_absolute_time()*info.numer)/info.denom);
}
/* Gate each DOWN, but always release our own press even if focus/deadline changes.
 * No allocation or AX calls between a DOWN and its matching UP. */
static int projectHIDSequence(CGEventRef events[4],pid_t pid,double interval,useconds_t delay,uint64_t stamps[4]){
    int posted=0;double began=clockNow();
    for(int click=0;click<2;click++){
        if(!frontmostOwned(pid,NULL) || !room() || (click && clockNow()-began>=interval))break;
        int down=click*2,up=down+1;
        stamps[down]=eventTimestamp();CGEventSetTimestamp(events[down],stamps[down]);
        CGEventPost(kCGHIDEventTap,events[down]);posted++;
        usleep(delay);
        stamps[up]=eventTimestamp();CGEventSetTimestamp(events[up],stamps[up]);
        CGEventPost(kCGHIDEventTap,events[up]);posted++;
        if(!click)usleep(delay);
    }
    return posted;
}
static void projectHIDClick(pid_t pid,NSString *directory,CGRect image,NSMutableDictionary *report){
    ProcessSerialNumber front={0,0};
    report[@"result"]=@"PROJECT_HID_GUARD_INCONCLUSIVE";
    report[@"guestDarwin13"]=@(guestDarwin13());report[@"imageInsideGuestDisplay"]=@(imageOnDisplay(image));
    if(![report[@"guestDarwin13"]boolValue] || ![report[@"imageInsideGuestDisplay"]boolValue] || !ownLibrary(directory) || !frontmostOwned(pid,&front) || !room())return;
    double interval=[NSEvent doubleClickInterval];
    if(!isfinite(interval) || interval<.01 || interval>10)return;
    useconds_t delay=(useconds_t)(fmin(.02,interval/8)*1e6);
    CGPoint point=CGPointMake(image.origin.x+image.size.width/8,image.origin.y+image.size.height/2);
    CGEventSourceRef source=CGEventSourceCreate(kCGEventSourceStatePrivate);if(!source)return;
    CGEventRef events[4]={0};BOOL complete=YES;
    for(int i=0;i<4;i++){
        events[i]=CGEventCreateMouseEvent(source,(i%2)?kCGEventLeftMouseUp:kCGEventLeftMouseDown,point,kCGMouseButtonLeft);
        if(!events[i])complete=NO;
        else{CGEventSetFlags(events[i],0);CGEventSetIntegerValueField(events[i],kCGMouseEventClickState,i<2?1:2);}
    }
    uint64_t stamps[4]={0};double began=clockNow();
    int posted=complete?projectHIDSequence(events,pid,interval,delay,stamps):0;
    for(int i=0;i<4;i++)if(events[i])CFRelease(events[i]);CFRelease(source);
    NSMutableArray *timestamps=[NSMutableArray array];for(int i=0;i<posted;i++)[timestamps addObject:@(stamps[i])];
    [report[@"actionsPerformed"]addObject:@{@"action":@"doubleClick",@"api":@"CGEventPost(kCGHIDEventTap)",@"scope":@"guest-global HID; Darwin13 gated",@"targetPID":@(pid),@"psnHigh":@(front.highLongOfPSN),@"psnLow":@(front.lowLongOfPSN),@"x":@(point.x),@"y":@(point.y),@"pointPolicy":@"center of left quarter of fresh AXImage",@"eventsPosted":@(posted),@"downsPosted":@(posted/2),@"upsPosted":@(posted/2),@"balancedRelease":@((posted%2)==0),@"eventTimestampsNanoseconds":timestamps,@"interEventDelayMicroseconds":@(delay),@"doubleClickIntervalSeconds":@(interval),@"elapsedSeconds":@(clockNow()-began),@"status":@"posted; delivery unqualified"}];
    report[@"result"]=posted==4?@"PROJECT_HID_DOUBLE_CLICK_POSTED_REQUIRES_REVIEW":@"PROJECT_HID_DOUBLE_CLICK_PARTIAL_UNCONFIRMED";
}
static void openGenerated(AXUIElementRef application,pid_t pid,NSString *directory,NSMutableDictionary *report,BOOL hid){
    ProjectTarget target={0},fresh={0};CGRect image={0},window={0},freshImage={0},freshWindow={0};
    report[@"result"]=@"PROJECT_OPEN_TARGET_INCONCLUSIVE";report[@"ownLibraryVerified"]=@(ownLibrary(directory));
    if(![report[@"ownLibraryVerified"]boolValue])goto done;
    target=findProject(application,pid,report);if(!target.image)goto done;
    report[@"targetGroup"]=snapshot(target.group,0);
    NSArray *imageActions=projectActions(target.image,report,@"imageActions"),*groupActions=projectActions(target.group,report,@"groupActions");
    if([report[@"imageActionsStatus"]intValue]!=kAXErrorSuccess || [report[@"groupActionsStatus"]intValue]!=kAXErrorSuccess)goto done;
    if(!rectangle(target.image,&image) || !rectangle(target.window,&window) || !LC_FCP_PROJECT_RECT_OK(image.origin.x,image.origin.y,image.size.width,image.size.height,window.origin.x,window.origin.y,window.size.width,window.size.height))goto done;
    report[@"imageRectangle"]=rectJSON(image);report[@"windowRectangle"]=rectJSON(window);
    fresh=findProject(application,pid,[NSMutableDictionary dictionary]);
    if(!fresh.image || !CFEqual(target.image,fresh.image) || !CFEqual(target.group,fresh.group) || !rectangle(fresh.image,&freshImage) || !rectangle(fresh.window,&freshWindow) || !CGRectEqualToRect(image,freshImage) || !CGRectEqualToRect(window,freshWindow) || !ownLibrary(directory) || !plainFocusedWindow(application,fresh.window,pid))goto done;
    if(hid){projectHIDClick(pid,directory,image,report);}
    else {
        AXUIElementRef semantic=[imageActions containsObject:@"AXOpen"]?fresh.image:[groupActions containsObject:@"AXOpen"]?fresh.group:NULL;
        if(semantic){
            AXError error=AXUIElementPerformAction(semantic,CFSTR("AXOpen"));actionResult(report[@"actionsPerformed"],@"AXOpen",@"verified generated project",error);
            report[@"result"]=error==kAXErrorSuccess?@"PROJECT_OPEN_ACTION_SENT_REQUIRES_REVIEW":@"PROJECT_OPEN_ACTION_UNCONFIRMED";
        }else{
            typedef void (*PostToPID)(pid_t,CGEventRef);PostToPID post=(PostToPID)dlsym(RTLD_DEFAULT,"CGEventPostToPid");ProcessSerialNumber psn={0,0};pid_t mapped=0;
            OSStatus status=post?noErr:GetProcessForPID(pid,&psn);OSStatus mapStatus=post?noErr:GetProcessPID(&psn,&mapped);
            if((!post && (status!=noErr || mapStatus!=noErr || mapped!=pid)) || !plainFocusedWindow(application,fresh.window,pid) || !ownLibrary(directory))goto done;
            CGPoint center=CGPointMake(image.origin.x+image.size.width/2,image.origin.y+image.size.height/2);CGEventRef events[4]={0};
            for(int i=0;i<4;i++){
                events[i]=CGEventCreateMouseEvent(NULL,(i%2)?kCGEventLeftMouseUp:kCGEventLeftMouseDown,center,kCGMouseButtonLeft);
                if(!events[i]){for(int j=0;j<4;j++)if(events[j])CFRelease(events[j]);goto done;}
                CGEventSetFlags(events[i],0);CGEventSetIntegerValueField(events[i],kCGMouseEventClickState,(i<2)?1:2);
            }
            // One double-click sequence, scoped to the guest app. No mouse-move/global post/warp.
            int posted=0;
            for(int i=0;i<4;i++){
                if(identity(pid)){if(post)post(pid,events[i]);else CGEventPostToPSN(&psn,events[i]);posted++;}
                CFRelease(events[i]);if(i<3)usleep(20000);
            }
            [report[@"actionsPerformed"]addObject:@{@"action":@"doubleClick",@"api":post?@"CGEventPostToPid":@"CGEventPostToPSN",@"targetPID":@(pid),@"psnHigh":@(psn.highLongOfPSN),@"psnLow":@(psn.lowLongOfPSN),@"centerX":@(center.x),@"centerY":@(center.y),@"eventsPosted":@(posted),@"status":@"posted; unconfirmed"}];
            report[@"result"]=posted==4?@"PROJECT_DOUBLE_CLICK_POSTED_REQUIRES_REVIEW":@"PROJECT_DOUBLE_CLICK_PARTIAL_UNCONFIRMED";
        }
    }
    usleep(300000);
 done:
    if(target.window && identity(pid) && room())report[@"postOpenWindowTree"]=snapshot(target.window,0);
    releaseProject(&fresh);releaseProject(&target);
}

/* Read actual menu children only; never infer an item from an index or shortcut. */
static AXUIElementRef uniqueChild(AXUIElementRef parent,NSString *role,NSString *title,pid_t pid){
    CFTypeRef children=attribute(parent,kAXChildrenAttribute);AXUIElementRef result=NULL;NSUInteger matches=0;
    if(children && CFGetTypeID(children)==CFArrayGetTypeID() && CFArrayGetCount(children)<=64)for(CFIndex i=0;i<CFArrayGetCount(children) && room();i++){
        CFTypeRef value=CFArrayGetValueAtIndex(children,i);if(!value || CFGetTypeID(value)!=AXUIElementGetTypeID())continue;
        AXUIElementRef child=(AXUIElementRef)value;
        if(ownedElement(child,pid) && equals(child,kAXRoleAttribute,role) && (!title || equals(child,kAXTitleAttribute,title))){matches++;result=child;}
    }
    if(matches==1 && result && room())CFRetain(result);else result=NULL;
    if(children)CFRelease(children);return result;
}
static AXUIElementRef masterShareItem(AXUIElementRef application,pid_t pid){
    CFTypeRef bar=attribute(application,kAXMenuBarAttribute);AXUIElementRef file=NULL,menu=NULL,share=NULL,submenu=NULL,item=NULL;
    if(bar && CFGetTypeID(bar)==AXUIElementGetTypeID() && ownedElement((AXUIElementRef)bar,pid))file=uniqueChild((AXUIElementRef)bar,@"AXMenuBarItem",@"File",pid);
    if(file)menu=uniqueChild(file,@"AXMenu",nil,pid);
    if(menu)share=uniqueChild(menu,@"AXMenuItem",@"Share",pid);
    if(share && enabled(share,YES))submenu=uniqueChild(share,@"AXMenu",nil,pid);
    if(submenu)item=uniqueChild(submenu,@"AXMenuItem",@"Master File (default)…",pid);
    if(item && (!enabled(item,YES) || !pressAvailable(item))){CFRelease(item);item=NULL;}
    if(submenu)CFRelease(submenu);if(share)CFRelease(share);if(menu)CFRelease(menu);if(file)CFRelease(file);if(bar)CFRelease(bar);
    return item;
}
typedef struct { NSUInteger scanned,runtime,project,clip;BOOL incomplete; } TimelineEvidence;
static void timelineEvidence(AXUIElementRef element,pid_t pid,NSUInteger depth,TimelineEvidence *e){
    if(!room() || ++e->scanned>256 || depth>10 || !ownedElement(element,pid)){e->incomplete=YES;return;}
    if(equals(element,kAXRoleAttribute,@"AXStaticText") && equals(element,CFSTR("AXDescription"),@"runtime") && equals(element,kAXValueAttribute,@"08:00 total - 1920\u2009×\u20091080 | 30 fps Stereo"))e->runtime++;
    if(equals(element,kAXRoleAttribute,@"AXButton") && equals(element,kAXTitleAttribute,@"LC-generated-8s") && enabled(element,YES))e->project++;
    if(equals(element,kAXRoleAttribute,@"AXLayoutItem") && equals(element,kAXSubroleAttribute,@"AXTimeline") && equals(element,CFSTR("AXDescription"),@"Video-Clip:LC-generated-prores422") && equals(element,kAXValueAttribute,@"00:00:08:00") && enabled(element,YES))e->clip++;
    // Browser/listing contents are irrelevant: the generated browser target is verified separately.
    if(equals(element,kAXRoleAttribute,@"AXImage") || equals(element,CFSTR("AXDescription"),@"organizer") || equals(element,kAXRoleAttribute,@"AXTable") || equals(element,kAXRoleAttribute,@"AXList") || equals(element,kAXRoleAttribute,@"AXOutline"))return;
    CFTypeRef children=attribute(element,kAXChildrenAttribute);
    if(children && CFGetTypeID(children)==CFArrayGetTypeID()){
        CFIndex count=CFArrayGetCount(children);if(count>64 || (depth==10 && count))e->incomplete=YES;
        else for(CFIndex i=0;i<count && room();i++){CFTypeRef child=CFArrayGetValueAtIndex(children,i);if(child && CFGetTypeID(child)==AXUIElementGetTypeID())timelineEvidence((AXUIElementRef)child,pid,depth+1,e);}
    }
    if(children)CFRelease(children);if(!room())e->incomplete=YES;
}
static BOOL verifiedTimeline(AXUIElementRef window,pid_t pid,NSMutableDictionary *report){
    TimelineEvidence evidence={0};timelineEvidence(window,pid,0,&evidence);
    report[@"generatedTimelineEvidence"]=@{@"scanned":@(evidence.scanned),@"incomplete":@(evidence.incomplete),@"runtimeMatches":@(evidence.runtime),@"projectButtonMatches":@(evidence.project),@"timelineClipMatches":@(evidence.clip),@"expectedRuntime":@"08:00 total - 1920\u2009×\u20091080 | 30 fps Stereo",@"expectedClipDuration":@"00:00:08:00"};
    return !evidence.incomplete && evidence.runtime==1 && evidence.project==1 && evidence.clip==1;
}
static void inspectMasterShare(AXUIElementRef application,pid_t pid,NSString *directory,NSMutableDictionary *report){
    ProjectTarget target={0};AXUIElementRef item=NULL,fresh=NULL;
    report[@"result"]=@"MASTER_SHARE_GUARD_INCONCLUSIVE";report[@"guestDarwin13"]=@(guestDarwin13());
    if(![report[@"guestDarwin13"]boolValue] || !ownLibrary(directory) || !frontmostOwned(pid,NULL))goto done;
    target=findProject(application,pid,report);
    if(!target.window || !verifiedTimeline(target.window,pid,report) || !plainFocusedWindow(application,target.window,pid))goto done;
    item=masterShareItem(application,pid);report[@"uniqueEnabledMasterFile"]=@(item!=NULL);if(!item)goto done;
    fresh=masterShareItem(application,pid);
    if(!fresh || !CFEqual(item,fresh) || !plainFocusedWindow(application,target.window,pid) || !frontmostOwned(pid,NULL) || !ownLibrary(directory) || !guestDarwin13() || !room())goto done;
    {
        AXError error=AXUIElementPerformAction(fresh,kAXPressAction);
        actionResult(report[@"actionsPerformed"],@"AXPress",@"File > Share > Master File (default)…",error);
        report[@"masterShareActionStatus"]=@(error);
        report[@"result"]=error==kAXErrorSuccess?@"MASTER_SHARE_PRESS_SENT_REQUIRES_PANE_REVIEW":@"MASTER_SHARE_PRESS_UNCONFIRMED";
        // CannotComplete/timeout may have opened the pane. Never retry the action.
        double until=clockNow()+3;NSArray *observed=@[];
        do{
            usleep(200000);
            if(!identity(pid) || !ownLibrary(directory) || !room())break;
            observed=panels(application);
        }while(!observed.count && clockNow()<until && room());
        report[@"sharePanels"]=observed;
        if(!observed.count && identity(pid) && ownLibrary(directory) && room()){
            CFTypeRef windows=attribute(application,kAXWindowsAttribute);NSMutableArray *others=[NSMutableArray array];
            if(windows && CFGetTypeID(windows)==CFArrayGetTypeID() && CFArrayGetCount(windows)<=8)for(CFIndex i=0;i<CFArrayGetCount(windows) && room();i++){
                CFTypeRef value=CFArrayGetValueAtIndex(windows,i);if(value && CFGetTypeID(value)==AXUIElementGetTypeID() && ownedElement((AXUIElementRef)value,pid) && !CFEqual(value,target.window))[others addObject:snapshot((AXUIElementRef)value,0)];
            }
            if(windows)CFRelease(windows);report[@"otherWindowsAfterShare"]=others;
        }
    }
 done:
    report[@"exportAttempted"]=@NO;report[@"nextOrSavePressed"]=@NO;
    if(fresh)CFRelease(fresh);if(item)CFRelease(item);releaseProject(&target);
}

int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc!=5 || strcmp(argv[1],"10.1") || (strcmp(argv[3],"new-private-library") && strcmp(argv[3],"create-private-library") && strcmp(argv[3],"open-generated-project") && strcmp(argv[3],"open-generated-project-hid") && strcmp(argv[3],"inspect-master-share"))){fprintf(stderr,"usage: fcp-ax-actions 10.1 ownedPID new-private-library|create-private-library|open-generated-project|open-generated-project-hid|inspect-master-share ownFixtureDirectory\n");return 2;}
        char *end=NULL;long number=strtol(argv[2],&end,10);if(!argv[2][0] || *end || number<=1 || number>INT_MAX)return 2;
        pid_t pid=(pid_t)number;NSString *directory=[NSString stringWithUTF8String:argv[4]];if(!directory)return 2;
        BOOL shareMode=!strcmp(argv[3],"inspect-master-share"),createMode=!strcmp(argv[3],"create-private-library"),hidMode=!strcmp(argv[3],"open-generated-project-hid"),openMode=!strcmp(argv[3],"open-generated-project")||hidMode;surgicalCreation=createMode||openMode||shareMode;
        alarm(createMode?55:shareMode?24:16);deadline=clockNow()+(createMode?48:shareMode?20:12);
        NSMutableArray *actions=[NSMutableArray array];
        NSMutableDictionary *report=[@{@"result":@"INCONCLUSIVE",@"variant":@"10.1",@"pid":@(pid),@"mode":[NSString stringWithUTF8String:argv[3]],@"directory":directory,
            @"intendedLibraryPath":[directory stringByAppendingPathComponent:@"private.fcpbundle"],@"actionsPerformed":actions,@"libraryCreationAttempted":@NO,
            @"trustRequested":@NO,@"axTrusted":@(AXIsProcessTrusted()),@"identityMatched":@(identity(pid)),@"privateFixtureValid":@(privateFixture(directory,!(openMode||shareMode)))}mutableCopy];
        AXUIElementRef application=NULL,dialog=NULL,button=NULL;
        if(shareMode){
            if(guestDarwin13() && [report[@"identityMatched"]boolValue] && [report[@"axTrusted"]boolValue] && [report[@"privateFixtureValid"]boolValue]){
                application=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(application,.15);inspectMasterShare(application,pid,directory,report);
            }
            goto output;
        }
        if(openMode){
            if(hidMode){report[@"guestDarwin13"]=@(guestDarwin13());if(![report[@"guestDarwin13"]boolValue]){report[@"result"]=@"PROJECT_HID_REQUIRES_GUEST_DARWIN13";goto output;}}
            if([report[@"identityMatched"]boolValue] && [report[@"axTrusted"]boolValue] && [report[@"privateFixtureValid"]boolValue]){
                application=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(application,.15);openGenerated(application,pid,directory,report,hidMode);
            }
            goto output;
        }
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
    output:
        report[@"identityStillMatched"]=@(identity(pid));report[@"nodes"]=@(nodes);report[@"attributeFailures"]=@(failures);
        report[@"truncated"]=@(truncated);report[@"deadlineExceeded"]=@(expired);
        struct stat info;BOOL exists=lstat([report[@"intendedLibraryPath"]fileSystemRepresentation],&info)==0;report[@"intendedLibraryExists"]=@(exists);
        report[@"qualification"]=shareMode ? @"One exact Master File menu press only; bounded Share pane inventory requires review. No Next, Save, export or performance qualification." : hidMode ? @"One guest-global HID double-click attempt only, gated to Darwin13 and an exact owned fixture. Delivery unqualified; fresh read-only post-action tree requires review. No timeline/render/export qualification." : openMode ? @"One exact generated-project open attempt only. Read-only post-action state is required; no timeline/render/export qualification." : createMode ? @"Explicit private-library creation attempt only; all input targets the owned guest FCP. No existing library selection or import/render/export qualification." : @"One verified New-button press only. Save-panel controls are inventoried; no path entered, Save pressed or existing library selected.";
        if(button)CFRelease(button);if(dialog)CFRelease(dialog);if(application)CFRelease(application);
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:NULL];if(!json || json.length>1048576)return 3;
        fwrite(json.bytes,1,json.length,stdout);putchar('\n');alarm(0);return 0;
    }
}
