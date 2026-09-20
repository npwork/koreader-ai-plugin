#!/bin/sh
# Called by KPM before the package is removed.
set -e

KOREADER_DIR="${KOREADER_DIR:-/mnt/us/koreader}"
TARGET="${KOREADER_DIR}/plugins/aidict.koplugin"

rm -rf "${TARGET}"

if [ "$1" = "upgrade" ]; then
    echo "Removed the old AI dictionary files."
else
    echo "Removed AI dictionary from ${TARGET}."
    echo "Settings stay in ${KOREADER_DIR}/settings/aidict.lua."
fi
