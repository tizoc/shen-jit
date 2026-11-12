/* Optional libcurl adapter over the public Shen C API. No Shen access between shen_release and shen_acquire. */
#include "shen.h"
#include <curl/curl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if LIBCURL_VERSION_NUM < 0x074400
#error "Shen curl requires libcurl 7.68.0 or newer"
#endif
#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

typedef struct { CURL *easy; bool busy; } Client;
typedef struct { unsigned char *data; size_t used, capacity; } Buffer;
typedef struct {
    char *method, *url, *ca, *proxy;
    unsigned char *upload;
    size_t upload_size, body_limit, header_limit, body_total, header_total;
    long timeout, connect_timeout, redirects;
    struct curl_slist *fields;
    Buffer body, head, trailers;
    bool headers_done;
    bool streaming, started, locked, callback_error;
    size_t chunk_size;
    CURL *easy;
    shen_vm *vm;             /* Only for this synchronous foreign call, on its calling thread. */
    shen_value handler;      /* Rooted throughout the transfer. */
    void *token;
    int reason;
    char error[CURL_ERROR_SIZE];
} Transfer;

/* Initialization precedes any transfer. */
static bool initialized;
static CURLcode initialize(void)
{
    if (initialized) return CURLE_OK;
    CURLcode rc = curl_global_init(CURL_GLOBAL_DEFAULT);
    if (!rc) initialized = true;
    return rc;
}

EXPORT int shen_curl_abi(void) { return 2; }

EXPORT shen_value shen_curl_version(shen_vm *vm, shen_value *args)
{
    (void)args;
    CURLcode rc = initialize();
    if (rc) return shen_raise(vm, curl_easy_strerror(rc));
    const char *s = curl_version();
    return shen_make_string(vm, s, strlen(s));
}

EXPORT shen_value shen_curl_open(shen_vm *vm, shen_value *args)
{
    (void)args;
    if ((*vm)->version != SHEN_API_VERSION) return shen_raise(vm, "curl: incompatible Shen C API");
    CURLcode rc = initialize();
    if (rc) return shen_raise(vm, curl_easy_strerror(rc));
    const curl_version_info_data *version = curl_version_info(CURLVERSION_NOW);
    if (!version || version->version_num < 0x074400)
        return shen_raise(vm, "curl: libcurl 7.68.0 or newer is required");
    Client *c = calloc(1, sizeof *c);
    if (!c) return shen_raise(vm, "curl: cannot allocate client");
    c->easy = curl_easy_init();
    if (!c->easy) { free(c); return shen_raise(vm, "curl: cannot create easy handle"); }
    shen_value p = shen_make_pointer(vm, c, "curl.client");
    if (p == SHEN_ERROR) { curl_easy_cleanup(c->easy); free(c); }
    return p;
}

EXPORT shen_value shen_curl_close(shen_vm *vm, shen_value *args)
{
    Client *c = shen_pointer(vm, args[0], "curl.client");
    if (!c) return shen_raise(vm, "curl: client is closed or stale");
    if (c->busy) return shen_raise(vm, "curl: client is already in use");
    c->busy = true;
    /* Invalidate every ordinary alias before the transfer waits or the native client is freed. */
    if (!shen_is_procedure(vm, args[1])) { c->busy = false; return shen_raise(vm, "curl: missing invalidator"); }
    if (shen_call(vm, args[1], 1, args) == SHEN_ERROR) { c->busy = false; return SHEN_ERROR; }
    if (shen_pointer(vm, args[0], "curl.client")) {
        c->busy = false;
        return shen_raise(vm, "curl: client was not invalidated");
    }
    void *token = shen_release(vm);
    curl_easy_cleanup(c->easy);
    free(c);
    shen_acquire(vm, token);
    return SHEN_TRUE;
}

static void clear_transfer(Transfer *t)
{
    free(t->method); free(t->url); free(t->ca); free(t->proxy); free(t->upload);
    curl_slist_free_all(t->fields);
    free(t->body.data); free(t->head.data); free(t->trailers.data);
}

static bool append(Buffer *b, const void *data, size_t n, size_t limit, Transfer *t)
{
    if (n > limit - b->used) return false;
    size_t need = b->used + n;
    if (need > b->capacity) {
        size_t capacity = b->capacity ? b->capacity : (limit < 4096 ? limit : 4096);
        while (capacity < need) capacity += capacity < limit - capacity ? capacity : limit - capacity;
        void *next = realloc(b->data, capacity);
        if (!next) { t->reason = 4; return false; }
        b->data = next;
        b->capacity = capacity;
    }
    if (n) memcpy(b->data + b->used, data, n);
    b->used += n;
    return true;
}

