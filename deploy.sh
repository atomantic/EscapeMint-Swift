#!/bin/bash
set -euo pipefail

# EscapeMint Swift - Local TestFlight Deploy
#
# Usage: ./deploy.sh [--skip-tests] [--ios] [--macos] [--watch] [--all]
#
#   Default (no platform flag): every platform the project has a scheme for
#     (keeps build numbers in lockstep so App Store Connect shows the same
#     build number on every deliverable).
#   --ios    : iOS only
#   --macos  : macOS only
#   --watch  : watchOS only (standalone watch app)
#   --all    : iOS + macOS + watchOS (equivalent to no flag on a tri-platform project)
#
# Uploads are serial with a 60s gap between each to avoid Apple's CDN
# rejecting concurrent uploads from the same API key ("another build is
# being processed" / 409 errors). Do not parallelize the altool calls.

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

# altool only looks in a short list of directories for the API key (it ignores
# --authenticationKeyPath style args). Symlink into ~/.private_keys/ so it can
# find the key by its AuthKey_<id>.p8 filename.
mkdir -p ~/.private_keys
KEY_FILENAME="AuthKey_${APPSTORE_API_KEY_ID}.p8"
if [ ! -f ~/.private_keys/"$KEY_FILENAME" ]; then
    ln -sf "$KEY_PATH" ~/.private_keys/"$KEY_FILENAME"
    echo "🔑 Symlinked API key to ~/.private_keys/"
fi

PROJECT="EscapeMint.xcodeproj"
BUILD_DIR="$SCRIPT_DIR/build"

# Scheme names (kept at the top so cross-porting this script is a 4-line edit)
SCHEME_IOS="EscapeMint_iOS"
SCHEME_MACOS="EscapeMint_macOS"
SCHEME_WATCH="EscapeMint_watchOS"        # does not exist yet — --watch will error if missing
SCHEME_TEST="EscapeMintTests_iOS"
APP_NAME="EscapeMint"                     # IPA / binary name

# Detect which schemes actually exist in the project. This lets us:
#   - silently skip missing platforms when --all or the default is used
#   - hard-error when an explicit per-platform flag (--ios/--macos/--watch)
#     requests a scheme that doesn't exist
AVAILABLE_SCHEMES=$(xcodebuild -project "$PROJECT" -list 2>/dev/null || true)
has_scheme() { echo "$AVAILABLE_SCHEMES" | grep -qxE "[[:space:]]*$1"; }

HAS_IOS=false;   has_scheme "$SCHEME_IOS"   && HAS_IOS=true
HAS_MACOS=false; has_scheme "$SCHEME_MACOS" && HAS_MACOS=true
HAS_WATCH=false; has_scheme "$SCHEME_WATCH" && HAS_WATCH=true

# Parse flags. Explicit per-platform flags (--ios/--macos/--watch) are tracked
# separately from the --all / default fan-out, so we can hard-error on an
# explicit flag referencing a missing scheme but silently skip missing schemes
# under --all.
SKIP_TESTS=false
BUILD_IOS=false
BUILD_MACOS=false
BUILD_WATCH=false
EXPLICIT_IOS=false
EXPLICIT_MACOS=false
EXPLICIT_WATCH=false
FAN_OUT=false
for arg in "$@"; do
    case "$arg" in
        --skip-tests) SKIP_TESTS=true ;;
        --ios)   EXPLICIT_IOS=true ;;
        --macos) EXPLICIT_MACOS=true ;;
        --watch) EXPLICIT_WATCH=true ;;
        --all)   FAN_OUT=true ;;
    esac
done

# No per-platform flag and no --all: fan out to every available platform.
if ! $EXPLICIT_IOS && ! $EXPLICIT_MACOS && ! $EXPLICIT_WATCH && ! $FAN_OUT; then
    FAN_OUT=true
fi

if $FAN_OUT; then
    $HAS_IOS   && BUILD_IOS=true
    $HAS_MACOS && BUILD_MACOS=true
    $HAS_WATCH && BUILD_WATCH=true
fi

# Explicit flags: honor them, and hard-error if the scheme is missing.
if $EXPLICIT_IOS; then
    $HAS_IOS   || { echo "❌ iOS scheme '$SCHEME_IOS' not found in project";       exit 1; }
    BUILD_IOS=true
fi
if $EXPLICIT_MACOS; then
    $HAS_MACOS || { echo "❌ macOS scheme '$SCHEME_MACOS' not found in project";   exit 1; }
    BUILD_MACOS=true
fi
if $EXPLICIT_WATCH; then
    $HAS_WATCH || { echo "❌ watchOS scheme '$SCHEME_WATCH' not found in project"; exit 1; }
    BUILD_WATCH=true
