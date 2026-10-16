#!/bin/zsh
set -eu
cd "${0:A:h:h}"
VERSION=v0.2.1
ROOT="$PWD/dist/huinote-stage"
MEETING_BUILD_CONFIGURATION=release MEETING_APP_OUTPUT="$ROOT/HuiNote · 会记.app" ./scripts/build.sh
cp docs/INSTALL.md "$ROOT/INSTALL.md"
cp docs/CONFIGURATION.md "$ROOT/CONFIGURATION.md"
# Only the signed app and generic installation documents enter the archive.
OUT="$PWD/dist/HuiNote-$VERSION-arm64.zip"
(cd "$ROOT" && /usr/bin/zip -q -r "$OUT" "HuiNote · 会记.app" INSTALL.md CONFIGURATION.md)
(cd dist && shasum -a 256 "HuiNote-$VERSION-arm64.zip" > SHA256SUMS.txt)
print -r -- "$OUT"
