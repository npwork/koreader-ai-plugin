# Getting the package onto the Kindle, over Wi-Fi

The target flow, end to end:

```
cloud session → make check → make repo → DigitalOcean → ;kpm install → Kindle
```

No USB, no laptop, at any step.

## What KPM needs from a repository

KPM (the Kindle package manager) is pointed at one URL:

```
;kpm add-repo https://npwork.github.io/koreader-ai-plugin/stable/manifest.json
```

It fetches that JSON, indexes every package and artifact in it, and on
`;kpm install <id>` downloads the artifact. Artifact URLs are resolved
**relative to the manifest URL** unless they contain a scheme, so the whole
tree under `stable/` can be served from any path as long as it stays together.

`scripts/kpmrepo.py repo` produces exactly that tree:

```
dist/repo/stable/
  manifest.json                                  what kpm reads
  version.json                                   what the plugin's update check reads
  SHA256SUMS                                     every artifact, checksummed
  packages/koreader-aidict/artifacts/koreader-aidict_0.1.0_kindleany.kpkg
```

A `.kpkg` is a gzipped tar with `manifest.json` at its root plus the files;
KPM extracts it into `/mnt/us/kmc/kpm/packages/<id>/` and then runs `install.sh`
from that directory. Ours copies `aidict.koplugin/` into
`/mnt/us/koreader/plugins/`.

`scripts/verify-package.sh` runs that whole dance — install, upgrade,
uninstall — against a temporary directory, so a packaging mistake fails in CI
rather than on the device.

## Channels

`stable` and `dev` are two independent repository trees, each with its own
manifest. Adding both to KPM would make it choose the highest version across
them, so add one:

```
;kpm add-repo https://npwork.github.io/koreader-ai-plugin/dev/manifest.json
```

The plugin's own update check reads `<repo_url>/<channel>/version.json` and
only reports; installing stays `kpm`'s job.

## Where it is hosted

GitHub Pages, built and published by `.github/workflows/pages.yml` on every
push to `main` and every `v*` tag:

```
https://npwork.github.io/koreader-ai-plugin/
  index.html          what to type on the Kindle
  stable/manifest.json
  dev/manifest.json
  <channel>/packages/…/*.kpkg
```

`scripts/build-site.sh` builds both channels into `site/` — stable from
`main`, dev from `dev` — each with that branch's own packaging script, so what
ships is what that commit would have shipped. Until a `dev` branch exists, the
dev channel mirrors stable so it is never empty.

Both are rebuilt every run: a Pages deployment replaces the whole site, so
building only the branch that changed would delete the other channel.

This needs the repository to be **public**: Pages is a paid feature on private
repositories. The plugin's source being public is not the same as the gateway
being open — the endpoint still takes a bearer token, and nothing secret lives
in this repository.

The artifacts have to be anonymously downloadable whatever the host: KPM speaks
plain libcurl and has no way to send credentials.

### The two secrets in the pipeline

`AIDICT_ENDPOINT` and `AIDICT_LIBRARY_ENDPOINT` (repository secrets) are the
two addresses, injected into `config.lua` inside the package at build time.
The source tree leaves both empty, so nothing commits either.
`scripts/verify-package.sh` fails if an address ever leaks into the committed
`config.lua`, if an injected one does not reach the built package, or if
setting one invents the other.

There was one until 2026-09-22, because the library's address was the
dictionary's with the last path segment swapped and both mounts sat on the
same gateway. `/koreader-ai` moved to a Cloudflare Worker and the library
stayed with the books, so the old rule produced `https://koreader-library` —
an address that is not one. They are set separately now.

Neither address is protected by this — the package is public and can be
unpacked. They are kept out of the repository so they are not searchable, and
the bearer token, which never enters the package, is what guards both.

### Releasing

A push is a release. `main` feeds the `stable` channel, `dev` feeds `dev`, and
`.github/workflows/pages.yml` runs on both.

Versions need no decision: `major.minor` come from that branch's `version.lua`,
and the patch is the branch's commit count. Every push therefore produces a
version strictly higher than the last, which is the only thing `kpm upgrade`
looks at. Raise `major` or `minor` in `version.lua` when a change earns it.

There are no tags, no version bump commits and no second workflow — which also
sidesteps the fact that a push made with `GITHUB_TOKEN` does not start other
workflows.

### Proving it actually works

The `verify` job in the same workflow runs after the deployment: it builds the
real KPM from source, points it at the **live** `stable/manifest.json`,
installs the plugin, and fails unless what landed is the version the channel
advertises. So a broken publish is caught by the publish itself, on the real
URL, not on the Kindle.

### Other hosts

The manifests use relative artifact URLs, so the whole tree can be served from
anywhere without regenerating it:

* **The gateway's own host**: a small lib serving `site/` as static files
  under `/kpm`, deployed by the push that already deploys the gateway. Keeps
  the repository on a domain you own; needs the artifacts committed to that
  repository.
* **Cloudflare**: a Worker with static assets, or Pages, on a subdomain of a
  zone you control. Deployed and re-pointed without touching the server.
  (R2 would also fit, once enabled on the account.)

Moving means changing `BASE_URL` in `scripts/build-site.sh`, the `repo_url`
default in `aidict/config.lua`, and re-adding the repository on the device.

## Checksums

KPM does not verify checksums itself. `sha256` is recorded anyway, on every
artifact in `manifest.json`, in `version.json` and in `SHA256SUMS`, so the
update check can verify what it is about to recommend and a publish can be
audited after the fact.
