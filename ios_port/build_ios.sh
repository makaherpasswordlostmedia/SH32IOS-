#!/usr/bin/env bash
# ===========================================================================
#  Silent Hill — iOS build
#
#  Produces an UNSIGNED SilentHill.ipa. Signing happens off-box: download the
#  artifact on Windows and install it with Sideloadly or AltServer using a free
#  Apple ID. Nothing here needs a keychain, a provisioning profile or a
#  developer account, which is what lets CI build it.
#
#  Requires macOS with Xcode (the toolchain, not the IDE) plus cmake and ninja.
#  There is no way around the macOS requirement: only Apple's clang can emit
#  arm64-apple-ios, and Homebrew GCC cannot target iOS at all.
#
#  Usage:
#    ./build_ios.sh              configure (if needed) + build + package
#    ./build_ios.sh rebuild      clean rebuild
#    ./build_ios.sh configure    force a fresh configure, then build
#    ./build_ios.sh simulator    build for the iOS Simulator instead of a device
#    ./build_ios.sh legacy       armv7 / iOS 9.3 — original iPad mini (A5)
#    ./build_ios.sh legacy-rebuild   clean rebuild of the legacy target
#
#  The "legacy" mode targets the first-generation iPad mini specifically:
#  A5, armv7, no arm64, capped at iOS 9.3.5. This is NOT just a different
#  -arch flag on the normal build:
#    - Only Xcode 7.x/7.3.1 still ships an armv7 iOS 9.3 SDK and a clang that
#      will emit armv7 code for iOS at all. Xcode 8+ dropped armv7 codegen for
#      device targets; recent Xcode dropped the SDK too. Point XCODE_LEGACY_APP
#      at a *separate*, older Xcode.app you keep around for exactly this
#      (xcode-select does not need to point at it — this script calls it
#      directly via DEVELOPER_DIR).
#    - The A5 GPU has no OpenGL ES 3, only ES2 — see the
#      RENDERER_OGLES_LEGACY switch in CMakeLists.txt.
#    - SDL2's own CMake build dropped armv7 well before this script's normal
#      SDL pin; ios_port/SDL must be checked out at an old-enough commit/tag
#      for its iOS build to still emit armv7 (SDL 2.0.9-2.0.12 era). This
#      script does not switch that out for you — see ios_port/README.md.
# ===========================================================================
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODE="${1:-build}"

BUILD_DIR="$REPO_ROOT/build-ios"
SYSROOT="iphoneos"
ARCH="arm64"
DEPLOY_TARGET="13.0"
LEGACY=0

case "$MODE" in
    simulator)
        BUILD_DIR="$REPO_ROOT/build-ios-sim"
        SYSROOT="iphonesimulator"
        ;;
    legacy|legacy-rebuild)
        LEGACY=1
        BUILD_DIR="$REPO_ROOT/build-ios-legacy"
        SYSROOT="iphoneos"
        ARCH="armv7"
        DEPLOY_TARGET="9.3"
        ;;
esac

for tool in cmake ninja xcrun; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: '$tool' not found. Needs macOS with Xcode + cmake + ninja." >&2
        exit 1
    }
done
if [ ! -e "$SCRIPT_DIR/SDL/CMakeLists.txt" ]; then
    echo "ERROR: SDL submodule missing at ios_port/SDL" >&2
    echo "  git submodule update --init --recursive ios_port/SDL" >&2
    exit 1
fi

