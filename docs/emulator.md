# Running the plugin in the KOReader emulator

The unit suite covers the plugin's behaviour without KOReader (that is the
point of the `aidict/` split), but `main.lua` — the buttons, the menu, the
widgets — is only exercised by running the real thing. On Linux that means
KOReader's SDL build, driven headlessly under `Xvfb`.

`scripts/emulator.sh` does the whole dance. **It does not work in the cloud
environment as configured today**, for one reason that is a settings change
away; the rest of this page is that reason, measured rather than guessed.

## What was tried, 2026-09-20

| Step | Result |
| --- | --- |
| `git clone --depth 1 koreader/koreader` | works (30 MB) |
| build dependencies from `doc/Building.md` via apt | works |
| `make fetchthirdparty` (git submodules) | works |
| `./kodev build` | **fails** on the first third-party download |

The build fetches 17 source tarballs from `github.com/<project>/archive/…` and
a dozen more from project sites. In this session:

| Host | Result |
| --- | --- |
| `github.com/…/archive/…`, `codeload.github.com` | 403 — the session's GitHub access is scoped to the attached repositories |
| `github.com/…/releases/download/…`, `raw.githubusercontent.com` | allowed |
| `mupdf.com`, `sqlite.org`, `cdn.openbsd.org`, `download.gnome.org`, `ftp.osuosl.org`, `framagit.org`, `android.googlesource.com` | blocked by the environment's allowed-domain list |
| `build.koreader.rocks` (KOReader's own build server) | blocked by the same list |

So the source build needs about a dozen domains added, and the GitHub archive
paths may stay blocked regardless, since that gate is the session's repository
scoping rather than the domain list.

## The one-line fix: use a prebuilt Linux build

Add **one** domain to the environment's **Allowed domains**
(claude.ai/code → environment selector → edit environment):

```
build.koreader.rocks
```

That is where KOReader publishes its nightly Linux builds. With it allowed:

```bash
KOREADER_DOWNLOAD_URL=https://build.koreader.rocks/download/nightly/<latest>/koreader-linux-x86_64-<version>.tar.xz \
  ./scripts/emulator.sh
```

The script unpacks it under `.emulator/`, links
`plugin/aidict.koplugin` into its `plugins/` directory and starts it under
`Xvfb`, so the plugin loads into a real KOReader with real widgets.

Adding `dl.koreader.rocks` or `github.com` release-asset URLs works the same
way: the script takes any `.tar.xz`, `.AppImage` or already-unpacked directory.

## Building from source instead

If you would rather build (`./kodev build`, `./kodev run`), add these to the
allowed domains as well:

```
codeload.github.com
mupdf.com
www.sqlite.org
cdn.openbsd.org
download.gnome.org
ftp.osuosl.org
framagit.org
gitlab.com
android.googlesource.com
sourceforge.net
```

Then:

```bash
git clone --depth 1 https://github.com/koreader/koreader ~/koreader-src
cd ~/koreader-src && make fetchthirdparty && ./kodev build
KOREADER_SRC=~/koreader-src /path/to/scripts/emulator.sh
```

Budget 40–60 minutes for the first build on four cores, and a few GB of disk.

## The third option: build it in CI

GitHub Actions runners have unrestricted network access, so the emulator build
works there without changing anything about the cloud environment. A workflow
that builds KOReader once, caches it, drops the plugin in and runs it under
`Xvfb` would give every push a real-KOReader smoke test — at the cost of a
long first run. Worth doing if the emulator is needed regularly; not written
yet.

## What still needs the physical Kindle

Whatever the emulator route, the Kindle stays the place to check:

* that `;kpm install` finds the repository over the device's Wi-Fi,
* that the plugin loads on the device's KOReader build,
* that the e-ink rendering of the answer is actually readable,
* and that the network call survives the Kindle's aggressive Wi-Fi sleep.

Everything else is cheaper to check in the container.
