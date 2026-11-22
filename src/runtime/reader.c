/* A reader for the stage 0 text the lowerer prints (src/lowerer/README.md): lists
   in ( ) or [ ], strings with \" \\ and \xHH escapes, numbers, booleans and
   symbols. It is not the Shen reader, which is kernel code. */
#include "reader.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

static void skip_space(Reader *r)
{
    while (r->p < r->end && isspace((unsigned char)*r->p))
        r->p++;
}

static bool delimiter(char c)
{
    return isspace((unsigned char)c) || c == '(' || c == ')' || c == '[' || c == ']' || c == '"';
}

static V fail(Reader *r, const char *message)
{
    if (!r->error)
        r->error = message;
    return V_CLEARED;
}

static V read_list(Reader *r, char close)
{
    VM *vm = r->vm;
    V items = V_NIL;
    vm_root(vm, &items);
    for (;;) {
        skip_space(r);
        if (r->p == r->end) {
            items = fail(r, "unterminated list");
            break;
        }
        if (*r->p == ')' || *r->p == ']') {
            if (*r->p++ != close)
                items = fail(r, "mismatched bracket");
            break;
        }
        V item = reader_read(r);
        if (item == V_CLEARED || (items = make_pair(vm, item, items)) == V_CLEARED) {
            items = fail(r, "cannot read list item");
            break;
        }
    }
    vm_unroot(vm, 1);
    if (items == V_CLEARED)
        return items;
    /* Reverse the fresh list in place. */
    V reversed = V_NIL;
    while (items != V_NIL) {
        V next = ptr(items)[1];
        ptr(items)[1] = reversed;
        reversed = items;
        items = next;
    }
    return reversed;
}

static V read_string(Reader *r)
{
    char small[256];
    size_t cap = sizeof small, len = 0;
    char *buf = small;
    while (r->p < r->end && *r->p != '"') {
        int c = (unsigned char)*r->p++;
        if (r->kl && c == 'c' && r->end - r->p >= 3 && r->p[0] == '#' &&
            isdigit((unsigned char)r->p[1])) {
            char *stop;
            long code = strtol(r->p + 1, &stop, 10);
            if (stop < r->end && *stop == ';' && code >= 0 && code <= 255) {
                c = (int)code;
                r->p = stop + 1;
            }
        } else if (!r->kl && c == '\\' && r->p < r->end) {
            c = (unsigned char)*r->p++;
            if (c == 'x' && r->end - r->p >= 2 && isxdigit((unsigned char)r->p[0]) &&
                isxdigit((unsigned char)r->p[1])) {
                char hex[3] = {r->p[0], r->p[1], 0};
                c = (int)strtol(hex, NULL, 16);
                r->p += 2;
            } else if (c != '"' && c != '\\') {
                if (buf != small)
                    free(buf);
                return fail(r, "unknown string escape");
            }
        }
        if (len == cap) {
            size_t ncap = cap * 2;
            char *more = buf == small ? malloc(ncap) : realloc(buf, ncap);
            if (!more) {
                if (buf != small)
                    free(buf);
                return fail(r, "out of memory");
            }
            if (buf == small)
                memcpy(more, small, len);
            buf = more;
            cap = ncap;
        }
        buf[len++] = (char)c;
    }
    if (r->p == r->end) {
        if (buf != small)
            free(buf);
        return fail(r, "unterminated string");
    }
    r->p++;
    V s = make_string(r->vm, len ? buf : "", len);
    if (buf != small)
        free(buf);
    return s;
}

static V read_atom(Reader *r)
{
    const char *start = r->p;
    while (r->p < r->end && !delimiter(*r->p))
        r->p++;
    size_t len = (size_t)(r->p - start);
    char token[64];
    if (len < sizeof token) {
        memcpy(token, start, len);
        token[len] = 0;
        unsigned char c0 = (unsigned char)token[0];
        if (isdigit(c0) || c0 == '-' || c0 == '+' || c0 == '.') {
            char *stop;
            long long n = strtoll(token, &stop, 10);
            if (stop != token && *stop == 0 && fix_fits(n))
                return fix(n);
            double d = strtod(token, &stop);
            if (stop != token && *stop == 0 && (isdigit(c0) || ((c0 == '-' || c0 == '.') && len > 1))) {
                /* The Shen reader computes "8.0" as 8 + 0/10, an integer. */
                char *dot = strchr(token, '.');
                if (r->kl && dot && !strpbrk(token, "eE") && strspn(dot + 1, "0") == strlen(dot + 1) &&
                    d == (double)(long long)d && fix_fits((long long)d))
                    return fix((long long)d);
                return make_float(r->vm, d);
            }
        }
        if (strcmp(token, "true") == 0)
            return V_TRUE;
        if (strcmp(token, "false") == 0)
            return V_FALSE;
    }
    return intern(r->vm, start, len);
}

V reader_read(Reader *r)
{
    skip_space(r);
    if (r->p == r->end)
        return fail(r, "unexpected end of input");
    char c = *r->p++;
    if (c == '(')
        return read_list(r, ')');
    if (c == '[')
        return read_list(r, ']');
    if (c == ')' || c == ']')
        return fail(r, "unexpected closing bracket");
    if (c == '"')
        return read_string(r);
    r->p--;
    return read_atom(r);
}

bool reader_at_end(Reader *r)
{
    skip_space(r);
    return r->p == r->end;
}
