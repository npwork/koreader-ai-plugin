#!/bin/sh
# Called by KPM with the package directory as the working directory.
set -e

KOREADER_DIR="${KOREADER_DIR:-/mnt/us/koreader}"
PLUGIN_NAME="aidict.koplugin"
TARGET="${KOREADER_DIR}/plugins/${PLUGIN_NAME}"

if [ ! -d "${KOREADER_DIR}" ]; then
    echo "KOReader was not found at ${KOREADER_DIR}."
    echo "Install KOReader first, then run this again."
    exit 1
fi

mkdir -p "${KOREADER_DIR}/plugins"
# Replace rather than merge, so no stale file from an older version survives.
rm -rf "${TARGET}"
mkdir -p "${TARGET}"
cp -r "${PLUGIN_NAME}/." "${TARGET}/"

if [ "$1" = "upgrade" ]; then
    echo "Updated AI dictionary in ${TARGET}."
else
    echo "Installed AI dictionary into ${TARGET}."
fi
echo "Restart KOReader to load it."
