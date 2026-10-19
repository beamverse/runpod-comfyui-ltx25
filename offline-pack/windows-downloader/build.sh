#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
command -v go >/dev/null || { echo 'Go 1.22 or newer is required' >&2; exit 1; }
export GOCACHE="${GOCACHE:-/tmp/ltx25-go-cache}"
export GOPATH="${GOPATH:-/tmp/ltx25-gopath}"
mkdir -p dist
if command -v go-winres >/dev/null && [[ -f winres/winres.json ]]; then go-winres make --in winres/winres.json --arch amd64; fi
version=$(git -C ../.. describe --always --dirty 2>/dev/null || echo dev)
account=${LTX25_R2_ACCOUNT_ID:-ad08bb8c3fe9619985d859879e41d93f}
bucket=${LTX25_R2_BUCKET:-ltx25-packs}
prefix=${LTX25_R2_PREFIX:-ltx25}
[[ -z "$account" || "$account" =~ ^[a-f0-9]{32}$ ]] || { echo 'LTX25_R2_ACCOUNT_ID must be 32 lowercase hex characters' >&2; exit 2; }
[[ -z "$bucket" || "$bucket" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || { echo 'LTX25_R2_BUCKET is not a valid bucket name' >&2; exit 2; }
[[ "$prefix" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "/$prefix/" != */../* ]] || { echo 'LTX25_R2_PREFIX is invalid' >&2; exit 2; }
if [[ ${LTX25_RELEASE:-0} == 1 && ( -z "$account" || -z "$bucket" ) ]]; then echo 'LTX25_RELEASE=1 requires LTX25_R2_ACCOUNT_ID and LTX25_R2_BUCKET' >&2; exit 2; fi
ldflags="-s -w -X main.buildVersion=$version -X main.defaultAccountID=$account -X main.defaultBucket=$bucket -X main.defaultPrefix=$prefix"
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "$ldflags" -o dist/ltx25-download.exe .
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "$ldflags" -o dist/ltx25-download-linux-amd64 .
sha256sum dist/ltx25-download.exe > dist/ltx25-download.exe.sha256
