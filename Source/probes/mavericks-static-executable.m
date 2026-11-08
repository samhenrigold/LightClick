// Copy only an already-running system executable's protected __TEXT mapping
// for static analysis. Never launches, injects into, suspends or writes a process.
#import <Foundation/Foundation.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/loader.h>
#include <mach-o/dyld_images.h>
#include <sys/sysctl.h>
static BOOL readText(task_t task,uint64_t address,void *data,size_t length) {
    mach_vm_size_t actual=0;
    return mach_vm_read_overwrite(task,address,length,(mach_vm_address_t)data,&actual)==KERN_SUCCESS&&actual==length;
}
int main(int argc,char **argv) {@autoreleasepool {
    char release[32]={0};size_t size=sizeof(release);sysctlbyname("kern.osrelease",release,&size,NULL,0);
    if(argc!=4||geteuid()!=0||atoi(release)!=18)return 64;
    NSString *source=@(argv[2]),*output=@(argv[3]);
    NSArray *allowed=@[@"/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",@"/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight",@"/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer"];
    if(![allowed containsObject:source]||![output hasPrefix:@"/tmp/MavericksStatic-"]||[output containsString:@"/../"])return 65;
    pid_t pid=atoi(argv[1]);char actualPath[PROC_PIDPATHINFO_MAXSIZE]={0};
    if(pid<=1||!proc_pidpath(pid,actualPath,sizeof(actualPath))||strcmp(actualPath,argv[2]))return 66;
    NSMutableData *binary=[NSMutableData dataWithContentsOfFile:source];
    if(binary.length<sizeof(struct mach_header_64))return 67;
    struct mach_header_64 *disk=binary.mutableBytes;
    if(disk->magic!=MH_MAGIC_64||disk->sizeofcmds>65536||sizeof(*disk)+disk->sizeofcmds>binary.length)return 68;
    task_t task=MACH_PORT_NULL;if(task_for_pid(mach_task_self(),pid,&task)!=KERN_SUCCESS)return 69;
    struct task_dyld_info info;mach_msg_type_number_t count=TASK_DYLD_INFO_COUNT;
    if(task_info(task,TASK_DYLD_INFO,(task_info_t)&info,&count)!=KERN_SUCCESS)return 70;
    struct dyld_all_image_infos images;struct dyld_image_info main;
    if(!readText(task,info.all_image_info_addr,&images,sizeof(images))||!readText(task,(uint64_t)images.infoArray,&main,sizeof(main)))return 71;
    uint64_t address=(uint64_t)main.imageLoadAddress;struct mach_header_64 header;
    if(!readText(task,address,&header,sizeof(header))||memcmp(&header,disk,sizeof(header)))return 72;
    NSMutableData *commands=[NSMutableData dataWithLength:header.sizeofcmds];
    if(!readText(task,address+sizeof(header),commands.mutableBytes,commands.length)||memcmp(commands.bytes,(uint8_t *)disk+sizeof(header),commands.length))return 73;
    uint8_t *cursor=commands.mutableBytes;NSUInteger recovered=0;
    for(uint32_t index=0;index<header.ncmds;index++) {
        struct load_command *command=(void *)cursor;
        if(command->cmdsize<sizeof(*command)||cursor+command->cmdsize>(uint8_t *)commands.mutableBytes+commands.length)return 74;
        if(command->cmd==LC_SEGMENT_64&&command->cmdsize>=sizeof(struct segment_command_64)) {
            struct segment_command_64 *segment=(void *)command;
            if(!strcmp(segment->segname,"__TEXT")&&(segment->flags&SG_PROTECTED_VERSION_1)) {
                if(segment->fileoff!=0||segment->filesize>binary.length||segment->filesize>67108864)return 75;
                if(!readText(task,address,binary.mutableBytes,segment->filesize))return 76;
                recovered=segment->filesize;
            }
        }
        cursor+=command->cmdsize;
    }
    mach_port_deallocate(mach_task_self(),task);
    // Mark only the analysis copy as unprotected and unsigned.
    disk=binary.mutableBytes;cursor=(uint8_t *)disk+sizeof(*disk);
    for(uint32_t index=0;recovered&&index<disk->ncmds;index++) {
        struct load_command *command=(void *)cursor;uint32_t length=command->cmdsize;
        if(command->cmd==LC_SEGMENT_64&&!strcmp(((struct segment_command_64 *)command)->segname,"__TEXT"))((struct segment_command_64 *)command)->flags&=~SG_PROTECTED_VERSION_1;
        if(command->cmd==LC_CODE_SIGNATURE) {
            uint8_t *end=(uint8_t *)disk+sizeof(*disk)+disk->sizeofcmds;
            memmove(cursor,cursor+length,end-cursor-length);memset(end-length,0,length);disk->ncmds--;disk->sizeofcmds-=length;break;
        }
        cursor+=length;
    }
    if(![binary writeToFile:output atomically:YES])return 78;
    puts([[[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:@{@"source":source,@"analysisCopy":output,@"protectedTextBytes":@(recovered),@"processModified":@NO}options:0 error:NULL]encoding:NSUTF8StringEncoding]autorelease]UTF8String]);
    return 0;
}}
