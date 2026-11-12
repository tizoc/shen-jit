#!/bin/sh
# Builds shen-jit from a release tarball and runs its suites on Linux, in
# Docker containers:
#
#   sh tests/linux.sh [arm64] [amd64]     (both by default; make test-linux)
#
# make dist writes the tarball: the tracked files, generated/, the inputs that
# take a Shen to make, and guide/, rendered with pandoc, which it needs here.
# Each container builds it with a C compiler alone (BOOTSTRAP=false makes any
# attempt to run a Shen fail), checks generated.sha256 and runs the suites.
# Optional libcurl tests install development headers, Python and openssl. The kernel checkout
# (KERNEL_DIR) is mounted read-only for its tests; check-lowerer, which runs
# under a Shen, stays out here. The images are pinned by digest: gcc 15 on arm64,
# gcc 14 on amd64, which Docker on Apple silicon runs through Rosetta.
set -e
cd "$(dirname "$0")/.."
KERNEL_DIR=$(cd "${KERNEL_DIR:-.deps/kernel}" && pwd)
IMAGE_arm64=gcc@sha256:fb2568a8cc0609134396aeb1eae1f3a91c8ceec54aaee67c798d9602593abd66
IMAGE_amd64=gcc@sha256:3ae7320d7dd41f446a48930e1edf4e7a41c7be5ae43a5ddbf017c53fe6495738
SUITES="check-generated test test-jit test-ops test-kl test-kernel test-stlib test-thorn test-native test-buffer test-json test-io test-fs test-process test-isolates test-tree-sitter test-http test-datalog test-ffi test-curl test-namespaces test-structs test-overrides test-differential test-kernel-stress test-kl-stress test-lib-stress test-san"

make dist < /dev/null > /dev/null
tarball=$(ls -t build/shen-jit-*.tar.gz | head -1)
status=0
for arch in ${@:-arm64 amd64}; do
    eval image=\$IMAGE_$arch
    work=$(mktemp -d)
    tar -C "$work" -xzf "$tarball"
    src=$(ls -d "$work"/shen-jit-*)
    echo "== linux/$arch, $(basename "$tarball")"
    if docker run --rm --platform "linux/$arch" -v "$src:/src" -v "$KERNEL_DIR:/kernel:ro" -w /src "$image" \
        sh -c 'apt-get update && apt-get install -y libcurl4-openssl-dev pkg-config python3 openssl &&
               sh tools/tree-sitter-deps.sh .deps &&
               exec make BOOTSTRAP=false KERNEL_DIR=/kernel "$@"' sh $SUITES < /dev/null > "$work.log" 2>&1; then
        grep -E 'passed|failed|cases|match' "$work.log" | grep -v '^\s' | tr '\n' ' '
        echo
        echo "linux/$arch: all suites passed"
    else
        tail -30 "$work.log"
        echo "linux/$arch: FAILED (log: $work.log)"
        status=1
    fi
    rm -rf "$work"
done
exit $status
