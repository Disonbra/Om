#!/usr/bin/env bash

set -Eeuo pipefail

MODE="${1:-device}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

WORK_DIR="${REPO_DIR}/ios_build"
XCODE_BUILD_DIR="${WORK_DIR}/xcode_output"
LOG_DIR="${WORK_DIR}/logs"

mkdir -p "${LOG_DIR}"

LOG_FILE="${LOG_DIR}/package_${MODE}.log"

exec > >(tee -a "${LOG_FILE}") 2>&1

echo "=== package_ipa.sh started at $(date) ==="

# ------------------------------------------------------------
# Mode configuration
# ------------------------------------------------------------

case "${MODE}" in
    device)
        PLATFORM_TAG="device"
        DESTINATION="generic/platform=iOS"
        BUILD_SUBDIR="Release-iphoneos"
        OUT_NAME="OpenMW.ipa"
        EXTRA_XCODE_ARGS=()
        ;;

    sim)
        PLATFORM_TAG="sim"
        DESTINATION="generic/platform=iOS Simulator"
        BUILD_SUBDIR="Release-iphonesimulator"
        OUT_NAME="OpenMW_Simulator.zip"
        EXTRA_XCODE_ARGS=(
            "ARCHS=arm64"
            "ONLY_ACTIVE_ARCH=NO"
        )
        ;;

    *)
        echo "Usage: $0 [device|sim]" >&2
        exit 2
        ;;
esac

echo "MODE=${MODE}"
echo "PLATFORM_TAG=${PLATFORM_TAG}"
echo "REPO_DIR=${REPO_DIR}"
echo "WORK_DIR=${WORK_DIR}"
echo "XCODE_BUILD_DIR=${XCODE_BUILD_DIR}"

# ------------------------------------------------------------
# Environment
# ------------------------------------------------------------

unset ANDROID_PREFS_ROOT || true
unset ANDROID_USER_HOME || true
unset ANDROID_SDK_HOME || true
unset ANDROID_HOME || true

export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-26.2}"
export DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-26.2}"

echo "IPHONEOS_DEPLOYMENT_TARGET=${IPHONEOS_DEPLOYMENT_TARGET}"
echo "DEPLOYMENT_TARGET=${DEPLOYMENT_TARGET}"

# ------------------------------------------------------------
# Validate scripts
# ------------------------------------------------------------

STAGE_SCRIPT="${SCRIPT_DIR}/stage_app_libs.sh"
PATCH_SCRIPT="${SCRIPT_DIR}/patch_shaders.sh"

if [[ ! -f "${STAGE_SCRIPT}" ]]; then
    echo "ERROR: stage_app_libs.sh was not found:"
    echo "${STAGE_SCRIPT}"
    exit 1
fi

if [[ ! -f "${PATCH_SCRIPT}" ]]; then
    echo "ERROR: patch_shaders.sh was not found:"
    echo "${PATCH_SCRIPT}"
    exit 1
fi

chmod +x "${STAGE_SCRIPT}" "${PATCH_SCRIPT}"

# ------------------------------------------------------------
# Stage libraries and resources
# ------------------------------------------------------------

echo "=== 1. Staging libraries and resources ==="

bash "${STAGE_SCRIPT}" "${PLATFORM_TAG}"

# ------------------------------------------------------------
# Locate generated shaders
# ------------------------------------------------------------

echo "=== 2. Locating generated shaders ==="

ASSETS_DIR="${REPO_DIR}/iosApp/OpenMWAssets"

if [[ ! -d "${ASSETS_DIR}" ]]; then
    echo "ERROR: OpenMWAssets directory was not created:"
    echo "${ASSETS_DIR}"
    exit 1
fi

SHADERS_DIR="$(
    find "${ASSETS_DIR}" \
        -type d \
        -path "*/resources/shaders" \
        -print -quit || true
)"

if [[ -z "${SHADERS_DIR}" ]]; then
    echo "ERROR: generated shader directory was not found."

    echo
    echo "OpenMWAssets tree:"
    find "${ASSETS_DIR}" \
        -maxdepth 8 \
        -print | sort || true

    echo
    echo "Shader files:"
    find "${ASSETS_DIR}" \
        -type f \
        \( \
            -name "*.vert" \
            -o -name "*.frag" \
            -o -name "*.comp" \
            -o -name "*.glsl" \
        \) \
        -print | sort || true

    exit 1
fi

echo "Shaders directory:"
echo "${SHADERS_DIR}"

# ------------------------------------------------------------
# Patch shaders
# ------------------------------------------------------------

echo "=== 3. Patching shaders ==="

bash "${PATCH_SCRIPT}" "${SHADERS_DIR}"

# ------------------------------------------------------------
# Locate Xcode project
# ------------------------------------------------------------

echo "=== 4. Locating Xcode project ==="

