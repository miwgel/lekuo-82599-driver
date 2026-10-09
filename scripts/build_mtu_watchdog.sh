#!/bin/bash
# Xcode app build phase. Compile and sign nested code before the app is signed.
set -euo pipefail

helper_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
helper="$helper_dir/LekuoMTUWatchdog"
mkdir -p "$helper_dir" "$DERIVED_FILE_DIR/MTUWatchdogModuleCache"
swift_compiler="${SWIFT_EXEC:-}"
if [ -z "$swift_compiler" ]; then
    swift_compiler="$(/usr/bin/xcrun --find swiftc)"
fi
parts=()
for architecture in $ARCHS; do
    part="$DERIVED_FILE_DIR/LekuoMTUWatchdog-$architecture"
    "$swift_compiler" -parse-as-library -swift-version 5 -O \
        -strict-concurrency=complete -warnings-as-errors \
        -file-prefix-map "$SRCROOT=/src" \
        -sdk "$SDKROOT" \
        -target "$architecture-apple-macos$MACOSX_DEPLOYMENT_TARGET" \
        -module-cache-path "$DERIVED_FILE_DIR/MTUWatchdogModuleCache" \
        "$SRCROOT/tools/mtu_protocol.swift" \
        "$SRCROOT/tools/mtu_watchdog.swift" \
        -o "$part"
    parts+=("$part")
done
if [ "${#parts[@]}" -eq 1 ]; then
    cp "${parts[0]}" "$helper"
else
    /usr/bin/lipo -create "${parts[@]}" -output "$helper"
fi

if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
    test -n "${EXPANDED_CODE_SIGN_IDENTITY:-}"
    /usr/bin/codesign --force --options runtime --timestamp \
        --identifier "$PRODUCT_BUNDLE_IDENTIFIER.MTUWatchdog" \
        --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$helper"
    /usr/bin/codesign --verify --strict "$helper"
fi
