#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
configuration=${CONFIGURATION:-release}
app_dir="$project_root/build/Cue.app"
contents_dir="$app_dir/Contents"
binary_path="$project_root/.build/arm64-apple-macosx/$configuration/Cue"

cd "$project_root"
swift build -c "$configuration" --product Cue

if [[ -d "$app_dir" ]]; then
    backup_stamp=$(date +%Y%m%d%H%M%S)
    mv "$app_dir" "$project_root/build/Cue.previous.$backup_stamp.app"
fi

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$binary_path" "$contents_dir/MacOS/Cue"
cp "$project_root/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$project_root/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
fluid_audio_bundle="$project_root/.build/arm64-apple-macosx/$configuration/FluidAudio_FluidAudio.bundle"
if [[ -d "$fluid_audio_bundle" ]]; then
    cp -R "$fluid_audio_bundle" "$contents_dir/Resources/"
fi
cp "$project_root/LICENSE" "$contents_dir/Resources/Cue-LICENSE.txt"
cp "$project_root/THIRD_PARTY_NOTICES.md" "$contents_dir/Resources/"

identity=${CODE_SIGN_IDENTITY:--}
signing_options=(--force --deep --options runtime --sign "$identity")
if [[ "$identity" != "-" ]]; then
    signing_options+=(--timestamp)
fi
codesign "${signing_options[@]}" \
    --entitlements "$project_root/Resources/Cue.entitlements" \
    "$app_dir"

echo "$app_dir"
