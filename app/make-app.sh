#!/bin/sh
# Build the Swift package, wrap the executable in Perspica.app, and sign it.
#
# Signing uses the self-signed "Yaku Signing" identity from a dedicated
# keychain (tools/make-signing-identity.sh creates both). A key in the login
# keychain hangs codesign on an authorization prompt that never appears. When
# the identity is missing the app is signed ad hoc, which works but makes macOS
# ask for its permissions again after every rebuild.
#
#   ./make-app.sh            build and sign build/Perspica.app
#   ./make-app.sh install    also replace ~/Applications/Perspica.app
set -eu
cd "$(dirname "$0")"

# The app was called Yaku until 2026-11-09. Only the names people see moved to
# Perspica: the bundle, its icon and its display name. The Swift product (and
# so CFBundleExecutable), the bundle identifier, the data and log folders and
# the signing identity keep the name Yaku, so permissions and data carry over.
APP_NAME=Perspica
EXECUTABLE=Yaku
LEGACY_APP_NAME=Yaku
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
cp "$BIN_DIR/$EXECUTABLE" "$CONTENTS/MacOS/$EXECUTABLE"

# The app icon. `Resources/Perspica.icon` is an Icon Composer document; actool
# compiles it to Assets.car (the Liquid Glass icon) and Perspica.icns (for anything
# that still asks for a plain .icns). The partial plist it writes holds
# CFBundleIconFile / CFBundleIconName, which are merged into Info.plist here
# rather than kept in the source plist, so the two cannot drift apart.
if [ -d Resources/$APP_NAME.icon ]; then
    # actool resolves relative paths against its own working directory, not
    # this script's, so both paths are made absolute first.
    xcrun actool "$(pwd)/Resources/$APP_NAME.icon" \
        --compile "$(pwd)/$CONTENTS/Resources" \
        --platform macosx \
        --minimum-deployment-target 26.0 \
        --app-icon "$APP_NAME" \
        --output-partial-info-plist "$(pwd)/$CONTENTS/Resources/icon-info.plist" \
        --output-format human-readable-text >/dev/null
    /usr/libexec/PlistBuddy -c "Merge $CONTENTS/Resources/icon-info.plist" "$CONTENTS/Info.plist"
    rm "$CONTENTS/Resources/icon-info.plist"
    echo "icon: $(ls "$CONTENTS/Resources" | tr '\n' ' ')"
fi

# The PDF worker's scripts ride along so the app does not depend on the
# checkout. The Python environment itself is installed on first use (SPEC 8.2).
# Every `.py` the worker imports has to be here: the app runs the bundle's copy
# (`PDFWorkerPaths.scriptsDirectory`), so a script left out is a script the user
# does not get.
mkdir -p "$CONTENTS/Resources/pdf-worker"
for script in ../pdf-worker/*.py; do
    cp "$script" "$CONTENTS/Resources/pdf-worker/$(basename "$script")"
done
cp ../pdf-worker/requirements.txt "$CONTENTS/Resources/pdf-worker/requirements.txt"

# llama-server is bundled only when explicitly asked for; during development
# the app falls back to /opt/homebrew/bin/llama-server.
if [ "${YAKU_BUNDLE_LLAMA:-0}" = "1" ] && [ -x /opt/homebrew/bin/llama-server ]; then
    cp /opt/homebrew/bin/llama-server "$CONTENTS/Helpers/llama-server"
    echo "bundled llama-server"
fi

if [ -f "$KEYCHAIN" ] && [ -f "$KEYCHAIN_PASSWORD_FILE" ]; then
    security unlock-keychain -p "$(cat "$KEYCHAIN_PASSWORD_FILE")" "$KEYCHAIN"
    # A hang here means the key is waiting on an authorization prompt; fail
    # instead of blocking the build forever.
    # `timeout` comes from Homebrew's coreutils; without it codesign runs unguarded.
    guard=""
    command -v timeout >/dev/null 2>&1 && guard="timeout $SIGN_TIMEOUT"
    # The hardened runtime (`--options runtime`) stops DYLD_INSERT_LIBRARIES
    # and unsigned code from being loaded into a process that holds the
    # Accessibility and Screen Recording grants. Resources/Yaku.entitlements
    # is empty on purpose: nothing the app does needs one. `--timestamp=none`
    # keeps a self-signed identity from calling Apple's timestamp server.
    if ! $guard codesign --force --options runtime --timestamp=none \
        --entitlements Resources/Yaku.entitlements \
        --sign "$IDENTITY" --keychain "$KEYCHAIN" "$APP"; then
        echo "error: codesign failed or timed out after ${SIGN_TIMEOUT}s" >&2
        exit 1
    fi
else
    echo "warning: no \"$IDENTITY\" identity ($KEYCHAIN); signing ad hoc." >&2
    echo "  macOS will ask for Accessibility and Screen Recording again after every rebuild." >&2
    echo "  Run tools/make-signing-identity.sh once to keep the grants." >&2
    codesign --force --options runtime --timestamp=none \
        --entitlements Resources/Yaku.entitlements \
        --sign - "$APP"
fi
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
echo "built: $(pwd)/$APP"
codesign -dvv "$APP" 2>&1 | grep -E '^Authority|^Identifier' | sed 's/^/  /'

if [ "${1:-}" = "install" ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/$APP_NAME.app"
    cp -R "$APP" "$HOME/Applications/$APP_NAME.app"
    echo "installed: $HOME/Applications/$APP_NAME.app"
    # The bundle under its old name has the same identifier; two copies would
    # leave Launch Services and the login item free to pick either one.
    if [ -d "$HOME/Applications/$LEGACY_APP_NAME.app" ]; then
        rm -rf "$HOME/Applications/$LEGACY_APP_NAME.app"
        echo "removed the old bundle: $HOME/Applications/$LEGACY_APP_NAME.app"
    fi
fi
