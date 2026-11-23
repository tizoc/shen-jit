/* Closed programs (docs/modules.md, docs/design.md): what an entry point can reach, found by reading
   installed bytecode and data, and an image of that alone.

   A node is a function cell, the arity beside one, a constant slot or a global slot, by its place in
   consecutive ranges, or an object, numbered as it is met. Zero is none. Nothing here allocates in
   the heap, so addresses hold throughout. Saving ends the process, and so does what cannot be
   closed, so all of this is kept once, for the process.

   A function that is only ever called by its name has its parameters followed into what its callers
   pass, so that a name that isolate.spawn-each or fn is given is known where it is given. What each
   code object does with its parameters, and what calls each, is found by reading them all again
   until nothing new comes of it.

   A closed program can no more compile than an isolate can, and what asks (shen-jit.builder?) is
   told so: what only the builder would do is not followed. */
#include "ops.h"

#include <stdlib.h>
#include <string.h>

/* What a slot may hold: a value that the code names, or one of these. */
#define ANY V_CLEARED     /* it is not known, but is not the property table */
#define TABLE V_FORWARD   /* it may be the property table, *property-vector*'s dictionary */
#define PROCEDURE V_NONE  /* a procedure, kept already */
enum { PARAMETERS = 64 }; /* of a function that are followed */
/* What the function was called with, or past PARAMETERS the head of that. */
static V parameter(size_t i) { return (V)i << 8 | PVAR_TAG; }
/* A list whose head is this symbol, as a function is named with arguments for it. */
static V headed(V symbol) { return tagged(ptr(symbol), TAG_PAIR); }

static V merge(V a, V b) { return a == b ? a : a == TABLE || b == TABLE ? TABLE : ANY; }

static V known(V v)
{
    return is_symbol(v) || is_fix(v) || is_boolean(v) || is_type(v, T_STRING) ? v :
           is_proc(v) ? PROCEDURE : is_pair(v) && is_symbol(ptr(v)[0]) ? headed(ptr(v)[0]) : ANY;
}

static V head(V v)
{
    return is_pair(v) ? tagged(ptr(v), TAG_SYMBOL) :
           is_pvar(v) && pvar_offset(v) < PARAMETERS ? parameter(pvar_offset(v) + PARAMETERS) : ANY;
}

/* How a name is used. */
typedef enum { CALLED, ARITY, READ, WRITTEN, TAG, USES } Use;

typedef struct {
    V value;
    size_t parent;     /* the node that reached it */
    union {
        size_t place;  /* while marking, a code object's in codes, plus one */
        size_t offset; /* then, in its part of the image */
    };
    unsigned char part;
    bool kept, tag;
} Node;

typedef struct {
    size_t node, outer;       /* outer: the place of the code it is nested in, plus one */
    bool made, escapes;       /* something makes its closures; they are called other than by name */
    uint64_t names[2][USES];  /* a bit for each parameter that is used as a name, or whose head is */
    size_t ncaptures;
    V *captures;
} Code;

typedef struct {
    V subject, attribute; /* of any subject, if it is ANY */
} Property;

static VM *vm;
static const char *output; /* removed if the program cannot be closed */
static size_t cells, constants, globals, objects; /* where each range of nodes starts */
static V *cell_names;
static size_t *slots; /* the parent of each slot that is kept, plus one */
static AddrMap numbers;
static Node *nodes;
static Code *codes;
static size_t *queue; /* the nodes kept, in order */
static V *tags;       /* the symbols that are first in a vector */
static Property *properties;
static size_t nnodes, ncodes, queued, visited, ntags, nproperties;
static size_t node;   /* whose dependencies are being read */
static V keeps, dispatch, accessors, substitutions; /* accessors: get, put and unput */
static V property_name, property_table;
static size_t property_slot, isolate_slot;
static size_t has_properties, spawns, prints; /* the first to read the property table, start an isolate or print */
static bool hooked[2], changed;

static _Noreturn void end(void)
{
    remove(output);
    exit(1);
}

static void *memory(void *p)
{
    if (!p) {
        fputs("shen-jit: closed build: out of memory\n", stderr);
        end();
    }
    return p;
}

/* Room for one more of the n items in an array. */
#define GROW(array, n)                                                                              \
    do {                                                                                            \
        static size_t capacity;                                                                     \
        array = memory(grow_array(array, &capacity, n, sizeof *array, 256));                        \
    } while (0)

static V find(const char *name) { return symbol_find(vm, name, strlen(name)); }

static bool take(V *list, V *item)
{
    if (!is_pair(*list))
        return false;
    *item = ptr(*list)[0];
    *list = ptr(*list)[1];
    return true;
}

static V binding(V name) { return is_symbol(name) ? *cell_function(vm, symbol_cell(name)) : V_CLEARED; }

static bool is_closure(V v) { return is_proc(v) && hdr_type(ptr(v)[0]) == T_CLOSURE; }

/* A closed program has these in place of kernel functions, unless it replaces them itself. */
static V substitute(V value)
{
    if (is_proc(value))
        for (V rows = substitutions, row; take(&rows, &row);)
            if (ptr(row)[0] == value)
                return ptr(row)[1];
    return value;
}

/* ---------------------------------------------------------------------------------------------
   Nodes. */

static Node *object(size_t id) { return &nodes[id - objects]; }

