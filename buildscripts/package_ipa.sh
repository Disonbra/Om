#!/usr/bin/env bash
# package_ipa.sh [device|sim]
# Builds the iOS app and packages it.
# device: creates OpenMW.ipa (for physical phones)
# sim:    creates OpenMW_Simulator.zip (for iOS Simulator on Mac)

set -Eeuo pipefail

MODE="${1:-device}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCODE_BUILD_DIR="${REPO_DIR}/ios_build/xcode_output"

# 1. Setup platform-specific variables
if [[ "${MODE}" == "sim" ]]; then
    PLATFORM_TAG="sim"
    DESTINATION="generic/platform=iOS Simulator"
    BUILD_SUBDIR="Release-iphonesimulator"
    OUT_NAME="OpenMW_Simulator.zip"

    # Force arm64 simulator build.
    EXTRA_XCODE_ARGS=("ARCHS=arm64")

    echo ">>>> MODE: Simulator (Architecture: arm64) <<<<"
else
    PLATFORM_TAG="device"
    DESTINATION="generic/platform=iOS"
    BUILD_SUBDIR="Release-iphoneos"
    OUT_NAME="OpenMW.ipa"

    EXTRA_XCODE_ARGS=()

    echo ">>>> MODE: Physical Device (IPA) <<<<"
fi

echo "=== 1. Staging libraries for ${MODE} ==="
"${REPO_DIR}/buildscripts/stage_app_libs.sh" "${PLATFORM_TAG}"

# Select platform-specific frameworks for the Xcode build.
# Xcode copies dependencies from iosApp/EmbeddedLibs.
if [[ "${MODE}" == "sim" ]]; then
    PLATFORM_LIBS_DIR="${REPO_DIR}/iosApp/EmbeddedLibsSim"
else
    PLATFORM_LIBS_DIR="${REPO_DIR}/iosApp/EmbeddedLibsDevice"
fi

COMMON_LIBS_DIR="${REPO_DIR}/iosApp/EmbeddedLibs"

if [[ ! -d "${PLATFORM_LIBS_DIR}" ]]; then
    echo "ERROR: Missing platform libraries directory:"
    echo "  ${PLATFORM_LIBS_DIR}" >&2
    exit 1
fi

rm -rf "${COMMON_LIBS_DIR}"
mkdir -p "${COMMON_LIBS_DIR}"

cp -R \
    "${PLATFORM_LIBS_DIR}/." \
    "${COMMON_LIBS_DIR}/"

echo "=== Selected libraries from ${PLATFORM_LIBS_DIR} ==="
find "${COMMON_LIBS_DIR}" -maxdepth 2 -print | sort

if [[ ! -f "${COMMON_LIBS_DIR}/libbz2.1.framework/libbz2.1" ]]; then
    echo "ERROR: libbz2.1.framework was not selected" >&2
    find "${PLATFORM_LIBS_DIR}" -iname '*bz2*' -print >&2
    exit 1
fi

echo "=== 2. Patching shaders for ${MODE} ==="
"${REPO_DIR}/buildscripts/patch_shaders.sh"

echo "=== 3. Cleaning project and environment ==="
unset ANDROID_PREFS_ROOT || true
unset ANDROID_USER_HOME || true

cd "${REPO_DIR}"
./gradlew clean --no-configuration-cache

echo "=== 4. Building iosApp (${MODE}, Release) ==="
mkdir -p "${XCODE_BUILD_DIR}"

xcodebuild \
    -project "${REPO_DIR}/iosApp/iosApp.xcodeproj" \
    -scheme iosApp \
    -configuration Release \
    -destination "${DESTINATION}" \
    -derivedDataPath "${XCODE_BUILD_DIR}" \
    "${EXTRA_XCODE_ARGS[@]}" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO

echo "=== 5. Locating built .app bundle ==="

APP_PATH="$(
    find "${XCODE_BUILD_DIR}/Build/Products/${BUILD_SUBDIR}" \
        -maxdepth 1 \
        -type d \
        -name "*.app" \
        -print \
        -quit
)"

if [[ -z "${APP_PATH}" ]]; then
    echo "ERROR: Could not find built .app file in:" >&2
    echo "  ${XCODE_BUILD_DIR}/Build/Products/${BUILD_SUBDIR}" >&2
    exit 1
fi

APP_NAME="$(basename "${APP_PATH}")"
echo "Found app: ${APP_NAME}"

echo "=== 6. Creating package: ${OUT_NAME} ==="

rm -rf "${REPO_DIR}/Payload"
mkdir -p "${REPO_DIR}/Payload"

cp -R \
    "${APP_PATH}" \
    "${REPO_DIR}/Payload/"

cd "${REPO_DIR}"
rm -f "${OUT_NAME}"

zip -r "${OUT_NAME}" Payload > /dev/null

rm -rf "${REPO_DIR}/Payload"

echo "=== Done! ==="
echo "Successfully created: ${REPO_DIR}/${OUT_NAME}"

if [[ "${MODE}" == "sim" ]]; then
    echo "Note: To install on a simulator, unzip and drag the .app folder onto the Simulator window."
fi
