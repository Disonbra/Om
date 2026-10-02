#!/bin/bash
# Stages engine dylibs from ios_build into the app's embedded-library directories.
#
#   ./buildscripts/stage_app_libs.sh
#   ./buildscripts/stage_app_libs.sh device
#   ./buildscripts/stage_app_libs.sh sim
#
# The Xcode project copies the appropriate platform directory into the app.

set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${REPO_DIR}/ios_build"
OPENMW_SRC="$(find "${WORK_DIR}/src" -maxdepth 1 -type d -name 'openmw-*' -print -quit)"

if [[ -z "${OPENMW_SRC}" || ! -d "${OPENMW_SRC}" ]]; then
    echo "ERROR : OpenMW source directory was not found under ${WORK_DIR}/src" >&2
    exit 1
fi

# These are the real files produced by build_ios.sh.
# Do not shorten these names here.
DYLIBS=(
    libSDL2-2.0.0.dylib
    libopenal.1.24.3.dylib
    libcollada-dom2.5-dp.2.5.0.dylib
    libjpeg.62.4.0.dylib
    libz.1.3.2.dylib
)

RESOURCES=(
    defaults.bin
    gamecontrollerdb.txt
    openmw.cfg
)

# Converts a real dylib filename into the framework name expected by Xcode.
framework_name_for_dylib() {
    local base_name="$1"
    local dylib_name="${base_name%.dylib}"

    case "${dylib_name}" in
        libopenal.1.24.3)
            printf '%s\n' "libopenal.1"
            ;;
        libjpeg.62.4.0)
            printf '%s\n' "libjpeg.62"
            ;;
        libz.1.3.2)
            printf '%s\n' "libz.1"
            ;;
        libcollada-dom2.5-dp.2.5.0)
            printf '%s\n' "libcollada-dom2.5-dp.0"
            ;;
        *)
            printf '%s\n' "${dylib_name}"
            ;;
    esac
}

