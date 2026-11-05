// Forks and waits for about a minute, so that a tally of the run is mostly fork. For guest-bench's --program.
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

static double now(void) {
    struct timeval t;
    gettimeofday(&t, NULL);
    return (double)t.tv_sec + (double)t.tv_usec / 1e6;
}

int main(void) {
    double start = now();
    unsigned long forks = 0;
    while (now() - start < 60) {
        pid_t child = fork();
        if (child < 0) {
            perror("fork");
            return 1;
        }
        if (child == 0)
            _exit(0);
        int status;
        waitpid(child, &status, 0);
        forks++;
    }
    printf("%lu forks, %.1f us/fork\n", forks, (now() - start) * 1e6 / (double)forks);
    return 0;
}