static size_t object_id(V value)
{
    value = substitute(value);
    if (!is_ptr(value))
        return 0;
    size_t id = addr_map_get(&numbers, (uintptr_t)ptr(value));
    if (id)
        return id;
    GROW(nodes, nnodes);
    id = objects + nnodes;
    if (!addr_map_put(&numbers, (uintptr_t)ptr(value), id))
        memory(NULL);
    nodes[nnodes++] = (Node){.value = value, .part = is_symbol(value) ? IMAGE_SYMBOLS :
                             in_program(vm, ptr(value)) ? IMAGE_PROGRAM : IMAGE_HEAP};
    return id;
}

static size_t cell_id(V name) { return cells + 2 * symbol_cell(name); }

static size_t global_id(V name)
{
    size_t slot = is_symbol(name) ? symbol_global(name) : 0;
    return slot ? globals + slot : 0;
}

static bool kept(size_t id) { return id && (id < objects ? slots[id] != 0 : object(id)->kept); }

static void keep(size_t id)
{
    if (!id || kept(id))
        return;
    GROW(queue, queued);
    queue[queued++] = id;
    changed = true;
    if (id < objects) {
        slots[id] = node + 1;
    } else {
        object(id)->kept = true;
        object(id)->parent = node;
    }
}

static void keep_value(V value) { keep(object_id(value)); }

static void keep_global(V name)
{
    keep_value(name);
    keep(global_id(name));
}

static void set(bool *flag)
{
    changed = changed || !*flag;
    *flag = true;
}

static void note(size_t *first)
{
    changed = changed || !*first;
    *first = *first ? *first : node;
}

/* A code object's place in codes, plus one. */
static size_t code_place(V code)
{
    size_t id = object_id(code);
    if (!object(id)->place) {
        GROW(codes, ncodes);
        codes[ncodes++] = (Code){.node = id};
        object(id)->place = ncodes;
    }
    return object(id)->place;
}

/* Until the next call of this, which may move it. */
static Code *code_of(V code)
{
    size_t place = code_place(code);
    return &codes[place - 1];
}

/* A value, which anything may call if it is a procedure. */
static void keep_escaping(V value)
{
    value = substitute(value);
    if (is_closure(value))
        set(&code_of(ptr(value)[CLO_CODE])->escapes);
    keep_value(value);
}

/* A name, whose function anything may call. */
static void keep_function(V name)
{
    if (is_symbol(name)) {
        keep(cell_id(name));
        keep_escaping(binding(name));
    }
}

/* A closure of this code captures these, as others may capture others. */
static void captures(Code *c, const V *values, size_t n)
{
    if (!c->made) {
        c->captures = memory(malloc((n + 1) * sizeof *c->captures));
        memcpy(c->captures, values, n * sizeof *values);
        c->ncaptures = n;
        set(&c->made);
    }
    for (size_t i = 0; i < n && i < c->ncaptures; i++) {
        V merged = merge(c->captures[i], values[i]);
        changed = changed || merged != c->captures[i];
        c->captures[i] = merged;
    }
}

/* ---------------------------------------------------------------------------------------------
   Reading code. */

static size_t reading, root;     /* the places of the code being read, and of the function it is nested in */
static const uint64_t *code;
static const uint32_t *words;
static size_t frame;
static V *now, *at_labels;       /* what each slot may hold here, and at each label */
static bool *reached;
static bool live, again, acting; /* code comes here; a label is reached with more; what is read is kept */
static size_t nhandlers, ninlined;
static uint32_t *handlers;       /* the labels of those that may be in place */
static uint32_t *inlined;        /* the cells of the names of the bodies inlined around here, from the outermost */
static size_t *inlined_ends;

static const char *const worker_hooks[2][2] = {
    {"shen-jit.*at-end*", "shen-jit.isolate-ending"}, {"shen-jit.*guards-dead*", "shen-jit.run-at-end"}
};
static const char isolate_flag[] = "shen-jit.*isolate*";
static const char not_through_get[] = "*property-vector* other than through get, put and unput";

/* The name of a code object or a global, for a diagnostic, or []. */
static V node_name(size_t id)
{
    if (id >= objects)
        return is_type(object(id)->value, T_CODE) ? ptr(object(id)->value)[CODE_NAME] : V_NIL;
    for (size_t cell = 0; id >= globals && cell < (constants - cells) / 2; cell++)
        if (global_id(cell_names[cell]) == id)
            return cell_names[cell];
    return V_NIL;
}

static void print_name(V name, const char *after)
{
    V text = ptr(name)[SYM_NAME];
    fprintf(stderr, "%.*s%s", (int)string_length(text), string_bytes(text), after);
}

/* Ends the process, as the program cannot be closed, saying what it needs and the way there from its
   entry point: with a name, if that has one, and the caller to declare it for, if that would do. */
static _Noreturn void refuse(const char *why, V name, V caller)
{
    V names[32];
    size_t n = 0;
    for (size_t i = ninlined; i-- && n < 8;)
        names[n++] = cell_names[inlined[i]];
    for (size_t id = node; id && n < sizeof names / sizeof names[0];) {
        V through = node_name(id);
        if (is_symbol(through))
            names[n++] = through;
        id = id < objects ? slots[id] - 1 : object(id)->parent;
    }
    fputs("shen-jit: closed build: ", stderr);
    while (n)
        print_name(names[--n], " -> ");
    fprintf(stderr, "requires %s", why);
    if (is_symbol(name))
        print_name(name, "");
    if (is_symbol(caller)) {
        fputs(" (declare it with --dispatch ", stderr);
        print_name(caller, " FUNCTION)");
    }
    fputc('\n', stderr);
    end();
}

