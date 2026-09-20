#!/bin/sh
# Cut a release: bump the version, commit, tag and push.
#
#   ./scripts/release.sh 0.2.0
#
# The tag is what the stable channel follows, so pushing it is what reaches
# the Kindle. CI publishes the site, installs the result from the live URL
# with the real KPM, and loads it into a real KOReader before the release
# counts as good.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$1"

if [ -z "${VERSION}" ]; then
    echo "usage: $0 <major.minor.patch>"
    echo "current: $(sed -n 's/.*string = "\([0-9.]*\)".*/\1/p' "${ROOT}/plugin/aidict.koplugin/aidict/version.lua")"
    exit 1
fi

case "${VERSION}" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "version must look like 1.2.3, got '${VERSION}'"; exit 1 ;;
esac

cd "${ROOT}"

[ -z "$(git status --porcelain)" ] || { echo "working tree is not clean"; exit 1; }
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "releases are cut from main"; exit 1; }
git rev-parse "v${VERSION}" >/dev/null 2>&1 && { echo "tag v${VERSION} already exists"; exit 1; }

MAJOR="${VERSION%%.*}"
REST="${VERSION#*.}"
MINOR="${REST%%.*}"
PATCH="${REST#*.}"

python3 - "${VERSION}" "${MAJOR}" "${MINOR}" "${PATCH}" <<'PY'
import re
import sys

version, major, minor, patch = sys.argv[1:5]
path = "plugin/aidict.koplugin/aidict/version.lua"
text = open(path).read()
text = re.sub(r'string\s*=\s*"[0-9.]+"', f'string = "{version}"', text, count=1)
text = re.sub(r"major\s*=\s*\d+", f"major = {major}", text, count=1)
text = re.sub(r"minor\s*=\s*\d+", f"minor = {minor}", text, count=1)
text = re.sub(r"patch\s*=\s*\d+", f"patch = {patch}", text, count=1)
open(path, "w").write(text)
PY

echo "==> Checking before tagging"
make check

git add plugin/aidict.koplugin/aidict/version.lua
git commit -m "Release v${VERSION}"
git tag -a "v${VERSION}" -m "v${VERSION}"

echo "==> Pushing"
git push origin main
git push origin "v${VERSION}"

cat <<MSG

Released v${VERSION}.

CI is now publishing it and proving it installs. Once that is green, on the
Kindle:

    ;kpm update
    ;kpm upgrade

then restart KOReader.
MSG
