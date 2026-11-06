// Re-enters the console user's session from the guest agent's root process. Shared by seamless-guest and
// seamless-input-guest. Includers define now() and darwin_major() first.
#ifndef SEAMLESS_CONSOLE_H
#define SEAMLESS_CONSOLE_H
static pid_t console_finder(uid_t uid) {
    char command[64];
    snprintf(command, sizeof(command), "/usr/bin/pgrep -x -U %u Finder", uid);
    FILE *pipe = popen(command, "r");
    int pid = 0;
    if (pipe) {
        if (fscanf(pipe, "%d", &pid) != 1)
            pid = 0;
        pclose(pipe);
    }
    return pid;
}

// The guest agent runs programs as root in the system session, which can't reach WindowServer. This runs the program
// again inside the console user's session: as that user, or as root where Accessibility needs it, since root doesn't
// need a TCC grant. asuser from 10.10, bsexec into their Finder before that. Returns the child's status.
static int run_in_console_session(int argc, char **argv, int as_user) {
    struct stat console = {0};
    pid_t finder = 0;
    double waited = now();
    while (now() - waited < 300) {
        if (!stat("/dev/console", &console) && console.st_uid >= 501 && (finder = console_finder(console.st_uid)))
            break;
        sleep(2);
    }
    if (!finder) {
        puts("# ERROR no one logged in to the desktop after 300 s");
        return 75;
    }
    // Let a desktop that has only just come up settle.
    if (now() - waited > 5)
        sleep(30);
    // The agent's staging folder is root's alone.
    char self[4096], directory[] = "/tmp/seamless-guest.XXXXXX", copy[64], account[32], target[16];
    uint32_t length = sizeof(self);
    if (_NSGetExecutablePath(self, &length) || !mkdtemp(directory))
        return 74;
    snprintf(copy, sizeof(copy), "%s/seamless-guest", directory);
    snprintf(account, sizeof(account), "#%u", console.st_uid);
    if (chmod(directory, 0755) || copyfile(self, copy, NULL, COPYFILE_DATA) || chmod(copy, 0755))
        return 74;
    int modern = darwin_major() >= 14;
    snprintf(target, sizeof(target), "%d", modern ? (int)console.st_uid : finder);
    char *arguments[64];
    int n = 0;
    arguments[n++] = "/bin/launchctl";
    arguments[n++] = modern ? "asuser" : "bsexec";
    arguments[n++] = target;
    if (as_user) {
        arguments[n++] = "/usr/bin/sudo";
        arguments[n++] = "-S";
        arguments[n++] = "-u";
        arguments[n++] = account;
    }
    arguments[n++] = "/usr/bin/env";
    arguments[n++] = "-i";
    arguments[n++] = "PATH=/usr/bin:/bin:/usr/sbin:/sbin";
    arguments[n++] = copy;
    for (int i = 1; i < argc && n < 62; i++)
        arguments[n++] = argv[i];
    arguments[n++] = "--in-session";
    arguments[n] = NULL;
    fflush(NULL);
    pid_t child = fork();
    if (child == 0) {
        // -S with no input can't prompt.
        freopen("/dev/null", "r", stdin);
        execv(arguments[0], arguments);
        _exit(127);
    }
    int status = 1;
    if (child < 0 || waitpid(child, &status, 0) < 0)
        status = 1;
    unlink(copy);
    rmdir(directory);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
#endif
