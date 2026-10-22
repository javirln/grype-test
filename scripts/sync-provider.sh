#!/usr/bin/env bash
# sync-provider.sh <provider>: first sync of one provider from its upstream source, with no cache, the way a job
# with lost caches starts. vunnel runs in Anchore's image with Anchore's .vunnel.yaml. Then grype-db backs up the
# workspace, which is what a later run would restore. Writes out/<provider>/: cache tarball, logs, timing.tsv.
set -uo pipefail
. "$(dirname "$0")/env.sh"
p="$1"
REPO="$PWD"
OUT="$REPO/out/$p"
LIMIT=$(( 340 * 60 ))   # stop before the 6 h job limit so the partial result is still uploaded
mkdir -p "$OUT" "$WORK/data/vunnel"
cp config/vunnel.yaml "$WORK/.vunnel.yaml"
cp config/grype-db.yaml "$WORK/grype-db.yaml"
docker pull -q "$VUNNEL_IMAGE" >/dev/null

name="vunnel-$p"
start=$(date -u +%FT%TZ)
s=$(date +%s)
# GITHUB_TOKEN is passed by name only (used by the github provider)
docker run -d --name "$name" --user "$(id -u):$(id -g)" -e HOME=/tmp -e GITHUB_TOKEN -w / \
  -v "$WORK/data/vunnel:/data/vunnel" -v "$WORK/.vunnel.yaml:/.vunnel.yaml" "$VUNNEL_IMAGE" run "$p" >/dev/null
id=$(docker inspect --format '{{.Id}}' "$name")
peak=0
status=done
while [ "$(docker inspect --format '{{.State.Running}}' "$name")" = true ]; do
  f="/sys/fs/cgroup/system.slice/docker-$id.scope/memory.peak"
  [ -r "$f" ] && peak=$(cat "$f")
  if (( $(date +%s) - s > LIMIT )); then status=stopped-at-limit; docker stop -t 30 "$name" >/dev/null; break; fi
  sleep 10
done
rc=$(docker inspect --format '{{.State.ExitCode}}' "$name")
docker logs --tail 3000 "$name" > "$OUT/vunnel.log" 2>&1
docker rm "$name" >/dev/null
secs=$(( $(date +%s) - s ))
ws=$(du -sb "$WORK/data/vunnel/$p" 2>/dev/null | cut -f1)

if [ "$rc" = 0 ]; then
  (cd "$WORK" && "$REPO/bin/grype-db" -c grype-db.yaml cache backup -p "$p" --path "$OUT/cache-$p.tar.gz") \
    > "$OUT/backup.log" 2>&1 || status=backup-failed
fi
bk=$(stat -c %s "$OUT/cache-$p.tar.gz" 2>/dev/null || echo 0)
printf 'provider\tstart_utc\tseconds\texit\tstatus\tpeak_mem_bytes\tworkspace_bytes\tbackup_bytes\n' > "$OUT/timing.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$start" "$secs" "$rc" "$status" "$peak" "${ws:-0}" "$bk" >> "$OUT/timing.tsv"
cat "$OUT/timing.tsv"
tail -5 "$OUT/vunnel.log"
df -h /mnt | tail -1
[ "$rc" = 0 ] && [ "$status" = done ]