# Creates a framework directory and returns its logical framework name.
package_as_framework() {
    local dylib_path="$1"
    local dest_dir="$2"
    local base_name
    local fw_name
    local fw_dir

    base_name="$(basename "${dylib_path}")"
    fw_name="$(framework_name_for_dylib "${base_name}")"
    fw_dir="${dest_dir}/${fw_name}.framework"

    rm -rf "${fw_dir}"
    mkdir -p "${fw_dir}"

    cp -L "${dylib_path}" "${fw_dir}/${fw_name}"

    install_name_tool \
        -id "@rpath/${fw_name}.framework/${fw_name}" \
        "${fw_dir}/${fw_name}" \
        2>/dev/null || true

    cat > "${fw_dir}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${fw_name}</string>
    <key>CFBundleIdentifier</key>
    <string>org.openmw.${fw_name//./}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${fw_name}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>15.6</string>
</dict>
</plist>
PLIST

    printf '%s\n' "${fw_name}"
}

stage_platform() {
    local platform="$1"
    local dest="$2"
    local openmw_config="$3"

    local prefix="${WORK_DIR}/ios-libs/${platform}"
    local assets_dest="${REPO_DIR}/iosApp/OpenMWAssets"

    mkdir -p "${dest}"
    mkdir -p "${assets_dest}"

    local fw_names=()

    # Package dependency dylibs as frameworks.
    for lib in "${DYLIBS[@]}"; do
        local dylib_path="${prefix}/lib/${lib}"

        if [[ ! -f "${dylib_path}" ]]; then
            echo "MISSING: ${dylib_path}" >&2
            echo "Run build_ios.sh first or check the native build output." >&2
            exit 1
        fi

        local fw_name
        fw_name="$(package_as_framework "${dylib_path}" "${dest}")"
        fw_names+=("${fw_name}")
    done

    # Copy resources from the OpenMW build output.
    local resources_src="${OPENMW_SRC}/build_openmw_${platform}/OpenMW.app/Contents/Resources"

    for res in "${RESOURCES[@]}"; do
        if [[ -f "${resources_src}/${res}" ]]; then
            cp -L "${resources_src}/${res}" "${assets_dest}/${res}"
            echo "Copied ${res} to OpenMWAssets"
        elif [[ -f "${resources_src}/${openmw_config}/${res}" ]]; then
            cp -L \
                "${resources_src}/${openmw_config}/${res}" \
                "${assets_dest}/${res}"
            echo "Copied ${openmw_config}/${res} to OpenMWAssets"
        else
            echo "WARNING: ${res} was not found in ${resources_src}"
        fi
    done

    # Copy default settings.cfg.
    if [[ -f "${REPO_DIR}/buildscripts/settings.cfg" ]]; then
        cp \
            "${REPO_DIR}/buildscripts/settings.cfg" \
            "${assets_dest}/settings.cfg"
        echo "Copied default settings.cfg to OpenMWAssets"
    fi

    # Copy pointer_arrow.png.
    if [[ -f "${REPO_DIR}/buildscripts/UI/pointer_arrow.png" ]]; then
        cp \
            "${REPO_DIR}/buildscripts/UI/pointer_arrow.png" \
            "${assets_dest}/pointer_arrow.png"
        echo "Copied pointer_arrow.png to OpenMWAssets"
    elif [[ -f "${REPO_DIR}/buildscripts/pointer_arrow.png" ]]; then
        cp \
            "${REPO_DIR}/buildscripts/pointer_arrow.png" \
            "${assets_dest}/pointer_arrow.png"
        echo "Copied pointer_arrow.png to OpenMWAssets"
    fi

    # Copy resources from the Release configuration.
    if [[ -d "${resources_src}/Release/resources" ]]; then
        echo "Copying resources folder from Release..."
        rm -rf "${assets_dest}/resources"
        cp -R \
            "${resources_src}/Release/resources" \
            "${assets_dest}/resources"
        echo "Copied resources folder to OpenMWAssets"
    fi

    # Fix openmw.cfg to use paths inside the app.
    if [[ -f "${assets_dest}/openmw.cfg" ]]; then
        sed -i '' \
            's|\${OPENMW_RESOURCE_FILES}|resources|g' \
            "${assets_dest}/openmw.cfg"

        sed -i '' \
            's|resources=../Resources/resources|resources=resources|g' \
            "${assets_dest}/openmw.cfg"

        sed -i '' \
            's|data=../Resources/resources/vfs-mw|data=resources/vfs-mw|g' \
            "${assets_dest}/openmw.cfg"
    fi

    # libopenmw.dylib is produced in the OpenMW build directory.
    local openmw=""
    local candidates=(
        "${prefix}/lib/libopenmw.dylib"
        "${OPENMW_SRC}/build_openmw_${platform}/OpenMW.app/Contents/MacOS/${openmw_config}/libopenmw.dylib"
        "${OPENMW_SRC}/build_openmw_${platform}/OpenMW.app/Contents/MacOS/Release/libopenmw.dylib"
        "${OPENMW_SRC}/build_openmw_${platform}/OpenMW.app/Contents/MacOS/Debug/libopenmw.dylib"
        "${OPENMW_SRC}/build_openmw_${platform}/OpenMW.app/Contents/MacOS/RelWithDebInfo/libopenmw.dylib"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -f "${candidate}" ]]; then
            openmw="${candidate}"
            break
        fi
    done

    if [[ -z "${openmw}" ]]; then
        echo "MISSING: libopenmw.dylib for ${platform}" >&2
        echo "Checked OpenMW build output under ${OPENMW_SRC}" >&2
        exit 1
    fi

    local openmw_fw_name
    openmw_fw_name="$(package_as_framework "${openmw}" "${dest}")"
    fw_names+=("${openmw_fw_name}")

    # Rewrite dependency install names to the embedded framework paths.
    for fw in "${fw_names[@]}"; do
        local target_bin="${dest}/${fw}.framework/${fw}"

        if [[ ! -f "${target_bin}" ]]; then
            echo "WARNING: framework binary not found: ${target_bin}" >&2
            continue
        fi

        while IFS= read -r linked; do
            [[ -z "${linked}" ]] && continue

            for dep_fw in "${fw_names[@]}"; do
                local old_name=""
                local new_name="@rpath/${dep_fw}.framework/${dep_fw}"

                case "${dep_fw}" in
                    libopenal.1)
                        old_name="libopenal.1.24.3.dylib"
                        ;;
                    libjpeg.62)
                        old_name="libjpeg.62.4.0.dylib"
                        ;;
                    libz.1)
                        old_name="libz.1.3.2.dylib"
                        ;;
                    libcollada-dom2.5-dp.0)
                        old_name="libcollada-dom2.5-dp.2.5.0.dylib"
                        ;;
                    libSDL2-2.0.0)
                        old_name="libSDL2-2.0.0.dylib"
                        ;;
                    libopenmw)
                        old_name="libopenmw.dylib"
                        ;;
                    *)
                        continue
                        ;;
                esac

                if [[ "${linked}" == *"${old_name}" ]]; then
                    install_name_tool \
                        -change "${linked}" \
                        "${new_name}" \
                        "${target_bin}" \
                        2>/dev/null || true
                fi
            done
        done < <(otool -L "${target_bin}" | tail -n +2 | awk '{print $1}')

        codesign -f -s - "${target_bin}" 2>/dev/null || true
    done

    echo "Staged ${platform} -> ${dest}"
}

case "${1:-both}" in
    device)
        stage_platform \
            OS64 \
            "${REPO_DIR}/iosApp/EmbeddedLibsDevice" \
            Release
        ;;
    sim)
        stage_platform \
            SIMULATORARM64 \
            "${REPO_DIR}/iosApp/EmbeddedLibsSim" \
            Release
        ;;
    both)
        stage_platform \
            OS64 \
            "${REPO_DIR}/iosApp/EmbeddedLibsDevice" \
            Release

        stage_platform \
            SIMULATORARM64 \
            "${REPO_DIR}/iosApp/EmbeddedLibsSim" \
            Release
        ;;
    *)
        echo "usage: $0 [device|sim|both]" >&2
        exit 1
        ;;
esac
