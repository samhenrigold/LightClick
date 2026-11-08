/* Private host-only stream interface, serialized I/O per endpoint.
 * shutdown may race I/O and wakes it; close follows I/O retirement and must
 * join the worker before returning. No caller buffer is retained after write.
 */
#ifndef LC_COPY_WORKER_H
#define LC_COPY_WORKER_H
#include <stddef.h>
#include <sys/types.h>
struct LCCopyEndpoint;
struct LCCopyEndpoint *LCCopyEndpointOpen(void);
ssize_t LCCopyEndpointWrite(struct LCCopyEndpoint *, const void *, size_t);
ssize_t LCCopyEndpointRead(struct LCCopyEndpoint *, void *, size_t);
int LCCopyEndpointShutdown(struct LCCopyEndpoint *);
int LCCopyEndpointClose(struct LCCopyEndpoint *);
unsigned LCCopyEndpointLiveCount(void);
#endif
