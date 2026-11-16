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

# Swift modules/executable and the development signing identity keep their
# old names. The public bundle ID and storage paths use Perspica.
APP_NAME=Perspica
EXECUTABLE=Yaku
LEGACY_APP_NAME=Yaku
BUILD_DIR=build
APP="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"

KEYCHAIN="$HOME/Library/Keychains/yaku-dev.keychain-db"
KEYCHAIN_PASSWORD_FILE="$HOME/Library/Application Support/Perspica/dev-signing/pass"
if [ ! -f "$KEYCHAIN_PASSWORD_FILE" ]; then
    KEYCHAIN_PASSWORD_FILE="$HOME/Library/Application Support/Yaku/dev-signing/pass"
fi
IDENTITY="Yaku Signing"
SIGN_TIMEOUT=30

swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)

# Rebuild the bundle from scratch, one concrete path at a time.
rm -rf "$CONTENTS"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Helpers"

cp Resources/Info.plist "$CONTENTS/Info.plist"
cp Resources/PLAMO-COMMUNITY-LICENSE-en.txt "$CONTENTS/Resources/PLAMO-COMMUNITY-LICENSE-en.txt"
cp ../LICENSE "$CONTENTS/Resources/LICENSE"
cp ../THIRD_PARTY_NOTICES.md "$CONTENTS/Resources/THIRD_PARTY_NOTICES.md"
cp ../ARTWORK.md "$CONTENTS/Resources/ARTWORK.md"
cp -R Resources/Licenses "$CONTENTS/Resources/Licenses"
cp "$BIN_DIR/$EXECUTABLE" "$CONTENTS/MacOS/$EXECUTABLE"

# The app icon. `Resources/Perspica.icon` is an Icon Composer document; actool
# compiles it to Assets.car (the Liquid Glass icon) and Perspica.icns (for anything
# that still asks for a plain .icns). The partial plist it writes holds
# CFBundleIconFile / CFBundleIconName, which are merged into Info.plist here
# rather than kept in the source plist, so the two cannot drift apart.
if [ -d Resources/$APP_NAME.icon ]; then
    # actool resolves relative paths against its own working directory, not
    # this script's, so both paths are made absolute first.
    # Polly's poses (Resources/Polly.xcassets) go into the same Assets.car: a
    # second actool run would overwrite it.
    xcrun actool "$(pwd)/Resources/$APP_NAME.icon" "$(pwd)/Resources/Polly.xcassets" \
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
    # Do not leave an obsolete Yaku app available to Launch Services.
    if [ -d "$HOME/Applications/$LEGACY_APP_NAME.app" ]; then
        rm -rf "$HOME/Applications/$LEGACY_APP_NAME.app"
        echo "removed the old bundle: $HOME/Applications/$LEGACY_APP_NAME.app"
    fi
fi
