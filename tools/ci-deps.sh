#!/bin/sh
# What building from a checkout, and CI, need from outside the repository, checked against these
# hashes. Usage:
#
#   sh tools/ci-deps.sh kernel DIR            the kernel's release, with klambda/ and tests/, in DIR
#   sh tools/ci-deps.sh shen-jit DIR          the release of Shen/JIT that builds this one, for this
#                                             platform, in DIR
#   sh tools/ci-deps.sh shen-scheme DIR       Shen/Scheme's release for this platform, in DIR: it can
#                                             build Shen/JIT too, and make bench compares against it
#   sh tools/ci-deps.sh shen-scheme-src DIR   its sources, whose benchmarks make bench runs
#
# Each prints what to use: DIR, or the executable. make deps runs the first two.
set -e
KERNEL=43.6
KERNEL_SHA256=61d1795755a57da252ba8108cdfccc680f95a04bfd395a54f533ab6724647ef5
BOOTSTRAP=0.1
BOOTSTRAP_URL=https://github.com/tizoc/shen-jit/releases/download/v$BOOTSTRAP/shen-jit-$BOOTSTRAP
SCHEME=0.54
SCHEME_URL=https://github.com/tizoc/shen-scheme/releases/download/v$SCHEME/shen-scheme-v$SCHEME

fetch() { # url, hash, directory
    mkdir -p "$3"
    name=${1##*/}
    curl -fsSL --retry 3 -o "$3/$name" "$1"
    echo "$2  $3/$name" | { command -v sha256sum > /dev/null && sha256sum -c - || shasum -a 256 -c -; } > /dev/null
    case "$name" in
    *.zip)
        unzip -q -o -d "$3" "$3/$name"
        for top in "$3"/shen-*/; do
            cp -R "$top". "$3"/
            rm -rf "$top"
        done
        ;;
    *)
        tar -C "$3" --strip-components=1 -xzf "$3/$name"
        ;;
    esac
    rm "$3/$name"
}

case "$1" in
kernel)
    fetch "https://github.com/Shen-Language/shen-sources/releases/download/shen-$KERNEL/ShenOSKernel-$KERNEL.tar.gz" \
        "$KERNEL_SHA256" "$2"
    echo "$2"
    ;;
shen-jit)
    # On Linux the static builds, which run on any system, as a host needs no libraries.
    case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)
        fetch "$BOOTSTRAP_URL-linux-x86_64-static.tar.gz" 4e569fe92e24a722afe406807e7ad3271fd2d6cc4b7744c981536f732e2953bd "$2" ;;
    Linux-aarch64)
        fetch "$BOOTSTRAP_URL-linux-arm64-static.tar.gz" 2aad3cce35a39be0d9f8859122a4ad1582564ba6afad597054b2cfb2011f0f9d "$2" ;;
    Darwin-arm64)
        fetch "$BOOTSTRAP_URL-macos-arm64.tar.gz" 4c21b9e3b100dec8411ca5a1685fd7acb6afc79d8c304b930af6bde4c5a7fb91 "$2" ;;
    MINGW*-x86_64 | MSYS*-x86_64)
        fetch "$BOOTSTRAP_URL-windows-x86_64.zip" 8bd2ddc99791253b134d92d4a03e7c366264aafb5917743590e8382e505ec7aa "$2"
        echo "$2/shen-jit.exe"
        exit 0 ;;
    *)
        echo "Shen/JIT $BOOTSTRAP has no release for $(uname -s) $(uname -m): build from a source tarball, or set BOOTSTRAP" >&2
        exit 1 ;;
    esac
    echo "$2/shen-jit"
    ;;
shen-scheme)
    case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)
        fetch "$SCHEME_URL-linux-x64-bin.tar.gz" 4a3805e24ddf7ea1edc8eb78a12ecf80c3ecd7133b9ab98a39e5c015f7f657ef "$2" ;;
    Linux-aarch64)
        fetch "$SCHEME_URL-linux-arm64-bin.tar.gz" 9b87c8fd5a9997e6221893b88f657fe5438fcfde089ec647d469dd5a472afa7d "$2" ;;
    Darwin-arm64)
        fetch "$SCHEME_URL-macOS-arm64-bin.tar.gz" 65cc2d42cbcbf7f8149df1a5bfb9614ca3f278bac70bb475f30252bfee22ab19 "$2" ;;
    MINGW*-x86_64 | MSYS*-x86_64)
        fetch "$SCHEME_URL-windows-x64-bin.zip" eb13a40592b620e766763ec5c10af0b9b8558a92feb59af99569576932591fc2 "$2" ;;
    *)
        echo "Shen/Scheme $SCHEME has no release for $(uname -s) $(uname -m)" >&2
        exit 1 ;;
    esac
    echo "$2/bin/shen-scheme"
    ;;
shen-scheme-src)
    fetch "$SCHEME_URL-src.tar.gz" 1de4a013690e204c5f3d61abd52f8adf1ecb2d2ebfa6bfdda184b312fd9bd007 "$2"
    echo "$2"
    ;;
*)
    echo "usage: ci-deps.sh kernel|shen-jit|shen-scheme|shen-scheme-src DIR" >&2
    exit 2
    ;;
esac
