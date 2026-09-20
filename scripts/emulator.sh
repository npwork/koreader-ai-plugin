#!/bin/sh
# Run KOReader with this plugin loaded, headlessly.
#
#   ./scripts/emulator.sh                       use $KOREADER_SRC or .emulator/
#   KOREADER_DOWNLOAD_URL=<url> ./scripts/emulator.sh   fetch a prebuilt Linux build first
#
# See docs/emulator.md for what the cloud environment needs allowed before
# either of those can reach anything.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMULATOR_DIR="${EMULATOR_DIR:-${ROOT}/.emulator}"
PLUGIN="${ROOT}/plugin/aidict.koplugin"

fetch_build() {
    url="$1"
    mkdir -p "${EMULATOR_DIR}"
    archive="${EMULATOR_DIR}/$(basename "${url}")"
    echo "Downloading ${url}"
    if ! curl -fSL --retry 2 -o "${archive}" "${url}"; then
        echo
        echo "The download was refused. In a cloud session this is almost always"
        echo "the environment's allowed-domain list — see docs/emulator.md."
        exit 1
    fi
    case "${archive}" in
        *.tar.xz | *.tar.gz | *.txz) tar xf "${archive}" -C "${EMULATOR_DIR}" ;;
        *.AppImage)
            chmod +x "${archive}"
            (cd "${EMULATOR_DIR}" && "${archive}" --appimage-extract >/dev/null)
            ;;
        *) echo "Don't know how to unpack ${archive}"; exit 1 ;;
    esac
}

if [ -n "${KOREADER_DOWNLOAD_URL}" ]; then
    fetch_build "${KOREADER_DOWNLOAD_URL}"
fi

# Where did we end up? Either a source checkout built with kodev, or an
# unpacked release.
find_reader() {
    for candidate in "$1" "$1/koreader" "$1/koreader-emulator-x86_64-linux-gnu/koreader" "$1/squashfs-root/usr/lib/koreader"; do
        if [ -f "${candidate}/reader.lua" ]; then
            echo "${candidate}"
            return 0
        fi
    done
    found="$(find "$1" -maxdepth 5 -name reader.lua -type f 2>/dev/null | head -1)"
    if [ -n "${found}" ]; then
        echo "${found%/reader.lua}"
    fi
    return 0
}

if [ -n "${KOREADER_SRC}" ]; then
    KOREADER_RUN_DIR="$(find_reader "${KOREADER_SRC}")"
else
    KOREADER_RUN_DIR="$(find_reader "${EMULATOR_DIR}")"
fi

if [ -z "${KOREADER_RUN_DIR}" ] || [ ! -f "${KOREADER_RUN_DIR}/reader.lua" ]; then
    echo "No KOReader build found."
    echo "Set KOREADER_SRC to a built checkout, or KOREADER_DOWNLOAD_URL to a Linux build."
    echo "docs/emulator.md explains both."
    exit 1
fi

echo "Using KOReader at ${KOREADER_RUN_DIR}"
mkdir -p "${KOREADER_RUN_DIR}/plugins"
rm -rf "${KOREADER_RUN_DIR}/plugins/aidict.koplugin"
ln -s "${PLUGIN}" "${KOREADER_RUN_DIR}/plugins/aidict.koplugin"

cd "${KOREADER_RUN_DIR}"
if [ -n "${DISPLAY}" ]; then
    exec ./reader.lua -d "$@"
fi

command -v xvfb-run >/dev/null || { echo "Install xvfb, or set DISPLAY."; exit 1; }
exec xvfb-run -a --server-args="-screen 0 600x800x24" ./reader.lua -d "$@"
