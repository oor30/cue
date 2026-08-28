#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
app_dir="$project_root/build/Cue.app"
archive="$project_root/build/Cue-notarization.zip"
identity=${CODE_SIGN_IDENTITY:-}
notary_profile=${NOTARYTOOL_PROFILE:-}

if [[ "$identity" != Developer\ ID\ Application:* ]]; then
    echo "CODE_SIGN_IDENTITYにDeveloper ID Application証明書名を指定してください。" >&2
    exit 2
fi
if [[ -z "$notary_profile" ]]; then
    echo "NOTARYTOOL_PROFILEにnotarytoolのKeychain Profile名を指定してください。" >&2
    exit 2
fi

CODE_SIGN_IDENTITY="$identity" CONFIGURATION=release \
    "$project_root/scripts/build-app.sh"

codesign --verify --deep --strict --verbose=2 "$app_dir"
ditto -c -k --keepParent "$app_dir" "$archive"
xcrun notarytool submit "$archive" \
    --keychain-profile "$notary_profile" \
    --wait
xcrun stapler staple "$app_dir"
xcrun stapler validate "$app_dir"
spctl --assess --type execute --verbose=4 "$app_dir"

echo "$app_dir"