/* What --dispatch knows this code by: the functions inlined around here, then its own name and those
   of what it is nested in, from the innermost out. V_NIL after the last. */
static V caller_name(size_t i)
{
    if (i < ninlined)
        return cell_names[inlined[ninlined - 1 - i]];
    i -= ninlined;
    for (size_t place = reading + 1; place; place = codes[place - 1].outer) {
        V name = ptr(object(codes[place - 1].node)->value)[CODE_NAME];
        if (is_proc(binding(name)) && i-- == 0)
            return name;
    }
    return V_NIL;
}

/* A name that is computed, for what op does: those that --dispatch declares, if it declares any. */
static void computed(Use use, V op)
{
    if (use == TAG)
        return; /* as docs/modules.md says */
    if (use == READ || use == WRITTEN)
        refuse("a computed global name in ", op, V_NIL);
    bool declared = false;
    V name;
    for (size_t i = 0; (name = caller_name(i)) != V_NIL; i++)
        for (V rows = dispatch, row; take(&rows, &row);)
            if (ptr(row)[0] == name) {
                V target = ptr(ptr(row)[1])[0];
                declared = true;
                if (use == ARITY)
                    keep(cell_id(target) + 1);
                else
                    keep_function(target);
            }
    if (!declared)
        refuse("a computed function name in ", op, caller_name(0));
}

/* What a closed program cannot have: evaluation, and what raises as it was not made before saving. */
static void check_function(V name)
{
    static const char *const evaluators[] = {"eval", "eval-kl", "shen-jit.eval-kl"};
    for (size_t i = 0; i < sizeof evaluators / sizeof evaluators[0]; i++)
        if (symbol_named(name, evaluators[i]))
            refuse("", name, V_NIL);
    if (symbol_named(name, "shen-jit.unprepared"))
        refuse("what was not prepared before it was saved", V_NIL, V_NIL);
}

/* Whether this is shen-jit.call-target, whose names were shen-jit.target's, where they were followed. */
static bool calls_target(void)
{
    V name;
    for (size_t i = 0; (name = caller_name(i)) != V_NIL; i++)
        if (symbol_named(name, "shen-jit.call-target"))
            return true;
    return false;
}

/* A symbol that is first in a vector, which its function prints. */
static void add_tag(V name)
{
    size_t id = object_id(name);
    keep(id);
    if (!object(id)->tag) {
        GROW(tags, ntags);
        tags[ntags++] = name;
        set(&object(id)->tag);
    }
}

static void named(Use use, V name)
{
    switch (use) {
    case CALLED: keep_function(name); break;
    case ARITY: keep(cell_id(name) + 1); break;
    case READ: keep_global(name); break;
    case WRITTEN:
        /* An isolate starts with a table of its own, and says what it is. */
        if ((name == property_name || symbol_named(name, isolate_flag)) &&
            !symbol_named(code[CODE_NAME], "shen-jit.start-isolate"))
            refuse("a change to ", name, V_NIL);
        for (size_t i = 0; i < 2; i++)
            if (symbol_named(name, worker_hooks[i][0]))
                set(&hooked[i]);
        keep_value(name);
        break;
    default: add_tag(name);
    }
}

/* What a slot holds is used as a name, by a primitive or the function op. */
static void use_name(Use use, V value, V op)
{
    if (is_symbol(value)) {
        named(use, value);
    } else if (is_pvar(value)) {
        size_t i = pvar_offset(value);
        uint64_t *names = &codes[root].names[i / PARAMETERS][use], bit = UINT64_C(1) << i % PARAMETERS;
        changed = changed || !(*names & bit);
        *names |= bit;
    } else if (value == ANY) {
        computed(use, op);
    } /* else it raises, or is a procedure already */
}

static V operand(uint32_t x)
{
    return x & OPERAND_CONST ? known(*ra_at(&vm->program->consts, code[CODE_CBASE] + (x & ~OPERAND_CONST))) : now[x];
}

static void merge_into(V *slot, V value)
{
    V merged = merge(*slot, value);
    again = again || merged != *slot;
    *slot = merged;
}

static void reach(uint32_t label)
{
    V *there = at_labels + label * frame;
    if (!reached[label])
        memcpy(there, now, frame * sizeof *there);
    again = again || !reached[label];
    reached[label] = true;
    for (size_t i = 0; i < frame; i++)
        merge_into(&there[i], now[i]);
}

/* A slot's new value, which the handlers in place may find there. */
static void put(size_t slot, V value)
{
    now[slot] = value;
    for (size_t i = 0; i < nhandlers; i++)
        merge_into(&at_labels[handlers[i] * frame + slot], value);
}

/* The property table goes only to get, put and unput. */
static void not_table(V value)
{
    if (acting && value == TABLE)
        refuse(not_through_get, V_NIL, V_NIL);
}

/* (get X P Table), (put X P V Table) or (unput X P Table): the properties called P are kept, of X or,
   if that is computed, of any subject. */
