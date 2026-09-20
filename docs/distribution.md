# Getting the package onto the Kindle, over Wi-Fi

The target flow, end to end:

```
cloud session → make check → make repo → DigitalOcean → ;kpm install → Kindle
```

No USB, no laptop, at any step.

## What KPM needs from a repository

KPM (the Kindle package manager) is pointed at one URL:

```
;kpm repo add https://repo.example/kpm/stable/manifest.json
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
;kpm repo add https://repo.example/kpm/dev/manifest.json
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

`scripts/build-site.sh` builds both channels into `site/`: **dev** from the
working tree, **stable** from the newest `v*` tag — rebuilt with that tag's own
packaging script, so a release is always reproduced the way it was released.
Until the first tag exists, stable carries the current build so the channel is
never empty.

This needs the repository to be **public**: Pages is a paid feature on private
repositories. The plugin's source being public is not the same as the gateway
being open — the endpoint still takes a bearer token, and nothing secret lives
in this repository.

The artifacts have to be anonymously downloadable whatever the host: KPM speaks
plain libcurl and has no way to send credentials.

### Proving it actually works

The `verify` job in the same workflow runs after the deployment: it builds the
real KPM from source, points it at the **live** `stable/manifest.json`,
installs the plugin, and fails unless what landed is the version the channel
advertises. So a broken publish is caught by the publish itself, on the real
URL, not on the Kindle.

### Other hosts

The manifests use relative artifact URLs, so the whole tree can be served from
anywhere without regenerating it:

* **DigitalOcean**, the original plan: a `libs/kpm-repo` lib in
  `ai-small-projects` serving `site/` as static files under `/kpm`, deployed by
  the push to `main` that already deploys the gateway. Keeps the URL on
  `gateway.example`; needs the artifacts committed to that repository.
* **Cloudflare**: a Worker with static assets, or Pages, on `kpm.gateway.example`.
  The account's API token already covers Workers, Pages and the `gateway.example`
  DNS, so this can be deployed and re-pointed without touching the droplet.
  (R2 would also fit, but is not enabled on the account.)

Moving means changing `BASE_URL` in `scripts/build-site.sh`, the `repo_url`
default in `aidict/config.lua`, and re-adding the repository on the device.

## Checksums

KPM does not verify checksums itself. `sha256` is recorded anyway, on every
artifact in `manifest.json`, in `version.json` and in `SHA256SUMS`, so the
update check can verify what it is about to recommend and a publish can be
audited after the fact.
