#!/bin/bash
#
# take_screenshots.sh — Capture App Store Connect screenshots for all languages and devices.
#
# Usage:
#   ./take_screenshots.sh                       # all languages, all devices
#   ./take_screenshots.sh en                    # single language, all devices
#   ./take_screenshots.sh en de fr              # specific languages, all devices
#   ./take_screenshots.sh --iphone-only         # all languages, iPhone only
#   ./take_screenshots.sh --ipad-only           # all languages, iPad only
#   ./take_screenshots.sh --screen 01_dashboard # only capture one screen
#
# Requires: EscapeMintUITests iOS UI-test target in EscapeMint.xcodeproj
#

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$PROJECT_DIR/EscapeMint.xcodeproj"
SCHEME="EscapeMint_iOS"
UI_TEST_TARGET="EscapeMintUITests"
SCREENSHOTS_DIR="$PROJECT_DIR/screenshots"
CONFIG_FILE_PROJECT="$PROJECT_DIR/.screenshot_config.json"
DERIVED_DATA="$PROJECT_DIR/.build/DerivedData"
BUNDLE_ID="net.shadowpuppet.EscapeMint"

# Supported languages (add your app's localizations here)
ALL_LANGUAGES=("en")
SCREEN_NAMES=("01_dashboard" "02_backtest" "03_fund_detail" "04_audit" "05_platforms" "06_settings")

# Currency code per locale
currency_for_locale() {
    case "$1" in
        en)    echo "USD" ;;
        de|fr|nl|es-ES|it) echo "EUR" ;;
        sv)    echo "SEK" ;;
        es-MX) echo "MXN" ;;
        pt-BR) echo "BRL" ;;
        ja)    echo "JPY" ;;
        zh-Hans) echo "CNY" ;;
        ko)    echo "KRW" ;;
        *)     echo "USD" ;;
    esac
}

