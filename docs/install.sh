#!/bin/bash
# TUIDock 설치·업데이트 (macOS)
#   curl -fsSL https://zidell.github.io/tuidock/install.sh | bash
# 최신 릴리스의 TUIDock.app을 /Applications(쓸 수 없으면 ~/Applications)에 넣고, tuidock 명령을 ~/.local/bin에 링크한다.
# 다시 실행하면 업데이트된다. 시험용 환경변수: ZIP_URL, APP_DIR, BIN_DIR.
set -euo pipefail

REPO="zidell/tuidock"
ZIP_URL="${ZIP_URL:-https://github.com/$REPO/releases/latest/download/TUIDock-macos.zip}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf 'tuidock: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "macOS에서만 설치할 수 있습니다 / macOS only"
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || die "macOS 14 이상이 필요합니다 / requires macOS 14+"

APP_DIR="${APP_DIR:-/Applications}"
if [ ! -w "$APP_DIR" ]; then
  APP_DIR="$HOME/Applications"
  mkdir -p "$APP_DIR"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "내려받는 중 / Downloading…"
curl -fsSL "$ZIP_URL" -o "$tmp/TUIDock.zip" || die "내려받기 실패 / download failed: $ZIP_URL"
ditto -x -k "$tmp/TUIDock.zip" "$tmp" || die "압축 풀기 실패 / extract failed"
[ -d "$tmp/TUIDock.app" ] || die "TUIDock.app이 들어 있지 않습니다 / TUIDock.app not found in archive"

rm -rf "${APP_DIR:?}/TUIDock.app"
mv "$tmp/TUIDock.app" "$APP_DIR/"
mkdir -p "$BIN_DIR"
ln -sf "$APP_DIR/TUIDock.app/Contents/Resources/tuidock" "$BIN_DIR/tuidock"

say "설치 완료 / Installed: $APP_DIR/TUIDock.app, $BIN_DIR/tuidock"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) cat <<MSG

$BIN_DIR 이 PATH에 없습니다. ~/.zshrc에 추가하세요 / Add it to your PATH in ~/.zshrc:
  export PATH="$BIN_DIR:\$PATH"
MSG
  ;;
esac
cat <<'MSG'

TUIDock 앱에 터미널 프로그램을 끌어다 놓거나, 터미널에서:  tuidock htop 😁
Drop a terminal program onto the TUIDock app, or from the terminal:  tuidock htop 😁
MSG