fi

if ! $BUILD_IOS && ! $BUILD_MACOS && ! $BUILD_WATCH; then
    echo "❌ No platforms to build — project has no recognized schemes ($SCHEME_IOS, $SCHEME_MACOS, $SCHEME_WATCH)."
    exit 1
fi

MSG="🎯 Deploying to:"
if $BUILD_IOS;   then MSG="$MSG iOS";     fi
if $BUILD_MACOS; then MSG="$MSG macOS";   fi
if $BUILD_WATCH; then MSG="$MSG watchOS"; fi
echo "$MSG"

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
    # Find a suitable iPhone simulator by UDID. Using an explicit UDID avoids the
    # "platform=iOS Simulator,name=iPhone 16,OS=latest" mismatch where xcodebuild
    # resolves 'latest' to a runtime the device isn't registered against.
    DEVICE_ID=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
preferred = ['iPhone 17 Pro', 'iPhone 17', 'iPhone 16 Pro', 'iPhone 16', 'iPhone 15']
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
    if [ -z "$DEVICE_ID" ]; then
        echo "❌ No available iPhone simulator found for tests"
        exit 1
    fi
    DESTINATION="platform=iOS Simulator,id=$DEVICE_ID"
    echo "📱 Test destination: $DESTINATION"
    xcodebuild test \
        -project "$PROJECT" \
        -scheme "$SCHEME_TEST" \
        -destination "$DESTINATION" \
        -configuration Debug \
        CODE_SIGNING_ALLOWED=NO \
        -quiet
    echo "✅ Tests passed"
fi

rm -rf "$BUILD_DIR"

# Write a shared export options plist. All three platforms use identical
# options (automatic signing, app-store-connect method), so one file is enough.
EXPORT_PLIST="$BUILD_DIR/exportOptions.plist"
mkdir -p "$BUILD_DIR"
cat > "$EXPORT_PLIST" <<EOF
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

# altool upload verification.
#
# altool exits 0 even when an upload actually failed — the failure is buried in
# its XML-ish stdout. Must tee the output and grep for definitive failure
# banners.
#
# Do NOT grep for plain "ERROR: " — altool logs transient multipart upload
# retries as "ERROR: [ContentDelivery.Uploader...] WILL RETRY PART N" and
# "ERROR: The network connection was lost.", which are recoverable events that
# Apple's uploader retries internally. Grepping for those killed the script
# mid-recovery on good uploads. Use only Apple's terminal-failure banners:
#   - "UPLOAD FAILED"       : Apple's summary banner when all retries exhausted
#   - "Validation failed (" : server-side 4xx from App Store Connect
#   - "ERROR ITMS-"         : legacy Apple error code format
#   - "product-errors"      : Apple's structured error output
FAIL_MARKERS="UPLOAD FAILED|Validation failed \(|ERROR ITMS-|product-errors"

# Tracks whether we already uploaded at least one platform — used to decide
# whether to insert the 60s delay before the next upload. We ONLY delay
# BETWEEN successful uploads, not before the first one.
UPLOADED_ONE=false
inter_upload_delay() {
    if $UPLOADED_ONE; then
        echo "⏳ Waiting 60s before next upload to avoid Apple CDN contention..."
        sleep 60
    fi
}

# --- iOS Build & Upload ---
if $BUILD_IOS; then
    ARCHIVE_IOS="$BUILD_DIR/${APP_NAME}_iOS.xcarchive"
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

    echo "📤 Exporting iOS IPA..."
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_IOS" \
        -exportOptionsPlist "$EXPORT_PLIST" \
        -exportPath "$EXPORT_IOS" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$KEY_PATH" \
        -authenticationKeyID "$APPSTORE_API_KEY_ID" \
        -authenticationKeyIssuerID "$APPSTORE_ISSUER_ID" \
        -quiet
    echo "✅ iOS IPA exported"

    IPA_PATH="$EXPORT_IOS/${APP_NAME}.ipa"
    if [ ! -f "$IPA_PATH" ]; then
        echo "❌ iOS IPA not found at $IPA_PATH"
        ls -la "$EXPORT_IOS/"
        exit 1
    fi

    inter_upload_delay

    # --transport DAV forces WebDAV transport, which is more reliable than
    # the default iTMSTransporter in our experience (fewer multipart retries,
    # less CDN contention when uploads from the same API key overlap).
    echo "🚀 Uploading iOS to TestFlight..."
    IOS_UPLOAD_LOG="$BUILD_DIR/ios_upload.log"
    set +e
    xcrun altool --upload-app \
        --file "$IPA_PATH" \
        --type ios \
        --apiKey "$APPSTORE_API_KEY_ID" \
        --apiIssuer "$APPSTORE_ISSUER_ID" \
        --transport DAV 2>&1 | tee "$IOS_UPLOAD_LOG"
    IOS_UPLOAD_STATUS=${PIPESTATUS[0]}
    set -e
    if [ "$IOS_UPLOAD_STATUS" -ne 0 ] || grep -qE "$FAIL_MARKERS" "$IOS_UPLOAD_LOG"; then
        echo "❌ iOS upload failed — see errors above"
        exit 1
    fi
    echo "✅ iOS upload complete!"
    UPLOADED_ONE=true
