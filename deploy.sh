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

# Auto-increment build number
CURRENT_BUILD=$(grep CURRENT_PROJECT_VERSION project.yml | head -1 | awk '{print $2}')
NEW_BUILD=$((CURRENT_BUILD + 1))
echo "📦 Build number: $CURRENT_BUILD → $NEW_BUILD"
/usr/bin/sed -i '' "s/CURRENT_PROJECT_VERSION: ${CURRENT_BUILD}/CURRENT_PROJECT_VERSION: ${NEW_BUILD}/" project.yml

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
    xcrun altool --upload-app \
        --file "$IPA_PATH" \
        --type ios \
        --apiKey "$APPSTORE_API_KEY_ID" \
        --apiIssuer "$APPSTORE_ISSUER_ID"
    echo "✅ iOS upload complete!"
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
    if ! xcrun altool --upload-app \
        --file "$PKG_PATH" \
        --type macos \
        --apiKey "$APPSTORE_API_KEY_ID" \
        --apiIssuer "$APPSTORE_ISSUER_ID"; then
        echo "❌ macOS upload failed"
        exit 1
    fi
    echo "✅ macOS upload complete!"
fi

echo "✅ Build $NEW_BUILD submitted to TestFlight."

git add project.yml "$PROJECT/project.pbxproj"
git commit -m "build: bump to build $NEW_BUILD"
echo "📝 Committed build number bump"

rm -rf "$BUILD_DIR"
echo "🧹 Cleaned build artifacts"
