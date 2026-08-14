#!/bin/bash

set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "Usage: $0 <arm64-app> <x86_64-app> <output-directory> <version>" >&2
    exit 2
fi

RTT_ARM_APP=$1
RTT_INTEL_APP=$2
RTT_OUTPUT_DIR=$3
RTT_VERSION=$4
RTT_UNIVERSAL_APP="$RTT_OUTPUT_DIR/RTT.app"
RTT_FRAMEWORKS_DIR="$RTT_UNIVERSAL_APP/Contents/Frameworks"
RTT_RESOURCES_DIR="$RTT_UNIVERSAL_APP/Contents/Resources"

[[ -d "$RTT_ARM_APP" ]] || { echo "Missing arm64 app: $RTT_ARM_APP" >&2; exit 1; }
[[ -d "$RTT_INTEL_APP" ]] || { echo "Missing x86_64 app: $RTT_INTEL_APP" >&2; exit 1; }

rm -rf "$RTT_UNIVERSAL_APP"
mkdir -p "$RTT_OUTPUT_DIR"
cp -R "$RTT_ARM_APP" "$RTT_UNIVERSAL_APP"

lipo -create \
    "$RTT_ARM_APP/Contents/MacOS/RTT" \
    "$RTT_INTEL_APP/Contents/MacOS/RTT" \
    -output "$RTT_UNIVERSAL_APP/Contents/MacOS/RTT"

lipo -create \
    "$RTT_ARM_APP/Contents/Resources/gawk" \
    "$RTT_INTEL_APP/Contents/Resources/gawk" \
    -output "$RTT_UNIVERSAL_APP/Contents/Resources/gawk"

for library in libintl.8.dylib libgmp.10.dylib libmpfr.6.dylib libreadline.8.dylib; do
    lipo -create \
        "$RTT_ARM_APP/Contents/Frameworks/$library" \
        "$RTT_INTEL_APP/Contents/Frameworks/$library" \
        -output "$RTT_FRAMEWORKS_DIR/$library"
done

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RTT_VERSION" "$RTT_UNIVERSAL_APP/Contents/Info.plist"
chmod +x "$RTT_UNIVERSAL_APP/Contents/MacOS/RTT" "$RTT_UNIVERSAL_APP/Contents/Resources/gawk"

for binary in "$RTT_UNIVERSAL_APP/Contents/MacOS/RTT" "$RTT_UNIVERSAL_APP/Contents/Resources/gawk"; do
    RTT_ARCHS=$(lipo -archs "$binary")
    [[ "$RTT_ARCHS" == *arm64* && "$RTT_ARCHS" == *x86_64* ]] || {
        echo "Not a Universal 2 binary: $binary ($RTT_ARCHS)" >&2
        exit 1
    }
done

RTT_SIGNING_IDENTITY=${SIGNING_IDENTITY:--}
RTT_CODESIGN_OPTIONS=(--force --timestamp=none --sign "$RTT_SIGNING_IDENTITY")
if [[ "$RTT_SIGNING_IDENTITY" != "-" ]]; then
    RTT_CODESIGN_OPTIONS+=(--options runtime)
fi
for framework in "$RTT_FRAMEWORKS_DIR"/*.dylib; do
    codesign "${RTT_CODESIGN_OPTIONS[@]}" "$framework"
done
codesign "${RTT_CODESIGN_OPTIONS[@]}" "$RTT_UNIVERSAL_APP/Contents/Resources/gawk"
codesign \
    "${RTT_CODESIGN_OPTIONS[@]}" \
    --identifier com.zhou.RTT \
    "$RTT_UNIVERSAL_APP"
codesign --verify --deep --strict "$RTT_UNIVERSAL_APP"

RTT_DMG_PATH="$RTT_OUTPUT_DIR/RTT-$RTT_VERSION-universal.dmg"
hdiutil create \
    -volname RTT \
    -srcfolder "$RTT_UNIVERSAL_APP" \
    -ov \
    -format UDZO \
    "$RTT_DMG_PATH"

lipo -archs "$RTT_UNIVERSAL_APP/Contents/MacOS/RTT"
lipo -archs "$RTT_UNIVERSAL_APP/Contents/Resources/gawk"
shasum -a 256 "$RTT_DMG_PATH" > "$RTT_DMG_PATH.sha256"
echo "Built $RTT_DMG_PATH"
