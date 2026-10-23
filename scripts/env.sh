# Pinned tools and paths for every script. Source it.
GRYPE_DB_VERSION=0.54.5
GRYPE_DB_SHA256=ab98cf01d66069f0d820ae355d28fe0a1e127aed46b8d56370f5c049d626e0f8   # grype-db_0.54.5_linux_amd64.tar.gz
GRYPE_VERSION=0.115.0
GRYPE_SHA256=3fad92940650e514c0aa2dad83526942a055e210cec09a8a59d9c024adc2b90e      # grype_0.115.0_linux_amd64.tar.gz
GRYPE_BIN_SHA256=05ffd2c28a607e48fb2269d9aac5b3d53e8a51bbac501946644745eae2119907  # the grype binary the sandboxes run
ORAS_VERSION=1.3.4
ORAS_SHA256=f27adb935022d94df8dc77719c322dda592c78a0d57a6f7dcdd8d900b248c454       # oras_1.3.4_linux_amd64.tar.gz
VUNNEL_IMAGE=ghcr.io/anchore/vunnel@sha256:4f90c3e4cf5b9871a0ec4768275b93979f6d5b014535b60044aa6c72029a4dc9
WORK="${WORK:-/mnt/work}"   # the runner's large temporary disk
PROVIDERS="${PROVIDERS:-$(sed -n 's/^ *- name: //p' "$(dirname "${BASH_SOURCE[0]}")/../config/grype-db.yaml")}"
# Provider caches (OCI artifacts, one per provider, tag latest): Anchore's public ones, and ours (incremental.yml)
ANCHORE_CACHE_REPO=ghcr.io/anchore/grype-db/data
CACHE_REPO="${CACHE_REPO:-ghcr.io/${GITHUB_REPOSITORY:-javirln/grype-test}/cache}"
