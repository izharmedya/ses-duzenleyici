#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-${ROOT_DIR}/build}"
if [[ "${OUTPUT_DIR}" != /* ]]; then
    OUTPUT_DIR="${ROOT_DIR}/${OUTPUT_DIR}"
fi
APP_NAME="Ses Düzenleyici"
EXECUTABLE_NAME="SesDuzenleyici"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ses-duzenleyici-build.XXXXXX")"
STAGED_APP="${STAGING_DIR}/${APP_NAME}.app"

cleanup() {
    rm -rf -- "${STAGING_DIR}"
}
trap cleanup EXIT

mkdir -p "${STAGED_APP}/Contents/MacOS" "${STAGED_APP}/Contents/Resources" "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd -- "${OUTPUT_DIR}" && pwd)"
DEST_APP="${OUTPUT_DIR}/${APP_NAME}.app"
PROJECT_APP="${ROOT_DIR}/${APP_NAME}.app"
if [[ "${DEST_APP}" == "${PROJECT_APP}" ]]; then
    printf 'Refusing to replace the app bundle in the source project. Use the default build/ folder.\n' >&2
    exit 1
fi
cp "${ROOT_DIR}/Info.plist" "${STAGED_APP}/Contents/Info.plist"

ARCH="$(uname -m)"
SDK_PATH="$(xcrun --show-sdk-path)"

xcrun swiftc \
    -O \
    -sdk "${SDK_PATH}" \
    -target "${ARCH}-apple-macosx14.2" \
    -import-objc-header "${ROOT_DIR}/RTAtomicBridge.h" \
    -framework SwiftUI \
    -framework AppKit \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework ServiceManagement \
    "${ROOT_DIR}/AudioDeviceManager.swift" \
    "${ROOT_DIR}/ProcessTapEngine.swift" \
    "${ROOT_DIR}/MixerPopoverView.swift" \
    "${ROOT_DIR}/App.swift" \
    -o "${STAGED_APP}/Contents/MacOS/${EXECUTABLE_NAME}"

codesign --force --deep --sign - "${STAGED_APP}"

# Publish only a fully compiled and signed bundle. The existing app in the project root is kept
# intact; the currently running copy is not interrupted by a source build.
rm -rf -- "${DEST_APP}"
mv "${STAGED_APP}" "${DEST_APP}"
printf 'Built app: %s\n' "${DEST_APP}"
