#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h:h}
NATIVE="$ROOT/native"
BUILD="$NATIVE/build"
APP="$BUILD/智连.app"
OUTPUT="$ROOT/../outputs"
SDK=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
mkdir -p "$BUILD/arm64" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUTPUT" "$ROOT/../.build-current/clang" "$ROOT/../.build-current/swift"
export CLANG_MODULE_CACHE_PATH="$ROOT/../.build-current/clang"
export SWIFT_MODULECACHE_PATH="$ROOT/../.build-current/swift"

/usr/bin/xcrun swiftc -O -parse-as-library -target arm64-apple-macosx13.0 -sdk "$SDK" "$NATIVE"/Sources/*.swift -o "$BUILD/arm64/Zhilian"
/bin/cp "$BUILD/arm64/Zhilian" "$APP/Contents/MacOS/Zhilian"
/bin/cp "$NATIVE/Info.plist" "$APP/Contents/Info.plist"
/bin/cp "$NATIVE/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/bin/cp "$NATIVE/Resources/china-ip-ranges.txt" "$APP/Contents/Resources/china-ip-ranges.txt"
/bin/mkdir -p "$APP/Contents/Resources/Core"
/bin/cp "$NATIVE/Resources/Core/mihomo" "$APP/Contents/Resources/Core/mihomo"
/bin/cp "$NATIVE/Resources/Core/LICENSE-MIHOMO.txt" "$APP/Contents/Resources/Core/LICENSE-MIHOMO.txt"
/bin/chmod +x "$APP/Contents/Resources/Core/mihomo"
/usr/bin/xattr -cr "$APP" 2>/dev/null || true
# The workspace's file provider can add FinderInfo/provenance between copy and signing.
# Remove these known signing blockers explicitly, then clear once more after the bundle is staged.
/usr/bin/xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
/usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' "$APP" 2>/dev/null || true
/usr/bin/xattr -cr "$APP" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$APP"

# Package from a fresh temporary volume. The source directory lives in a macOS file-provider
# location, which can add Finder metadata after signing and make otherwise valid bundles fail
# Gatekeeper validation. The staged copy is cleaned and signed immediately before archiving.
PACKAGE_STAGE=$(/usr/bin/mktemp -d)
PACKAGE_APP="$PACKAGE_STAGE/智连.app"
/usr/bin/ditto "$APP" "$PACKAGE_APP"
/usr/bin/xattr -d com.apple.FinderInfo "$PACKAGE_APP" 2>/dev/null || true
/usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' "$PACKAGE_APP" 2>/dev/null || true
/usr/bin/xattr -cr "$PACKAGE_APP" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$PACKAGE_APP"
/usr/bin/codesign --verify --deep --strict "$PACKAGE_APP"
/bin/rm -f "$OUTPUT/智连-0.5.2-macOS.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_APP" "$OUTPUT/智连-0.5.2-macOS.zip"

/bin/ln -s /Applications "$PACKAGE_STAGE/Applications"
/bin/rm -f "$OUTPUT/智连-0.5.2.dmg"
if ! /usr/bin/hdiutil create -volname "智连" -srcfolder "$PACKAGE_STAGE" -ov -format UDZO "$OUTPUT/智连-0.5.2.dmg"; then
  /usr/bin/hdiutil makehybrid -hfs -hfs-volume-name "智连" -o "$OUTPUT/智连-0.5.2.dmg" "$PACKAGE_STAGE"
fi
echo "$APP"
