// Recover the already-loaded original Dock's protected TEXT for static analysis
// and private compatibility experiments. Read only the executable mapping.
#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/loader.h>
#include <mach-o/dyld_images.h>
#include <sys/sysctl.h>
static BOOL readMemory(task_t task,uint64_t address,void *data,size_t length){mach_vm_size_t actual=0;return mach_vm_read_overwrite(task,address,length,(mach_vm_address_t)data,&actual)==KERN_SUCCESS&&actual==length;}
int main(int argc,char **argv){@autoreleasepool{
 char release[32];size_t size=sizeof(release);sysctlbyname("kern.osrelease",release,&size,NULL,0);if(atoi(release)!=13||argc!=2||geteuid()!=0)return 64;
 task_t task;pid_t pid=atoi(argv[1]);if(pid<=1||task_for_pid(mach_task_self(),pid,&task)!=KERN_SUCCESS)return 75;
 struct task_dyld_info info;mach_msg_type_number_t count=TASK_DYLD_INFO_COUNT;if(task_info(task,TASK_DYLD_INFO,(task_info_t)&info,&count)!=KERN_SUCCESS)return 76;
 struct dyld_all_image_infos images;if(!readMemory(task,info.all_image_info_addr,&images,sizeof(images)))return 77;
 struct dyld_image_info main;if(!readMemory(task,(uint64_t)images.infoArray,&main,sizeof(main)))return 78;
 uint64_t address=(uint64_t)main.imageLoadAddress;struct mach_header_64 header;if(!readMemory(task,address,&header,sizeof(header))||header.magic!=MH_MAGIC_64||header.sizeofcmds>65536)return 79;
 NSMutableData *commands=[NSMutableData dataWithLength:header.sizeofcmds];if(!readMemory(task,address+sizeof(header),commands.mutableBytes,commands.length))return 80;
 NSString *path=@"/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock";NSMutableData *binary=[NSMutableData dataWithContentsOfFile:path];
 if(!binary || ((struct mach_header_64 *)binary.mutableBytes)->magic!=MH_MAGIC_64)return 81;
 uint8_t *cursor=commands.mutableBytes;uint64_t slide=0;BOOL found=NO;
 for(unsigned i=0;i<header.ncmds;i++){struct load_command *command=(void *)cursor;if(command->cmdsize<sizeof(*command)||cursor+command->cmdsize>(uint8_t *)commands.mutableBytes+commands.length)return 82;if(command->cmd==LC_SEGMENT_64){struct segment_command_64 *segment=(void *)command;if(!strcmp(segment->segname,"__TEXT")){slide=address-segment->vmaddr;found=YES;break;}}cursor+=command->cmdsize;}
 if(!found)return 83;cursor=commands.mutableBytes;NSUInteger recovered=0;
 for(unsigned i=0;i<header.ncmds;i++){struct load_command *command=(void *)cursor;if(command->cmd==LC_SEGMENT_64){struct segment_command_64 *segment=(void *)command;if(segment->flags&SG_PROTECTED_VERSION_1){if(segment->fileoff+segment->filesize>binary.length)return 84;if(!readMemory(task,slide+segment->vmaddr,(uint8_t *)binary.mutableBytes+segment->fileoff,segment->filesize))return 85;recovered+=segment->filesize;}}cursor+=command->cmdsize;}
 cursor=(uint8_t *)binary.mutableBytes+sizeof(header);for(unsigned i=0;i<header.ncmds;i++){struct load_command *command=(void *)cursor;if(command->cmd==LC_SEGMENT_64)((struct segment_command_64 *)command)->flags&=~SG_PROTECTED_VERSION_1;cursor+=command->cmdsize;}
 // The copied executable no longer matches Apple's signature. Remove the
 // signature command instead of pretending the recovered bytes are signed.
 struct mach_header_64 *output=binary.mutableBytes;cursor=(uint8_t *)binary.mutableBytes+sizeof(header);
 for(unsigned i=0;i<output->ncmds;i++){struct load_command *command=(void *)cursor;uint32_t length=command->cmdsize;if(command->cmd==LC_CODE_SIGNATURE){uint8_t *end=(uint8_t *)binary.mutableBytes+sizeof(header)+output->sizeofcmds;memmove(cursor,cursor+length,end-(cursor+length));memset(end-length,0,length);output->ncmds--;output->sizeofcmds-=length;break;}cursor+=length;}
 if(!recovered||![binary writeToFile:@"/tmp/MavericksDockDecrypted"atomically:YES])return 86;
 printf("{\"recoveredTextBytes\":%lu,\"imageBytes\":%lu}\n",(unsigned long)recovered,(unsigned long)binary.length);return 0;
}}