# Parse arguments
LANGUAGES=()
DEVICES=()
SCREEN=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --iphone-only) DEVICES=(iphone) ; shift ;;
        --ipad-only)   DEVICES=(ipad) ; shift ;;
        --screen)
            if [[ $# -lt 2 || -z "$2" ]]; then
                echo "❌ --screen requires a screen name." >&2
                exit 2
            fi
            SCREEN="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--iphone-only|--ipad-only] [--screen <name>] [lang1 lang2 ...]"
            echo ""
            echo "Languages: ${ALL_LANGUAGES[*]}"
            echo "Screens: ${SCREEN_NAMES[*]}"
            exit 0
            ;;
        *)
            LANGUAGES+=("$1") ; shift ;;
    esac
done

# Defaults
[[ ${#LANGUAGES[@]} -eq 0 ]] && LANGUAGES=("${ALL_LANGUAGES[@]}")
[[ ${#DEVICES[@]} -eq 0 ]] && DEVICES=(iphone ipad)

if [[ -n "$SCREEN" ]]; then
    screen_is_valid=false
    for screen_name in "${SCREEN_NAMES[@]}"; do
        if [[ "$screen_name" == "$SCREEN" ]]; then screen_is_valid=true; break; fi
    done
    if [[ "$screen_is_valid" != true ]]; then
        echo "❌ Unknown screenshot screen '$SCREEN'. Choose one of: ${SCREEN_NAMES[*]}" >&2
        exit 2
    fi
fi

# Resolve the project scheme and the UI-test target before starting a build.
if ! PROJECT_METADATA="$(xcodebuild -project "$PROJECT" -list -json 2>&1)"; then
    echo "❌ Unable to read schemes from $PROJECT. Run 'xcodegen generate' first." >&2
    printf '%s\n' "$PROJECT_METADATA" >&2
    exit 1
fi
if ! printf '%s' "$PROJECT_METADATA" | python3 -c '
import json, sys
project = json.load(sys.stdin).get("project", {})
if sys.argv[1] not in project.get("schemes", []):
    print(f"❌ Required Xcode scheme {sys.argv[1]} is missing from EscapeMint.xcodeproj. Run xcodegen generate.", file=sys.stderr)
    raise SystemExit(1)
if sys.argv[2] not in project.get("targets", []):
    print(f"❌ Required iOS UI-test target {sys.argv[2]} is missing from EscapeMint.xcodeproj. Run xcodegen generate.", file=sys.stderr)
    raise SystemExit(1)
' "$SCHEME" "$UI_TEST_TARGET"; then
    exit 1
fi

# Select a currently installed simulator instead of assuming one fixed Xcode runtime.
resolve_simulator() {
    local family="$1"
    python3 - "$family" <<'PY'
import json, subprocess, sys

family = sys.argv[1]
try:
    device_data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True))
    runtime_data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"], text=True))
except (subprocess.CalledProcessError, json.JSONDecodeError):
    raise SystemExit(1)

runtimes = {
    runtime.get("identifier"): runtime
    for runtime in runtime_data.get("runtimes", [])
    if runtime.get("isAvailable") and "iOS" in runtime.get("name", "")
}
if family == "iphone":
    preferred = ["iPhone 17 Pro Max", "iPhone 16 Pro Max", "iPhone 15 Pro Max", "iPhone 14 Pro Max", "iPhone 17 Pro", "iPhone 16 Pro", "iPhone 15 Pro", "iPhone 17", "iPhone 16", "iPhone 15"]
    prefix = "iPhone "
else:
    preferred = ["iPad Pro 13-inch (M5)", "iPad Pro 13-inch (M4)", "iPad Pro 13-inch (M2)", "iPad Air 13-inch (M4)", "iPad Air 13-inch (M3)", "iPad Air 13-inch (M2)", "iPad Pro (12.9-inch) (6th generation)"]
    prefix = "iPad "

available = []
for runtime_id, devices in device_data.get("devices", {}).items():
    runtime = runtimes.get(runtime_id)
    if runtime is None:
        continue
    for device in devices:
        name = device.get("name", "")
        if device.get("isAvailable") and name.startswith(prefix):
            try:
                rank = preferred.index(name)
            except ValueError:
                rank = len(preferred)
            version = tuple(int(part) if part.isdigit() else 0 for part in runtime.get("version", "").split("."))
            available.append((rank, tuple(-part for part in version), name, runtime.get("version", ""), device.get("udid", "")))

if not available:
    raise SystemExit(1)
_, _, name, version, udid = sorted(available)[0]
print(f"{name}|{version}|{udid}")
PY
}

RESOLVED_DEVICES=()
for family in "${DEVICES[@]}"; do
    if ! simulator="$(resolve_simulator "$family")"; then
        if [[ "$family" == iphone ]]; then
            echo "❌ No available iPhone simulator with an installed iOS runtime. Install an iOS runtime and create an iPhone simulator before building screenshots." >&2
        else
            echo "❌ No available iPad simulator with an installed iOS runtime. Install an iOS runtime and create an iPad simulator before building screenshots." >&2
        fi
        exit 1
    fi
    IFS='|' read -r device_name device_os simulator_udid <<< "$simulator"
    if [[ "$family" == iphone ]]; then
        RESOLVED_DEVICES+=("$device_name|$device_os|iphone_6.7|testCaptureIPhoneScreenshots|$simulator_udid")
    else
        RESOLVED_DEVICES+=("$device_name|$device_os|ipad_13|testCaptureIPadScreenshots|$simulator_udid")
    fi
done
DEVICES=("${RESOLVED_DEVICES[@]}")

TOTAL_LANGS=${#LANGUAGES[@]}
TOTAL_DEVICES=${#DEVICES[@]}
TOTAL_RUNS=$((TOTAL_LANGS * TOTAL_DEVICES))
CURRENT_RUN=0
FAILED=()
mkdir -p "$DERIVED_DATA"
trap 'rm -f "$CONFIG_FILE_PROJECT"' EXIT

echo "=========================================="
echo "  EscapeMint App Store Screenshot Capture"
echo "=========================================="
echo "  Languages: ${LANGUAGES[*]}"
echo "  Devices:   $TOTAL_DEVICES"
echo "  Total runs: $TOTAL_RUNS"
[[ -n "$SCREEN" ]] && echo "  Screen:    $SCREEN"
echo "  Output:    $SCREENSHOTS_DIR/{locale}/{device}/"
for device_spec in "${DEVICES[@]}"; do
    IFS='|' read -r DEVICE_NAME DEVICE_OS _ _ <<< "$device_spec"
    echo "  Simulator: $DEVICE_NAME (iOS $DEVICE_OS)"
done
echo "=========================================="
echo ""

write_config() {
    local locale="$1"
    local device="$2"
    local currency
    currency=$(currency_for_locale "$locale")
    python3 - "$locale" "$device" "$SCREENSHOTS_DIR" "$currency" "$SCREEN" > "$CONFIG_FILE_PROJECT" <<'PY'
import json, sys
locale, device, output_dir, currency, target_screen = sys.argv[1:]
json.dump({
    "locale": locale,
    "device": device,
    "output_dir": output_dir,
    "currency": currency,
    "target_screen": target_screen,
}, sys.stdout)
PY
}

export_screenshots() {
    local result_bundle="$1"
    local locale="$2"
    local device_folder="$3"
    local target_screen="$4"
    local attachments_dir="$5"
    local output_dir="$SCREENSHOTS_DIR/$locale/$device_folder"

    mkdir -p "$attachments_dir" "$output_dir"
    if ! xcrun xcresulttool export attachments \
        --path "$result_bundle" \
        --output-path "$attachments_dir" \
        --filter '*.png' >/dev/null; then
        echo "❌ Could not export screenshot attachments from $result_bundle" >&2
        return 1
    fi

    python3 - "$attachments_dir/manifest.json" "$attachments_dir" "$output_dir" "$target_screen" <<'PY'
import json, pathlib, shutil, sys

manifest_path, source_dir, output_dir, target_screen = sys.argv[1:]
expected = [target_screen] if target_screen else [
    "01_dashboard", "02_backtest", "03_fund_detail", "04_audit", "05_platforms", "06_settings"
]
manifest = json.loads(pathlib.Path(manifest_path).read_text(encoding="utf-8"))
found = {}
for test in manifest:
    for attachment in test.get("attachments", []):
        name = pathlib.Path(attachment.get("suggestedHumanReadableName", "")).stem
        for expected_name in expected:
            if name == expected_name or name.startswith(expected_name + "_"):
                found[expected_name] = attachment.get("exportedFileName")

missing = [name for name in expected if name not in found]
for name in expected:
    filename = found.get(name)
    if filename:
        source = pathlib.Path(source_dir) / filename
        destination = pathlib.Path(output_dir) / f"{name}.png"
        if not source.is_file():
            missing.append(name)
            continue
        shutil.copy2(source, destination)

if missing:
    print("❌ Screenshot test did not produce: " + ", ".join(sorted(set(missing))), file=sys.stderr)
    raise SystemExit(1)
print("Saved: " + ", ".join(f"{name}.png" for name in expected))
PY
}

# Build test bundles (once per device)
for device_spec in "${DEVICES[@]}"; do
    IFS='|' read -r DEVICE_NAME DEVICE_OS DEVICE_FOLDER TEST_METHOD SIMULATOR_UDID <<< "$device_spec"

    echo "🔨 Building test bundle for $DEVICE_NAME..."
    xcodebuild build-for-testing \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "platform=iOS Simulator,name=$DEVICE_NAME,OS=$DEVICE_OS" \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=NO \
        -quiet 2>&1 || {
            echo "❌ Build failed for $DEVICE_NAME"
            exit 1
        }
    echo "✅ Build complete for $DEVICE_NAME"
    echo ""
done

# Boot simulators and pre-grant notification permissions
for device_spec in "${DEVICES[@]}"; do
    IFS='|' read -r DEVICE_NAME _ _ _ SIMULATOR_UDID <<< "$device_spec"
    echo "🚀 Booting $DEVICE_NAME simulator..."
    xcrun simctl boot "$SIMULATOR_UDID" 2>/dev/null || true
    xcrun simctl bootstatus "$SIMULATOR_UDID" -b >/dev/null
done
for device_spec in "${DEVICES[@]}"; do
    IFS='|' read -r DEVICE_NAME _ _ _ SIMULATOR_UDID <<< "$device_spec"
    xcrun simctl privacy "$SIMULATOR_UDID" grant notifications "$BUNDLE_ID" 2>/dev/null || true
done

# Capture screenshots
for device_spec in "${DEVICES[@]}"; do
    IFS='|' read -r DEVICE_NAME DEVICE_OS DEVICE_FOLDER TEST_METHOD SIMULATOR_UDID <<< "$device_spec"

    for LANG in "${LANGUAGES[@]}"; do
        CURRENT_RUN=$((CURRENT_RUN + 1))
        echo "📸 [$CURRENT_RUN/$TOTAL_RUNS] $LANG on $DEVICE_NAME..."

        write_config "$LANG" "$DEVICE_FOLDER"
        SCREENSHOT_CONFIG="$(<"$CONFIG_FILE_PROJECT")"
        RESULT_BUNDLE="$DERIVED_DATA/ScreenshotResults/${LANG}_${DEVICE_FOLDER}.xcresult"
        ATTACHMENTS_DIR="$DERIVED_DATA/ScreenshotAttachments/${LANG}_${DEVICE_FOLDER}"
        rm -rf "$RESULT_BUNDLE" "$ATTACHMENTS_DIR"
        mkdir -p "$(dirname "$RESULT_BUNDLE")" "$(dirname "$ATTACHMENTS_DIR")"

        if TEST_RUNNER_SCREENSHOT_CONFIG="$SCREENSHOT_CONFIG" xcodebuild test-without-building \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
            -derivedDataPath "$DERIVED_DATA" \
            -resultBundlePath "$RESULT_BUNDLE" \
            -only-testing:"$UI_TEST_TARGET/ScreenshotTests/$TEST_METHOD" \
            CODE_SIGNING_ALLOWED=NO \
            -quiet; then
            if export_screenshots "$RESULT_BUNDLE" "$LANG" "$DEVICE_FOLDER" "$SCREEN" "$ATTACHMENTS_DIR"; then
                echo "   ✅ $LANG / $DEVICE_FOLDER complete"
            else
                FAILED+=("$LANG/$DEVICE_FOLDER")
            fi
        else
            echo "   ⚠️  $LANG / $DEVICE_FOLDER had test failures" >&2
            FAILED+=("$LANG/$DEVICE_FOLDER")
        fi
    done
done

# Summary
echo ""
echo "=========================================="
echo "  Screenshot Capture Complete"
echo "=========================================="

TOTAL_SCREENSHOTS=$(find "$SCREENSHOTS_DIR" -name "*.png" -newer "$PROJECT_DIR/take_screenshots.sh" 2>/dev/null | wc -l | tr -d ' ')
echo "  Screenshots captured: $TOTAL_SCREENSHOTS"
echo "  Output directory: $SCREENSHOTS_DIR/"
echo ""

for LANG in "${LANGUAGES[@]}"; do
    for device_spec in "${DEVICES[@]}"; do
        IFS='|' read -r _ _ DEVICE_FOLDER _ _ <<< "$device_spec"
        DIR="$SCREENSHOTS_DIR/$LANG/$DEVICE_FOLDER"
        if [[ -d "$DIR" ]]; then
            COUNT=$(ls "$DIR"/*.png 2>/dev/null | wc -l | tr -d ' ')
            echo "  $LANG/$DEVICE_FOLDER: $COUNT screenshots"
        fi
    done
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo ""
    echo "⚠️  Runs with failures:"
    for f in "${FAILED[@]}"; do
        echo "  - $f"
    done
    exit 1
fi

echo ""
echo "Done! Upload screenshots to App Store Connect via Transporter or the web UI."
