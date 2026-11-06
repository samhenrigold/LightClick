// Joining the console user's session from the guest agent's root process, before 10.10's launchctl asuser. Shared by
// every tool that goes into the session that way.
#ifndef SEAMLESS_SESSION_JOIN_H
#define SEAMLESS_SESSION_JOIN_H
#include <bsm/audit.h>
#include <mach/mach.h>

// launchctl bsexec only moves a process's bootstrap port, and it prints "bsexec failed" on 10.9. WindowServer works out
// a client's GUI session from its audit session, which stays the system's, so it answers every session query with
// nothing: no window list, though the connection and display calls still work. So join Finder's audit session too.
static int join_session_of(pid_t pid) {
    mach_port_t task = MACH_PORT_NULL, bootstrap = MACH_PORT_NULL, session = MACH_PORT_NULL;
    audit_token_t token;
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    if (task_for_pid(mach_task_self(), pid, &task) || task_info(task, TASK_AUDIT_TOKEN, (task_info_t)&token, &count) ||
        task_get_bootstrap_port(task, &bootstrap))
        return -1;
    // The session ID's place in an audit token: uid, gid, ruid, rgid, pid, asid, ...
    if (audit_session_port((au_asid_t)token.val[6], &session) == -1 || audit_session_join(session) == -1)
        return -1;
    return task_set_bootstrap_port(mach_task_self(), bootstrap) ? -1 : 0;
}

#endif
