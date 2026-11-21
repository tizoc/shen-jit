#!/bin/sh
# Builds the adapters and the client in a temporary directory, then checks them with Git as the
# oracle. Without what that needs, it says what it skipped and passes.
set -eu
SHEN=$1
skip() {
    echo "shen-git: skipped ($1)"
    exit 0
}
if [ "${OS:-}" = Windows_NT ]; then skip "the git library is for POSIX systems"; fi
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
"$SHEN" eval -m ffi \
  -e '(shen-jit.library git-probe ["libc.so.6" "libSystem.dylib"])' \
  -e '(define-foreign git-probe.abs git-probe "abs" (int32) --> int32)' \
  -e '(output "git shared: ~A~%"
        (trap-error (git-probe.abs -1)
          (/. E (if (= (error-to-string E) "foreign: this static build cannot load libraries")
                    static
                    (simple-error (error-to-string E))))))' > "$dir/probe.out" 2>&1
if grep -q '^git shared: static' "$dir/probe.out"; then skip "a static build cannot load libraries"; fi
grep -q '^git shared: 1' "$dir/probe.out"
compiler=${CC:-cc}
command -v "${compiler%% *}" > /dev/null || skip "no C compiler"
command -v git > /dev/null || skip "no git"
command -v python3 > /dev/null || skip "no python3"
# SHA-256 repositories, which Git is the oracle for, came in Git 2.29.
version=$(git --version | sed -n 's/^git version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
major=${version%% *}
minor=${version#* }
if [ -z "$version" ] || [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 29 ]; }; then
    skip "git $major.$minor is older than 2.29"
fi
python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' || skip "python3 is older than 3.8"
printf '#include <zlib.h>\nint main(void) { return zlibVersion() == 0; }\n' > "$dir/zlib.c"
$compiler $(pkg-config --cflags zlib 2>/dev/null || true) -c "$dir/zlib.c" -o "$dir/zlib.o" 2> /dev/null ||
    skip "no zlib headers"
sh lib/build-fs.sh "$dir/shen-fs.so"
sh lib/git/build-native.sh "$dir/shen-git-native.so"
"$SHEN" build example-apps/shen-git/shen-git.shenmod -o "$dir/shen-git"
python3 example-apps/shen-git/test.py "$dir/shen-git" "$SHEN"
