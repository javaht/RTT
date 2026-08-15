#!/bin/bash

set -euo pipefail

RTT_PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
RTT_CONFIGURATION=${CONFIGURATION:-release}
RTT_APP_DIR="$RTT_PROJECT_DIR/dist/RTT.app"
RTT_CONTENTS_DIR="$RTT_APP_DIR/Contents"

cd "$RTT_PROJECT_DIR"
swift build -c "$RTT_CONFIGURATION"
RTT_BIN_DIR=$(swift build -c "$RTT_CONFIGURATION" --show-bin-path)

if [[ -d "$RTT_APP_DIR" ]]; then
    rm -r "$RTT_APP_DIR"
fi

mkdir -p "$RTT_CONTENTS_DIR/MacOS" "$RTT_CONTENTS_DIR/Resources"
cp "$RTT_BIN_DIR/RTT" "$RTT_CONTENTS_DIR/MacOS/RTT"
cp "$RTT_PROJECT_DIR/Packaging/Info.plist" "$RTT_CONTENTS_DIR/Info.plist"
cp -R "$RTT_BIN_DIR/RTT_RTT.bundle/Resources/." "$RTT_CONTENTS_DIR/Resources/"
"$RTT_PROJECT_DIR/scripts/install-app-icon.sh" "$RTT_CONTENTS_DIR"
chmod +x "$RTT_CONTENTS_DIR/MacOS/RTT" "$RTT_CONTENTS_DIR/Resources/trans" "$RTT_CONTENTS_DIR/Resources/gawk"

RTT_SIGNING_IDENTITY=${SIGNING_IDENTITY:-}
if [[ -z "$RTT_SIGNING_IDENTITY" ]]; then
    RTT_SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
        | head -n 1)
fi
if [[ -z "$RTT_SIGNING_IDENTITY" ]]; then
    RTT_SIGNING_IDENTITY="-"
fi

codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp=none \
    --identifier com.zhou.RTT \
    --sign "$RTT_SIGNING_IDENTITY" \
    "$RTT_APP_DIR"

codesign --verify --deep --strict "$RTT_APP_DIR"
echo "Built $RTT_APP_DIR"
echo "Signed with: $RTT_SIGNING_IDENTITY"
