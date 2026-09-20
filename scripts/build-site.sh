#!/bin/sh
# Build the static site that GitHub Pages serves: one KPM repository per
# channel, side by side.
#
#   site/
#     index.html                 what to type on the Kindle
#     stable/manifest.json       built from the newest v* tag
#     dev/manifest.json          built from whatever is checked out now
#     <channel>/packages/…       the .kpkg files themselves
#
# Artifact URLs inside each manifest stay relative, so the whole tree can move
# to another host without being regenerated.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE="${SITE:-${ROOT}/site}"
BASE_URL="${BASE_URL:-https://npwork.github.io/koreader-ai-plugin}"

rm -rf "${SITE}"
mkdir -p "${SITE}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# --- dev: the working tree as it stands -----------------------------------
python3 "${ROOT}/scripts/kpmrepo.py" package --output "${WORK}/dev" >/dev/null
python3 "${ROOT}/scripts/kpmrepo.py" repo "${WORK}"/dev/*.kpkg \
    --channel dev --output "${SITE}" --base-url "${BASE_URL}" >/dev/null
echo "dev:    $(basename "$(ls "${WORK}"/dev/*.kpkg)")"

# --- stable: the newest release tag ----------------------------------------
TAG="$(git -C "${ROOT}" tag --list 'v*' --sort=-v:refname | head -1)"

if [ -n "${TAG}" ]; then
    mkdir -p "${WORK}/tag"
    git -C "${ROOT}" archive "${TAG}" | tar -x -C "${WORK}/tag"
    # Build with that tag's own packaging script, so a release is always
    # rebuilt the way it was released.
    python3 "${WORK}/tag/scripts/kpmrepo.py" package --output "${WORK}/stable" >/dev/null
    echo "stable: ${TAG}"
else
    # No release yet: give the stable channel the current build, so the
    # channel exists and can be added on the device.
    cp -r "${WORK}/dev" "${WORK}/stable"
    echo "stable: no v* tag yet, using the current build"
fi

python3 "${ROOT}/scripts/kpmrepo.py" repo "${WORK}"/stable/*.kpkg \
    --channel stable --output "${SITE}" --base-url "${BASE_URL}" >/dev/null

# --- a short entry point, for typing on a Kindle ---------------------------
# The same repository as stable/manifest.json, but at the site root so the URL
# typed on the device is shorter. Its artifact URLs have to be absolute, since
# they no longer sit next to it.
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

# --- the page a human lands on ---------------------------------------------
VERSION="$(python3 -c "
import json, sys
print(json.load(open('${SITE}/stable/version.json'))['packages']['koreader-aidict']['version_string'])
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
  <p>That short URL is the stable channel. <code>${BASE_URL}/stable/manifest.json</code>
  is the same repository; either one works.</p>
  <p>Then restart KOReader.</p>

  <h2>Update</h2>
<pre><code>;kpm update
;kpm upgrade koreader-aidict</code></pre>

  <h2>Channels</h2>
  <table>
    <tr><th>Channel</th><th>Manifest</th><th>What it carries</th></tr>
    <tr><td>stable</td><td><a href="stable/manifest.json">stable/manifest.json</a></td><td>the newest tagged release (${VERSION})</td></tr>
    <tr><td>dev</td><td><a href="dev/manifest.json">dev/manifest.json</a></td><td>the current main branch</td></tr>
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