static bool property_call(V target, const V *args, size_t n)
{
    bool accessor = false;
    for (V list = accessors, f; take(&list, &f);)
        accessor = accessor || f == target;
    if (!accessor || n < 3 || args[n - 1] != TABLE)
        return false;
    if (!is_symbol(args[1]) && args[1] != TABLE)
        refuse("a computed property of *property-vector*", V_NIL, V_NIL);
    Property p = {is_symbol(args[0]) ? args[0] : ANY, args[1]};
    for (size_t i = 0; i < nproperties; i++)
        if (properties[i].attribute == p.attribute &&
            (properties[i].subject == p.subject || properties[i].subject == ANY))
            return true;
    GROW(properties, nproperties);
    properties[nproperties++] = p;
    changed = true;
    keep_value(p.attribute);
    keep_value(p.subject);
    return true;
}

/* A call by name of a function, which the node holds. */
static void call(size_t id, V target, const V *args, size_t n)
{
    target = substitute(target);
    size_t values = n - (acting && property_call(target, args, n)); /* the table is not one of these then */
    for (size_t i = 0; i < values; i++)
        not_table(args[i]);
    if (!acting)
        return;
    keep(id);
    if (!is_closure(target))
        return;
    Code called = *code_of(ptr(target)[CLO_CODE]);
    V name = ptr(ptr(target)[CLO_CODE])[CODE_NAME];
    for (Use use = 0; use < USES; use++)
        for (size_t i = 0; i < n && i < PARAMETERS; i++) {
            if ((called.names[0][use] >> i) & 1)
                use_name(use, args[i], name);
            if ((called.names[1][use] >> i) & 1 && (args[i] == ANY || is_pair(args[i]) || is_pvar(args[i])))
                use_name(use, head(args[i]), name);
        }
}

/* The symbol there is of this name, or V_NIL. */
static V interned(V text)
{
    V name = is_type(text, T_STRING) ? symbol_find(vm, string_bytes(text), string_length(text)) : V_NIL;
    return is_symbol(name) && !symbol_named(name, "true") && !symbol_named(name, "false") ? name : V_NIL;
}

/* What a primitive reaches by the names it is given. */
static void primitive(unsigned prim, const V *args)
{
    if (prim >= primitive_count)
        return; /* only instructions */
    V a = args[0], b = args[1], op = find(primitive_table[prim].name);
    switch (prim) {
    case P_EVAL_KL: case P_INSTALL: case P_SEALING: case P_FOREIGN: case P_SET_ARITY:
    case P_INLINE_BODY: case P_SAVE_EXECUTABLE: case P_SAVE_CLOSED:
        refuse("", op, V_NIL);
    case P_VALUE: use_name(READ, a, op); break;
    case P_SET: use_name(WRITTEN, a, op); break;
    case P_ARITY: use_name(ARITY, a, op); break;
    case P_FUNCTION: case P_APPLY: case P_SEALEDP:
        if (!calls_target())
            use_name(CALLED, a, op);
        break;
    case P_ARITYP: /* its function is called by name, if at all */
        if (is_symbol(a))
            keep(cell_id(a));
        else
            use_name(CALLED, a, op);
        break;
    case P_INTERN: keep_value(interned(a)); break;
    case P_PRINTER: note(&prints); break;
    case P_SET_ADDRESS:
        if (!is_fix(b) || b == fix(0))
            use_name(TAG, args[2], op);
        break;
    case P_ABSVECTOR3: use_name(TAG, a, op); break;
    case P_FILLED_VECTOR: use_name(TAG, b, op); break;
    case P_ISOLATE:
        for (size_t i = 0; isolate_tags[i]; i++)
            if (is_symbol(find(isolate_tags[i])))
                add_tag(find(isolate_tags[i]));
        if (!is_fix(a) || a == fix(0)) {
            note(&spawns);
            use_name(CALLED, b, op);
        }
        break;
    default: break;
    }
}

static V result(unsigned prim, const V *args)
{
    switch (prim) {
    case P_FUNCTION: return PROCEDURE;
    case P_INTERN: return is_symbol(interned(args[0])) ? interned(args[0]) : ANY;
    case P_CONS: return is_symbol(args[0]) ? headed(args[0]) : ANY;
    case P_HD: return head(args[0]);
    case P_VALUE: return symbol_named(args[0], isolate_flag) ? V_TRUE : ANY; /* it cannot compile either */
    default: return ANY;
    }
}

static void read_primitive(const uint32_t *op)
{
    V args[8] = {ANY, ANY, ANY, ANY, ANY, ANY, ANY, ANY}; /* what is used is among the first three */
    for (unsigned i = 0; i < op[3]; i++) {
        args[i & 7] = operand(op[4 + i]);
        not_table(args[i & 7]);
    }
    bool table = op[2] == P_VALUE && args[0] == property_name;
    if (acting && table) {
        note(&has_properties);
        keep_value(property_name);
    } else if (acting) {
        primitive(op[2], args);
    }
    put(op[1], table ? TABLE : result(op[2], args));
}

