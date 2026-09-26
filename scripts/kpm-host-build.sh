#!/bin/sh
# Builds the real KPM against system libraries: upstream's meson subprojects cannot be fetched in a
# sandboxed CI, so the patch swaps them for pkg-config lookups and leaves the rest upstream's.
# KPM_REF picks the version.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KPM_DIR="${KPM_DIR:-${ROOT}/.kpm}"
SRC="${KPM_DIR}/src"
BUILD="${KPM_DIR}/build"
SANDBOX="${KPM_SANDBOX:-${KPM_DIR}/sandbox}"

if [ ! -d "${SRC}" ]; then
    echo "Cloning KindleModding/kpm"
    git clone --depth 1 ${KPM_REF:+--branch "${KPM_REF}"} https://github.com/KindleModding/kpm "${SRC}"
fi

# FBInk drives the Kindle's e-ink framebuffer and pulls submodules from hosts a
# sandboxed environment cannot reach. The CLI only touches it behind --fbink.
cp "${ROOT}/scripts/fbink-stub/fbink.h" "${ROOT}/scripts/fbink-stub/fbink_stub.c" "${SRC}/cli/"

python3 - "${SRC}/cli/meson.build" <<'PY2'
import re
import sys

path = sys.argv[1]
text = open(path).read()
if "# host-build patch" not in text:
    start = text.index("subproject('fbink'")
    end = text.index("fbink_dep = dependency('fbink')") + len("fbink_dep = dependency('fbink')")
    text = text[:start] + """# host-build patch: a no-op FBInk instead of the real e-ink backend
sources += files('fbink_stub.c')
fbink_dep = declare_dependency(include_directories: include_directories('.'))""" + text[end:]
    open(path, "w").write(text)
PY2

python3 - "${SRC}/meson.build" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path).read()

if "# host-build patch" not in text:
    start = text.index("subproject('zstd'")
    end = text.index("# I know it seems ugly")
    text = text[:start] + "# host-build patch: system libraries instead of static subprojects\n\n" + text[end:]

# gnu2x is the older spelling of the same standard; meson only learned the
# gnu23 name in 1.4, and Ubuntu 24.04 ships 1.3.
text = text.replace("c_std=gnu23", "c_std=gnu2x")

text = text.replace("curl.get_variable('curl_dep')", "dependency('libcurl')")
text = re.sub(
    r"sqlite3_dep = dependency\('sqlite3'.*?\n\]\)",
    "sqlite3_dep = dependency('sqlite3')",
    text,
    flags=re.S,
)
text = text.replace("dependency('libcjson', static: true)", "dependency('libcjson')")
text = text.replace("dependency('libarchive', static: true)", "dependency('libarchive')")
text = text.replace("dependency('libcrypto', static: true)", "dependency('libcrypto')")
open(path, "w").write(text)
PY

mkdir -p "${SANDBOX}"
if [ ! -d "${BUILD}" ]; then
    # fbink's wrap is a git clone rather than a tarball, so it works where the wrapdb tarballs do not.
    meson setup "${BUILD}" "${SRC}" \
        -Ddb_path="${SANDBOX}/kpm.db" \
        -Dpkg_path="${SANDBOX}/packages"
fi
meson compile -C "${BUILD}"

echo
echo "kpm built: ${BUILD}/cli/kpm"
echo "database:  ${SANDBOX}/kpm.db"
