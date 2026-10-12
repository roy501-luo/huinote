#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
# Public certificate fingerprint only. Never put a private key or password here.
IDENTITY="${MEETING_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" && -f signing/identity.txt ]]; then
  IDENTITY="$(tr -d '[:space:]' < signing/identity.txt)"
fi
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  if [[ "${ALLOW_ADHOC_SIGNING:-0}" != "1" ]]; then
    print -u2 '缺少固定签名身份，已停止构建，避免破坏录音授权。请配置 signing/identity.txt 或 MEETING_SIGN_IDENTITY。'
    exit 1
  fi
  IDENTITY="-"
fi
# This credential helper is intentionally rebuilt only when its own source/identity changes.
# Rebuilding the UI must not change its Keychain partition (cdhash).
HELPER_DIR="$PWD/signing/keychain-helper"
mkdir -p "$HELPER_DIR"
HELPER_STAMP="$(shasum -a 256 KeychainHelper/main.swift | cut -d ' ' -f1):$IDENTITY"
if [[ ! -f "$HELPER_DIR/stamp" || "$(cat "$HELPER_DIR/stamp")" != "$HELPER_STAMP" || ! -x "$HELPER_DIR/MeetingAssistantKeychain" ]]; then
  # Bind a fresh helper to this machine's certificate; keep the established cache unchanged.
  HELPER_SOURCE="KeychainHelper/main.swift"
  if [[ "$IDENTITY" != "-" ]]; then
    if [[ ! "$IDENTITY" =~ '^[[:xdigit:]]{40}$' ]]; then
      print -u2 'MEETING_SIGN_IDENTITY 必须是证书的 40 位 SHA-1 指纹。'
      exit 1
    fi
    HELPER_SOURCE="$HELPER_DIR/main.generated.swift"
    sed "s/b26476f919894124381dab0746284a36d8282de3/${(L)IDENTITY}/g" KeychainHelper/main.swift > "$HELPER_SOURCE"
  fi
  swiftc -O -module-cache-path "$PWD/.build/ModuleCache" "$HELPER_SOURCE" -o "$HELPER_DIR/MeetingAssistantKeychain"
  codesign --force --options runtime --identifier local.MeetingAssistant.keychain --sign "$IDENTITY" "$HELPER_DIR/MeetingAssistantKeychain"
  codesign --verify --strict "$HELPER_DIR/MeetingAssistantKeychain"
  print -r -- "$HELPER_STAMP" > "$HELPER_DIR/stamp"
fi
codesign --verify --strict "$HELPER_DIR/MeetingAssistantKeychain"
swift build --disable-sandbox -c debug
APP="${MEETING_APP_OUTPUT:-$PWD/dist/会议助手.app}"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/meeting-signed-build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
STAGED="$STAGING/会议助手.app"
mkdir -p "$STAGED/Contents/MacOS" "$STAGED/Contents/Resources"
cp .build/debug/MeetingAssistant "$STAGED/Contents/MacOS/MeetingAssistant"
cp "$HELPER_DIR/MeetingAssistantKeychain" "$STAGED/Contents/MacOS/MeetingAssistantKeychain"
cp Resources/plaud_download.py "$STAGED/Contents/Resources/plaud_download.py"
cp Resources/Info.plist "$STAGED/Contents/Info.plist"
codesign --force --sign "$IDENTITY" "$STAGED"
codesign --verify --deep --strict "$STAGED"
# Verify before touching the previously working app.
mkdir -p "${APP:h}"
ditto "$STAGED" "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
