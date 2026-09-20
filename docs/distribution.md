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

## Hosting it on the droplet — the remaining piece

The gateway on the DigitalOcean box already serves all of `gateway.example` through
the Cloudflare tunnel, path-routed per lib. Serving the repository is therefore
a static-file mount at `/kpm`, and deployment is the push to `main` that
already deploys the gateway.

What that needs, in order:

1. A `libs/kpm-repo` lib in `ai-small-projects` that serves a directory of
   static files under `/kpm`, with the right content types
   (`application/json` for the manifests, `application/octet-stream` for
   `.kpkg`) and no caching on `manifest.json` / `version.json`.
2. The channel trees themselves, committed under that lib — the plugin is
   about 12 KB packaged, so the repository is small enough to live in git.
3. `make repo` output copied in, then pushed: CI deploys the gateway and the
   Kindle sees the new version on its next `;kpm update`.

Until that exists, the built tree in `dist/repo/` is complete and can be served
from anywhere — the manifest does not hard-code a host.

## Checksums

KPM does not verify checksums itself. `sha256` is recorded anyway, on every
artifact in `manifest.json`, in `version.json` and in `SHA256SUMS`, so the
update check can verify what it is about to recommend and a publish can be
audited after the fact.
