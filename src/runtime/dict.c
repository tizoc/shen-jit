/* Native dictionaries, behind the port's overrides of the kernel's dict
   family. A dictionary is an absvector [shen.dictionary, count, buckets]:
   the kernel's tag stays at index 0, so its dict? and printer still work.
   The buckets are an absvector whose length is a power of two, each a list
   of (Key . Value) entries. A lookup walks one bucket in C; an insertion adds
   an entry in place and doubles the buckets when the count exceeds them.

   The arguments arrive in vm->args, which are roots: anything read from them
   is read again after an allocation. Entries are checked as they are walked,
   since an absvector can be changed with address->; a malformed dictionary
   raises an error rather than being trusted. */
#include "ops.h"

enum { DICT_COUNT = 2, DICT_BUCKETS = 3 }; /* words of the dictionary absvector */

/* The bucket array of d and its length, or NULL if d is not a dictionary. */
static V *buckets(V d, size_t *n)
{
    if (!is_object(d) || obj_type(d) != T_VECTOR || hdr_size(ptr(d)[0]) != 3 ||
        !is_fix(ptr(d)[DICT_COUNT]) || fixval(ptr(d)[DICT_COUNT]) < 0)
        return NULL;
    V b = ptr(d)[DICT_BUCKETS];
    if (!is_object(b) || obj_type(b) != T_VECTOR)
        return NULL;
    *n = (size_t)hdr_size(ptr(b)[0]);
    return *n && !(*n & (*n - 1)) ? ptr(b) + 1 : NULL;
}

static bool entry_cell(V c) { return is_pair(c) && is_pair(ptr(c)[0]); }

/* Whether o lies in the program space: shared (isolate.share), and so never changed, though a
   dictionary that is not shared may hold its buckets or entries, as a copy of one that is. */
static bool fixed(VM *vm, V o) { return in_program(vm, ptr(o)); }

/* Whether any bucket cell or entry of b is fixed, which growing would relink. */
static bool any_fixed(VM *vm, V *b, size_t n)
{
    for (size_t i = 0; i < n; i++)
        for (V c = b[i]; entry_cell(c); c = ptr(c)[1])
            if (fixed(vm, c) || fixed(vm, ptr(c)[0]))
                return true;
    return false;
}

/* The entry for k, [] if there is none, or V_CLEARED if the bucket is
   malformed. */
static V find(V *b, size_t n, V k, uint64_t h)
{
    for (V c = b[h & (n - 1)]; c != V_NIL; c = ptr(c)[1]) {
        if (!entry_cell(c))
            return V_CLEARED;
        V e = ptr(c)[0];
        if (ptr(e)[0] == k || sj_equal(ptr(e)[0], k))
            return e;
    }
    return V_NIL;
}

/* The number of entries, or -1 if a bucket is malformed. */
static long entries(V *b, size_t n)
{
    long count = 0;
    for (size_t i = 0; i < n; i++) {
        V c = b[i];
        for (; entry_cell(c); c = ptr(c)[1])
            count++;
        if (c != V_NIL)
            return -1;
    }
    return count;
}

/* (shen-jit.dict-find D K): K's entry, or []. */
V sj_dict_find(VM *vm)
{
    size_t n;
    V *b = buckets(vm->args[0], &n);
    V e = b ? find(b, n, vm->args[1], sj_hash(vm->args[1])) : V_CLEARED;
    return e == V_CLEARED ? sj_raise_value(vm, "~S is not a dictionary", vm->args[0]) : e;
}

/* Rehash every entry into n buckets, relinking the existing cells; the
   caller has checked them all. */
static bool grow(VM *vm, size_t n)
{
    V fresh = make_vector(vm, n, V_NIL);
    if (fresh == V_CLEARED)
        return false;
    V d = vm->args[0], old = ptr(d)[DICT_BUCKETS];
    size_t m = (size_t)hdr_size(ptr(old)[0]);
    for (size_t i = 0; i < m; i++) {
        V c = ptr(old)[1 + i];
        while (c != V_NIL) {
            V next = ptr(c)[1];
            size_t j = sj_hash(ptr(ptr(c)[0])[0]) & (n - 1);
            ptr(c)[1] = ptr(fresh)[1 + j];
            ptr(fresh)[1 + j] = c;
            c = next;
        }
    }
    ptr(d)[DICT_BUCKETS] = fresh;
    return true;
}

