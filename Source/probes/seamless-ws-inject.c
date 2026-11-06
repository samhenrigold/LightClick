// Loads seamless-ws-hook.dylib into a WindowServer that's already running, so a guest needs no restart. In the guest,
// as root:
//
//     seamless-ws-inject /var/tmp/seamless-ws-hook.dylib
//
// Makes the hook's table, as WindowServer can't by now, then runs a thread there that asks for a real thread that
// dlopens the hook. Libraries in the shared cache are at the same address in both processes, so these addresses are
// good there.
#include "seamless-ws-table.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/thread_act.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static pid_t find_windowserver(void) {
    pid_t pids[4096];
    int count = proc_listallpids(pids, sizeof(pids));
    for (int i = 0; i < count; i++) {
        char name[64];
        if (proc_name(pids[i], name, sizeof(name)) > 0 && !strcmp(name, "WindowServer"))
            return pids[i];
    }
    return 0;
}

// The hook's own log and table are made here for the same reason.
static uint8_t *put_bytes(uint8_t *to, const void *bytes, size_t size) {
    memcpy(to, bytes, size);
    return to + size;
}
static uint8_t *load_constant(uint8_t *to, uint8_t reg_prefix, uint8_t reg_op, uint64_t value) {
    *to++ = reg_prefix;
    *to++ = reg_op;
    return put_bytes(to, &value, 8);
}

int main(int argc, char **argv) {
    if (argc != 2)
        return 2;
    int log = open("/var/tmp/seamless-ws-probe.log", O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (log >= 0) {
        fchmod(log, 0666);
        close(log);
    }
    int table = open(SWS_PATH, O_RDWR | O_CREAT, 0666);
    if (table < 0 || fchmod(table, 0666) || ftruncate(table, sizeof(struct SWSTable))) {
        perror("table");
        return 1;
    }
    close(table);
    pid_t pid = find_windowserver();
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = pid ? task_for_pid(mach_task_self(), pid, &task) : KERN_FAILURE;
    if (kr) {
        fprintf(stderr, "task_for_pid(%d): %s\n", pid, mach_error_string(kr));
        return 1;
    }
    enum { stack_size = 64 * 1024, page_size = 16 * 1024 };
    mach_vm_address_t code = 0, stack = 0;
    if (mach_vm_allocate(task, &code, page_size, VM_FLAGS_ANYWHERE) ||
        mach_vm_allocate(task, &stack, stack_size, VM_FLAGS_ANYWHERE))
        return 1;
    void *create = dlsym(RTLD_DEFAULT, "pthread_create_from_mach_thread"),
         *open_library = dlsym(RTLD_DEFAULT, "dlopen");
    if (!create || !open_library)
        return 1;
    uint8_t image[page_size] = {0};
    // Data: the path at +0x800, the pthread_t at +0xf00, then the real thread's start at +0x100.
    strncpy((char *)image + 0x800, argv[1], 0x600);
    uint8_t *p = image;
    static const uint8_t align[] = {0x48, 0x83, 0xec, 0x08}; // subq $8, %rsp
    p = put_bytes(p, align, sizeof(align));
    p = load_constant(p, 0x48, 0xbf, code + 0xf00); // rdi: the pthread_t
    static const uint8_t no_attributes[] = {0x31, 0xf6}; // xorl %esi, %esi
    p = put_bytes(p, no_attributes, sizeof(no_attributes));
    p = load_constant(p, 0x48, 0xba, code + 0x100); // rdx: its start
    p = load_constant(p, 0x48, 0xb9, code + 0x800); // rcx: the path
    p = load_constant(p, 0x48, 0xb8, (uint64_t)create);
    static const uint8_t call[] = {0xff, 0xd0}; // callq *%rax
    p = put_bytes(p, call, sizeof(call));
    // A bare Mach thread can't make a MIG call to end itself: it has no thread data. It waits here to be ended from
    // outside.
    static const uint8_t wait_here[] = {0xeb, 0xfe}; // jmp .
    p = put_bytes(p, wait_here, sizeof(wait_here));
    p = image + 0x100; // The real thread: dlopen(path, RTLD_NOW). rdi is already the path.
    static const uint8_t mode[] = {0xbe, RTLD_NOW, 0, 0, 0}; // movl $RTLD_NOW, %esi
    p = put_bytes(p, mode, sizeof(mode));
    p = load_constant(p, 0x48, 0xb8, (uint64_t)open_library);
    static const uint8_t tail[] = {0xff, 0xe0}; // jmpq *%rax
    p = put_bytes(p, tail, sizeof(tail));
    if (mach_vm_write(task, code, (vm_offset_t)image, page_size) ||
        mach_vm_protect(task, code, page_size, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE))
        return 1;
    x86_thread_state64_t state;
    memset(&state, 0, sizeof(state));
    state.__rip = code;
    state.__rsp = stack + stack_size - 8; // As a call would leave it.
    thread_act_t thread = MACH_PORT_NULL;
    kr = thread_create_running(task, x86_THREAD_STATE64, (thread_state_t)&state, x86_THREAD_STATE64_COUNT, &thread);
    if (kr) {
        fprintf(stderr, "thread_create_running: %s\n", mach_error_string(kr));
        return 1;
    }
    usleep(100000);
    thread_terminate(thread);
    printf("injected into %d\n", pid);
    return 0;
}