XCODE_PROJECT="$(
    find "${REPO_DIR}/iosApp" \
        -type d \
        -name "*.xcodeproj" \
        -print -quit
)"

if [[ -z "${XCODE_PROJECT}" ]]; then
    echo "ERROR: Xcode project was not found under:"
    echo "${REPO_DIR}/iosApp"
    exit 1
fi

echo "Xcode project:"
echo "${XCODE_PROJECT}"

# ------------------------------------------------------------
# Build
# ------------------------------------------------------------

echo "=== 5. Building iosApp (${MODE}, Release) ==="

mkdir -p "${XCODE_BUILD_DIR}"

xcodebuild \
    -project "${XCODE_PROJECT}" \
    -scheme iosApp \
    -configuration Release \
    -destination "${DESTINATION}" \
    -derivedDataPath "${XCODE_BUILD_DIR}" \
    "${EXTRA_XCODE_ARGS[@]}" \
    IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET}" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    build

# ------------------------------------------------------------
# Locate app
# ------------------------------------------------------------

echo "=== 6. Locating built app ==="

PRODUCTS_DIR="${XCODE_BUILD_DIR}/Build/Products/${BUILD_SUBDIR}"

if [[ ! -d "${PRODUCTS_DIR}" ]]; then
    echo "ERROR: products directory was not found:"
    echo "${PRODUCTS_DIR}"
    exit 1
fi

APP_PATH="$(
    find "${PRODUCTS_DIR}" \
        -maxdepth 1 \
        -type d \
        -name "*.app" \
        -print -quit
)"

if [[ -z "${APP_PATH}" ]]; then
    echo "ERROR: no .app bundle was found in:"
    echo "${PRODUCTS_DIR}"

    find "${PRODUCTS_DIR}" \
        -maxdepth 2 \
        -print | sort || true

    exit 1
fi

APP_NAME="$(basename "${APP_PATH}")"

echo "APP_PATH=${APP_PATH}"
echo "APP_NAME=${APP_NAME}"

# ------------------------------------------------------------
# Verify app
# ------------------------------------------------------------

echo "=== 7. Verifying app ==="

if [[ ! -f "${APP_PATH}/Info.plist" ]]; then
    echo "ERROR: Info.plist was not found:"
    echo "${APP_PATH}/Info.plist"
    exit 1
fi

APP_EXECUTABLE="$(
    /usr/libexec/PlistBuddy \
        -c "Print :CFBundleExecutable" \
        "${APP_PATH}/Info.plist"
)"

APP_EXECUTABLE_PATH="${APP_PATH}/${APP_EXECUTABLE}"

if [[ ! -f "${APP_EXECUTABLE_PATH}" ]]; then
    echo "ERROR: application executable was not found:"
    echo "${APP_EXECUTABLE_PATH}"
    exit 1
fi

echo "Application executable:"
file "${APP_EXECUTABLE_PATH}"
lipo -info "${APP_EXECUTABLE_PATH}" || true

# ------------------------------------------------------------
# Package
# ------------------------------------------------------------

echo "=== 8. Creating ${OUT_NAME} ==="

OUTPUT_PATH="${REPO_DIR}/${OUT_NAME}"
PACKAGE_ROOT="${WORK_DIR}/package_${MODE}"

rm -rf "${PACKAGE_ROOT}" "${OUTPUT_PATH}"

if [[ "${MODE}" == "device" ]]; then
    mkdir -p "${PACKAGE_ROOT}/Payload"

    cp -R \
        "${APP_PATH}" \
        "${PACKAGE_ROOT}/Payload/"

    (
        cd "${PACKAGE_ROOT}"
        zip -qry "${OUTPUT_PATH}" Payload
    )
else
    mkdir -p "${PACKAGE_ROOT}"

    cp -R \
        "${APP_PATH}" \
        "${PACKAGE_ROOT}/"

    (
        cd "${PACKAGE_ROOT}"
        zip -qry "${OUTPUT_PATH}" "${APP_NAME}" \
            -x "*.DS_Store"
    )
fi

# ------------------------------------------------------------
# Verify package
# ------------------------------------------------------------

if [[ ! -f "${OUTPUT_PATH}" ]]; then
    echo "ERROR: package was not created:"
    echo "${OUTPUT_PATH}"
    exit 1
fi

echo "Created package:"
echo "${OUTPUT_PATH}"

ls -lh "${OUTPUT_PATH}"

echo
echo "Package contents:"
unzip -l "${OUTPUT_PATH}"

if [[ "${MODE}" == "device" ]]; then
    if ! unzip -l "${OUTPUT_PATH}" | grep -q "Payload/.*\.app/"; then
        echo "ERROR: device package does not contain Payload/*.app"
        exit 1
    fi
fi

echo
echo "=== package_ipa.sh completed successfully ==="
