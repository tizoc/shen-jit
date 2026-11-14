/* C written for Shen/JIT: procedures that take and return Shen values, and can call Shen. Plain
   C functions need none of this: see lib/ffi.shen. A procedure is declared in Shen with its
   arity, after loading lib/ffi.shen:

     (shen-jit.library mine ["./libmine.so" "./libmine.dylib" "mine.dll"])
     (define-foreign-procedure sum-list mine "sum_list" 1)

   and has one C shape, in which args is an array that is already rooted:

     #include "shen.h"

     shen_value sum_list(shen_vm *vm, shen_value *args)
     {
         int64_t sum = 0;
         for (shen_value l = args[0]; shen_is_pair(vm, l); l = shen_tail(vm, l)) {
             shen_value x = shen_head(vm, l);
             if (!shen_is_fixnum(x))
                 return shen_raise_value(vm, "sum_list: ~S is not an integer", x);
             sum += shen_fixnum(x);
         }
         return shen_make_fixnum(sum);
     }

   It links against nothing, and is built by something like

     cc -shared -fPIC -I include -o libmine.so mine.c

   THE RULES

   1. A value is valid until the next call here that may allocate, unless it is in a root. Those
      calls are marked below. Other reads do not allocate, so a loop like the one above needs no
      root. A pointer from shen_string_bytes or shen_bytes_data lasts as long as a value does.
   2. Never nest two allocating calls in one expression. In shen_cons(vm, shen_cons(vm, a, b), c),
      c may be read before or after the inner call. Use two statements, with the first result
      in a root.
   3. SHEN_ERROR means an error is propagating: return it, as it is, unless you have read it with
      shen_exception and mean to go on. Never pass it to another call.
   4. Nothing malloc'd by one side is freed by the other, and no FILE * crosses.
   5. Between shen_release and shen_acquire, touch no value and call nothing here but
      shen_root_delete.
   6. Returning from a procedure unroots what it rooted, however it returns. A callback a C library
      makes, not being a procedure, unroots its own. A callback must come on the thread that called
      the library: a thread the runtime did not start cannot call in.
   7. shen_vm is this isolate's and this call's: never keep one past the call that gave it.

   A read of the wrong type gives SHEN_NONE, or NULL, or as it says below, and never raises. Passing
   SHEN_NONE or SHEN_ERROR on, or returning SHEN_NONE, ends the process with a message naming the
   procedure, and so does a value left over from before a collection, where that can be seen. So
   test under the environment variable SHEN_JIT_GC_STRESS=1: every allocation then collects, and every
   read checks its value too, which finds most of what breaks rule 1. A value that has lived through
   an even number of collections points back into the heap, and goes unseen.

   Nothing here promises where an object is or whether it moves, and values may only be stored in
   objects by shen_vector_set and in roots by shen_root_set.

   This is not stable until Shen/JIT 1.0: anything here may change before then, and
   SHEN_API_VERSION says when it has. */
#ifndef SHEN_H
#define SHEN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint64_t shen_value;
typedef const struct shen_api *shen_vm;

/* A root that outlives a call. It never moves, so a pointer to it can be kept anywhere. */
typedef struct shen_root_box {
    const struct shen_api *api; /* the rest is the runtime's */
} shen_root_box;

#define SHEN_API_VERSION 1

#define SHEN_NIL ((shen_value)0x2)   /* [] */
#define SHEN_FALSE ((shen_value)0xA)
#define SHEN_TRUE ((shen_value)0x12)
#define SHEN_ERROR ((shen_value)0x1A) /* an error is propagating: return it */
#define SHEN_NONE ((shen_value)0x2A)  /* a read of the wrong type: never a value in Shen */

/* Integers fit 62 bits. */
static inline int shen_is_fixnum(shen_value v) { return (v & 3) == 0; }
static inline int64_t shen_fixnum(shen_value v) { return (int64_t)v >> 2; }
static inline shen_value shen_make_fixnum(int64_t n) { return (shen_value)((uint64_t)n << 2); }
static inline int shen_fits_fixnum(int64_t n)
{
    return n >= -(INT64_C(1) << 61) && n < (INT64_C(1) << 61);
}
static inline shen_value shen_make_bool(int b) { return b ? SHEN_TRUE : SHEN_FALSE; }

