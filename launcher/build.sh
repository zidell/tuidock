#!/bin/bash
# 실행기 빌드: build.sh <출력 파일> [--universal]. Swift 네 파일 + C(libvterm·pty). Xcode 커맨드라인 도구만 있으면 된다.
# tuidock make(빌드해 둔 실행기가 없을 때)와 scripts/build-app.sh가 부른다.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$1"
archs=("")
[ "${2:-}" = --universal ] && archs=(arm64 x86_64)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
bins=()
for a in "${archs[@]}"; do
  cflags=(-O2 -std=c99 -I"$HERE/libvterm/include") swiftflags=(-O)
  if [ -n "$a" ]; then
    cflags+=(-arch "$a" -mmacosx-version-min=14.0)
    swiftflags+=(-target "$a-apple-macos14")
  fi
  objs=()
  for c in "$HERE"/libvterm/src/*.c "$HERE/pty.c"; do
    o="$tmp/${a:-native}-$(basename "$c" .c).o"
    clang "${cflags[@]}" -c "$c" -o "$o"
    objs+=("$o")
  done
  bin="$tmp/launcher-${a:-native}"
  swiftc "${swiftflags[@]}" -parse-as-library -import-objc-header "$HERE/bridge.h" -o "$bin" "$HERE/launcher.swift" "$HERE/terminal.swift" "$HERE/config.swift" "$HERE/settings.swift" "${objs[@]}"
  bins+=("$bin")
done
if [ ${#bins[@]} -gt 1 ]; then
  lipo -create -output "$out" "${bins[@]}"
else
  cp "${bins[0]}" "$out"
fi
