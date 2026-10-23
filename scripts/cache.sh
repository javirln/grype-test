#!/usr/bin/env bash
# cache.sh: provider caches as OCI artifacts, in the format of Anchore's ghcr.io/anchore/grype-db/data/<provider>:
# one layer, the `grype-db cache backup` tarball, tag latest. Two registries: Anchore's (read anonymously) and ours
# ($CACHE_REPO, read and written with the workflow token, passed by name).
#
#   cache.sh login                          log in to our registry (GITHUB_TOKEN, GITHUB_ACTOR)
#   cache.sh meta <ours|anchore> <provider> [tag|digest]
#                                           print manifest_digest, created, layer_digest, layer_bytes (TAB);
#                                           exit 3 when the artifact is absent
#   cache.sh push <provider> <file>         push <file> as $CACHE_REPO/<provider>:latest (+ run-<id>), print the digest
#   cache.sh restore <provider> <mode> [digest]
#                                           pick a cache, download it, `grype-db cache restore` it into $WORK, and
#                                           append one row to $OUT/restore.tsv. Modes:
#                                             sync    ours:latest if it exists, else Anchore's latest
#                                             ours    ours@<digest> (the cache this cycle pushed)
#                                             newer   the newer (created annotation) of ours:latest and Anchore's
#                                             anchore Anchore's latest (the sync falls back to it on a registry error)
set -euo pipefail
. "$(dirname "$0")/env.sh"
REPO="$PWD"
ORAS="$REPO/bin/oras"
OURS_CFG="$WORK/oras/ours"
ANON_CFG="$WORK/oras/anon"   # stays empty: Anchore's caches are pulled anonymously
mkdir -p "$OURS_CFG" "$ANON_CFG"
# ORAS_OURS_FLAGS: extra flags for our registry, for example --plain-http for a local test registry
read -r -a OURS_FLAGS <<<"${ORAS_OURS_FLAGS:-}"

oras_for() {   # oras_for <ours|anchore> <args...>
  local who=$1; shift
  if [ "$who" = ours ]; then DOCKER_CONFIG="$OURS_CFG" "$ORAS" "$@" "${OURS_FLAGS[@]}"
  else DOCKER_CONFIG="$ANON_CFG" "$ORAS" "$@"; fi
}
repo_for() { if [ "$1" = ours ]; then echo "$CACHE_REPO/$2"; else echo "$ANCHORE_CACHE_REPO/$2"; fi; }

meta() {   # meta <ours|anchore> <provider> [tag|digest]
  local who=$1 p=$2 ref=${3:-latest} r sep=: d m err
  r=$(repo_for "$who" "$p")
  [[ $ref == sha256:* ]] && sep=@
  err=$(mktemp)
  if ! d=$(oras_for "$who" manifest fetch --descriptor "$r$sep$ref" 2>"$err" | jq -r .digest); then
    # a missing package answers "denied" on GHCR, a missing tag "not found"
    if grep -qiE 'not found|denied|name unknown|manifest unknown' "$err"; then
      echo "absent: $who $r$sep$ref: $(tr -d '\n' < "$err" | cut -c1-160)" >&2; rm -f "$err"; return 3
    fi
    cat "$err" >&2; rm -f "$err"; return 1
  fi
  rm -f "$err"
  m=$(oras_for "$who" manifest fetch "$r@$d")
  jq -r --arg d "$d" '[$d, .annotations["org.opencontainers.image.created"] // "", .layers[0].digest, .layers[0].size] | @tsv' <<<"$m"
}