/* One entry each. From 1.0, appended to and never reordered. Use the functions below. */
struct shen_api {
    unsigned version;
    int (*is_string)(shen_vm *, shen_value);
    int (*is_pair)(shen_vm *, shen_value);
    int (*is_vector)(shen_vm *, shen_value);
    int (*is_symbol)(shen_vm *, shen_value);
    int (*is_real)(shen_vm *, shen_value);
    int (*is_bytes)(shen_vm *, shen_value);
    int (*is_procedure)(shen_vm *, shen_value);
    double (*number)(shen_vm *, shen_value);
    shen_value (*head)(shen_vm *, shen_value);
    shen_value (*tail)(shen_vm *, shen_value);
    int64_t (*vector_length)(shen_vm *, shen_value);
    shen_value (*vector_ref)(shen_vm *, shen_value, int64_t);
    shen_value (*symbol_name)(shen_vm *, shen_value);
    const char *(*string_bytes)(shen_vm *, shen_value, size_t *);
    int64_t (*string_copy)(shen_vm *, shen_value, char *, size_t);
    unsigned char *(*bytes_data)(shen_vm *, shen_value, size_t *);
    void *(*pointer)(shen_vm *, shen_value, const char *);
    shen_value (*global)(shen_vm *, const char *);
    shen_value (*function)(shen_vm *, const char *);
    shen_value (*make_real)(shen_vm *, double);
    shen_value (*make_string)(shen_vm *, const char *, size_t);
    shen_value (*make_bytes)(shen_vm *, const void *, size_t);
    shen_value (*cons)(shen_vm *, shen_value, shen_value);
    shen_value (*make_vector)(shen_vm *, int64_t, shen_value);
    shen_value (*intern)(shen_vm *, const char *);
    shen_value (*make_pointer)(shen_vm *, void *, const char *);
    int (*vector_set)(shen_vm *, shen_value, int64_t, shen_value);
    void (*root)(shen_vm *, shen_value *);
    void (*unroot)(shen_vm *, size_t);
    shen_root_box *(*root_new)(shen_vm *, shen_value);
    shen_value (*root_get)(shen_root_box *);
    void (*root_set)(shen_root_box *, shen_value);
    void (*root_delete)(shen_root_box *);
    shen_value (*call)(shen_vm *, shen_value, size_t, const shen_value *);
    shen_value (*raise)(shen_vm *, const char *);
    shen_value (*raise_value)(shen_vm *, const char *, shen_value);
    shen_value (*exception)(shen_vm *);
    shen_value (*exception_message)(shen_vm *);
    void *(*release)(shen_vm *);
    void (*acquire)(shen_vm *, void *);
};

/* Reading: nothing here allocates, raises or collects. */

static inline int shen_is_string(shen_vm *vm, shen_value v) { return (*vm)->is_string(vm, v); }
static inline int shen_is_pair(shen_vm *vm, shen_value v) { return (*vm)->is_pair(vm, v); }
static inline int shen_is_vector(shen_vm *vm, shen_value v) { return (*vm)->is_vector(vm, v); }
static inline int shen_is_symbol(shen_vm *vm, shen_value v) { return (*vm)->is_symbol(vm, v); }
static inline int shen_is_real(shen_vm *vm, shen_value v) { return (*vm)->is_real(vm, v); }
static inline int shen_is_bytes(shen_vm *vm, shen_value v) { return (*vm)->is_bytes(vm, v); }
static inline int shen_is_procedure(shen_vm *vm, shen_value v) { return (*vm)->is_procedure(vm, v); }
/* A real or an integer, as a double; NaN for anything else. */
static inline double shen_number(shen_vm *vm, shen_value v) { return (*vm)->number(vm, v); }
static inline shen_value shen_head(shen_vm *vm, shen_value v) { return (*vm)->head(vm, v); }
static inline shen_value shen_tail(shen_vm *vm, shen_value v) { return (*vm)->tail(vm, v); }
/* -1 if it is not a vector. */
static inline int64_t shen_vector_length(shen_vm *vm, shen_value v) { return (*vm)->vector_length(vm, v); }
static inline shen_value shen_vector_ref(shen_vm *vm, shen_value v, int64_t i) { return (*vm)->vector_ref(vm, v, i); }
/* The symbol's name, a Shen string. */
static inline shen_value shen_symbol_name(shen_vm *vm, shen_value v) { return (*vm)->symbol_name(vm, v); }
/* NULL if it is not a string. These bytes are not NUL-terminated: length says how many. */
static inline const char *shen_string_bytes(shen_vm *vm, shen_value v, size_t *length)
{
    return (*vm)->string_bytes(vm, v, length);
}
/* Copies at most size - 1 bytes and a NUL, and gives the string's whole length; -1 if it is not one. */
static inline int64_t shen_string_copy(shen_vm *vm, shen_value v, char *to, size_t size)
{
    return (*vm)->string_copy(vm, v, to, size);
}
/* A byte buffer's bytes, which C may write; NULL if it is not one. */
static inline unsigned char *shen_bytes_data(shen_vm *vm, shen_value v, size_t *length)
{
    return (*vm)->bytes_data(vm, v, length);
}
/* The address in a pointer of this kind, or of any if kind is NULL. NULL for another kind, for
   anything else, and for a dead pointer. */
