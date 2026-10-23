#!/usr/bin/env bash
# install-tools.sh <grype-db|grype|oras>: download the pinned release tarball, verify its sha256, install it into ./bin.
set -euo pipefail
. "$(dirname "$0")/env.sh"
mkdir -p bin tmp
case "$1" in
  grype-db) url="https://github.com/anchore/grype-db/releases/download/v${GRYPE_DB_VERSION}/grype-db_${GRYPE_DB_VERSION}_linux_amd64.tar.gz"; sha=$GRYPE_DB_SHA256 ;;
  grype)    url="https://github.com/anchore/grype/releases/download/v${GRYPE_VERSION}/grype_${GRYPE_VERSION}_linux_amd64.tar.gz"; sha=$GRYPE_SHA256 ;;
  oras)     url="https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_amd64.tar.gz"; sha=$ORAS_SHA256 ;;
  *) echo "unknown tool $1" >&2; exit 2 ;;
esac
curl -sSfL -o "tmp/$1.tar.gz" "$url"
echo "$sha  tmp/$1.tar.gz" | sha256sum -c -
tar -xzf "tmp/$1.tar.gz" -C bin "$1"
if [ "$1" = grype ]; then echo "$GRYPE_BIN_SHA256  bin/grype" | sha256sum -c -; fi
"bin/$1" version > "tmp/$1.version"   # not piped into head: an early close is SIGPIPE (141) under pipefail
sed -n 1,3p "tmp/$1.version"
