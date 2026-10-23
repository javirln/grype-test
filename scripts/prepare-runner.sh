#!/usr/bin/env bash
# Free disk space on a GitHub-hosted runner and create the work directory on the large temporary disk.
#   FREE_DISK=0  skip the clean-up (about 2 min, 27 GB): a sync job of one provider does not need it
#   SWAP_GB=<n>  add a swap file of n GB, a margin for the grype-db build (peak RSS 9 to 12 GB on a 16 GB runner)
set -euo pipefail
. "$(dirname "$0")/env.sh"
df -h / /mnt
if [ "${FREE_DISK:-1}" = 1 ]; then
  sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /usr/local/.ghcup /opt/hostedtoolcache/CodeQL \
    /usr/local/share/boost /usr/share/swift
  sudo docker image prune -af >/dev/null || true
fi
if [ "${SWAP_GB:-0}" -gt 0 ]; then
  sudo fallocate -l "${SWAP_GB}G" /mnt/swapfile-extra
  sudo chmod 600 /mnt/swapfile-extra
  sudo mkswap /mnt/swapfile-extra >/dev/null
  sudo swapon /mnt/swapfile-extra
  swapon --show
fi
sudo mkdir -p "$WORK" && sudo chown "$(id -u):$(id -g)" "$WORK"
for t in zstd sqlite3; do command -v "$t" >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq zstd sqlite3; break; }; done
df -h / /mnt
nproc; free -g
