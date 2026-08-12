#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
output_dir="${1:-$project_dir/../outputs}"
build_dir="$project_dir/build"
app_bundle="$build_dir/智连.app"
contents_dir="$app_bundle/Contents"
resources_dir="$contents_dir/Resources"
macos_dir="$contents_dir/MacOS"
dmg_stage="$build_dir/dmg"
compiled_icon="$project_dir/app/assets/AppIcon.icns"
final_dmg="$output_dir/智连-0.2.0.dmg"

if [[ "$build_dir" != "$project_dir/build" ]]; then
  print -u2 "拒绝清理非预期构建目录"
  exit 1
fi

/bin/rm -rf "$build_dir"
/bin/rm -f "$final_dmg"
/bin/mkdir -p "$build_dir" "$dmg_stage" "$output_dir"

/usr/bin/osacompile -s -o "$app_bundle" "$project_dir/packaging/launcher.applescript"
/bin/mkdir -p "$resources_dir/static" "$resources_dir/data"

/bin/cp "$project_dir/app/zhilian.rb" "$resources_dir/zhilian.rb"
/bin/cp -R "$project_dir/app/static/." "$resources_dir/static/"
/bin/cp -R "$project_dir/app/data/." "$resources_dir/data/"

/bin/cp "$compiled_icon" "$resources_dir/AppIcon.icns"

/usr/libexec/PlistBuddy -c "Delete :CFBundleIdentifier" "$contents_dir/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string cn.zhilian.desktop" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleDisplayName" "$contents_dir/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string 智连" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleName" "$contents_dir/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleName string 智连" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleShortVersionString" "$contents_dir/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.2.0" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleVersion" "$contents_dir/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 2" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$contents_dir/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :LSMinimumSystemVersion" "$contents_dir/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 11.0" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :LSUIElement" "$contents_dir/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Delete :NSAppTransportSecurity" "$contents_dir/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$contents_dir/Info.plist"

/usr/bin/plutil -lint "$contents_dir/Info.plist" >/dev/null
/usr/bin/codesign --force --deep --sign - "$app_bundle"

/bin/cp -R "$app_bundle" "$dmg_stage/智连.app"
/bin/ln -s /Applications "$dmg_stage/Applications"
if ! /usr/bin/hdiutil create -volname "智连" -srcfolder "$dmg_stage" -ov -format UDZO "$final_dmg"; then
  /usr/bin/hdiutil makehybrid -hfs -hfs-volume-name "智连" -o "$final_dmg" "$dmg_stage"
fi

print "已生成原生窗口版：$final_dmg"
