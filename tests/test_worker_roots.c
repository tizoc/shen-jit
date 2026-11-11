/* Independent VMs on two OS threads, each deleting the other's C roots. */
#include "../include/shen.h"
#include "../src/runtime/vm.h"
#include "../src/runtime/ops.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    unsigned arrived, generation;
    VM *vm[2];
    shen_root_box *roots[2][32];
    int failed[2];
} Test;
typedef struct { Test *test; unsigned index; } Arg;

static void barrier(Test *t)
{
    pthread_mutex_lock(&t->lock);
    unsigned generation = t->generation;
    if (++t->arrived == 2) {
        t->arrived = 0;
        t->generation++;
        pthread_cond_broadcast(&t->changed);
    } else {
        while (generation == t->generation)
            pthread_cond_wait(&t->changed, &t->lock);
    }
    pthread_mutex_unlock(&t->lock);
}

static void *run(void *argument)
{
    Arg *a = argument;
    Test *t = a->test;
    unsigned id = a->index;
    VM *vm = t->vm[id];
    shen_vm *api_vm = (shen_vm *)(void *)&vm->api;
    for (unsigned round = 0; round < 60; round++) {
        for (unsigned k = 0; k < 32; k++) {
            unsigned char bytes[3] = {(unsigned char)id, (unsigned char)round, (unsigned char)k};
            V value = make_bytes(vm, bytes, sizeof bytes);
            if (value == V_CLEARED || !(t->roots[id][k] = vm->api->root_new(api_vm, value)))
                abort();
        }
        vm_collect(vm, 0);
        for (unsigned k = 0; k < 32; k++) {
            V value = vm->api->root_get(t->roots[id][k]);
            unsigned char *b = (unsigned char *)(ptr(value) + 1);
            if (obj_type(value) != T_BYTES || b[0] != id || b[1] != round || b[2] != k)
                t->failed[id] = 1;
        }
        barrier(t);
        for (unsigned k = 0; k < 32; k++)
            vm->api->root_delete(t->roots[1 - id][k]);
        barrier(t);
        vm_collect(vm, 0);
        unsigned count = 0;
        for (ForeignRoot *r = vm->free_foreign_roots; r; r = r->next) {
            if (r->owner != vm || r->value != V_NIL || ++count > 32)
                abort();
        }
        if (count != 32)
            t->failed[id] = 1;
    }
    return NULL;
}

int main(void)
{
    Test test = {.lock = PTHREAD_MUTEX_INITIALIZER, .changed = PTHREAD_COND_INITIALIZER};
    test.vm[0] = vm_create(1024, 64);
    test.vm[1] = vm_create(1024, 64);
    if (!test.vm[0] || !test.vm[1])
        return 1;
    pthread_t threads[2];
    Arg args[2] = {{&test, 0}, {&test, 1}};
    for (unsigned i = 0; i < 2; i++)
        if (pthread_create(&threads[i], NULL, run, &args[i]))
            abort();
    for (unsigned i = 0; i < 2; i++)
        pthread_join(threads[i], NULL);
    vm_destroy(test.vm[0]);
    vm_destroy(test.vm[1]);
    pthread_cond_destroy(&test.changed);
    pthread_mutex_destroy(&test.lock);
    if (test.failed[0] || test.failed[1])
        return 1;
    puts("independent VM root queues: 3840 cross-thread deletions passed");
    return 0;
}
