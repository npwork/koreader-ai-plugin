#!/bin/sh
# Drives the real KPM through add, install, upgrade and uninstall against a local HTTP repository,
# all inside .kpm/sandbox.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KPM="${ROOT}/.kpm/build/cli/kpm"
SANDBOX="${ROOT}/.kpm/sandbox"
PORT="${PORT:-8731}"
BASE_URL="http://127.0.0.1:${PORT}"

if [ ! -x "${KPM}" ]; then
    echo "No kpm binary. Run scripts/kpm-host-build.sh first."
    exit 1
fi

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
    [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null
    rm -rf "${WORK}"
}
trap cleanup EXIT

fail() {
    echo "FAILED: $1"
    exit 1
}

echo "==> Building 0.1.0 and the repository around it"
python3 "${ROOT}/scripts/kpmrepo.py" package --output "${WORK}/dist" --version 0.1.0 >/dev/null
python3 "${ROOT}/scripts/kpmrepo.py" repo "${WORK}"/dist/*.kpkg \
    --channel stable --output "${WORK}/repo" --base-url "${BASE_URL}" >/dev/null

echo "==> Serving it on ${BASE_URL}"
(cd "${WORK}/repo" && exec python3 -m http.server "${PORT}" --bind 127.0.0.1) >/dev/null 2>&1 &
SERVER_PID=$!
tries=0
until curl -fsS "${BASE_URL}/stable/manifest.json" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "${tries}" -gt 50 ] && fail "the repository server never came up"
    sleep 0.2
done

# A device that has never seen this repository.
rm -rf "${SANDBOX}"
mkdir -p "${SANDBOX}/packages" "${SANDBOX}/koreader/plugins"
PLUGIN_DIR="${SANDBOX}/koreader/plugins/aidict.koplugin"
export KOREADER_DIR="${SANDBOX}/koreader"

# KPM seeds the official repository, which the sandbox cannot reach: its "could not fetch" lines
# are not this test failing.

echo "==> kpm add-repo"
"${KPM}" -y add-repo "${BASE_URL}/stable/manifest.json"
# kpm logs through stderr, so fold it in before looking.
"${KPM}" list-repo 2>&1 | grep -q "npwork packages" || fail "the repository was not registered"

echo "==> kpm install koreader-aidict"
"${KPM}" -y install koreader-aidict
[ -f "${PLUGIN_DIR}/main.lua" ] || fail "main.lua did not land in the plugins directory"
[ -f "${PLUGIN_DIR}/aidict/lookup.lua" ] || fail "the aidict modules did not land"
[ -f "${PLUGIN_DIR}/_meta.lua" ] || fail "_meta.lua did not land"
grep -q '"0.1.0"' "${PLUGIN_DIR}/aidict/version.lua" || fail "installed the wrong version"

echo "==> Publishing 0.1.1 to the same channel"
python3 "${ROOT}/scripts/kpmrepo.py" package --output "${WORK}/dist" --version 0.1.1 >/dev/null
python3 "${ROOT}/scripts/kpmrepo.py" repo "${WORK}"/dist/*.kpkg \
    --channel stable --output "${WORK}/repo" --base-url "${BASE_URL}" >/dev/null

# A file the old version shipped and the new one must not keep.
touch "${PLUGIN_DIR}/stale.lua"

echo "==> kpm update && kpm upgrade"
"${KPM}" -y update
"${KPM}" -y upgrade
grep -q '"0.1.1"' "${PLUGIN_DIR}/aidict/version.lua" || fail "the upgrade did not take"
[ ! -f "${PLUGIN_DIR}/stale.lua" ] || fail "the upgrade left a file from the old version behind"

echo "==> Checking the published checksums"
(cd "${WORK}/repo/stable" && sha256sum -c SHA256SUMS >/dev/null) || fail "SHA256SUMS does not match the artifacts"
python3 - "${WORK}/repo/stable" <<'PY'
import hashlib, json, sys
from pathlib import Path

root = Path(sys.argv[1])
manifest = json.loads((root / "manifest.json").read_text())
versions = json.loads((root / "version.json").read_text())

for package_id, package in manifest["packages"].items():
    for artifact in package["artifacts"]:
        blob = (root / artifact["url"]).read_bytes()
        digest = hashlib.sha256(blob).hexdigest()
        assert digest == artifact["sha256"], f"{artifact['url']} does not match its manifest sha256"

latest = versions["packages"]["koreader-aidict"]
assert latest["version_string"] == "0.1.1", f"version.json still points at {latest['version_string']}"
assert latest["url"].endswith("koreader-aidict_0.1.1_kindleany.kpkg"), latest["url"]
PY

echo "==> kpm uninstall"
"${KPM}" -y uninstall koreader-aidict
[ ! -d "${PLUGIN_DIR}" ] || fail "uninstall left the plugin behind"

echo
echo "distribution verified: add-repo, install, upgrade and uninstall all work"
echo "against the real kpm, over HTTP, with checksums that match."
