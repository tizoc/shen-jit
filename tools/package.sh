#!/bin/sh
# A release archive of the built executables, the libraries, the guide, the example applications and
# the tests, with every license they carry. Usage:
#
#   sh tools/package.sh PLATFORM    (in a release tarball, after make release stlib)
#
# Writes build/shen-jit-VERSION-PLATFORM.zip on Windows and .tar.gz elsewhere.
set -e
platform=$1
name=shen-jit-$(cat VERSION)-$platform
rm -rf "build/$name"
mkdir "build/$name"
if [ -f build/shen-jit.exe ]; then
    cp build/shen-jit.exe build/shen-jit-stlib.exe "build/$name/"
else
    cp build/shen-jit build/shen-jit-stlib "build/$name/"
fi
# What programs load, what C written for Shen includes, the rendered guide, which make dist put
# in the tarball, and the example applications and tests, to run or read beside them.
cp -R lib include guide example-apps tests "build/$name/"
mkdir "build/$name/tools"
cp tools/curl-fetch.shen "build/$name/tools/"
cp tools/fs-copy.shen "build/$name/tools/"
cp tools/process-filter.shen "build/$name/tools/"
cp LICENSE "build/$name/LICENSE.txt"
cp LICENSE-shen-kernel.txt "build/$name/LICENSE-shen-kernel.txt"
cp vendor/sljit/LICENSE "build/$name/LICENSE-sljit.txt"
cp vendor/xxhash/LICENSE "build/$name/LICENSE-xxhash.txt"
cd build
if [ -f shen-jit.exe ]; then
    zip -q -r "$name.zip" "$name"
    echo "build/$name.zip"
else
    COPYFILE_DISABLE=1 tar -czf "$name.tar.gz" "$name"
    echo "build/$name.tar.gz"
fi
rm -rf "$name"
