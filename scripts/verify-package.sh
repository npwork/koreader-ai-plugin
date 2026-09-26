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

# Both addresses are injected at build time, never committed. Anchored on the default's leading
# spaces: `endpoint = "…"` is a substring of `library_endpoint = "…"`.
AIDICT_ENDPOINT="https://koreader-ai.test" \
AIDICT_LIBRARY_ENDPOINT="https://gateway.test/koreader-library" \
    python3 "${ROOT}/scripts/kpmrepo.py" package --output "${WORK}/dist-ep" >/dev/null
mkdir -p "${WORK}/pkg-ep"
tar xzf "${WORK}"/dist-ep/*.kpkg -C "${WORK}/pkg-ep"
grep -q '^    endpoint = "https://koreader-ai.test",$' \
    "${WORK}/pkg-ep/aidict.koplugin/aidict/config.lua" \
    || { echo "the endpoint was not baked into the package"; exit 1; }
grep -q '^    library_endpoint = "https://gateway.test/koreader-library",$' \
    "${WORK}/pkg-ep/aidict.koplugin/aidict/config.lua" \
    || { echo "the library endpoint was not baked into the package"; exit 1; }
grep -q '^    endpoint = "",$' "${ROOT}/plugin/aidict.koplugin/aidict/config.lua" \
    || { echo "an endpoint leaked into the committed config.lua"; exit 1; }
grep -q '^    library_endpoint = "",$' "${ROOT}/plugin/aidict.koplugin/aidict/config.lua" \
    || { echo "a library endpoint leaked into the committed config.lua"; exit 1; }

# Baking one address must leave the other empty rather than invent one that would 404 on a device.
AIDICT_ENDPOINT="https://koreader-ai.test" \
    python3 "${ROOT}/scripts/kpmrepo.py" package --output "${WORK}/dist-one" >/dev/null
mkdir -p "${WORK}/pkg-one"
tar xzf "${WORK}"/dist-one/*.kpkg -C "${WORK}/pkg-one"
grep -q '^    library_endpoint = "",$' \
    "${WORK}/pkg-one/aidict.koplugin/aidict/config.lua" \
    || { echo "packaging invented a library address"; exit 1; }
grep -q 'api_key = ""' "${ROOT}/plugin/aidict.koplugin/aidict/config.lua" \
    || { echo "a key leaked into the committed config.lua"; exit 1; }

# The package is world-readable and the key opens far more than the dictionary: never package one.
grep -q 'api_key = ""' "${WORK}/pkg-ep/aidict.koplugin/aidict/config.lua" \
    || { echo "a key was baked into the package"; exit 1; }
AIDICT_TOKEN="must-be-ignored" AIDICT_ENDPOINT="https://koreader-ai.test" \
    python3 "${ROOT}/scripts/kpmrepo.py" package --output "${WORK}/dist-nokey" >/dev/null
mkdir -p "${WORK}/pkg-nokey"
tar xzf "${WORK}"/dist-nokey/*.kpkg -C "${WORK}/pkg-nokey"
grep -q 'api_key = ""' "${WORK}/pkg-nokey/aidict.koplugin/aidict/config.lua" \
    || { echo "AIDICT_TOKEN in the environment still reached the package"; exit 1; }

# The gateway takes its key as `?token=`, so an endpoint with a query, fragment or userinfo would
# publish the credential; each must be refused.
for bad in \
        "https://koreader-ai.test?token=leaked" \
        "https://koreader-ai.test#leaked" \
        "https://someone:leaked@koreader-ai.test"; do
    if AIDICT_ENDPOINT="$bad" python3 "${ROOT}/scripts/kpmrepo.py" package \
            --output "${WORK}/dist-bad" >/dev/null 2>&1; then
        echo "packaging accepted an endpoint that can carry a credential: $bad"; exit 1
    fi
    # The library mount takes the key the same way.
    if AIDICT_LIBRARY_ENDPOINT="$bad" python3 "${ROOT}/scripts/kpmrepo.py" package \
            --output "${WORK}/dist-bad" >/dev/null 2>&1; then
        echo "packaging accepted a library endpoint that can carry a credential: $bad"; exit 1
    fi
done

# Every Lua file must parse: injection rewrites source.
find "${WORK}/pkg-ep" -name '*.lua' -exec luac5.1 -p {} +

echo "package verified: install, upgrade and uninstall all behave,"
echo "and the endpoint is injected at build time while the key never is"
