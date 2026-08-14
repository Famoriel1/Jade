#!/bin/bash
#
# build_ipa.sh — Build two ad-hoc signed IPAs:
#   1. Jade.ipa         (bundle ID: com.jason.Jade)
#   2. Jade-MHA.ipa     (bundle ID: com.apple.mobile.MobileHouseArrest)
#
# Ad-hoc signing (codesign -s -) sets the CodeDirectory identifier via
# --identifier, which is what containermanagerd checks for MHA identity
# (SandboxEscape-Usage-Manual.md §3.1).
#
# Usage: ./build_ipa.sh
# Output: build/Jade.ipa, build/Jade-MHA.ipa
#
set -euo pipefail

# === Config ===
PROJECT="Jade.xcodeproj"
SCHEME="Jade"
CONFIG="Debug"
BUILD_DIR="build"

# === Find Xcode ===
if [ -d "/Applications/Xcode-beta.app" ]; then
    export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
elif [ -d "/Applications/Xcode.app" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
else
    echo "Error: Xcode not found" >&2
    exit 1
fi

# === Step 1: Build unsigned .app ===
echo "=== Building unsigned .app ($CONFIG) ==="
DERIVED_DATA="${BUILD_DIR}/DerivedData"
rm -rf "$DERIVED_DATA"
BUILD_LOG="${BUILD_DIR}/build.log"
xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED_DATA" \
    -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    DEVELOPMENT_TEAM="" \
    2>&1 | tee "$BUILD_LOG" | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)" || true

if ! grep -q "BUILD SUCCEEDED" "$BUILD_LOG"; then
    echo "Error: Build failed. See $BUILD_LOG for details." >&2
    exit 1
fi

APP_PATH=$(find "$DERIVED_DATA/Build/Products" -name "Jade.app" -type d | head -1)
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "Error: Jade.app not found after build" >&2
    exit 1
fi
echo "Built: $APP_PATH"

# === Step 2: create_ipa function ===
# Args: bundle_id  output_name  display_name
create_ipa() {
    local bundle_id="$1"
    local output_name="$2"
    local display_name="$3"
    local work_dir="${BUILD_DIR}/${output_name}"
    local ipa_path="${BUILD_DIR}/${output_name}.ipa"

    echo ""
    echo "=== Creating ${output_name}.ipa ==="
    echo "  Bundle ID:     $bundle_id"
    echo "  Display name:  $display_name"

    rm -rf "$work_dir" "$ipa_path"
    mkdir -p "$work_dir/Payload"

    # Copy .app
    cp -R "$APP_PATH" "$work_dir/Payload/Jade.app"
    local app="$work_dir/Payload/Jade.app"

    # Clean stray files (workbuddy memory .md files leaked into bundle)
    rm -f "$app"/*.md

    # Modify Info.plist: bundle ID + display name
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${bundle_id}" "$app/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${display_name}" "$app/Info.plist"

    # Create entitlements (ad-hoc: no team-identifier / application-identifier)
    local ent_file="$work_dir/entitlements.plist"
    cat > "$ent_file" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>get-task-allow</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.jason.Jade</string>
    </array>
    <key>com.apple.lsd.appdb</key>
    <true/>
</dict>
</plist>
EOF

    # Ad-hoc sign with --identifier (sets CodeDirectory identifier,
    # which containermanagerd checks via SecTaskCopySigningIdentifier)
    echo "  Signing (ad-hoc, identifier=$bundle_id)..."
    codesign -f -s - \
        --identifier "$bundle_id" \
        --entitlements "$ent_file" \
        "$app"

    # Verify
    echo "  Verifying..."
    codesign -dv --entitlements - "$app" 2>&1 \
        | grep -E "Identifier|Authority|TeamIdentifier|application-groups" \
        | sed 's/^/    /'

    # Package IPA
    echo "  Packaging..."
    local abs_ipa
    abs_ipa="$(cd "$(dirname "$ipa_path")" && pwd)/$(basename "$ipa_path")"
    (cd "$work_dir" && zip -r -q "$abs_ipa" Payload)

    echo "  Done: $ipa_path"
}

# === Step 3: Build both IPAs ===
create_ipa "com.jason.Jade" "Jade" "Jade"
create_ipa "com.apple.mobile.MobileHouseArrest" "Jade-MHA" "Jade MHA"

# === Summary ===
echo ""
echo "=== Build complete ==="
ls -lh "${BUILD_DIR}"/*.ipa
