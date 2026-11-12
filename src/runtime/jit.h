/* The baseline JIT (docs/design.md, "Guest frames and calling convention"). */
#ifndef SJ_JIT_H
#define SJ_JIT_H

#include "vm.h"

typedef struct Jit Jit;

/* Compiles the adapter and the shared stubs. */
Jit *jit_create(void);
void *jit_compile_stub(Jit *jit);
void *jit_foreign_stub(Jit *jit);
/* Uses those stubs for a VM, setting vm->program->compile_stub and vm->program->foreign_stub. */
void jit_attach(VM *vm, Jit *jit);
/* Both, for a fresh VM. */
bool jit_init(VM *vm);
void jit_destroy(VM *vm);
void jit_dispose(Jit *jit); /* unattached stubs, e.g. after an image-load failure */
/* For SHEN_JIT_STATS: code objects compiled, and those freed since. */
void jit_stats(VM *vm, size_t *compiled, size_t *freed);
/* Compile everything again on its next call, for a change in what code must
   test. Frames running the old code finish in it, so it stays. */
void jit_recompile(VM *vm);

/* Calls a procedure from C with arguments that the caller keeps rooted.
   Returns V_CLEARED, with the error in vm->exception, if an error is not
   caught. No helper calls guest code; C written for Shen does, through jit_call_nested. */
V jit_call(VM *vm, V proc, size_t n, const V *args);

#endif
