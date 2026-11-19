/* Test-only access to the guest heap counters, including inline JIT allocation. */
#include "../include/shen.h"
#include "../src/runtime/vm.h"
#include <stdio.h>

static uint64_t *cursor;
static size_t collections, large_words;

static VM *heap(shen_vm *api)
{
    return (VM *)((char *)api - offsetof(VM, api));
}

shen_value shen_test_tun_mark(shen_vm *api, shen_value *args)
{
    (void)args;
    VM *vm = heap(api);
    cursor = vm->hp;
    collections = vm->collections;
    large_words = vm->large_since;
    return shen_make_fixnum(0);
}

shen_value shen_test_tun_words(shen_vm *api, shen_value *args)
{
    (void)args;
    VM *vm = heap(api);
    if (vm->collections != collections)
        return shen_make_fixnum(-1);
    return shen_make_fixnum(vm->hp - cursor + (vm->large_since - large_words));
}

shen_value shen_test_tun_notify(shen_vm *api, shen_value *args)
{
    (void)api;
    puts(shen_fixnum(args[0]) == 0 ? "TUN ready" : "UDP queue full");
    fflush(stdout);
    return SHEN_TRUE;
}
