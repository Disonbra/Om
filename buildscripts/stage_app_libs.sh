#!/bin/bash
# Stages the engine dylibs from the ios_build tree into the app's
# per-platform embedded-library directories. Run after build_ios.sh.
#
#   ./buildscripts/stage_app_libs.sh            # stage both platforms
#   ./buildscripts/stage_app_libs.sh device     # device only
#   ./buildscripts/stage_app_libs.sh sim        # simulator only
#
# The Xcode project's "Select Platform Libraries" build phase copies the
# right set into iosApp/EmbeddedLibs/ at build time.
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${REPO_DIR}/ios_build"
OPENMW_SRC=$(ls -d "${WORK_DIR}/src/"openmw-* 2>/dev/null | head -1)

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

package_as_framework() {
    local dylib_path="$1"
    local dest_dir="$2"
    local base_name="$(basename "$dylib_path")"
    local fw_name="${base_name%.dylib}"
    
    local fw_dir="${dest_dir}/${fw_name}.framework"
    mkdir -p "${fw_dir}"
    
    # Copy the file into the framework
    cp -L "${dylib_path}" "${fw_dir}/${fw_name}"
    
    # Update its own id
    install_name_tool -id "@rpath/${fw_name}.framework/${fw_name}" "${fw_dir}/${fw_name}" 2>/dev/null || true
    
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
}

stage_platform() {
    local platform="$1" dest="$2" openmw_config="$3"
    local prefix="${WORK_DIR}/ios-libs/${platform}"
    local assets_dest="${REPO_DIR}/iosApp/OpenMWAssets"
    mkdir -p "${dest}"
    mkdir -p "${assets_dest}"

    local fw_names=()
    for lib in "${DYLIBS[@]}"; do
        if [ ! -e "${prefix}/lib/${lib}" ]; then
            echo "MISSING: ${prefix}/lib/${lib} (run build_ios.sh first)" >&2
            exit 1
        fi
        package_as_framework "${prefix}/lib/${lib}" "${dest}"
        fw_names+=("${lib%.dylib}")
    done

    # Copy resources to OpenMWAssets
    local resources_src="${OPENMW_SRC}/build_openmw_${platform}/OpenMW.app/Contents/Resources"
    for res in "${RESOURCES[@]}"; do
        if [ -e "${resources_src}/${res}" ]; then
            cp -L "${resources_src}/${res}" "${assets_dest}/${res}"
            echo "Copied ${res} to OpenMWAssets"
        elif [ -e "${resources_src}/${openmw_config}/${res}" ]; then
            cp -L "${resources_src}/${openmw_config}/${res}" "${assets_dest}/${res}"
            echo "Copied ${openmw_config}/${res} to OpenMWAssets"
        else
            echo "WARNING: Resource ${res} not found in ${resources_src} (or ${openmw_config}/ subfolder)"
        fi
    done

    # Copy default settings.cfg from buildscripts
    if [ -f "${REPO_DIR}/buildscripts/settings.cfg" ]; then
        cp "${REPO_DIR}/buildscripts/settings.cfg" "${assets_dest}/settings.cfg"
        echo "Copied default settings.cfg to OpenMWAssets"
    fi

    # Copy pointer_arrow.png from buildscripts
    if [ -f "${REPO_DIR}/buildscripts/UI/pointer_arrow.png" ]; then
        cp "${REPO_DIR}/buildscripts/UI/pointer_arrow.png" "${assets_dest}/pointer_arrow.png"
        echo "Copied pointer_arrow.png to OpenMWAssets"
    elif [ -f "${REPO_DIR}/buildscripts/pointer_arrow.png" ]; then
        cp "${REPO_DIR}/buildscripts/pointer_arrow.png" "${assets_dest}/pointer_arrow.png"
        echo "Copied pointer_arrow.png to OpenMWAssets"
    fi

    # Copy the resources folder (always from Release)
    if [ -d "${resources_src}/Release/resources" ]; then
        echo "Copying resources folder from Release..."
        rm -rf "${assets_dest}/resources"
        cp -R "${resources_src}/Release/resources" "${assets_dest}/resources"
        echo "Copied resources folder to OpenMWAssets"
    fi

    # Fix openmw.cfg to use local paths
    if [ -f "${assets_dest}/openmw.cfg" ]; then
        sed -i '' 's|\${OPENMW_RESOURCE_FILES}|resources|g' "${assets_dest}/openmw.cfg"
        sed -i '' 's|resources=../Resources/resources|resources=resources|g' "${assets_dest}/openmw.cfg"
        sed -i '' 's|data=../Resources/resources/vfs-mw|data=resources/vfs-mw|g' "${assets_dest}/openmw.cfg"
    fi



    # libopenmw comes from the engine build dir (the buildscript does not
    # install it into the prefix).
    local openmw=""
    # Check candidates: prefix, then the requested config, then fallbacks
    local candidates=(
        "${prefix}/lib/libopenmw.dylib"
        "${OPENMW_SRC}/build_openmw_${platform}/OpenMW.app/Contents/MacOS/${openmw_config}/libopenmw.dylib"
        "${OPENMW_SRC}/build_openmw_${platform}/OpenMW.app/Contents/MacOS/Release/libopenmw.dylib"
        "${OPENMW_SRC}/build_openmw_${platform}/OpenMW.app/Contents/MacOS/Debug/libopenmw.dylib"
        "${OPENMW_SRC}/build_openmw_${platform}/OpenMW.app/Contents/MacOS/RelWithDebInfo/libopenmw.dylib"
    )

    for candidate in "${candidates[@]}"; do
        if [ -e "${candidate}" ]; then openmw="${candidate}"; break; fi
    done
    if [ -z "${openmw}" ]; then
        echo "MISSING: libopenmw.dylib for ${platform} (build OpenMW first)" >&2
        exit 1
    fi
    package_as_framework "${openmw}" "${dest}"
    fw_names+=("libopenmw")
    
    # Fix up cross-references
    for fw in "${fw_names[@]}"; do
        local target_bin="${dest}/${fw}.framework/${fw}"
        local linked_libs=$(otool -L "${target_bin}" | awk 'NR>1 {print $1}')
        for linked in $linked_libs; do
            for dep_fw in "${fw_names[@]}"; do
                if [[ "${linked}" == *"${dep_fw}.dylib" ]]; then
                    install_name_tool -change "${linked}" "@rpath/${dep_fw}.framework/${dep_fw}" "${target_bin}" 2>/dev/null || true
                fi
            done
        done
        codesign -f -s - "${target_bin}" 2>/dev/null || true
    done
    echo "Staged ${platform} -> ${dest}"
}

case "${1:-both}" in
    device) stage_platform OS64 "${REPO_DIR}/iosApp/EmbeddedLibsDevice" Release ;;
    sim)    stage_platform SIMULATORARM64 "${REPO_DIR}/iosApp/EmbeddedLibsSim" Release ;;
    both)
        stage_platform OS64 "${REPO_DIR}/iosApp/EmbeddedLibsDevice" Release
        stage_platform SIMULATORARM64 "${REPO_DIR}/iosApp/EmbeddedLibsSim" Release
        ;;
    *) echo "usage: $0 [device|sim|both]" >&2; exit 1 ;;
esac
