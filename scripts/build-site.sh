#!/bin/sh
# Both channels are rebuilt every time: Pages replaces the whole site on each deploy.
# The patch is the branch's commit count, so every push outranks the last for `kpm upgrade`.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE="${SITE:-${ROOT}/site}"
BASE_URL="${BASE_URL:-https://npwork.github.io/koreader-ai-plugin}"
STABLE_BRANCH="${STABLE_BRANCH:-main}"
DEV_BRANCH="${DEV_BRANCH:-dev}"

rm -rf "${SITE}"
mkdir -p "${SITE}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Prefer the remote ref, so a CI checkout of one branch can still build the other.
resolve_ref() {
    for candidate in "origin/$1" "$1"; do
        if git -C "${ROOT}" rev-parse --verify --quiet "${candidate}" >/dev/null 2>&1; then
            echo "${candidate}"
            return 0
        fi
    done
    return 1
}

version_for() {
    base="$(sed -n 's/.*string = "\([0-9]*\)\.\([0-9]*\)\.[0-9]*".*/\1.\2/p' \
        "$1/plugin/aidict.koplugin/aidict/version.lua")"
    echo "${base}.$2"
}

build_channel() {
    channel="$1"
    ref="$2"
    tree="${WORK}/tree-${channel}"

    mkdir -p "${tree}"
    git -C "${ROOT}" archive "${ref}" | tar -x -C "${tree}"

    count="$(git -C "${ROOT}" rev-list --count "${ref}")"
    version="$(version_for "${tree}" "${count}")"

    # That branch's own packaging script, so what ships is what that commit would have shipped.
    python3 "${tree}/scripts/kpmrepo.py" package \
        --output "${WORK}/pkg-${channel}" --version "${version}" >/dev/null
    python3 "${ROOT}/scripts/kpmrepo.py" repo "${WORK}/pkg-${channel}"/*.kpkg \
        --channel "${channel}" --output "${SITE}" --base-url "${BASE_URL}" >/dev/null

    echo "${channel}: ${version} (${ref}, ${count} commits)"
}

STABLE_REF="$(resolve_ref "${STABLE_BRANCH}")" || {
    echo "no ${STABLE_BRANCH} branch to build the stable channel from"
    exit 1
}
build_channel stable "${STABLE_REF}"

if DEV_REF="$(resolve_ref "${DEV_BRANCH}")"; then
    build_channel dev "${DEV_REF}"
else
    # No dev branch yet: give the channel the stable build, so it can already be added on a device.
    echo "dev: no ${DEV_BRANCH} branch, mirroring stable"
    python3 "${ROOT}/scripts/kpmrepo.py" repo "${WORK}/pkg-stable"/*.kpkg \
        --channel dev --output "${SITE}" --base-url "${BASE_URL}" >/dev/null
fi

# stable/manifest.json again at the root, for a shorter URL to type; its artifact URLs must be absolute.
python3 - "${SITE}" "${BASE_URL}" <<'SHORTCUT'
import json
import sys

site, base_url = sys.argv[1], sys.argv[2].rstrip("/")
manifest = json.load(open(f"{site}/stable/manifest.json"))

for package in manifest["packages"].values():
    for artifact in package["artifacts"]:
        if "://" not in artifact["url"]:
            artifact["url"] = f"{base_url}/stable/{artifact['url']}"

with open(f"{site}/kpm.json", "w") as out:
    json.dump(manifest, out, indent=2)
    out.write("\n")
SHORTCUT

STABLE_VERSION="$(python3 -c "
import json
print(json.load(open('${SITE}/stable/version.json'))['packages']['koreader-aidict']['version_string'])
")"
DEV_VERSION="$(python3 -c "
import json
print(json.load(open('${SITE}/dev/version.json'))['packages']['koreader-aidict']['version_string'])
")"

cat > "${SITE}/index.html" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>npwork KPM repository</title>
<style>
  :root { color-scheme: light dark; --fg: #16181d; --bg: #fbfbfa; --muted: #5c6370; --line: #e3e3e0; }
  @media (prefers-color-scheme: dark) {
    :root { --fg: #e8e8e6; --bg: #17181c; --muted: #9aa0ab; --line: #2c2e34; }
  }
  body { margin: 0; padding: 48px 16px; background: var(--bg); color: var(--fg);
         font: 16px/1.6 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif; }
  main { max-width: 42rem; margin: 0 auto; }
  h1 { font-size: 1.5rem; margin: 0 0 .25rem; }
  p.sub { color: var(--muted); margin: 0 0 2rem; }
  h2 { font-size: 1rem; margin: 2rem 0 .5rem; }
  pre { background: color-mix(in srgb, var(--fg) 6%, transparent); border: 1px solid var(--line);
        border-radius: 8px; padding: 12px 14px; overflow-x: auto; font-size: .9rem; }
  code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
  table { border-collapse: collapse; width: 100%; font-size: .95rem; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--line); }
  th { color: var(--muted); font-weight: 500; }
  footer { margin-top: 3rem; color: var(--muted); font-size: .85rem; }
  a { color: inherit; }
</style>
</head>
<body>
<main>
  <h1>npwork KPM repository</h1>
  <p class="sub">KOReader plugins for a jailbroken Kindle, installed over Wi-Fi.</p>

  <h2>Install</h2>
  <p>Type this into the Kindle search bar, one line at a time:</p>
<pre><code>;kpm add-repo ${BASE_URL}/kpm.json
;kpm install koreader-aidict</code></pre>
  <p>Then restart KOReader. That short URL is the stable channel;
  <code>${BASE_URL}/stable/manifest.json</code> is the same repository.</p>

  <h2>Update</h2>
<pre><code>;kpm update
;kpm upgrade</code></pre>

  <h2>Channels</h2>
  <table>
    <tr><th>Channel</th><th>Manifest</th><th>Follows</th><th>Now</th></tr>
    <tr><td>stable</td><td><a href="stable/manifest.json">stable/manifest.json</a></td><td>the <code>main</code> branch</td><td>${STABLE_VERSION}</td></tr>
    <tr><td>dev</td><td><a href="dev/manifest.json">dev/manifest.json</a></td><td>the <code>dev</code> branch</td><td>${DEV_VERSION}</td></tr>
  </table>
  <p>Add one, not both: KPM would otherwise pick whichever version is higher.</p>

  <footer>
    Built from <a href="https://github.com/npwork/koreader-ai-plugin">npwork/koreader-ai-plugin</a>.
    Every artifact is checksummed in its channel's <code>SHA256SUMS</code>.
  </footer>
</main>
</body>
</html>
HTML

# Pages runs Jekyll by default, which would swallow paths it considers special.
touch "${SITE}/.nojekyll"

echo "site built in ${SITE}"