static inline void *shen_pointer(shen_vm *vm, shen_value v, const char *kind) { return (*vm)->pointer(vm, v, kind); }
/* A global's value, and the procedure a name is defined as: SHEN_NONE if there is none. */
static inline shen_value shen_global(shen_vm *vm, const char *name) { return (*vm)->global(vm, name); }
static inline shen_value shen_function(shen_vm *vm, const char *name) { return (*vm)->function(vm, name); }

/* Making: each of these may collect, and gives SHEN_ERROR if it is out of memory. */

static inline shen_value shen_make_real(shen_vm *vm, double d) { return (*vm)->make_real(vm, d); }
static inline shen_value shen_make_string(shen_vm *vm, const char *bytes, size_t length)
{
    return (*vm)->make_string(vm, bytes, length);
}
/* Zeros if bytes is NULL. */
static inline shen_value shen_make_bytes(shen_vm *vm, const void *bytes, size_t length)
{
    return (*vm)->make_bytes(vm, bytes, length);
}
static inline shen_value shen_cons(shen_vm *vm, shen_value head, shen_value tail) { return (*vm)->cons(vm, head, tail); }
static inline shen_value shen_make_vector(shen_vm *vm, int64_t length, shen_value fill)
{
    return (*vm)->make_vector(vm, length, fill);
}
static inline shen_value shen_intern(shen_vm *vm, const char *name) { return (*vm)->intern(vm, name); }
/* A pointer of this kind, which names a symbol; [] for NULL, as in Shen. */
static inline shen_value shen_make_pointer(shen_vm *vm, void *address, const char *kind)
{
    return (*vm)->make_pointer(vm, address, kind);
}

/* Writing, the only way to store a value in an object. Gives 0 if it is not a vector, the index is
   out of range, or the vector is shared (isolate.share), as nothing changes one. Does not allocate. */
static inline int shen_vector_set(shen_vm *vm, shen_value v, int64_t i, shen_value x) { return (*vm)->vector_set(vm, v, i, x); }

/* Roots for a call: the local must hold a value already, and stays up to date while rooted. */
static inline void shen_root(shen_vm *vm, shen_value *local) { (*vm)->root(vm, local); }
static inline void shen_unroot(shen_vm *vm, size_t how_many) { (*vm)->unroot(vm, how_many); }

/* Roots beyond a call. NULL if out of memory. Deleting needs no shen_vm and no lock, so it can be
   done from anywhere, once. */
static inline shen_root_box *shen_root_new(shen_vm *vm, shen_value v) { return (*vm)->root_new(vm, v); }
static inline shen_value shen_root_get(shen_root_box *r) { return r->api->root_get(r); }
static inline void shen_root_set(shen_root_box *r, shen_value v) { r->api->root_set(r, v); }
static inline void shen_root_delete(shen_root_box *r) { r->api->root_delete(r); }

/* Calling Shen, which may collect. An error that nothing in the callee catches comes back as
   SHEN_ERROR, and no longjmp crosses C. */
static inline shen_value shen_call(shen_vm *vm, shen_value f, size_t n, const shen_value *args)
{
    return (*vm)->call(vm, f, n, args);
}

/* Raising: each gives SHEN_ERROR, to return. The message is copied, and ~S in it stands for the value. */
static inline shen_value shen_raise(shen_vm *vm, const char *message) { return (*vm)->raise(vm, message); }
static inline shen_value shen_raise_value(shen_vm *vm, const char *message, shen_value v)
{
    return (*vm)->raise_value(vm, message, v);
}
/* After shen_call gave SHEN_ERROR: the error, as trap-error would see it. Does not allocate. */
static inline shen_value shen_exception(shen_vm *vm) { return (*vm)->exception(vm); }
/* Its message, as a Shen string. May collect. */
static inline shen_value shen_exception_message(shen_vm *vm) { return (*vm)->exception_message(vm); }

/* Around C that waits. They change nothing now, as nothing else uses an isolate's heap meanwhile. */
static inline void *shen_release(shen_vm *vm) { return (*vm)->release(vm); }
static inline void shen_acquire(shen_vm *vm, void *token) { (*vm)->acquire(vm, token); }

#ifdef __cplusplus
}
#endif

#endif
