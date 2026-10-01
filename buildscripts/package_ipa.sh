#!/usr/bin/env bash

set -Eeuo pipefail

MODE="${1:-device}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

WORK_DIR="${REPO_DIR}/ios_build"
XCODE_BUILD_DIR="${WORK_DIR}/xcode_output"
LOG_DIR="${WORK_DIR}/logs"

mkdir -p "${LOG_DIR}"

exec > >(tee -a "${LOG_DIR}/package_${MODE}.log") 2>&1

echo "=== package_ipa.sh started at $(date) ==="
echo "MODE=${MODE}"
echo "REPO_DIR=${REPO_DIR}"

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
        EXTRA_XCODE_ARGS=("ARCHS=arm64" "ONLY_ACTIVE_ARCH=NO")
        ;;

    *)
        echo "Usage: $0 [device|sim]" >&2
        exit 2
        ;;
esac

echo "=== MODE: ${MODE} ==="

# ------------------------------------------------------------
# Environment
# ------------------------------------------------------------

unset ANDROID_PREFS_ROOT || true
unset ANDROID_USER_HOME || true
unset ANDROID_SDK_HOME || true
unset ANDROID_HOME || true

export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-26.2}"
export DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-26.2}"

# ------------------------------------------------------------
# Stage libraries and resources
# ------------------------------------------------------------

echo "=== 1. Staging libraries for ${MODE} ==="

bash "${SCRIPT_DIR}/stage_app_libs.sh" "${PLATFORM_TAG}"

# ------------------------------------------------------------
# Locate and patch generated shaders
# ------------------------------------------------------------

echo "=== 2. Locating generated shaders ==="

SHADERS_DIR="$(
    find "${REPO_DIR}/iosApp/OpenMWAssets" \
        -type d \
        -path "*/resources/shaders" \
        -print -quit || true
)"

if [[ -z "${SHADERS_DIR}" ]]; then
    echo "ERROR: generated shaders directory not found."
    echo
    echo "OpenMWAssets tree:"
    find "${REPO_DIR}/iosApp/OpenMWAssets" \
        -maxdepth 6 \
        -print | sort || true
    exit 1
fi

echo "Shaders directory: ${SHADERS_DIR}"

echo "=== 3. Patching shaders ==="

bash "${SCRIPT_DIR}/patch_shaders.sh" "${SHADERS_DIR}"

# ------------------------------------------------------------
# Find Xcode project
# ------------------------------------------------------------

XCODE_PROJECT="$(
    find "${REPO_DIR}/iosApp" \
        -type d \
        -name "*.xcodeproj" \
        -print -quit
)"

if [[ -z "${XCODE_PROJECT}" ]]; then
    echo "ERROR: Xcode project not found in ${REPO_DIR}/iosApp"
    exit 1
fi

echo "Xcode project: ${XCODE_PROJECT}"

# ------------------------------------------------------------
# Build
# ------------------------------------------------------------

echo "=== 4. Building iosApp ==="

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

echo "=== 5. Locating built app ==="

PRODUCTS_DIR="${XCODE_BUILD_DIR}/Build/Products/${BUILD_SUBDIR}"

if [[ ! -d "${PRODUCTS_DIR}" ]]; then
    echo "ERROR: products directory not found:"
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
    echo "ERROR: .app was not found in:"
    echo "${PRODUCTS_DIR}"
    find "${PRODUCTS_DIR}" -maxdepth 2 -print || true
    exit 1
fi

APP_NAME="$(basename "${APP_PATH}")"

echo "Found app: ${APP_PATH}"

# ------------------------------------------------------------
# Package
# ------------------------------------------------------------

echo "=== 6. Creating ${OUT_NAME} ==="

OUTPUT_PATH="${REPO_DIR}/${OUT_NAME}"
PACKAGE_ROOT="${WORK_DIR}/package_${MODE}"
PAYLOAD_DIR="${PACKAGE_ROOT}/Payload"

rm -rf "${PACKAGE_ROOT}" "${OUTPUT_PATH}"
mkdir -p "${PAYLOAD_DIR}"

cp -R "${APP_PATH}" "${PAYLOAD_DIR}/"

if [[ "${MODE}" == "device" ]]; then
    (
        cd "${PACKAGE_ROOT}"
        zip -qry "${OUTPUT_PATH}" Payload
    )
else
    (
        cd "${PACKAGE_ROOT}"
        zip -qry "${OUTPUT_PATH}" "${APP_NAME}" \
            -x "*.DS_Store"
    )
fi

if [[ ! -f "${OUTPUT_PATH}" ]]; then
    echo "ERROR: package was not created:"
    echo "${OUTPUT_PATH}"
    exit 1
fi

echo "Created:"
echo "${OUTPUT_PATH}"

ls -lh "${OUTPUT_PATH}"

echo
echo "Package contents:"
unzip -l "${OUTPUT_PATH}"

echo "=== package_ipa.sh completed ==="