static shen_value result(shen_vm *vm, Transfer *t, CURLcode rc, CURL *easy);

/* Callback roots must leave before this C frame does. */
static bool stream_event(Transfer *t, bool head, const char *data, size_t n)
{
    shen_value args[2] = {SHEN_NIL, SHEN_NIL};
    shen_root(t->vm, &args[0]);
    shen_root(t->vm, &args[1]);
    args[head ? 0 : 1] = head ? result(t->vm, t, CURLE_OK, t->easy) : shen_make_bytes(t->vm, data, n);
    shen_value out = SHEN_ERROR;
    if (args[head ? 0 : 1] != SHEN_ERROR)
        out = shen_call(t->vm, t->handler, 2, args);
    shen_unroot(t->vm, 2);
    if (out == SHEN_ERROR) t->callback_error = true;
    if (out != SHEN_TRUE) { t->reason = 5; return false; }
    if (head) t->started = true;
    return true;
}

static size_t body_callback(char *data, size_t size, size_t count, void *context)
{
    Transfer *t = context;
    if (size && count > SIZE_MAX / size) { t->reason = 2; return 0; }
    size_t n = size * count;
    if (n > t->body_limit - t->body_total) { t->reason = 2; return 0; }
    if (t->streaming && n) {
        shen_acquire(t->vm, t->token);
        t->locked = true;
        if (!t->started && !stream_event(t, true, NULL, 0)) return 0;
        for (size_t at = 0; at < n;) {
            size_t part = n - at < t->chunk_size ? n - at : t->chunk_size;
            if (!stream_event(t, false, data + at, part)) return 0;
            t->body_total += part;
            at += part;
        }
        /* The sink accepted everything before libcurl can read again. No queue or body buffer. */
        t->token = shen_release(t->vm);
        t->locked = false;
        return n;
    }
    if (!append(&t->body, data, n, t->body_limit, t)) return 0;
    t->body_total += n;
    return n;
}

static bool status_line(const char *data, size_t n)
{
    if (n < 10 || memcmp(data, "HTTP/", 5)) return false;
    size_t i = 5;
    while (i < n && ((data[i] >= '0' && data[i] <= '9') || data[i] == '.')) i++;
    return i > 5 && i + 4 < n && data[i] == ' ' &&
           data[i+1] >= '0' && data[i+1] <= '9' && data[i+2] >= '0' && data[i+2] <= '9' &&
           data[i+3] >= '0' && data[i+3] <= '9' && (data[i+4] == ' ' || data[i+4] == '\r' || data[i+4] == '\n');
}

static size_t header_callback(char *data, size_t size, size_t count, void *context)
{
    Transfer *t = context;
    if (size && count > SIZE_MAX / size) { t->reason = 3; return 0; }
    size_t n = size * count;
    if (n > t->header_limit - t->header_total) { t->reason = 3; return 0; }
    t->header_total += n;
    if (status_line(data, n)) {
        t->head.used = t->trailers.used = t->body.used = 0;
        t->headers_done = false;
    }
    Buffer *out = t->headers_done ? &t->trailers : &t->head;
    if (!append(out, data, n, t->header_limit, t)) return 0;
    if ((n == 2 && data[0] == '\r' && data[1] == '\n') || (n == 1 && data[0] == '\n'))
        t->headers_done = true;
    return n;
}

/* No allocating Shen call occurs while input addresses are borrowed. */
static char *copy_text(shen_vm *vm, shen_value v, size_t maximum)
{
    size_t n;
    const char *s = shen_string_bytes(vm, v, &n);
    if (!s || n > maximum || memchr(s, 0, n)) return NULL;
    char *out = malloc(n + 1);
    if (out) { memcpy(out, s, n); out[n] = 0; }
    return out;
}

static bool number_option(shen_vm *vm, shen_value config, int i, int64_t max, int64_t *out)
{
    shen_value v = shen_vector_ref(vm, config, i);
    if (!shen_is_fixnum(v)) return false;
    *out = shen_fixnum(v);
    return *out >= 0 && *out <= max;
}

