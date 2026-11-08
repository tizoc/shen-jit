#!/bin/sh
# Optional, pinned test/example dependencies. Loading the binding never fetches or compiles code.
set -eu
root=${1:-.deps}
fetch() {
    name=$1 version=$2 checksum=$3
    target="$root/$name"
    if [ -f "$target/.shen-dependency" ] && [ "$(cat "$target/.shen-dependency")" = "$checksum" ]; then
        return
    fi
    mkdir -p "$root"
    temp=$(mktemp -d "$root/.tree-sitter.XXXXXX")
    trap 'rm -rf "$temp"' EXIT HUP INT TERM
    curl -fsSL --retry 3 "https://codeload.github.com/tree-sitter/$name/tar.gz/refs/tags/v$version" -o "$temp/source.tar.gz"
    echo "$checksum  $temp/source.tar.gz" | {
        if command -v sha256sum > /dev/null; then sha256sum -c -; else shasum -a 256 -c -; fi
    } > /dev/null
    mkdir "$temp/source"
    tar -C "$temp/source" --strip-components=1 -xzf "$temp/source.tar.gz"
    echo "$checksum" > "$temp/source/.shen-dependency"
    rm -rf "$target"
    mv "$temp/source" "$target"
    rm -rf "$temp"
    trap - EXIT HUP INT TERM
}
fetch tree-sitter 0.26.13 ece24c3c5e2a76384075e830c7139b59fce8fb01e4ef8436fab08bbe10444c89
fetch tree-sitter-c 0.24.2 2eeb4db31f8fa0865e45488503d13403923bcb485a1bdb637abff8c42dd97364
echo "$root"
