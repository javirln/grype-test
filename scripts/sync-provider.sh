#!/usr/bin/env bash
# sync-provider.sh <provider>: sync one provider with vunnel (Anchore's image and .vunnel.yaml), then back up the
# workspace with `grype-db cache backup`. Writes out/<provider>/: logs, timing.tsv.
#
# Default (bootstrap.yml): a first sync from the upstream source with no cache, the way a job with lost caches
# starts. The cache tarball goes to out/<provider>/.
#
# INCREMENTAL=1 (incremental.yml): first restore a cache (ours if it exists, else Anchore's; scripts/cache.sh), so
# vunnel fetches only the changes. Push the backup as our new cache only when vunnel and the backup succeeded.
# FAIL_PROVIDER=<provider> runs that provider's vunnel with no network, to test the failure path.
set -uo pipefail
. "$(dirname "$0")/env.sh"
p="$1"
REPO="$PWD"
OUT="$REPO/out/$p"
LIMIT=$(( 340 * 60 ))   # stop before the 6 h job limit so the partial result is still uploaded
INCREMENTAL="${INCREMENTAL:-0}"
mkdir -p "$OUT" "$WORK/data/vunnel"
cp config/vunnel.yaml "$WORK/.vunnel.yaml"
cp config/grype-db.yaml "$WORK/grype-db.yaml"
docker pull -q "$VUNNEL_IMAGE" >/dev/null

# vunnel's result count of a workspace (sqlite result store), to show what an incremental run added
results() { local db="$WORK/data/vunnel/$p/results/results.db"; [ -r "$db" ] && sqlite3 -readonly "$db" 'select count(*) from results' 2>/dev/null || echo -; }

restore_s=0 before=-
if [ "$INCREMENTAL" = 1 ]; then
  s=$(date +%s)
  if ! OUT="$OUT" "$REPO/scripts/cache.sh" restore "$p" sync; then
    echo "restore of our cache failed: restore Anchore's cache" >&2
    OUT="$OUT" "$REPO/scripts/cache.sh" restore "$p" anchore || echo "restore failed: vunnel runs with an empty workspace" >&2
  fi
  restore_s=$(( $(date +%s) - s ))
  before=$(results)
  BK="$WORK/backup/cache-$p.tar.gz"   # pushed to the registry, not uploaded as an artifact
else
  BK="$OUT/cache-$p.tar.gz"
fi
mkdir -p "$(dirname "$BK")"

net=()
if [ -n "${FAIL_PROVIDER:-}" ] && [ "${FAIL_PROVIDER}" = "$p" ]; then
  echo "FAIL_PROVIDER=$p: vunnel runs with no network, on purpose"
  net=(--network none)
fi

name="vunnel-$p"
start=$(date -u +%FT%TZ)
s=$(date +%s)
# GITHUB_TOKEN is passed by name only (used by the github provider)
docker run -d --name "$name" "${net[@]}" --user "$(id -u):$(id -g)" -e HOME=/tmp -e GITHUB_TOKEN -w / \
  -v "$WORK/data/vunnel:/data/vunnel" -v "$WORK/.vunnel.yaml:/.vunnel.yaml" "$VUNNEL_IMAGE" run "$p" >/dev/null
id=$(docker inspect --format '{{.Id}}' "$name")
# stream a progress line every 2 minutes into the job log (the full log is uploaded at the end)
( while docker inspect "$name" >/dev/null 2>&1; do
    sleep 120
    echo "[$(date -u +%TZ)] +$(( $(date +%s) - s ))s: $(docker logs --tail 1 "$name" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-200)"
  done ) &
progress=$!
peak=0
status=done
while [ "$(docker inspect --format '{{.State.Running}}' "$name")" = true ]; do
  f="/sys/fs/cgroup/system.slice/docker-$id.scope/memory.peak"
  [ -r "$f" ] && peak=$(cat "$f")
  if (( $(date +%s) - s > LIMIT )); then status=stopped-at-limit; docker stop -t 30 "$name" >/dev/null; break; fi
  sleep 10
done
rc=$(docker inspect --format '{{.State.ExitCode}}' "$name")
docker logs "$name" > "$WORK/vunnel-$p.log" 2>&1
# the head shows how the run started (incremental or full); the tail how it ended
{ sed -n '1,300p' "$WORK/vunnel-$p.log"; echo "[...]"; tail -n 3000 "$WORK/vunnel-$p.log"; } > "$OUT/vunnel.log"
docker rm "$name" >/dev/null
kill "$progress" 2>/dev/null
secs=$(( $(date +%s) - s ))
ws=$(du -sb "$WORK/data/vunnel/$p" 2>/dev/null | cut -f1)
after=$(results)

if [ "$rc" = 0 ] && [ "$status" = done ]; then
  (cd "$WORK" && "$REPO/bin/grype-db" -c grype-db.yaml cache backup -p "$p" --path "$BK") \
    > "$OUT/backup.log" 2>&1 || status=backup-failed
elif [ "$status" = done ]; then
  status=vunnel-failed
fi
bk=$(stat -c %s "$BK" 2>/dev/null || echo 0)

pushed=- push_s=0
if [ "$INCREMENTAL" = 1 ] && [ "$status" = done ]; then
  s=$(date +%s)
  if pushed=$("$REPO/scripts/cache.sh" push "$p" "$BK"); then :; else status=push-failed; pushed=-; fi
  push_s=$(( $(date +%s) - s ))
fi

printf 'provider\tstart_utc\tseconds\texit\tstatus\tpeak_mem_bytes\tworkspace_bytes\tbackup_bytes\trestore_seconds\tresults_before\tresults_after\tpushed_digest\tpush_seconds\n' > "$OUT/timing.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$start" "$secs" "$rc" "$status" "$peak" "${ws:-0}" "$bk" \
  "$restore_s" "$before" "$after" "$pushed" "$push_s" >> "$OUT/timing.tsv"
cat "$OUT/timing.tsv"
tail -5 "$OUT/vunnel.log"
df -h "$WORK" | tail -1
[ "$rc" = 0 ] && [ "$status" = done ]
