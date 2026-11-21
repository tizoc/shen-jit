/* SHA-1 and SHA-256 (FIPS 180-4), zlib, CRC32 and index stat data for the Git library. */
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE 1
#include "shen.h"
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <zlib.h>

#define EXPORT __attribute__((visibility("default")))

static const unsigned char *slice(shen_vm *vm, shen_value *args, size_t *length)
{
    size_t total;
    unsigned char *bytes = shen_bytes_data(vm, args[0], &total);
    if (!bytes || !shen_is_fixnum(args[1]) || !shen_is_fixnum(args[2])) return NULL;
    int64_t start = shen_fixnum(args[1]), count = shen_fixnum(args[2]);
    if (start < 0 || count < 0 || (uint64_t)start > total || (uint64_t)count > total - start)
        return NULL;
    *length = (size_t)count;
    return bytes + start;
}

static uint32_t get32(const unsigned char *at)
{
    return (uint32_t)at[0] << 24 | (uint32_t)at[1] << 16 | (uint32_t)at[2] << 8 | at[3];
}

static void put32(unsigned char *at, uint64_t value)
{
    at[0] = (unsigned char)(value >> 24);
    at[1] = (unsigned char)(value >> 16);
    at[2] = (unsigned char)(value >> 8);
    at[3] = (unsigned char)value;
}

static uint32_t rol(uint32_t x, int n) { return x << n | x >> (32 - n); }
static uint32_t ror(uint32_t x, int n) { return x >> n | x << (32 - n); }

static void sha1_block(uint32_t *h, const unsigned char *p)
{
    uint32_t w[80], a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
    for (int i = 0; i < 16; i++) w[i] = get32(p + 4 * i);
    for (int i = 16; i < 80; i++) w[i] = rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    for (int i = 0; i < 80; i++) {
        uint32_t f = i < 20 ? ((b & c) | (~b & d)) + 0x5a827999
                   : i < 40 ? (b ^ c ^ d) + 0x6ed9eba1
                   : i < 60 ? ((b & c) | (b & d) | (c & d)) + 0x8f1bbcdc
                   : (b ^ c ^ d) + 0xca62c1d6;
        uint32_t t = rol(a, 5) + f + e + w[i];
        e = d, d = c, c = rol(b, 30), b = a, a = t;
    }
    h[0] += a, h[1] += b, h[2] += c, h[3] += d, h[4] += e;
}

static const uint32_t K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

static void sha256_block(uint32_t *h, const unsigned char *p)
{
    uint32_t w[64], s[8];
    for (int i = 0; i < 16; i++) w[i] = get32(p + 4 * i);
    for (int i = 16; i < 64; i++)
        w[i] = w[i - 16] + (ror(w[i - 15], 7) ^ ror(w[i - 15], 18) ^ (w[i - 15] >> 3)) + w[i - 7] +
               (ror(w[i - 2], 17) ^ ror(w[i - 2], 19) ^ (w[i - 2] >> 10));
    memcpy(s, h, sizeof s);
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = s[7] + (ror(s[4], 6) ^ ror(s[4], 11) ^ ror(s[4], 25)) +
                      ((s[4] & s[5]) ^ (~s[4] & s[6])) + K256[i] + w[i];
        uint32_t t2 = (ror(s[0], 2) ^ ror(s[0], 13) ^ ror(s[0], 22)) +
                      ((s[0] & s[1]) ^ (s[0] & s[2]) ^ (s[1] & s[2]));
        memmove(s + 1, s, 7 * sizeof *s);
        s[4] += t1;
        s[0] = t1 + t2;
    }
    for (int i = 0; i < 8; i++) h[i] += s[i];
}

