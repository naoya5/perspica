#!/bin/sh
# Build the Swift package, wrap the executable in Yaku.app, and sign it.
#
# Signing uses a dedicated development keychain rather than the login
# keychain. The login keychain's certificate hangs codesign on an
# authorization prompt that never appears, so it is deliberately not used
# (SPEC 16; the parent thread owns the SPEC wording).
#
#   ./make-app.sh            build and sign build/Yaku.app
#   ./make-app.sh install    also replace ~/Applications/Yaku.app
set -eu
cd "$(dirname "$0")"

APP_NAME=Yaku
BUILD_DIR=build
APP="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"

KEYCHAIN="$HOME/Library/Keychains/yaku-dev.keychain-db"
KEYCHAIN_PASSWORD_FILE="$HOME/Library/Application Support/Yaku/dev-signing/pass"
IDENTITY="Yaku Signing"
SIGN_TIMEOUT=30

swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)

# Rebuild the bundle from scratch, one concrete path at a time.
rm -rf "$CONTENTS"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Helpers"

cp Resources/Info.plist "$CONTENTS/Info.plist"
cp Resources/PLAMO-COMMUNITY-LICENSE-en.txt "$CONTENTS/Resources/PLAMO-COMMUNITY-LICENSE-en.txt"
cp "$BIN_DIR/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"

# The PDF worker's scripts ride along so the app does not depend on the
# checkout. The Python environment itself is installed on first use (SPEC 8.2).
mkdir -p "$CONTENTS/Resources/pdf-worker"
cp ../pdf-worker/translate_pdf.py "$CONTENTS/Resources/pdf-worker/translate_pdf.py"
cp ../pdf-worker/paragraph_translator.py "$CONTENTS/Resources/pdf-worker/paragraph_translator.py"
cp ../pdf-worker/requirements.txt "$CONTENTS/Resources/pdf-worker/requirements.txt"

# llama-server is bundled only when explicitly asked for; during development
# the app falls back to /opt/homebrew/bin/llama-server.
if [ "${YAKU_BUNDLE_LLAMA:-0}" = "1" ] && [ -x /opt/homebrew/bin/llama-server ]; then
    cp /opt/homebrew/bin/llama-server "$CONTENTS/Helpers/llama-server"
    echo "bundled llama-server"
fi

if [ ! -f "$KEYCHAIN_PASSWORD_FILE" ]; then
    echo "error: signing password file not found: $KEYCHAIN_PASSWORD_FILE" >&2
    exit 1
fi
security unlock-keychain -p "$(cat "$KEYCHAIN_PASSWORD_FILE")" "$KEYCHAIN"

# A hang here means the key is waiting on an authorization prompt; fail
# instead of blocking the build forever.
if ! timeout "$SIGN_TIMEOUT" codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$APP"; then
    echo "error: codesign failed or timed out after ${SIGN_TIMEOUT}s" >&2
    exit 1
fi

codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
echo "built: $(pwd)/$APP"
codesign -dvv "$APP" 2>&1 | grep -E '^Authority|^Identifier' | sed 's/^/  /'

if [ "${1:-}" = "install" ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/$APP_NAME.app"
    cp -R "$APP" "$HOME/Applications/$APP_NAME.app"
    echo "installed: $HOME/Applications/$APP_NAME.app"
fi
