#!/bin/bash
# package_ipa.sh [device|sim]
# Builds the iOS app and packages it.
# device: creates OpenMW.ipa (for physical phones)
# sim:    creates OpenMW_Simulator.zip (for iOS Simulator on Mac)

set -e

MODE="${1:-device}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCODE_BUILD_DIR="${REPO_DIR}/ios_build/xcode_output"

# 1. Setup platform specific variables
if [ "${MODE}" == "sim" ]; then
    PLATFORM_TAG="sim"
    DESTINATION="generic/platform=iOS Simulator"
    BUILD_SUBDIR="Release-iphonesimulator"
    OUT_NAME="OpenMW_Simulator.zip"
    # We force arm64 for the simulator to avoid Gradle/Compose issues with multi-arch strings
    EXTRA_XCODE_ARGS="ARCHS=arm64"
    echo ">>>> MODE: Simulator (Architecture: arm64) <<<<"
else
    PLATFORM_TAG="device"
    DESTINATION="generic/platform=iOS"
    BUILD_SUBDIR="Release-iphoneos"
    OUT_NAME="OpenMW.ipa"
    EXTRA_XCODE_ARGS=""
    echo ">>>> MODE: Physical Device (IPA) <<<<"
fi

echo "=== 1. Staging libraries for ${MODE} ==="
"${REPO_DIR}/buildscripts/stage_app_libs.sh" "${PLATFORM_TAG}"

echo "=== 2. Patching Shaders for ${MODE} ==="
"${REPO_DIR}/buildscripts/patch_shaders.sh"

echo "=== 3. Cleaning project and environment ==="
# Unset variables that can conflict with the Gradle build phase in Xcode
unset ANDROID_PREFS_ROOT
unset ANDROID_USER_HOME

cd "${REPO_DIR}"
./gradlew clean --no-configuration-cache

echo "=== 4. Building iosApp (${MODE}, Release) ==="
mkdir -p "${XCODE_BUILD_DIR}"

xcodebuild -project "${REPO_DIR}/iosApp/iosApp.xcodeproj" \
           -scheme iosApp \
           -configuration Release \
           -destination "${DESTINATION}" \
           -derivedDataPath "${XCODE_BUILD_DIR}" \
           ${EXTRA_XCODE_ARGS} \
           CODE_SIGN_IDENTITY="" \
           CODE_SIGNING_REQUIRED=NO \
           CODE_SIGNING_ALLOWED=NO

echo "=== 5. Locating built .app bundle ==="
APP_PATH=$(find "${XCODE_BUILD_DIR}/Build/Products/${BUILD_SUBDIR}" -name "*.app" | head -1)

if [ -z "$APP_PATH" ]; then
    echo "ERROR: Could not find built .app file in ${XCODE_BUILD_DIR}/Build/Products/${BUILD_SUBDIR}"
    exit 1
fi

APP_NAME=$(basename "$APP_PATH")
echo "Found app: ${APP_NAME}"

echo "=== 6. Creating package: ${OUT_NAME} ==="
rm -rf "${REPO_DIR}/Payload"
mkdir -p "${REPO_DIR}/Payload"

# Copy the app bundle into the Payload folder
cp -R "${APP_PATH}" "${REPO_DIR}/Payload/"

cd "${REPO_DIR}"
rm -f "${OUT_NAME}"

# Zip it up
zip -r "${OUT_NAME}" Payload > /dev/null

# Cleanup
rm -rf Payload

echo "=== Done! ==="
echo "Successfully created: ${REPO_DIR}/${OUT_NAME}"
if [ "${MODE}" == "sim" ]; then
    echo "Note: To install on a simulator, unzip and drag the .app folder onto the Simulator window."
fi