static bool prepare(shen_vm *vm, shen_value *args, Transfer *t)
{
    shen_value config = args[5];
    int64_t limits[6];
    if (shen_vector_length(vm, config) != (t->streaming ? 9 : 8)) return false;
    for (int i = 0; i < 6; i++) {
        int64_t max = i == 1 && t->streaming ? (INT64_C(1) << 61) - 1 :
                      i < 2 ? 268435456 : i == 2 ? 1048576 : i < 5 ? 2147483647 : 20;
        if (!number_option(vm, config, i, max, &limits[i])) return false;
    }
    if (!limits[3] || !limits[4]) return false;
    if (t->streaming) {
        int64_t chunk;
        if (!number_option(vm, config, 8, 65536, &chunk) || !chunk) return false;
        t->chunk_size = (size_t)chunk;
    }
    t->body_limit = (size_t)limits[1]; t->header_limit = (size_t)limits[2];
    t->timeout = (long)limits[3]; t->connect_timeout = (long)limits[4]; t->redirects = (long)limits[5];
    t->method = copy_text(vm, args[1], 32);
    t->url = copy_text(vm, args[2], 8192);
    if (!t->method || !t->url) return false;
    for (int i = 6; i < 8; i++) {
        shen_value v = shen_vector_ref(vm, config, i);
        if (v != SHEN_NIL) {
            char *s = copy_text(vm, v, i == 6 ? 4096 : 8192);
            if (!s) return false;
            if (i == 6) t->ca = s; else t->proxy = s;
        }
    }
    size_t n;
    unsigned char *body = shen_bytes_data(vm, args[4], &n);
    if (!body || n > (size_t)limits[0]) return false;
    t->upload = malloc(n ? n : 1);
    if (!t->upload) return false;
    if (n) memcpy(t->upload, body, n);
    t->upload_size = n;
    size_t total = 0, fields = 0;
    shen_value l = args[3];
    while (shen_is_pair(vm, l)) {
        if (++fields > 100) return false;
        char *line = copy_text(vm, shen_head(vm, l), 8192);
        if (!line) return false;
        size_t length = strlen(line);
        if (strpbrk(line, "\r\n") || length > 65536 - total) { free(line); return false; }
        total += length;
        struct curl_slist *next = curl_slist_append(t->fields, line);
        free(line);
        if (!next) return false;
        t->fields = next;
        l = shen_tail(vm, l);
    }
    return l == SHEN_NIL;
}

#define SET(option, value) do { CURLcode rc = curl_easy_setopt(easy, option, value); if (rc) return rc; } while (0)
static CURLcode configure(CURL *easy, Transfer *t)
{
    SET(CURLOPT_URL, t->url);
    SET(CURLOPT_NOSIGNAL, 1L);
    SET(CURLOPT_ERRORBUFFER, t->error);
    SET(CURLOPT_WRITEFUNCTION, body_callback); SET(CURLOPT_WRITEDATA, t);
    SET(CURLOPT_HEADERFUNCTION, header_callback); SET(CURLOPT_HEADERDATA, t);
    SET(CURLOPT_HTTPHEADER, t->fields);
    SET(CURLOPT_HEADEROPT, (long)CURLHEADER_SEPARATE);
    SET(CURLOPT_SUPPRESS_CONNECT_HEADERS, 1L);
    SET(CURLOPT_SSL_VERIFYPEER, 1L); SET(CURLOPT_SSL_VERIFYHOST, 2L);
    SET(CURLOPT_HTTP_CONTENT_DECODING, 0L);
    SET(CURLOPT_TIMEOUT_MS, t->timeout); SET(CURLOPT_CONNECTTIMEOUT_MS, t->connect_timeout);
    SET(CURLOPT_PROTOCOLS, (long)(CURLPROTO_HTTP | CURLPROTO_HTTPS));
    bool https = curl_strnequal(t->url, "https://", 8);
    SET(CURLOPT_REDIR_PROTOCOLS, (long)(https ? CURLPROTO_HTTPS : CURLPROTO_HTTP | CURLPROTO_HTTPS));
    SET(CURLOPT_FOLLOWLOCATION, t->redirects ? 1L : 0L); SET(CURLOPT_MAXREDIRS, t->redirects);
    if (t->ca) SET(CURLOPT_CAINFO, t->ca);
    if (t->proxy) SET(CURLOPT_PROXY, t->proxy);
    if (!strcmp(t->method, "HEAD")) SET(CURLOPT_NOBODY, 1L);
    else if (strcmp(t->method, "GET")) {
        SET(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)t->upload_size);
        SET(CURLOPT_POSTFIELDS, t->upload);
        if (strcmp(t->method, "POST")) SET(CURLOPT_CUSTOMREQUEST, t->method);
    }
    return CURLE_OK;
}
#undef SET

