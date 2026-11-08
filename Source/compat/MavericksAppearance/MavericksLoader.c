// A small zippered bootstrap keeps UIKit and legacy processes launchable.
// Only native macOS x86_64 processes load the AppKit compatibility code.
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
struct LCInterpose { const void *replacement,*original; };
typedef void (*LCDynamicInterpose)(const struct mach_header *,const struct LCInterpose *,size_t);
static LCDynamicInterpose interpose;
static const struct LCInterpose *tuples;
static size_t tupleCount;
static const struct mach_header *bodyHeader;
static void applyInterposes(const struct mach_header *header,intptr_t slide) {
    if(header==bodyHeader)return;
    Dl_info info;
    if(dladdr(header,&info)&&info.dli_fname&&(strstr(info.dli_fname,"/LoreUI.framework/")||strstr(info.dli_fname,"/MavericksAppearance.dylib")))return;
    if(interpose&&tupleCount)interpose(header,tuples,tupleCount);
}
__attribute__((constructor)) static void loadDesktopAppearance(void) {
    const struct mach_header *main=_dyld_get_image_header(0);
    if(main->magic!=MH_MAGIC_64)return;
    const uint8_t *cursor=(const uint8_t *)main+sizeof(struct mach_header_64);
    for(uint32_t i=0;i<main->ncmds;i++){
        const struct load_command *command=(const struct load_command *)cursor;
        if(command->cmd==LC_BUILD_VERSION&&((const struct build_version_command *)command)->platform==6)return;
        cursor+=command->cmdsize;
    }
    void *body=dlopen("/Library/Application Support/MavericksAppearance/MavericksAppearanceBody.dylib",RTLD_NOW|RTLD_LOCAL);
    if(!body){fprintf(stderr,"Mavericks appearance: %s\n",dlerror());return;}
    void (*setup)(void)=(void(*)(void))dlsym(body,"MavericksCatalogInstall");if(setup)setup();
    setup=(void(*)(void))dlsym(body,"MavericksCoreUIInstall");if(setup)setup();
    void *entry=dlsym(body,"MavericksAppearanceDiagnostics");Dl_info info;
    if(!entry||!dladdr(entry,&info))return;
    bodyHeader=info.dli_fbase;intptr_t slide=0;
    cursor=(const uint8_t *)bodyHeader+sizeof(struct mach_header_64);
    for(uint32_t i=0;i<bodyHeader->ncmds;i++){
        const struct load_command *command=(const struct load_command *)cursor;
        if(command->cmd==LC_SEGMENT_64){const struct segment_command_64 *segment=(const struct segment_command_64 *)command;if(!strcmp(segment->segname,"__TEXT"))slide=(intptr_t)bodyHeader-segment->vmaddr;}
        cursor+=command->cmdsize;
    }
    cursor=(const uint8_t *)bodyHeader+sizeof(struct mach_header_64);
    for(uint32_t i=0;i<bodyHeader->ncmds;i++){
        const struct load_command *command=(const struct load_command *)cursor;
        if(command->cmd==LC_SEGMENT_64){const struct segment_command_64 *segment=(const struct segment_command_64 *)command;const struct section_64 *section=(const struct section_64 *)(segment+1);
            for(uint32_t j=0;j<segment->nsects;j++)if(!strcmp(section[j].sectname,"__interpose")){tuples=(const struct LCInterpose *)(section[j].addr+slide);tupleCount=section[j].size/sizeof(*tuples);}}
        cursor+=command->cmdsize;
    }
    interpose=(LCDynamicInterpose)dlsym(RTLD_DEFAULT,"dyld_dynamic_interpose");
    if(!interpose)interpose=(LCDynamicInterpose)dlsym(RTLD_DEFAULT,"_dyld_dynamic_interpose");
    if(interpose&&tuples)_dyld_register_func_for_add_image(applyInterposes);
}