fi

# --- macOS Build & Upload ---
if $BUILD_MACOS; then
    ARCHIVE_MACOS="$BUILD_DIR/${APP_NAME}_macOS.xcarchive"
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

    echo "📤 Exporting macOS pkg..."
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_MACOS" \
        -exportOptionsPlist "$EXPORT_PLIST" \
        -exportPath "$EXPORT_MACOS" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$KEY_PATH" \
        -authenticationKeyID "$APPSTORE_API_KEY_ID" \
        -authenticationKeyIssuerID "$APPSTORE_ISSUER_ID" \
        -quiet
    echo "✅ macOS pkg exported"

    # macOS export produces a .pkg file (name varies with app name/platform)
    PKG_PATH=$(find "$EXPORT_MACOS" -name "*.pkg" | head -1)
    if [ -z "$PKG_PATH" ]; then
        echo "❌ macOS package not found in $EXPORT_MACOS"
        ls -la "$EXPORT_MACOS/"
        exit 1
    fi

    inter_upload_delay

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
    if [ "$MACOS_UPLOAD_STATUS" -ne 0 ] || grep -qE "$FAIL_MARKERS" "$MACOS_UPLOAD_LOG"; then
        echo "❌ macOS upload failed — see errors above"
        exit 1
    fi
    echo "✅ macOS upload complete!"
    UPLOADED_ONE=true
fi

# --- watchOS Build & Upload ---
# Only applies to STANDALONE watch apps (no iOS companion). Watch extensions
# bundled with an iOS app ship inside the iOS IPA — do NOT build them here.
if $BUILD_WATCH; then
    ARCHIVE_WATCH="$BUILD_DIR/${APP_NAME}_watchOS.xcarchive"
    EXPORT_WATCH="$BUILD_DIR/export_watchos"

    echo "📦 Archiving watchOS..."
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$SCHEME_WATCH" \
        -configuration Release \
        -destination 'generic/platform=watchOS' \
        -archivePath "$ARCHIVE_WATCH" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$KEY_PATH" \
        -authenticationKeyID "$APPSTORE_API_KEY_ID" \
        -authenticationKeyIssuerID "$APPSTORE_ISSUER_ID" \
        -quiet
    echo "✅ watchOS archive complete"

    echo "📤 Exporting watchOS IPA..."
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_WATCH" \
        -exportOptionsPlist "$EXPORT_PLIST" \
        -exportPath "$EXPORT_WATCH" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$KEY_PATH" \
        -authenticationKeyID "$APPSTORE_API_KEY_ID" \
        -authenticationKeyIssuerID "$APPSTORE_ISSUER_ID" \
        -quiet
    echo "✅ watchOS IPA exported"

    WATCH_IPA=$(find "$EXPORT_WATCH" -name "*.ipa" | head -1)
    if [ -z "$WATCH_IPA" ]; then
        echo "❌ watchOS IPA not found in $EXPORT_WATCH"
        ls -la "$EXPORT_WATCH/"
        exit 1
    fi

    inter_upload_delay

    echo "🚀 Uploading watchOS to TestFlight..."
    WATCH_UPLOAD_LOG="$BUILD_DIR/watch_upload.log"
    set +e
    # altool --type for standalone watchOS apps is still "ios" (Apple's app
    # types are {ios, macos, appletvos, visionos} — watchOS rides under ios).
    xcrun altool --upload-app \
        --file "$WATCH_IPA" \
        --type ios \
        --apiKey "$APPSTORE_API_KEY_ID" \
        --apiIssuer "$APPSTORE_ISSUER_ID" \
        --transport DAV 2>&1 | tee "$WATCH_UPLOAD_LOG"
    WATCH_UPLOAD_STATUS=${PIPESTATUS[0]}
    set -e
    if [ "$WATCH_UPLOAD_STATUS" -ne 0 ] || grep -qE "$FAIL_MARKERS" "$WATCH_UPLOAD_LOG"; then
        echo "❌ watchOS upload failed — see errors above"
        exit 1
    fi
    echo "✅ watchOS upload complete!"
    UPLOADED_ONE=true
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
