#!/bin/zsh
set -eu
cd "${0:A:h:h}"
VERSION=v0.4.1-beta.1
ROOT="$PWD/dist/beta-stage"
MEETING_BUILD_CONFIGURATION=release MEETING_APP_OUTPUT="$ROOT/会议助手.app" ./scripts/build.sh
cp docs/INSTALL.md "$ROOT/INSTALL.md"
cp docs/CONFIGURATION.md "$ROOT/CONFIGURATION.md"
# Only the signed app and generic installation documents enter the archive.
OUT="$PWD/dist/MeetingAssistant-$VERSION-arm64.zip"
(cd "$ROOT" && /usr/bin/zip -q -r "$OUT" 会议助手.app INSTALL.md CONFIGURATION.md)
(cd dist && shasum -a 256 "MeetingAssistant-$VERSION-arm64.zip" > SHA256SUMS.txt)
print -r -- "$OUT"
