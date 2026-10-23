# grype-test

Spike: build a [grype](https://github.com/anchore/grype) vulnerability DB from the upstream sources on
GitHub-hosted runners, with no cache, following the [grype-db](https://github.com/anchore/grype-db) README
(`pull`, `build`, `package`).

The workflow `Bootstrap a grype DB from sources` (manual trigger) does this:

1. One job for each of the 26 providers of Anchore's nightly build (`publish-nightly-r2.yaml`). The job runs a
   first sync of the provider with vunnel (Anchore's image and `.vunnel.yaml`), records the time, the peak memory
   and the size, and backs up the workspace with `grype-db cache backup`.
2. One job restores all the backups, runs `grype-db build` and `grype-db package`, and checks the DB with grype
   v0.115.0 against Anchore's latest published DB: records per provider, and the probe SBOMs in `sbom/`.

Nothing is published. The DB and `report.md` are workflow artifacts (5 days).

Pinned versions are in `scripts/env.sh`: grype-db v0.54.5, the vunnel image digest, grype v0.115.0.

## Incremental cycle

The workflow `Incremental grype DB cycle` (manual trigger, `incremental.yml`) runs one cycle of the incremental
design. Each provider job restores a cache: ours (`ghcr.io/javirln/grype-test/cache/<provider>:latest`) if it
exists, else Anchore's (`ghcr.io/anchore/grype-db/data/<provider>:latest`). vunnel runs on top of it, so it collects
only the changes. The job pushes the backup as our new cache only when vunnel succeeded. The build job uses the cache
that each provider job pushed. For a provider whose job failed, it uses the newer of our last good cache and
Anchore's cache. The check adds the `date_captured` of each provider, the vulnerability IDs of Anchore's DB that ours
misses (a provider fails above 1%), and the archive sizes. The input `fail_provider` runs one provider's vunnel with
no network, to test the failure path. oras (pinned in `scripts/env.sh`) reads and writes the caches.
