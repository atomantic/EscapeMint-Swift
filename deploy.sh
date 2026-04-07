#!/bin/bash
set -euo pipefail

# EscapeMint Swift - Local TestFlight Deploy
# Usage: ./deploy.sh [--skip-tests] [--macos] [--ios] [--all]
# Default (no platform flag): iOS only
# --macos: macOS only
# --all: both iOS and macOS

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if [ -f .env ]; then
    set -a
    source .env
    set +a
else
    echo "❌ .env file not found. Copy .env.example to .env and fill in values."
    exit 1
fi

KEY_PATH="$APPSTORE_API_PRIVATE_KEY_PATH"
if [ ! -f "$KEY_PATH" ]; then
    echo "❌ API key not found at: $KEY_PATH"
    exit 1
fi

mkdir -p ~/.private_keys
KEY_FILENAME="AuthKey_${APPSTORE_API_KEY_ID}.p8"
if [ ! -f ~/.private_keys/"$KEY_FILENAME" ]; then
    ln -sf "$KEY_PATH" ~/.private_keys/"$KEY_FILENAME"
    echo "🔑 Symlinked API key to ~/.private_keys/"
fi

PROJECT="EscapeMint.xcodeproj"
BUILD_DIR="$SCRIPT_DIR/build"

# Parse flags
SKIP_TESTS=false
BUILD_IOS=false
BUILD_MACOS=false
for arg in "$@"; do
    case "$arg" in
        --skip-tests) SKIP_TESTS=true ;;
        --macos) BUILD_MACOS=true ;;
        --ios) BUILD_IOS=true ;;
        --all) BUILD_IOS=true; BUILD_MACOS=true ;;
    esac
done
# Default to iOS if no platform specified
if ! $BUILD_IOS && ! $BUILD_MACOS; then
    BUILD_IOS=true
fi

# Auto-increment build number. If anything fails after this point, roll back
# project.yml and the generated pbxproj to their BYTE-EXACT pre-bump state so we
# don't permanently consume a build number that never reached TestFlight.
#
# We snapshot the files to unique tempfiles instead of `git checkout --`, because
# git-checkout would also discard any pre-existing uncommitted changes the operator
# may have in these files (e.g. in-progress edits to project.yml or the pbxproj).
ORIG_PROJECT_YML=$(mktemp)
ORIG_PBXPROJ=$(mktemp)
cp project.yml "$ORIG_PROJECT_YML"
cp "$PROJECT/project.pbxproj" "$ORIG_PBXPROJ"

CURRENT_BUILD=$(grep CURRENT_PROJECT_VERSION project.yml | head -1 | awk '{print $2}')
NEW_BUILD=$((CURRENT_BUILD + 1))
echo "📦 Build number: $CURRENT_BUILD → $NEW_BUILD"
/usr/bin/sed -i '' "s/CURRENT_PROJECT_VERSION: ${CURRENT_BUILD}/CURRENT_PROJECT_VERSION: ${NEW_BUILD}/" project.yml

DEPLOY_SUCCESS=false
rollback_build_bump() {
    if [ "$DEPLOY_SUCCESS" = "false" ]; then
        echo "↩️  Rolling back build number bump (deploy did not complete)..."
        cp "$ORIG_PROJECT_YML" project.yml 2>/dev/null || true
        cp "$ORIG_PBXPROJ" "$PROJECT/project.pbxproj" 2>/dev/null || true
    fi
    rm -f "$ORIG_PROJECT_YML" "$ORIG_PBXPROJ"
}
trap rollback_build_bump EXIT

echo "⚙️  Regenerating Xcode project..."
xcodegen generate

if ! $SKIP_TESTS; then
    echo "🧪 Running tests..."
    # Find a suitable iPhone simulator by device ID to avoid OS:latest mismatch
    DEVICE_ID=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
preferred = ['iPhone 16 Pro', 'iPhone 16', 'iPhone 17 Pro', 'iPhone 15']
for name in preferred:
    for runtime, devices in data.get('devices', {}).items():
        for d in devices:
            if d['name'] == name and d.get('isAvailable', False):
                print(d['udid']); sys.exit(0)
# fallback: any available iPhone
for runtime, devices in data.get('devices', {}).items():
    for d in devices:
        if 'iPhone' in d['name'] and d.get('isAvailable', False):
            print(d['udid']); sys.exit(0)
" 2>/dev/null)
    DESTINATION="platform=iOS Simulator,id=$DEVICE_ID"
    echo "📱 Test destination: $DESTINATION"
    xcodebuild test \
        -project "$PROJECT" \
        -scheme EscapeMintTests_iOS \
        -destination "$DESTINATION" \
        -configuration Debug \
        CODE_SIGNING_ALLOWED=NO \
        -quiet
    echo "✅ Tests passed"
fi

rm -rf "$BUILD_DIR"

