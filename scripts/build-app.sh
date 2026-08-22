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

mkdir -p "$RTT_CONTENTS_DIR/MacOS" "$RTT_CONTENTS_DIR/Resources" "$RTT_CONTENTS_DIR/Frameworks"
cp "$RTT_BIN_DIR/RTT" "$RTT_CONTENTS_DIR/MacOS/RTT"
cp "$RTT_PROJECT_DIR/Packaging/Info.plist" "$RTT_CONTENTS_DIR/Info.plist"
cp -R "$RTT_BIN_DIR/RTT_RTT.bundle/Resources/." "$RTT_CONTENTS_DIR/Resources/"
"$RTT_PROJECT_DIR/scripts/install-app-icon.sh" "$RTT_CONTENTS_DIR"

# spec D 自动更新：Sparkle framework（SPM artifact，通用二进制）拷入 bundle 并挂 rpath。
# 与 build-arch-app.sh 保持同一逻辑；缺失时警告但不阻断（更新功能运行时降级）。
# framework 签名由脚本末尾对整个 bundle 的 codesign --deep 覆盖，无需单独签。
RTT_SPARKLE_FW="$RTT_PROJECT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ -d "$RTT_SPARKLE_FW" ]]; then
    cp -R "$RTT_SPARKLE_FW" "$RTT_CONTENTS_DIR/Frameworks/"
    install_name_tool -add_rpath '@loader_path/../Frameworks' "$RTT_CONTENTS_DIR/MacOS/RTT"
else
    echo "warning: Sparkle.framework not found in SPM artifacts; update features will degrade at runtime" >&2
fi
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
