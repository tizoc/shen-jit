/* Bounded isolated runtimes. This is not part of include/shen.h. */
#ifndef SJ_WORKER_H
#define SJ_WORKER_H
#include "vm.h"

V worker_scope(VM *vm); /* image, entry symbol, count, [initial max shared-bytes], body */
V worker_batch(VM *vm); /* opaque scope token, one byte request per worker */
V worker_index(VM *vm);
V worker_live(VM *vm);
V worker_cancelled(VM *vm);
V worker_shared_view(VM *vm);
#endif
