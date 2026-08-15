#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <app-contents-directory>" >&2
    exit 2
fi

RTT_CONTENTS_DIR=$1
RTT_PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
RTT_RESOURCES_DIR="$RTT_CONTENTS_DIR/Resources"
RTT_ICON_SOURCE="$RTT_PROJECT_DIR/Packaging/RTTIcon.png"
RTT_ICONSET_DIR="$RTT_RESOURCES_DIR/RTT.iconset"
RTT_ICNS_PATH="$RTT_RESOURCES_DIR/RTT.icns"

[[ -f "$RTT_ICON_SOURCE" ]] || { echo "Missing icon source: $RTT_ICON_SOURCE" >&2; exit 1; }
rm -rf "$RTT_ICONSET_DIR"
mkdir -p "$RTT_ICONSET_DIR"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" -s format png "$RTT_ICON_SOURCE" \
        --out "$RTT_ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" -s format png "$RTT_ICON_SOURCE" \
        --out "$RTT_ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$RTT_ICONSET_DIR" -o "$RTT_ICNS_PATH"
rm -rf "$RTT_ICONSET_DIR"
echo "Installed $RTT_ICNS_PATH"
