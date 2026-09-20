#!/bin/sh
# Build the package, then install, upgrade and uninstall it into a throwaway
# tree — the same steps KPM runs on the device, minus the device.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

python3 "${ROOT}/scripts/kpmrepo.py" package --output "${WORK}/dist" >/dev/null
PACKAGE="$(ls "${WORK}"/dist/*.kpkg)"

mkdir -p "${WORK}/pkg" "${WORK}/koreader/plugins"
tar xzf "${PACKAGE}" -C "${WORK}/pkg"

# The manifest KPM reads before it unpacks anything.
python3 -c "
import json, sys
manifest = json.load(open('${WORK}/pkg/manifest.json'))
for key in ('manifest_version', 'id', 'name', 'author', 'description', 'version', 'dependencies'):
    assert key in manifest, 'package manifest is missing ' + key
assert len(manifest['version']) == 3, 'version must be a [major, minor, patch] triple'
"

cd "${WORK}/pkg"
KOREADER_DIR="${WORK}/koreader" sh install.sh >/dev/null
test -f "${WORK}/koreader/plugins/aidict.koplugin/main.lua"
test -f "${WORK}/koreader/plugins/aidict.koplugin/aidict/lookup.lua"

# An upgrade must not leave a file from the previous version behind.
touch "${WORK}/koreader/plugins/aidict.koplugin/stale.lua"
KOREADER_DIR="${WORK}/koreader" sh install.sh upgrade >/dev/null
test ! -f "${WORK}/koreader/plugins/aidict.koplugin/stale.lua"

KOREADER_DIR="${WORK}/koreader" sh uninstall.sh >/dev/null
test ! -d "${WORK}/koreader/plugins/aidict.koplugin"

# The gateway address is injected at build time, never committed.
AIDICT_ENDPOINT="https://gateway.test/koreader-ai" \
    python3 "${ROOT}/scripts/kpmrepo.py" package --output "${WORK}/dist-ep" >/dev/null
mkdir -p "${WORK}/pkg-ep"
tar xzf "${WORK}"/dist-ep/*.kpkg -C "${WORK}/pkg-ep"
grep -q 'endpoint = "https://gateway.test/koreader-ai"' \
    "${WORK}/pkg-ep/aidict.koplugin/aidict/config.lua" \
    || { echo "the endpoint was not baked into the package"; exit 1; }
grep -q 'endpoint = ""' "${ROOT}/plugin/aidict.koplugin/aidict/config.lua" \
    || { echo "an endpoint leaked into the committed config.lua"; exit 1; }

# Every Lua file in the package must parse. Injection rewrites source, and a
# value with a newline in it once produced a config.lua that only failed on
# the device.
find "${WORK}/pkg-ep" -name '*.lua' -exec luac5.1 -p {} +

echo "package verified: install, upgrade and uninstall all behave,"
echo "and the endpoint is injected at build time rather than committed"