static void read_call(const uint32_t *op)
{
    bool tail = op[0] == OP_TAIL_CALL || op[0] == OP_TAIL_CALL_SEALED || op[0] == OP_TAIL_CALL_VALUE;
    bool by_value = op[0] == OP_CALL_VALUE || op[0] == OP_TAIL_CALL_VALUE;
    bool sealed = op[0] == OP_CALL_SEALED || op[0] == OP_TAIL_CALL_SEALED;
    const uint32_t *x = op + (tail ? 1 : 2); /* the window, the target and the count */
    size_t window = x[0], n = x[by_value ? 1 : 2];
    if (by_value) {
        for (size_t i = window + 1; i < window + 2 + n; i++) /* the callee, then the arguments */
            not_table(now[i]);
    } else {
        size_t id = sealed ? constants + x[1] : cells + 2 * x[1];
        V target = sealed ? *ra_at(&vm->program->consts, x[1]) : *cell_function(vm, x[1]);
        if (is_symbol(target)) { /* a sealed call that its first run would bind */
            if (acting)
                keep(id);
            id = cell_id(target);
            target = binding(target);
        }
        call(id, target, now + window + 2, n);
    }
    live = !tail;
    if (tail)
        return;
    for (size_t i = window; i < frame; i++)
        put(i, ANY);
    put(op[1], ANY);
}

static void read_closure(const uint32_t *op)
{
    size_t n = op[3];
    V *values = memory(malloc((n + 1) * sizeof *values));
    for (size_t i = 0; i < n; i++)
        not_table(values[i] = operand(op[4 + i]));
    if (acting) {
        V nested = *ra_at(&vm->program->consts, code[CODE_CBASE] + code[CODE_NCONST] + op[2]);
        captures(code_of(is_proc(nested) ? ptr(nested)[CLO_CODE] : nested), values, n);
    }
    free(values);
    put(op[1], PROCEDURE);
}

/* An instruction on registers (docs/bytecode.md): the slots it reads and writes, and where it jumps. */
static void read_registers(const uint32_t *op)
{
    const char *kinds = raw_kinds(op[0]);
    if (op[0] == OP_FLOAT_LOAD || op[0] == OP_FLOAT_STORE)
        for (uint32_t i = 0; i < op[3]; i++)
            not_table(operand(op[4 + i]));
    else
        for (size_t i = 0; kinds[i]; i++) {
            uint32_t x = op[1 + i];
            switch (kinds[i]) {
            case 's': put(x, ANY); break;
            case 'o': not_table(operand(x)); break;
            case 'l': case 'b': reach(x); break;
            case 'f':
                if (acting)
                    keep(cells + 2 * x);
            }
        }
    live = op[0] != OP_AGAIN;
}

static void read_instruction(const uint32_t *op)
{
    switch (op[0]) {
    case OP_CONST: put(op[1], operand(op[2] | OPERAND_CONST)); break;
    case OP_MOVE: put(op[1], now[op[2]]); break;
    case OP_CAPTURE: put(op[1], op[2] < codes[reading].ncaptures ? codes[reading].captures[op[2]] : ANY); break;
    case OP_EXCEPTION: put(op[1], ANY); break;
    case OP_CLOSURE: read_closure(op); break;
    case OP_PRIM: read_primitive(op); break;
    case OP_CALL: case OP_TAIL_CALL: case OP_CALL_SEALED: case OP_TAIL_CALL_SEALED:
    case OP_CALL_VALUE: case OP_TAIL_CALL_VALUE: read_call(op); break;
    case OP_RETURN:
        not_table(operand(op[1]));
        live = false;
        break;
    case OP_JUMP:
        reach(op[1]);
        live = false;
        break;
    case OP_JUMP_IF_FALSE:
        not_table(operand(op[1]));
        if (operand(op[1]) != V_TRUE)
            reach(op[2]);
        live = operand(op[1]) != V_FALSE;
        break;
    case OP_JUMP_UNLESS_ENTRY: reach(op[3]); break;
    case OP_ENTRY: reach(op[2]); break; /* its parameters hold anything already */
    case OP_PUSH_HANDLER:
        reach(op[1]);
        handlers[nhandlers++] = op[1];
        break;
    case OP_POP_HANDLER: break;
    case OP_INLINE:
        if (acting) {
            check_function(cell_names[op[1]]);
            keep_value(cell_names[op[1]]);
        }
        break;
    default: read_registers(op);
    }
}

/* Once through the code, in order. A handler is in place, as far as this can tell, up to its label. */
static void read_through(size_t length)
{
    again = false;
    live = true;
    nhandlers = ninlined = 0;
    for (size_t i = 0; i < frame; i++)
        now[i] = ANY;
    if (reading == root && !codes[reading].escapes)
        for (size_t i = 0; i < (code[CODE_ARITY] & UINT32_MAX) && i < PARAMETERS; i++)
            now[2 + i] = parameter(i);
    for (size_t i = 0; i < length; i += insn_length(words + i)) {
        const uint32_t *op = words + i;
        while (ninlined && inlined_ends[ninlined - 1] <= i)
            ninlined--;
        if (op[0] == OP_LABEL || op[0] == OP_LOOP) {
            size_t others = 0;
            for (size_t h = 0; h < nhandlers; h++)
                if (handlers[h] != op[1])
                    handlers[others++] = handlers[h];
            nhandlers = others;
            if (live)
                reach(op[1]);
            live = reached[op[1]];
            memcpy(now, at_labels + op[1] * frame, frame * sizeof *now);
        } else if (live) {
            read_instruction(op);
        }
        if (op[0] == OP_INLINE) {
            size_t after = i + insn_length(op);
            for (uint32_t n = op[2]; n && after < length; n--)
                after += insn_length(words + after);
            inlined[ninlined] = op[1];
            inlined_ends[ninlined++] = after;
        }
    }
    ninlined = 0;
}