/* Internal result: code, reason, message, accepted bytes, status, URL, body, head, trailers, ms, redirects. */
static shen_value result(shen_vm *vm, Transfer *t, CURLcode rc, CURL *easy)
{
    long status = 0, redirects = 0;
    curl_off_t elapsed = 0;
    char *url = NULL;
    curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &status);
    curl_easy_getinfo(easy, CURLINFO_EFFECTIVE_URL, &url);
    curl_easy_getinfo(easy, CURLINFO_TOTAL_TIME_T, &elapsed);
    curl_easy_getinfo(easy, CURLINFO_REDIRECT_COUNT, &redirects);
    const char *message = t->reason == 2 ? "response body exceeds limit" :
                          t->reason == 3 ? "response headers exceed limit" :
                          t->reason == 4 ? "cannot allocate transfer buffer" :
                          t->reason == 5 ? "response sink rejected data" :
                          t->error[0] ? t->error : curl_easy_strerror(rc);
    shen_value out = shen_make_vector(vm, 11, SHEN_NIL);
    if (out == SHEN_ERROR) return out;
    shen_root(vm, &out);
    shen_vector_set(vm, out, 0, shen_make_fixnum(rc));
    shen_vector_set(vm, out, 1, shen_make_fixnum(t->reason));
    shen_vector_set(vm, out, 3, shen_make_fixnum((int64_t)t->body_total));
    shen_vector_set(vm, out, 4, shen_make_fixnum(status));
    shen_vector_set(vm, out, 9, shen_make_fixnum((int64_t)(elapsed / 1000)));
    shen_vector_set(vm, out, 10, shen_make_fixnum(redirects));
    shen_value value = shen_make_string(vm, message, strlen(message));
    if (value == SHEN_ERROR) goto failed;
    shen_vector_set(vm, out, 2, value);
    if (rc) goto done;
    value = shen_make_string(vm, url ? url : t->url, strlen(url ? url : t->url));
    if (value == SHEN_ERROR) goto failed;
    shen_vector_set(vm, out, 5, value);
    Buffer *buffers[] = {&t->body, &t->head, &t->trailers};
    for (int i = 0; i < 3; i++) {
        value = shen_make_bytes(vm, buffers[i]->data, buffers[i]->used);
        if (value == SHEN_ERROR) goto failed;
        shen_vector_set(vm, out, 6 + i, value);
    }
done:
    shen_unroot(vm, 1);
    return out;
failed:
    shen_unroot(vm, 1);
    return SHEN_ERROR;
}

static shen_value request(shen_vm *vm, shen_value *args, shen_value handler)
{
    Client *c = shen_pointer(vm, args[0], "curl.client");
    if (!c) return shen_raise(vm, "curl: client is closed or stale");
    if (c->busy) return shen_raise(vm, "curl: client is already in use");
    Transfer t = {.vm = vm, .easy = c->easy, .handler = handler, .streaming = handler != SHEN_NIL};
    shen_root(vm, &t.handler);
    c->busy = true;
    if (!prepare(vm, args, &t)) {
        clear_transfer(&t); c->busy = false;
        shen_unroot(vm, 1);
        return shen_raise(vm, "curl: invalid native request or cannot allocate request data");
    }
    curl_easy_reset(c->easy);
    CURLcode rc = configure(c->easy, &t);
    if (!rc) {
        t.token = shen_release(vm);
        rc = curl_easy_perform(c->easy);
        /* A failed callback keeps a pending Shen exception until return. */
        if (!t.locked) shen_acquire(vm, t.token);
    }
    if (!rc && t.streaming && !t.started && !stream_event(&t, true, NULL, 0)) rc = CURLE_WRITE_ERROR;
    shen_value out = t.callback_error ? SHEN_ERROR : result(vm, &t, rc, c->easy);
    /* Reset callbacks and borrowed C pointers before disposing of their storage. Connections survive. */
    curl_easy_reset(c->easy);
    clear_transfer(&t);
    c->busy = false;
    shen_unroot(vm, 1);
    return out;
}

EXPORT shen_value shen_curl_request(shen_vm *vm, shen_value *args)
{
    return request(vm, args, SHEN_NIL);
}

EXPORT shen_value shen_curl_stream(shen_vm *vm, shen_value *args)
{
    if (shen_vector_length(vm, args[1]) != 5 || !shen_is_procedure(vm, args[2]))
        return shen_raise(vm, "curl: invalid streaming request");
    /* prepare only reads these values, before any allocating Shen call. */
    shen_value input[6] = {args[0]};
    for (int i = 0; i < 5; i++) input[i + 1] = shen_vector_ref(vm, args[1], i);
    return request(vm, input, args[2]);
}
