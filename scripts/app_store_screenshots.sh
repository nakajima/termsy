#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
RESULTS_DIR="${ROOT_DIR}/build/app-store-screenshots"
DERIVED_DATA_DIR="${RESULTS_DIR}/DerivedData"
FINAL_DIR="${RESULTS_DIR}/final"
LOGS_DIR="${RESULTS_DIR}/logs"
PROJECT="${ROOT_DIR}/Termsy.xcodeproj"
SCHEME="Termsy"
APP_BUNDLE_ID="fm.folder.Termsy"
APP_PATH="${DERIVED_DATA_DIR}/Build/Products/Debug-iphonesimulator/Termsy.app"
IPAD_XCRESULT_DIR="${RESULTS_DIR}/xcresults-ipad"

SCENARIOS=(
  "saved-sessions"
  "new-session"
  "terminal"
  "session-picker"
  "settings"
)

IPHONE_DEVICE="iPhone 17 Pro Max"
IPAD_DEVICE="iPad Air 13-inch (M3)"
IPHONE_UPLOAD_WIDTH=1284
IPHONE_UPLOAD_HEIGHT=2778

mkdir -p "$FINAL_DIR" "$LOGS_DIR" "$IPAD_XCRESULT_DIR"
rm -rf "$FINAL_DIR"/* "$LOGS_DIR"/* "$IPAD_XCRESULT_DIR"/*

find_udid() {
  local name="$1"
  xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
obj = json.load(sys.stdin)
candidates = []
for runtime, devices in obj["devices"].items():
    if "iOS" not in runtime:
        continue
    version = runtime.rsplit("iOS-", 1)[-1].replace("-", ".")
    parts = tuple(int(p) for p in version.split("."))
    for device in devices:
        if device.get("isAvailable") and device.get("name") == name:
            candidates.append((parts, device["udid"]))
if not candidates:
    sys.exit(1)
candidates.sort(reverse=True)
print(candidates[0][1])
' "$name"
}

boot_device() {
  local udid="$1"
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl status_bar "$udid" override \
    --time 9:41 \
    --dataNetwork wifi \
    --wifiMode active \
    --wifiBars 3 \
    --batteryState charged \
    --batteryLevel 100 >/dev/null
  xcrun simctl ui "$udid" appearance dark >/dev/null 2>&1 || true
}

build_app() {
  echo "==> Building app"
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,name=${IPHONE_DEVICE}" \
    -derivedDataPath "$DERIVED_DATA_DIR" >/tmp/termsy-build-screenshots.log

  if [[ ! -d "$APP_PATH" ]]; then
    echo "Built app not found at $APP_PATH" >&2
    exit 1
  fi
}

launch_for_iphone_screenshot() {
  local udid="$1"
  local scenario="$2"
  xcrun simctl terminate "$udid" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true

  local launched=0
  for _ in {1..10}; do
    if SIMCTL_CHILD_TERMSY_SCREENSHOT_SCENARIO="$scenario" \
      xcrun simctl launch \
        --terminate-running-process \
        "$udid" "$APP_BUNDLE_ID" >/dev/null
    then
      launched=1
      break
    fi
    sleep 1
  done

  if [[ "$launched" -ne 1 ]]; then
    echo "Failed to launch scenario ${scenario} on ${udid}" >&2
    return 1
  fi

  case "$scenario" in
    terminal|session-picker)
      sleep 6
      ;;
    *)
      sleep 4
      ;;
  esac
}

capture_screenshot() {
  local udid="$1"
  local output_path="$2"
  xcrun simctl io "$udid" screenshot --type=png "$output_path" >/dev/null
}

run_ipad_ui_test() {
  local test_name="$1"
  local result_bundle="$2"

  rm -rf "$result_bundle"
  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,name=${IPAD_DEVICE}" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    -resultBundlePath "$result_bundle" \
    -only-testing:"TermsyUITests/TermsyUITests/${test_name}" \
    >/tmp/termsy-ipad-ui-test.log
}

normalize_png() {
  local input_path="$1"
  local output_path="$2"
  swift -e 'import AppKit
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let image = NSImage(contentsOf: input) else {
    fputs("Failed to load image at \(input.path)\n", stderr)
    exit(1)
}
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Failed to normalize image at \(input.path)\n", stderr)
    exit(1)
}
try png.write(to: output)
' "$input_path" "$output_path"
}

prepare_iphone_png() {
  local input_path="$1"
  local output_path="$2"
  local portrait_width="$3"
  local portrait_height="$4"
  swift -e 'import AppKit
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let portraitWidth = CGFloat(Int(CommandLine.arguments[3])!)
let portraitHeight = CGFloat(Int(CommandLine.arguments[4])!)
guard let image = NSImage(contentsOf: input),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("Failed to load image at \(input.path)\n", stderr)
    exit(1)
}
let sourceSize = CGSize(width: cgImage.width, height: cgImage.height)
let targetSize = sourceSize.width > sourceSize.height
    ? CGSize(width: portraitHeight, height: portraitWidth)
    : CGSize(width: portraitWidth, height: portraitHeight)
let scale = max(targetSize.width / sourceSize.width, targetSize.height / sourceSize.height)
let scaledSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
let drawRect = CGRect(
    x: (targetSize.width - scaledSize.width) / 2,
    y: (targetSize.height - scaledSize.height) / 2,
    width: scaledSize.width,
    height: scaledSize.height
)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(targetSize.width),
    pixelsHigh: Int(targetSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Failed to create bitmap for \(output.path)\n", stderr)
    exit(1)
}
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Failed to create graphics context for \(output.path)\n", stderr)
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
NSColor.black.setFill()
NSRect(origin: .zero, size: targetSize).fill()
NSImage(cgImage: cgImage, size: sourceSize).draw(in: drawRect)
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG for \(output.path)\n", stderr)
    exit(1)
}
try png.write(to: output)
' "$input_path" "$output_path" "$portrait_width" "$portrait_height"
}

export_ipad_attachment() {
  local result_bundle="$1"
  local expected_name="$2"
  local output_path="$3"
  local export_dir
  export_dir="$(mktemp -d "${RESULTS_DIR}/attachment-export.XXXXXX")"
  xcrun xcresulttool export attachments --path "$result_bundle" --output-path "$export_dir" >/dev/null

  local exported_file_name
  exported_file_name="$(jq -r --arg name "$expected_name" '.[] | .attachments[] | select(.suggestedHumanReadableName | startswith($name)) | .exportedFileName' "$export_dir/manifest.json" | head -n1)"

  if [[ -z "$exported_file_name" ]]; then
    echo "Could not find exported attachment metadata named ${expected_name} in ${result_bundle}" >&2
    cat "$export_dir/manifest.json" >&2 || true
    return 1
  fi

  local attachment_path="${export_dir}/${exported_file_name}"
  if [[ ! -f "$attachment_path" ]]; then
    echo "Expected exported attachment missing: ${attachment_path}" >&2
    find "$export_dir" -maxdepth 2 -type f | sort >&2 || true
    return 1
  fi

  normalize_png "$attachment_path" "$output_path"
  rm -rf "$export_dir"
}

build_app

iphone_udid="$(find_udid "$IPHONE_DEVICE")"
ipad_udid="$(find_udid "$IPAD_DEVICE")"

if [[ -z "$iphone_udid" || -z "$ipad_udid" ]]; then
  echo "Could not find required simulators" >&2
  exit 1
fi

echo "==> Booting ${IPHONE_DEVICE}"
boot_device "$iphone_udid"

echo "==> Installing app on ${IPHONE_DEVICE}"
xcrun simctl uninstall "$iphone_udid" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$iphone_udid" "$APP_PATH" >/dev/null
sleep 2

screenshot_index=1
for scenario in "${SCENARIOS[@]}"; do
  printf -v ordered_name "%s-%02d-%s.png" "iphone" "$screenshot_index" "$scenario"
  raw_capture_path="${RESULTS_DIR}/raw-${ordered_name}"
  echo "==> Capturing ${ordered_name}"
  launch_for_iphone_screenshot "$iphone_udid" "$scenario"
  capture_screenshot "$iphone_udid" "$raw_capture_path"
  prepare_iphone_png \
    "$raw_capture_path" \
    "${FINAL_DIR}/${ordered_name}" \
    "$IPHONE_UPLOAD_WIDTH" \
    "$IPHONE_UPLOAD_HEIGHT"
  rm -f "$raw_capture_path"
  screenshot_index=$((screenshot_index + 1))
done

echo "==> Booting ${IPAD_DEVICE}"
boot_device "$ipad_udid"

ipad_tests=(
  "testIpadSavedSessionsScreenshot|ipad-01-saved-sessions"
  "testIpadNewSessionScreenshot|ipad-02-new-session"
  "testIpadTerminalScreenshot|ipad-03-terminal"
  "testIpadSessionPickerScreenshot|ipad-04-session-picker"
  "testIpadSettingsScreenshot|ipad-05-settings"
)

for entry in "${ipad_tests[@]}"; do
  IFS='|' read -r test_name attachment_name <<< "$entry"
  result_bundle="${IPAD_XCRESULT_DIR}/${attachment_name}.xcresult"
  echo "==> Capturing ${attachment_name}.png via UI test"
  run_ipad_ui_test "$test_name" "$result_bundle"
  export_ipad_attachment "$result_bundle" "$attachment_name" "${FINAL_DIR}/${attachment_name}.png"
done

echo

echo "Screenshots written to: ${FINAL_DIR}"
ls -1 "$FINAL_DIR"