/* (shen-jit.dict-put D K V): sets K to V and returns V. */
V sj_dict_put(VM *vm)
{
    size_t n;
    if (is_object(vm->args[0]) && hdr_shared(ptr(vm->args[0])[0]))
        return sj_raise_value(vm, "~S is shared, and cannot change", vm->args[0]);
    V *b = buckets(vm->args[0], &n);
    uint64_t h = sj_hash(vm->args[1]);
    V e = b ? find(b, n, vm->args[1], h) : V_CLEARED;
    if (e == V_CLEARED)
        return sj_raise_value(vm, "~S is not a dictionary", vm->args[0]);
    if (e != V_NIL) {
        if (fixed(vm, e))
            return sj_raise_value(vm, "~S is shared, and cannot change", vm->args[0]);
        ptr(e)[1] = vm->args[2];
        return vm->args[2];
    }
    /* A new key: check every bucket first if the dictionary will grow. */
    bool full = (size_t)fixval(ptr(vm->args[0])[DICT_COUNT]) + 1 > n;
    if (full && entries(b, n) < 0)
        return sj_raise_value(vm, "~S is not a dictionary", vm->args[0]);
    if (fixed(vm, ptr(vm->args[0])[DICT_BUCKETS]) || (full && any_fixed(vm, b, n)))
        return sj_raise_value(vm, "~S is shared, and cannot change", vm->args[0]);
    uint64_t *p = vm_alloc(vm, 4); /* the entry and its bucket cell */
    if (!p)
        return sj_raise(vm, "out of memory");
    V d = vm->args[0];
    b = buckets(d, &n);
    size_t i = h & (n - 1);
    p[0] = vm->args[1];
    p[1] = vm->args[2];
    p[2] = tagged(p, TAG_PAIR);
    p[3] = b[i];
    b[i] = tagged(p + 2, TAG_PAIR);
    ptr(d)[DICT_COUNT] = fix(fixval(ptr(d)[DICT_COUNT]) + 1);
    if (full && !grow(vm, 2 * n))
        return sj_raise(vm, "out of memory");
    return vm->args[2];
}

/* (shen-jit.dict-remove D K): removes K's entry, if any, and returns K. */
V sj_dict_remove(VM *vm)
{
    size_t n;
    V d = vm->args[0], k = vm->args[1];
    if (is_object(d) && hdr_shared(ptr(d)[0]))
        return sj_raise_value(vm, "~S is shared, and cannot change", d);
    V *b = buckets(d, &n);
    if (!b)
        return sj_raise_value(vm, "~S is not a dictionary", vm->args[0]);
    V *link = &b[sj_hash(k) & (n - 1)];
    V holder = ptr(d)[DICT_BUCKETS]; /* what link lies in: the buckets, then the cell before */
    for (V c = *link; c != V_NIL; holder = c, link = &ptr(c)[1], c = *link) {
        if (!entry_cell(c))
            return sj_raise_value(vm, "~S is not a dictionary", vm->args[0]);
        V e = ptr(c)[0];
        if (ptr(e)[0] == k || sj_equal(ptr(e)[0], k)) {
            if (fixed(vm, holder))
                return sj_raise_value(vm, "~S is shared, and cannot change", d);
            *link = ptr(c)[1];
            ptr(d)[DICT_COUNT] = fix(fixval(ptr(d)[DICT_COUNT]) - 1);
            break;
        }
    }
    return k;
}

/* (shen-jit.dict-entries D): a new list of new (Key . Value) pairs, a
   snapshot that later changes to D do not affect. */
V sj_dict_entries(VM *vm)
{
    size_t n;
    V *b = buckets(vm->args[0], &n);
    long count = b ? entries(b, n) : -1;
    if (count < 0)
        return sj_raise_value(vm, "~S is not a dictionary", vm->args[0]);
    uint64_t *p = vm_alloc(vm, 4 * (size_t)count);
    if (!p && count)
        return sj_raise(vm, "out of memory");
    b = buckets(vm->args[0], &n);
    V list = V_NIL;
    for (size_t i = 0; i < n; i++)
        for (V c = b[i]; c != V_NIL; c = ptr(c)[1], p += 4) {
            p[0] = ptr(ptr(c)[0])[0];
            p[1] = ptr(ptr(c)[0])[1];
            p[2] = tagged(p, TAG_PAIR);
            p[3] = list;
            list = tagged(p + 2, TAG_PAIR);
        }
    return list;
}
