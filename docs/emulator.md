# Running the plugin in the KOReader emulator

The unit suite covers the plugin's behaviour without KOReader (that is the
point of the `aidict/` split), but `main.lua` — the buttons, the menu, the
widgets — is only exercised by running the real thing. On Linux that means
KOReader's SDL build, driven headlessly under `Xvfb`.

`scripts/emulator.sh` drives the full application. A prebuilt GitHub release
also supports a smaller headless popup check with SDL's dummy driver, without
Xvfb. Verified in the cloud on 2026-10-26 against v2026.07.1: download and unpack
the x86_64 AppImage, change into its `usr/lib/koreader` directory, then run:

```bash
SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software \
  AIDICT_PLUGIN_DIR=/absolute/path/to/koreader-ai-plugin/plugin/aidict.koplugin \
  ./luajit /absolute/path/to/koreader-ai-plugin/scripts/test-heading-popup.lua
```

This opens a real dictionary popup using a supplied answer, checks the English /
Russian word toggle, and writes both screenshots under `/tmp` (override with
`AIDICT_SCREENSHOT_DIR`). The older source-build and download restrictions below
are historical; they do not apply when the GitHub release assets are accessible.

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

## What already runs: the CI smoke test

GitHub runners have unrestricted network access, so that is where the plugin
meets a real KOReader today. `.github/workflows/koreader-smoke.yml` downloads
the latest stable KOReader release, extracts the AppImage, copies
`plugin/aidict.koplugin` into its `plugins/` directory, starts it under `Xvfb`
on a sample document, and fails unless the log says the plugin loaded and says
nothing about it erroring. It runs on every PR and every push to `main` or `dev` that touches `plugin/`, takes
a couple of minutes, and needs no KOReader build.

That covers "does real KOReader accept this plugin". It does not cover tapping
a word and looking at the answer, which is what a local emulator — or the
Kindle — is for.

## What still needs the physical Kindle

Whatever the emulator route, the Kindle stays the place to check:

* that `;kpm install` finds the repository over the device's Wi-Fi,
* that the plugin loads on the device's KOReader build,
* that the e-ink rendering of the answer is actually readable,
* and that the network call survives the Kindle's aggressive Wi-Fi sleep.

Everything else is cheaper to check in the container.