/* Keeps what the code at a place in codes depends on. */
static void read_code(size_t place)
{
    reading = root = place;
    while (codes[root].outer)
        root = codes[root].outer - 1;
    node = codes[place].node;
    code = ptr(object(node)->value);
    frame = code[CODE_FRAME];
    V bytes = code[CODE_BYTECODE];
    uint32_t *unpacked = memory(malloc((string_length(bytes) + 1) * sizeof *unpacked));
    size_t length = bytecode_unpack((const uint8_t *)string_bytes(bytes), string_length(bytes), unpacked);
    size_t labels = 0;
    words = unpacked;
    for (size_t i = 0; i < length; i += insn_length(words + i))
        if ((words[i] == OP_LABEL || words[i] == OP_LOOP) && words[i + 1] >= labels)
            labels = words[i + 1] + 1;
    now = memory(calloc((labels + 1) * frame, sizeof *now));
    at_labels = now + frame;
    reached = memory(calloc(labels + 1, sizeof *reached));
    handlers = memory(malloc((length + 1) * sizeof *handlers));
    inlined = memory(malloc((length + 1) * sizeof *inlined));
    inlined_ends = memory(malloc((length + 1) * sizeof *inlined_ends));
    do
        read_through(length);
    while (again);
    acting = true;
    read_through(length);
    acting = false;
    free(unpacked);
    free(now);
    free(reached);
    free(handlers);
    free(inlined);
    free(inlined_ends);
}

/* ---------------------------------------------------------------------------------------------
   Marking. */

/* A code object's constants, and the code nested in it, whose closures are values. */
static void visit_code(V value)
{
    const V *w = ptr(value);
    size_t here = node;
    node = object(node)->parent; /* to be refused as its caller */
    check_function(w[CODE_NAME]);
    node = here;
    size_t place = code_place(value), nested = w[CODE_CBASE] + w[CODE_NCONST];
    for (size_t i = w[CODE_CBASE]; i < nested + w[CODE_NCODE]; i++) {
        keep(constants + i);
        if (i >= nested) {
            V v = *ra_at(&vm->program->consts, i);
            Code *inner = code_of(is_proc(v) ? ptr(v)[CLO_CODE] : v);
            inner->escapes = true;
            inner->outer = place;
        }
    }
    keep_value(w[CODE_NAME]);
    keep_value(w[CODE_BYTECODE]);
}

static void visit_closure(V value)
{
    const V *w = ptr(value);
    size_t n = hdr_size(w[0]);
    V *values = memory(malloc((n + 1) * sizeof *values));
    for (size_t i = 0; i < n; i++) {
        values[i] = known(w[CLO_CAPS + i]);
        keep_escaping(w[CLO_CAPS + i]);
    }
    captures(code_of(w[CLO_CODE]), values, n);
    free(values);
    keep_value(w[CLO_CODE]);
}

/* A plain C function cannot reach Shen. One written for Shen can look names up. */
static void visit_foreign(V value)
{
    V name = ffi_name(value), names = keeps, k = V_NIL;
    while (ffi_procedure(value) && k != name)
        if (!take(&names, &k))
            refuse("a C procedure, which may look names up (--keep it, and those): ", name, V_NIL);
}

static void visit_object(V value)
{
    const V *w = ptr(value);
    if (value == property_table)
        refuse(not_through_get, V_NIL, V_NIL);
    size_t first = 0, count = 2;
    if (!is_pair(value))
        obj_values(w[0], &first, &count);
    if (is_type(value, T_CODE)) {
        visit_code(value);
    } else if (is_closure(value)) {
        visit_closure(value);
    } else if (is_type(value, T_POINTER)) {
        keep_value(w[POINTER_KIND]); /* its owner and address are cleared */
    } else {
        if (is_proc(value))
            visit_foreign(value);
        if (is_type(value, T_VECTOR) && count && is_symbol(w[1]))
            add_tag(w[1]);
        for (size_t i = 0; i < count; i++)
            keep_escaping(w[first + i]);
    }
}

static void visit_slot(size_t id)
{
    if (id >= globals) {
        keep_escaping(vm->globals[id - globals]);
    } else if (id >= constants) { /* what sealed calls call, or a code object's own */
        keep_value(*ra_at(&vm->program->consts, id - constants));
    } else {
        size_t slot = id - cells;
        keep_value(cell_names[slot / 2]);
        keep_value(*ra_at(&vm->program->cells, slot));
        if (!(slot & 1))
            keep(id + 1);
    }
}

static void visit(void)
{
    while (visited < queued) {
        node = queue[visited++];
        if (node < objects)
            visit_slot(node);
        else
            visit_object(object(node)->value);
    }
}

static V option_name(const char *option, V *list)
{
    V name = V_NIL;
    if (take(list, &name) && is_proc(binding(name)))
        return name;
    fprintf(stderr, "shen-jit: closed build: %s ", option);
    if (is_symbol(name))
        print_name(name, ": ");
    fputs("there is no such function\n", stderr);
    end();
}

