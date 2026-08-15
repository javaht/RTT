#!/bin/bash

set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "Usage: $0 <arm64|x86_64> <output-directory> <version> <build-number>" >&2
    exit 2
fi

RTT_ARCH=$1
RTT_OUTPUT_DIR=$2
RTT_VERSION=$3
RTT_BUILD_NUMBER=$4
RTT_PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
RTT_TRIPLE="$RTT_ARCH-apple-macosx26.0"
RTT_SCRATCH_DIR="$RTT_PROJECT_DIR/.build-$RTT_ARCH"
RTT_APP_DIR="$RTT_OUTPUT_DIR/RTT.app"
RTT_CONTENTS_DIR="$RTT_APP_DIR/Contents"
RTT_FRAMEWORKS_DIR="$RTT_CONTENTS_DIR/Frameworks"
RTT_RESOURCES_DIR="$RTT_CONTENTS_DIR/Resources"

case "$RTT_ARCH" in
    arm64|x86_64) ;;
    *) echo "Unsupported architecture: $RTT_ARCH" >&2; exit 2 ;;
esac

cd "$RTT_PROJECT_DIR"
brew install gawk gettext gmp mpfr readline

swift build \
    -c release \
    --triple "$RTT_TRIPLE" \
    --scratch-path "$RTT_SCRATCH_DIR"
RTT_BIN_DIR=$(swift build \
    -c release \
    --triple "$RTT_TRIPLE" \
    --scratch-path "$RTT_SCRATCH_DIR" \
    --show-bin-path)

rm -rf "$RTT_APP_DIR"
mkdir -p "$RTT_CONTENTS_DIR/MacOS" "$RTT_RESOURCES_DIR" "$RTT_FRAMEWORKS_DIR"
cp "$RTT_BIN_DIR/RTT" "$RTT_CONTENTS_DIR/MacOS/RTT"
cp "$RTT_PROJECT_DIR/Packaging/Info.plist" "$RTT_CONTENTS_DIR/Info.plist"
cp -R "$RTT_BIN_DIR/RTT_RTT.bundle/Resources/." "$RTT_RESOURCES_DIR/"
"$RTT_PROJECT_DIR/scripts/install-app-icon.sh" "$RTT_CONTENTS_DIR"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RTT_VERSION" "$RTT_CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $RTT_BUILD_NUMBER" "$RTT_CONTENTS_DIR/Info.plist"

RTT_GAWK_PREFIX=$(brew --prefix gawk)
RTT_GETTEXT_PREFIX=$(brew --prefix gettext)
RTT_GMP_PREFIX=$(brew --prefix gmp)
RTT_MPFR_PREFIX=$(brew --prefix mpfr)
RTT_READLINE_PREFIX=$(brew --prefix readline)

rm -f "$RTT_RESOURCES_DIR/gawk"
cp "$RTT_GAWK_PREFIX/bin/gawk" "$RTT_RESOURCES_DIR/gawk"
cp "$RTT_GETTEXT_PREFIX/lib/libintl.8.dylib" "$RTT_FRAMEWORKS_DIR/libintl.8.dylib"
cp "$RTT_GMP_PREFIX/lib/libgmp.10.dylib" "$RTT_FRAMEWORKS_DIR/libgmp.10.dylib"
cp "$RTT_MPFR_PREFIX/lib/libmpfr.6.dylib" "$RTT_FRAMEWORKS_DIR/libmpfr.6.dylib"
cp "$RTT_READLINE_PREFIX/lib/libreadline.8.dylib" "$RTT_FRAMEWORKS_DIR/libreadline.8.dylib"

install_name_tool -change \
    "$RTT_GETTEXT_PREFIX/lib/libintl.8.dylib" \
    '@loader_path/../Frameworks/libintl.8.dylib' \
    "$RTT_RESOURCES_DIR/gawk"
install_name_tool -change \
    "$RTT_READLINE_PREFIX/lib/libreadline.8.dylib" \
    '@loader_path/../Frameworks/libreadline.8.dylib' \
    "$RTT_RESOURCES_DIR/gawk"
install_name_tool -change \
    "$RTT_MPFR_PREFIX/lib/libmpfr.6.dylib" \
    '@loader_path/../Frameworks/libmpfr.6.dylib' \
    "$RTT_RESOURCES_DIR/gawk"
install_name_tool -change \
    "$RTT_GMP_PREFIX/lib/libgmp.10.dylib" \
    '@loader_path/../Frameworks/libgmp.10.dylib' \
    "$RTT_RESOURCES_DIR/gawk"
install_name_tool -change \
    "$RTT_GMP_PREFIX/lib/libgmp.10.dylib" \
    '@loader_path/libgmp.10.dylib' \
    "$RTT_FRAMEWORKS_DIR/libmpfr.6.dylib"

chmod +x "$RTT_CONTENTS_DIR/MacOS/RTT" "$RTT_RESOURCES_DIR/trans" "$RTT_RESOURCES_DIR/gawk"

RTT_SIGNING_IDENTITY=${SIGNING_IDENTITY:--}
RTT_CODESIGN_OPTIONS=(--force --timestamp=none --sign "$RTT_SIGNING_IDENTITY")
if [[ "$RTT_SIGNING_IDENTITY" != "-" ]]; then
    RTT_CODESIGN_OPTIONS+=(--options runtime)
fi
for framework in "$RTT_FRAMEWORKS_DIR"/*.dylib; do
    codesign "${RTT_CODESIGN_OPTIONS[@]}" "$framework"
done
codesign "${RTT_CODESIGN_OPTIONS[@]}" "$RTT_RESOURCES_DIR/gawk"
codesign \
    "${RTT_CODESIGN_OPTIONS[@]}" \
    --identifier com.zhou.RTT \
    "$RTT_APP_DIR"
codesign --verify --deep --strict "$RTT_APP_DIR"

echo "Built $RTT_APP_DIR for $RTT_ARCH"
