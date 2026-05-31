#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATH="$PROJECT_ROOT/Observe.xcodeproj"
SCHEME="Observe"
CONFIGURATION="Release"
APP_NAME="Observe"
ARTIFACTS_DIR="$PROJECT_ROOT/artifacts"
DERIVED_DATA_DIR="$ARTIFACTS_DIR/DerivedData"
APP_ARTIFACT="$ARTIFACTS_DIR/$APP_NAME.app"
DMG_STAGING_DIR="$ARTIFACTS_DIR/dmg-staging"
DMG_ARTIFACT="$ARTIFACTS_DIR/$APP_NAME.dmg"
APPLICATIONS_APP="/Applications/$APP_NAME.app"

artifact_link() {
    local path="$1"
    printf 'file://%s\n' "$path"
}

verify_homekit_signature() {
    local app_path="$1"
    local signature_output
    local entitlements_output

    signature_output="$(/usr/bin/codesign -dvv "$app_path" 2>&1 || true)"
    if grep -q 'Signature=adhoc' <<<"$signature_output"; then
        echo "Built app is ad-hoc signed. HomeKit will not work from this artifact." >&2
        echo "Open the project in Xcode, make sure automatic signing is available, then rerun this script." >&2
        exit 1
    fi

    if grep -q 'TeamIdentifier=not set' <<<"$signature_output"; then
        echo "Built app has no TeamIdentifier. HomeKit permissions will not persist correctly." >&2
        echo "Open the project in Xcode, make sure automatic signing is available, then rerun this script." >&2
        exit 1
    fi

    entitlements_output="$(/usr/bin/codesign -d --entitlements - "$app_path" 2>/dev/null || true)"
    if ! grep -q 'com.apple.developer.homekit' <<<"$entitlements_output"; then
        echo "Built app is missing the HomeKit entitlement." >&2
        echo "Refusing to package an app that cannot access Home data correctly." >&2
        exit 1
    fi
}

ask_yes_no() {
    local prompt="$1"

    if [[ ! -t 0 ]]; then
        return 1
    fi

    local answer
    while true; do
        read -r -p "$prompt [y/n] " answer
        case "$answer" in
            y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

echo "Building $APP_NAME for macOS..."
mkdir -p "$ARTIFACTS_DIR"

# HomeKit requires a stable signed app identity with the HomeKit entitlement.
# Do not disable code signing here; unsigned artifacts repeatedly prompt for
# Home access and cannot reliably read the user's homes.
xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS,variant=Mac Catalyst" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    -allowProvisioningUpdates \
    build

BUILT_APP="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION-maccatalyst/$APP_NAME.app"
if [[ ! -d "$BUILT_APP" ]]; then
    echo "Expected app was not created at: $BUILT_APP" >&2
    exit 1
fi

echo "Creating app artifact..."
rm -rf "$APP_ARTIFACT"
cp -R "$BUILT_APP" "$APP_ARTIFACT"
verify_homekit_signature "$APP_ARTIFACT"

echo "Creating DMG artifact..."
rm -rf "$DMG_STAGING_DIR" "$DMG_ARTIFACT"
mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_ARTIFACT" "$DMG_STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_ARTIFACT"
rm -rf "$DMG_STAGING_DIR"

echo
echo "Artifacts created:"
echo "- App: $(artifact_link "$APP_ARTIFACT")"
echo "- DMG: $(artifact_link "$DMG_ARTIFACT")"
echo "- Build products: $(artifact_link "$DERIVED_DATA_DIR/Build/Products")"
echo

if ask_yes_no "Copy $APP_NAME.app to /Applications and overwrite any existing copy?"; then
    echo "Copying to /Applications..."
    if [[ -d "$APPLICATIONS_APP" ]]; then
        rm -rf "$APPLICATIONS_APP"
    fi
    cp -R "$APP_ARTIFACT" "$APPLICATIONS_APP"
    echo "Installed app: $(artifact_link "$APPLICATIONS_APP")"

    if ask_yes_no "Run $APP_NAME.app from /Applications now?"; then
        open "$APPLICATIONS_APP"
    fi
else
    echo "Skipped copying to /Applications."
fi
