// Library entry points test-i386.c references from tests that do not run in 64-bit mode. They must never be reached.
extern void exit(int);
extern int puts(const char *);
#define NEVER(name)                                                                                                    \
    void name(void) {                                                                                                  \
        puts(#name " called");                                                                                         \
        exit(3);                                                                                                       \
    }
NEVER(sigaction)
NEVER(setjmp)
NEVER(longjmp)
NEVER(fabs)
NEVER(rint)
NEVER(acos)
NEVER(asin)
NEVER(atan)
NEVER(atan2)
NEVER(cos)
NEVER(exp)
NEVER(fmod)
NEVER(log)
NEVER(sin)
NEVER(sqrt)
NEVER(tan)