# --- iOS Build & Upload ---
if $BUILD_IOS; then
    SCHEME_IOS="EscapeMint_iOS"
    ARCHIVE_IOS="$BUILD_DIR/EscapeMint_iOS.xcarchive"
    EXPORT_IOS="$BUILD_DIR/export_ios"

    echo "📦 Archiving iOS..."
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$SCHEME_IOS" \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "$ARCHIVE_IOS" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$KEY_PATH" \
        -authenticationKeyID "$APPSTORE_API_KEY_ID" \
        -authenticationKeyIssuerID "$APPSTORE_ISSUER_ID" \
        -quiet
    echo "✅ iOS archive complete"

    cat > "$BUILD_DIR/exportOptions_ios.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF

    echo "📤 Exporting iOS IPA..."
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_IOS" \
        -exportOptionsPlist "$BUILD_DIR/exportOptions_ios.plist" \
        -exportPath "$EXPORT_IOS" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$KEY_PATH" \
        -authenticationKeyID "$APPSTORE_API_KEY_ID" \
        -authenticationKeyIssuerID "$APPSTORE_ISSUER_ID" \
        -quiet
    echo "✅ iOS IPA exported"

    IPA_PATH="$EXPORT_IOS/EscapeMint.ipa"
    if [ ! -f "$IPA_PATH" ]; then
        echo "❌ iOS IPA not found at $IPA_PATH"
        ls -la "$EXPORT_IOS/"
        exit 1
    fi

    echo "🚀 Uploading iOS to TestFlight..."
    IOS_UPLOAD_LOG="$BUILD_DIR/ios_upload.log"
    set +e
    xcrun altool --upload-app \
        --file "$IPA_PATH" \
        --type ios \
        --apiKey "$APPSTORE_API_KEY_ID" \
        --apiIssuer "$APPSTORE_ISSUER_ID" 2>&1 | tee "$IOS_UPLOAD_LOG"
    IOS_UPLOAD_STATUS=${PIPESTATUS[0]}
    set -e
    # altool can exit 0 while the XML plist in its output actually says UPLOAD FAILED.
    # Grep for the definitive failure markers so deploy.sh doesn't report phantom success.
    #
    # IMPORTANT: do NOT grep for plain "ERROR: " — altool logs transient multipart upload
    # retries as "ERROR: [ContentDelivery.Uploader...] WILL RETRY PART N" which are normal
    # recoverable events, NOT terminal failures. We false-positived on those and killed the
    # script mid-recovery. Use only Apple's definitive failure markers:
    #   - "UPLOAD FAILED" : Apple's summary banner printed once when all retries exhausted
    #   - "Validation failed (" : server-side 4xx from App Store Connect
    #   - "ERROR ITMS-" : legacy Apple error code format (still emitted for some failures)
    #   - "product-errors" : Apple's structured error output
    if [ "$IOS_UPLOAD_STATUS" -ne 0 ] || grep -qE "UPLOAD FAILED|Validation failed \(|ERROR ITMS-|product-errors" "$IOS_UPLOAD_LOG"; then
        echo "❌ iOS upload failed — see errors above"
        exit 1
    fi
    echo "✅ iOS upload complete!"

    if $BUILD_MACOS; then
        echo "⏳ Waiting 60s before macOS upload to avoid Apple CDN contention..."
        sleep 60
    fi
fi

# --- macOS Build & Upload ---
if $BUILD_MACOS; then
    SCHEME_MACOS="EscapeMint_macOS"
    ARCHIVE_MACOS="$BUILD_DIR/EscapeMint_macOS.xcarchive"
    EXPORT_MACOS="$BUILD_DIR/export_macos"

    echo "📦 Archiving macOS..."
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$SCHEME_MACOS" \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -archivePath "$ARCHIVE_MACOS" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$KEY_PATH" \
        -authenticationKeyID "$APPSTORE_API_KEY_ID" \
        -authenticationKeyIssuerID "$APPSTORE_ISSUER_ID" \
        -quiet
    echo "✅ macOS archive complete"

    cat > "$BUILD_DIR/exportOptions_macos.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF

    echo "📤 Exporting macOS pkg..."
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_MACOS" \
        -exportOptionsPlist "$BUILD_DIR/exportOptions_macos.plist" \
        -exportPath "$EXPORT_MACOS" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$KEY_PATH" \
        -authenticationKeyID "$APPSTORE_API_KEY_ID" \
        -authenticationKeyIssuerID "$APPSTORE_ISSUER_ID" \
        -quiet
    echo "✅ macOS pkg exported"

    # macOS export produces a .pkg file
    PKG_PATH=$(find "$EXPORT_MACOS" -name "*.pkg" | head -1)
    if [ -z "$PKG_PATH" ]; then
        echo "❌ macOS package not found in $EXPORT_MACOS"
        ls -la "$EXPORT_MACOS/"
        exit 1
    fi

    echo "🚀 Uploading macOS to TestFlight..."
    MACOS_UPLOAD_LOG="$BUILD_DIR/macos_upload.log"
    set +e
    xcrun altool --upload-app \
        --file "$PKG_PATH" \
        --type macos \
        --apiKey "$APPSTORE_API_KEY_ID" \
        --apiIssuer "$APPSTORE_ISSUER_ID" 2>&1 | tee "$MACOS_UPLOAD_LOG"
    MACOS_UPLOAD_STATUS=${PIPESTATUS[0]}
    set -e
    # Same grep-pattern discipline as iOS: definitive markers only, no plain "ERROR: ".
    if [ "$MACOS_UPLOAD_STATUS" -ne 0 ] || grep -qE "UPLOAD FAILED|Validation failed \(|ERROR ITMS-|product-errors" "$MACOS_UPLOAD_LOG"; then
        echo "❌ macOS upload failed — see errors above"
        exit 1
    fi
    echo "✅ macOS upload complete!"
fi

echo "✅ Build $NEW_BUILD submitted to TestFlight."

# Commit the build number bump only after all uploads succeed, so a failed deploy
# doesn't leave a permanently-consumed build number committed to main. DEPLOY_SUCCESS
# is flipped AFTER `git commit` succeeds — if the commit itself fails (hooks, config
# issues, etc.) under `set -e`, the EXIT trap still sees DEPLOY_SUCCESS=false and
# rolls back the pre-commit file changes.
git add project.yml "$PROJECT/project.pbxproj"
git commit -m "build: bump to build $NEW_BUILD"
DEPLOY_SUCCESS=true
echo "📝 Committed build number bump"

rm -rf "$BUILD_DIR"
echo "🧹 Cleaned build artifacts"