case "${1:-}" in
  login)
    [ -n "${GITHUB_TOKEN:-}" ] || { echo "GITHUB_TOKEN is not set" >&2; exit 2; }
    DOCKER_CONFIG="$OURS_CFG" "$ORAS" login "${CACHE_REPO%%/*}" -u "${GITHUB_ACTOR:-github-actions}" \
      --password-stdin "${OURS_FLAGS[@]}" <<<"$GITHUB_TOKEN" >/dev/null
    echo "logged in to ${CACHE_REPO%%/*}"
    ;;

  meta)
    meta "$2" "$3" "${4:-latest}"
    ;;

  push)
    p=$2 f=$3
    dir=$(dirname "$f") base=$(basename "$f")
    tags=latest
    [ -n "${GITHUB_RUN_ID:-}" ] && tags="latest,run-$GITHUB_RUN_ID"
    out=$(cd "$dir" && DOCKER_CONFIG="$OURS_CFG" "$ORAS" push "$(repo_for ours "$p"):$tags" \
            "$base:application/vnd.oci.image.layer.v1.tar" \
            --annotation "org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY:-javirln/grype-test}" \
            --format json "${OURS_FLAGS[@]}")
    jq -r .digest <<<"$out"
    ;;

  restore)
    p=$2 mode=$3 want=${4:-}
    OUT="${OUT:?OUT must be set}"
    mkdir -p "$OUT" "$WORK/data/vunnel" "$WORK/caches"
    [ -f "$WORK/grype-db.yaml" ] || cp config/grype-db.yaml "$WORK/grype-db.yaml"
    a_meta=$(meta anchore "$p" latest) || a_meta=""
    o_meta=""; o_rc=0
    if [ "$mode" = ours ]; then o_meta=$(meta ours "$p" "$want") || o_rc=$?
    elif [ "$mode" != anchore ]; then o_meta=$(meta ours "$p" latest) || o_rc=$?; fi
    [ "$o_rc" = 0 ] || [ "$o_rc" = 3 ] || exit "$o_rc"   # a registry error is not "absent"
    a_created=$(cut -f2 <<<"$a_meta"); o_created=$(cut -f2 <<<"$o_meta")
    case "$mode" in
      sync)  if [ -n "$o_meta" ]; then src=ours; else src=anchore; fi ;;
      ours)  [ -n "$o_meta" ] || { echo "our cache $p@$want is missing" >&2; exit 1; }; src=ours ;;
      anchore) src=anchore ;;
      newer) if [ -n "$o_meta" ] && [ -n "$a_meta" ]; then
               # RFC 3339 UTC strings of the same shape sort as times
               if [[ "$o_created" > "$a_created" ]]; then src=ours; else src=anchore; fi
             elif [ -n "$o_meta" ]; then src=ours; else src=anchore; fi ;;
      *) echo "unknown mode $mode" >&2; exit 2 ;;
    esac
    if [ "$src" = ours ]; then sel=$o_meta; else sel=$a_meta; fi
    [ -n "$sel" ] || { echo "no cache for $p" >&2; exit 1; }
    IFS=$'\t' read -r m_digest created l_digest l_size <<<"$sel"
    f="$WORK/caches/$p.tar.gz"
    s=$(date +%s)
    oras_for "$src" blob fetch --output "$f" "$(repo_for "$src" "$p")@$l_digest"
    fetch_s=$(( $(date +%s) - s ))
    s=$(date +%s)
    (cd "$WORK" && "$REPO/bin/grype-db" -c grype-db.yaml cache restore --path "$f" --delete-existing) \
      > "$OUT/restore-$p.log" 2>&1
    restore_s=$(( $(date +%s) - s ))
    rm -f "$f"
    age=$(( $(date +%s) - $(date -d "$created" +%s) ))
    [ -s "$OUT/restore.tsv" ] || printf 'provider\tmode\tsource\tmanifest_digest\tcreated\tage_seconds\tlayer_bytes\tfetch_seconds\trestore_seconds\tours_latest_created\tanchore_latest_created\n' > "$OUT/restore.tsv"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$mode" "$src" "$m_digest" "$created" "$age" "$l_size" \
      "$fetch_s" "$restore_s" "${o_created:--}" "${a_created:--}" | tee -a "$OUT/restore.tsv"
    ;;

  *) sed -n '2,17p' "$0" >&2; exit 2 ;;
esac