static void start(void)
{
    const char *const started[] = {"shen-jit.*entry*", "*home-directory*", "*hush*", "*argv*",
                                   "*stinput*", "*stoutput*", "*sterror*"};
    for (size_t i = 0; i < sizeof started / sizeof started[0]; i++)
        keep_global(find(started[i]));
    keep_function(global_value(vm, find(started[0])));
    for (V names = keeps; is_pair(names);)
        keep_function(option_name("--keep", &names));
    for (V rows = dispatch, row; take(&rows, &row);) {
        option_name("--dispatch", &row);
        option_name("--dispatch", &row);
    }
}

/* What isolates need: what starts one, and what ends one that has something to do then. */
static void keep_isolates(void)
{
    node = spawns;
    keep_function(find("shen-jit.start-isolate"));
    for (size_t i = 0; isolate_constants[i]; i++)
        keep_global(find(isolate_constants[i]));
    for (size_t i = 0; i < 2; i++)
        if (hooked[i])
            keep_function(find(worker_hooks[i][1]));
}

/* The functions that print vectors, whose names are first in them. */
static void keep_printers(void)
{
    for (size_t i = 0; i < ntags; i++)
        if (is_proc(binding(tags[i])) && *cell_arity(vm, symbol_cell(tags[i])) == fix(1)) {
            node = object_id(tags[i]);
            keep_function(tags[i]);
        }
}

/* Whether an entry's attribute is kept: not a function's form, which fn makes again. */
static bool kept_attribute(V entry, V attribute)
{
    for (size_t i = 0; i < nproperties; i++)
        if (is_pair(attribute) && ptr(attribute)[0] == properties[i].attribute &&
            (properties[i].subject == ANY || properties[i].subject == ptr(entry)[0]))
            return !symbol_named(ptr(attribute)[0], "shen.lambda-form");
    return false;
}

/* Whether an entry of the property table is kept, if only as one with no attributes, and how many
   of its attributes are. */
static bool kept_entry(V entry, size_t *attributes)
{
    bool subject = false;
    for (size_t i = 0; i < nproperties; i++)
        subject = subject || properties[i].subject == ptr(entry)[0];
    *attributes = 0;
    for (V list = ptr(entry)[1], attribute; take(&list, &attribute);)
        *attributes += kept_attribute(entry, attribute);
    return subject || *attributes;
}

/* Keeps what the property table's copy holds, and counts it. */
static void keep_properties(size_t *entries, size_t *attributes)
{
    size_t n, found;
    V *buckets = sj_dict_buckets(property_table, &n);
    node = has_properties;
    if (!buckets)
        refuse("*property-vector* to be a dictionary", V_NIL, V_NIL);
    *entries = *attributes = 0;
    for (size_t i = 0; i < n; i++)
        for (V row = buckets[i], entry; take(&row, &entry);)
            if (kept_entry(entry, &found)) {
                ++*entries;
                *attributes += found;
                keep_escaping(ptr(entry)[0]);
                for (V list = ptr(entry)[1], attribute; take(&list, &attribute);)
                    if (kept_attribute(entry, attribute))
                        keep_escaping(attribute);
            }
    keep_value(ptr(property_table)[DICT_TAG]);
}

static void mark(size_t *entries, size_t *attributes)
{
    start();
    do {
        changed = false;
        visit();
        for (size_t i = 0; i < ncodes; i++)
            if (codes[i].made && kept(codes[i].node)) {
                read_code(i);
                visit();
            }
        if (spawns)
            keep_isolates();
        if (prints)
            keep_printers();
        if (has_properties)
            keep_properties(entries, attributes);
    } while (changed);
}

/* ---------------------------------------------------------------------------------------------
   The image. Symbols, the program's objects and the heap's are packed. Cells, constants and globals
   keep their places, which code holds, and what is not kept in them is cleared. */

static size_t object_words(V value) { return is_pair(value) ? 2 : obj_words(ptr(value)[0]); }

static V moved(V value)
{
    value = substitute(value);
    if (!is_ptr(value))
        return value;
    size_t id = addr_map_get(&numbers, (uintptr_t)ptr(value));
    if (!kept(id)) {
        fputs("shen-jit: closed build: the image would hold what was not kept\n", stderr);
        end();
    }
    const Node *n = object(id);
    uint64_t location = n->part == IMAGE_SYMBOLS ? IMAGE_IN_SYMBOLS : n->part == IMAGE_PROGRAM ? IMAGE_IN_OBJECTS : 0;
    return location | n->offset * sizeof(V) | tag3(value);
}

static void copy_object(const Node *n, V *out)
{
    memcpy(out, ptr(n->value), object_words(n->value) * sizeof *out);
    size_t first = 0, count = 2;
    if (!is_pair(n->value)) {
        image_clear_raw(out);
        obj_values(out[0], &first, &count);
    }
    if (is_type(n->value, T_CODE))
        out[CODE_INLINE] = V_NIL; /* nothing is compiled from source again */
    if (is_symbol(n->value))
        out[SYM_CELL] &= ~(UINT64_C(1) << MARK_BIT);
    for (size_t i = 0; i < count; i++)
        out[first + i] = moved(out[first + i]);
}

/* A value at this place in the heap's part of the image. */
static V placed(const V *heap, const V *at, unsigned tag) { return (V)(at - heap) * sizeof(V) | tag; }

