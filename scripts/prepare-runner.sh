#!/usr/bin/env bash
# Free disk space on a GitHub-hosted runner and create the work directory on the large temporary disk.
set -euo pipefail
. "$(dirname "$0")/env.sh"
df -h / /mnt
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /usr/local/.ghcup /opt/hostedtoolcache/CodeQL \
  /usr/local/share/boost /usr/share/swift
sudo docker image prune -af >/dev/null || true
sudo mkdir -p "$WORK" && sudo chown "$(id -u):$(id -g)" "$WORK"
for t in zstd sqlite3; do command -v "$t" >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq zstd sqlite3; break; }; done
df -h / /mnt
nproc; free -g
