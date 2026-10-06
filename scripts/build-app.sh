#!/bin/bash
# GUI 생성기 TUIDock.app을 dist/에 만든다. --install이면 /Applications에 넣고 ~/.local/bin/tuidock 명령을 앱 안 tuidock에 링크한다.
# 실행기·아이콘 도구를 빌드해 Resources에 넣어 두므로, 받은 사람은 Xcode 없이 앱을 만든다.
# UNIVERSAL=1이면 Apple Silicon + Intel(배포용).
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/TUIDock.app"
VERSION="${VERSION:-0.1.0}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/launcher" "$APP/Contents/Resources/icon"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# build 출력 소스...: 유니버설이면 두 아키텍처로 빌드해 lipo
build() {
  local out="$1"; shift
  if [ "${UNIVERSAL:-}" = 1 ]; then
    swiftc -O -target arm64-apple-macos14 -o "$tmp/a" "$@"
    swiftc -O -target x86_64-apple-macos14 -o "$tmp/x" "$@"
    lipo -create -output "$out" "$tmp/a" "$tmp/x"
  else
    swiftc -O -o "$out" "$@"
  fi
}
build "$APP/Contents/MacOS/TUIDock" -parse-as-library app/TUIDockApp.swift icon/IconRender.swift
bash launcher/build.sh "$APP/Contents/Resources/launcher/launcher" $([ "${UNIVERSAL:-}" = 1 ] && echo --universal)
build "$APP/Contents/Resources/icon/icon" icon/IconRender.swift icon/main.swift
cp tuidock "$APP/Contents/Resources/tuidock"
cp -R launcher/fonts "$APP/Contents/Resources/launcher/fonts" # 자체 터미널 기본 글꼴 D2Coding(OFL.txt 포함)

# TUIDock 자신의 아이콘: app/AppIcon.png(scripts/make-icon.swift로 그림)
cp app/AppIcon.png "$tmp/icon.png"
mkdir "$tmp/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$tmp/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

plist="$APP/Contents/Info.plist"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict/></plist>\n' > "$plist"
put() { plutil -insert "$1" -string "$2" "$plist"; }
put CFBundleName TUIDock
put CFBundleDisplayName TUIDock
put CFBundleIdentifier com.zidell.tuidock
put CFBundleExecutable TUIDock
put CFBundleIconFile AppIcon
put CFBundlePackageType APPL
put CFBundleShortVersionString "${VERSION#v}"
put CFBundleVersion 1
put LSMinimumSystemVersion 14.0
codesign --force --deep -s - "$APP" 2>/dev/null
echo "만듦: $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/TUIDock.app && cp -R "$APP" /Applications/
  echo "설치: /Applications/TUIDock.app"
  # 명령도 앱 안 것을 쓴다(빌드해 둔 실행기로 바로 만들어 Xcode가 필요 없다)
  mkdir -p ~/.local/bin
  ln -sf /Applications/TUIDock.app/Contents/Resources/tuidock ~/.local/bin/tuidock
  echo "명령: ~/.local/bin/tuidock"
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "~/.local/bin이 PATH에 없다. 셸 설정에 추가한다" ;; esac
fi