static size_t table_buckets(size_t entries)
{
    size_t n = 8;
    while (n < entries)
        n *= 2;
    return n;
}

/* The property table, of the entries and attributes that are kept. */
static V copy_properties(const V *heap, V *table, size_t entries)
{
    size_t n, size = table_buckets(entries), found;
    V *buckets = table + 1 + DICT_FIELDS, *next = buckets + 1 + size;
    table[0] = HEADER(T_VECTOR, DICT_FIELDS);
    table[DICT_TAG] = moved(ptr(property_table)[DICT_TAG]);
    table[DICT_COUNT] = fix((int64_t)entries);
    table[DICT_BUCKETS] = placed(heap, buckets, TAG_OBJECT);
    buckets[0] = HEADER(T_VECTOR, size);
    for (size_t i = 1; i <= size; i++)
        buckets[i] = V_NIL;
    V *old = sj_dict_buckets(property_table, &n);
    for (size_t i = 0; i < n; i++)
        for (V row = old[i], entry; take(&row, &entry);) {
            if (!kept_entry(entry, &found))
                continue;
            V *bucket = buckets + 1 + (sj_hash(ptr(entry)[0]) & (size - 1));
            next[0] = placed(heap, next + 2, TAG_PAIR); /* a cell of the bucket, and the entry */
            next[1] = *bucket;
            *bucket = placed(heap, next, TAG_PAIR);
            next[2] = moved(ptr(entry)[0]);
            V *last = next + 3;
            next += 4;
            for (V list = ptr(entry)[1], attribute; take(&list, &attribute);)
                if (kept_attribute(entry, attribute)) {
                    *last = placed(heap, next, TAG_PAIR);
                    next[0] = moved(attribute);
                    last = next + 1;
                    next += 2;
                }
            *last = V_NIL;
        }
    return placed(heap, table, TAG_OBJECT);
}

static V slot_value(size_t id)
{
    if (id == isolate_slot)
        return V_TRUE;
    return id >= globals ? vm->globals[id - globals] :
           id >= constants ? *ra_at(&vm->program->consts, id - constants) : *ra_at(&vm->program->cells, id - cells);
}

static void copy_image(ImageContents *image, size_t entries, size_t attributes)
{
    const size_t starts[] = {cells, constants, globals, objects};
    size_t *n = image->words;
    for (size_t i = 0; i < nnodes; i++)
        if (nodes[i].kept) {
            nodes[i].offset = n[nodes[i].part];
            n[nodes[i].part] += object_words(nodes[i].value);
        }
    size_t table = n[IMAGE_HEAP];
    if (has_properties)
        n[IMAGE_HEAP] += 1 + DICT_FIELDS + 1 + table_buckets(entries) + 4 * entries + 2 * attributes;
    for (size_t part = 0; part < IMAGE_PARTS; part++) {
        if (part >= IMAGE_CELLS)
            n[part] = starts[part - IMAGE_CELLS + 1] - starts[part - IMAGE_CELLS];
        image->parts[part] = memory(malloc((n[part] + 1) * sizeof(V)));
        for (size_t i = 0; part >= IMAGE_CELLS && i < n[part]; i++) {
            size_t id = starts[part - IMAGE_CELLS] + i;
            image->parts[part][i] = slots[id] ? moved(slot_value(id)) : V_CLEARED;
        }
    }
    for (size_t i = 0; i < nnodes; i++)
        if (nodes[i].kept)
            copy_object(&nodes[i], image->parts[nodes[i].part] + nodes[i].offset);
    if (has_properties)
        image->parts[IMAGE_GLOBALS][property_slot - globals] =
            copy_properties(image->parts[IMAGE_HEAP], image->parts[IMAGE_HEAP] + table, entries);
}

/* An image of what the program can reach. If it needs what a closed program cannot have, says so,
   removes the file and ends the process. Options are the functions to keep besides, and rows of a
   caller and a function that it calls by a computed name. */
void image_closed(VM *builder, V options, const char *file, ImageContents *image)
{
    vm = builder;
    output = file;
    vm_root(vm, &options);
    if (!image_collect(vm))
        memory(NULL);
    vm_unroot(vm, 1);
    Program *p = vm->program;
    cells = 1;
    constants = cells + p->cells.count;
    globals = constants + p->consts.count;
    objects = globals + p->nglobals;
    cell_names = memory(calloc(p->cells.count / 2 + 1, sizeof *cell_names));
    slots = memory(calloc(objects, sizeof *slots));
    for (V *at = p->space.base; at < p->space.symbols_next; at += SYM_WORDS)
        if (*at)
            cell_names[symbol_cell(tagged(at, TAG_SYMBOL))] = tagged(at, TAG_SYMBOL);
    V kernel = global_value(vm, find("shen-jit.*closed*"));
    accessors = ptr(kernel)[0];
    substitutions = ptr(kernel)[1];
    keeps = ptr(options)[0];
    dispatch = ptr(ptr(options)[1])[0];
    property_name = find("*property-vector*");
    property_slot = global_id(property_name);
    isolate_slot = global_id(find(isolate_flag));
    property_table = vm->globals[property_slot - globals];
    size_t entries = 0, attributes = 0;
    mark(&entries, &attributes);
    copy_image(image, entries, attributes);
}
