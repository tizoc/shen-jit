# xxHash provenance

- Upstream: https://github.com/Cyan4973/xxHash
- Version: 0.8.3 (`xxhash.h`, SHA-256 prefix `17973c0dc49d9854`)
- License: BSD 2-Clause (`LICENSE`)
- Copied on 2026-11-01, unmodified.

Shen/JIT includes it header-only (`XXH_INLINE_ALL`) in `src/runtime/objects.c`
and uses `XXH3_64bits` for string and symbol-name hashes, and `XXH64` for `shen-jit.xxh64`.