/* The message's whole blocks, then the padded tail: 0x80, zeros and the length in bits. */
static void digest(int width, const unsigned char *data, size_t n, unsigned char *out)
{
    static const uint32_t start1[5] = {0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0};
    static const uint32_t start256[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                         0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    void (*block)(uint32_t *, const unsigned char *) = width == 20 ? sha1_block : sha256_block;
    uint32_t h[8];
    memcpy(h, width == 20 ? start1 : start256, width == 20 ? sizeof start1 : sizeof start256);
    size_t whole = n - n % 64, rest = n - whole, end = rest < 56 ? 64 : 128;
    for (size_t i = 0; i < whole; i += 64) block(h, data + i);
    unsigned char tail[128] = {0};
    if (rest) memcpy(tail, data + whole, rest);
    tail[rest] = 0x80;
    put32(tail + end - 8, (uint64_t)n >> 29);
    put32(tail + end - 4, (uint64_t)n << 3);
    for (size_t i = 0; i < end; i += 64) block(h, tail + i);
    for (int i = 0; i < width / 4; i++) put32(out + 4 * i, h[i]);
}

EXPORT shen_value shen_git_digest(shen_vm *vm, shen_value *args)
{
    unsigned char out[32];
    size_t length;
    const unsigned char *bytes = slice(vm, args, &length);
    int64_t width = shen_is_fixnum(args[3]) ? shen_fixnum(args[3]) : 0;
    if (!bytes || (width != 20 && width != 32)) return shen_raise(vm, "git: cannot hash bytes");
    digest((int)width, bytes, length, out);
    return shen_make_bytes(vm, out, (size_t)width);
}

EXPORT shen_value shen_git_deflate(shen_vm *vm, shen_value *args)
{
    size_t length;
    const unsigned char *bytes = slice(vm, args, &length);
    if (!bytes || length > UINT_MAX) return shen_raise(vm, "git: invalid compression input");
    uLongf capacity = compressBound((uLong)length);
    unsigned char *out = malloc(capacity);
    if (!out) return shen_raise(vm, "git: cannot allocate compression output");
    int code = compress(out, &capacity, bytes, (uLong)length);
    shen_value result = code == Z_OK ? shen_make_bytes(vm, out, capacity)
                                   : shen_raise(vm, "git: zlib compression failed");
    free(out);
    return result;
}
EXPORT shen_value shen_git_inflate(shen_vm *vm, shen_value *args)
{
    size_t length;
    const unsigned char *bytes = slice(vm, args, &length);
    int64_t limit = shen_is_fixnum(args[3]) ? shen_fixnum(args[3]) : -1;
    if (!bytes || length > UINT_MAX || limit < 0 || limit >= UINT_MAX)
        return shen_raise(vm, "git: invalid decompression input");

    /* The extra byte lets a stream at its exact limit finish and verifies the limit. */
    size_t maximum = (size_t)limit + 1;
    size_t capacity = maximum < 4096 ? maximum : 4096;
    unsigned char *out = malloc(capacity);
    if (!out) return shen_raise(vm, "git: cannot allocate decompression output");
    z_stream stream = {0};
    if (inflateInit(&stream) != Z_OK) {
        free(out);
        return shen_raise(vm, "git: cannot initialize zlib");
    }
    stream.next_in = (Bytef *)bytes;
    stream.avail_in = (uInt)length;
    int code;
    do {
        stream.next_out = out + stream.total_out;
        stream.avail_out = (uInt)(capacity - stream.total_out);
        code = inflate(&stream, Z_NO_FLUSH);
        if (code != Z_OK || stream.avail_out) break;
        if (capacity == maximum) break;
        size_t next = capacity < maximum - capacity ? capacity * 2 : maximum;
        unsigned char *grown = realloc(out, next);
        if (!grown) { code = Z_MEM_ERROR; break; }
        out = grown;
        capacity = next;
    } while (1);
    size_t written = stream.total_out, consumed = stream.total_in;
    inflateEnd(&stream);
    if (code != Z_STREAM_END || written > (size_t)limit) {
        free(out);
        return shen_raise(vm, "git: invalid, incomplete, or oversized zlib stream");
    }
    shen_value value = shen_make_bytes(vm, out, written);
    free(out);
    if (value == SHEN_ERROR) return value;
    return shen_cons(vm, value, shen_make_fixnum((int64_t)consumed));
}

/* lstat as Git's index records it: ctime, mtime, dev, ino, mode, uid, gid and size, each
   truncated to 32 bits, big-endian, with the mode as Git's. A missing path gives []. */
EXPORT shen_value shen_git_stat(shen_vm *vm, shen_value *args)
{
    char path[4096];
    int64_t length = shen_string_copy(vm, args[0], path, sizeof path);
    if (length <= 0 || (uint64_t)length >= sizeof path || memchr(path, 0, (size_t)length))
        return shen_raise(vm, "git: invalid path");
    struct stat st;
    if (lstat(path, &st) < 0) {
        if (errno == ENOENT || errno == ENOTDIR) return SHEN_NIL;
        char message[4200];
        snprintf(message, sizeof message, "git: %s: %s", path, strerror(errno));
        return shen_raise(vm, message);
    }
#ifdef __APPLE__
    struct timespec c = st.st_ctimespec, m = st.st_mtimespec;
#else
    struct timespec c = st.st_ctim, m = st.st_mtim;
#endif
    uint32_t mode = S_ISLNK(st.st_mode) ? 0120000 : S_ISDIR(st.st_mode) ? 0040000
                  : !S_ISREG(st.st_mode) ? 0 : (st.st_mode & S_IXUSR) ? 0100755 : 0100644;
    uint64_t fields[10] = {(uint64_t)c.tv_sec, (uint64_t)c.tv_nsec, (uint64_t)m.tv_sec,
                           (uint64_t)m.tv_nsec, st.st_dev, st.st_ino, mode, st.st_uid,
                           st.st_gid, (uint64_t)st.st_size};
    unsigned char out[40];
    for (int i = 0; i < 10; i++) put32(out + 4 * i, fields[i]);
    return shen_make_bytes(vm, out, sizeof out);
}

EXPORT shen_value shen_git_crc32(shen_vm *vm, shen_value *args)
{
    size_t length;
    const unsigned char *bytes = slice(vm, args, &length);
    if (!bytes || length > UINT_MAX) return shen_raise(vm, "git: invalid CRC32 input");
    return shen_make_fixnum((int64_t)crc32(0, bytes, (uInt)length));
}