if [ "$LEGACY" = 1 ]; then
    # XCODE_LEGACY_APP: path to an Xcode 7.3.1.app (or similar) that still has
    # the armv7 iOS 9.3 SDK. Not xcode-select's active Xcode, which is assumed
    # to be a modern one for the normal arm64 build.
    XCODE_LEGACY_APP="${XCODE_LEGACY_APP:-/Applications/Xcode_7.3.1.app}"
    if [ ! -d "$XCODE_LEGACY_APP" ]; then
        echo "ERROR: legacy Xcode not found at $XCODE_LEGACY_APP" >&2
        echo "  Set XCODE_LEGACY_APP to point at an Xcode 7.x install." >&2
        echo "  Modern Xcode cannot emit armv7 code for iOS devices at all —" >&2
        echo "  this is not a flag you can pass to today's clang." >&2
        exit 1
    fi
    export DEVELOPER_DIR="$XCODE_LEGACY_APP/Contents/Developer"

    LEGACY_SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null)"
    if [ -z "$LEGACY_SDK_VERSION" ]; then
        echo "ERROR: could not read the iphoneos SDK version from $XCODE_LEGACY_APP" >&2
        exit 1
    fi
    echo "Using legacy toolchain: $XCODE_LEGACY_APP (SDK $LEGACY_SDK_VERSION)"
fi

need_configure=0
[ "$MODE" = "configure" ] && need_configure=1
[ -f "$BUILD_DIR/CMakeCache.txt" ] || need_configure=1
[ "$MODE" = "configure" ] && rm -rf "$BUILD_DIR"
[ "$MODE" = "legacy-rebuild" ] && { need_configure=1; rm -rf "$BUILD_DIR"; }

if [ "$need_configure" = 1 ]; then
    echo "=== Configuring (iOS / $SYSROOT / $ARCH / min $DEPLOY_TARGET) ==="
    # Ninja, not the Xcode generator: signing is done off-box so Xcode's
    # signing integration buys nothing, and this keeps the build shaped like
    # every other one in the repo.
    EXTRA_FLAGS=()
    if [ "$LEGACY" = 1 ]; then
        # Bitcode was still opt-in in this SDK era and PsyCross/SDL don't
        # need it; leaving it off avoids a class of "ld: unsupported bitcode
        # bundle" failures that only show up on old toolchains.
        EXTRA_FLAGS+=(-DCMAKE_XCODE_ATTRIBUTE_ENABLE_BITCODE=NO)
        # Pin the sysroot to the exact SDK the legacy Xcode ships, versioned,
        # rather than the bare "iphoneos" alias — avoids CMake resolving the
        # alias against whatever xcode-select's *active* (modern) Xcode is if
        # DEVELOPER_DIR isn't picked up consistently by every subprocess.
        SYSROOT="iphoneos${LEGACY_SDK_VERSION}"
    fi
    cmake -S "$SCRIPT_DIR" -B "$BUILD_DIR" -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY_TARGET" \
        -DCMAKE_OSX_SYSROOT="$SYSROOT" \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        "${EXTRA_FLAGS[@]}" || exit 1
fi

echo "=== Building ==="
if [ "$MODE" = "rebuild" ]; then
    cmake --build "$BUILD_DIR" --clean-first || exit 1
else
    cmake --build "$BUILD_DIR" || exit 1
fi

APP="$(find "$BUILD_DIR" -maxdepth 4 -name 'SilentHill.app' -type d | head -1)"
if [ -z "$APP" ]; then
    echo "ERROR: SilentHill.app was not produced." >&2
    exit 1
fi
echo "Built: $APP"

# An .ipa is just a zip with the .app inside a Payload/ directory. Unsigned is
# fine — Sideloadly re-signs on the way onto the device.
echo "=== Packaging .ipa ==="
STAGE="$BUILD_DIR/ipa"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
( cd "$STAGE" && zip -qry "$BUILD_DIR/SilentHill-unsigned.ipa" Payload ) || exit 1

echo "OK: $BUILD_DIR/SilentHill-unsigned.ipa"
echo
echo "This .ipa is UNSIGNED. To install it on a device from Windows:"
echo "  1. Install iTunes and iCloud from apple.com, NOT the Microsoft Store"
echo "     (the Store builds break both Sideloadly and AltServer)."
echo "  2. Open Sideloadly, drag the .ipa in, sign in with your Apple ID."
echo "  3. A free account's certificate lasts 7 days; leave Sideloadly's"
echo "     auto-refresh running, or a paid account raises that to a year."
echo
echo "The game needs your own Silent Hill disc image. Once installed, put the"
echo "BIN/CUE in Files.app under 'On My iPhone > Silent Hill > gamedata'."
