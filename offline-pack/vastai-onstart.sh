#!/usr/bin/env bash
# Vast.ai on-start script for the offline pack builder (image ubuntu:24.04, 150GB+ disk).
# Installs the tools, fetches this repository, checks R2, then builds and uploads a pack
# in the background. Secrets (HF_TOKEN, R2_*) come from Vast.ai account environment
# variables, never from the template. Restarting the instance resumes where it stopped.
# Log: $LTX25_HOME/build.log
set -Eeuo pipefail

LTX25_REPO=${LTX25_REPO:-https://github.com/beamverse/runpod-comfyui-ltx25.git}
LTX25_REF=${LTX25_REF:-main}
LTX25_HOME=${LTX25_HOME:-/root/ltx25}
LTX25_AUTOBUILD=${LTX25_AUTOBUILD:-1}

log() { printf '[ltx25-onstart] %s\n' "$*"; }
mkdir -p "$LTX25_HOME"
exec > >(tee -a "$LTX25_HOME/onstart.log") 2>&1

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git unzip
if ! command -v rclone >/dev/null; then
    curl -fsSL https://rclone.org/install.sh | bash
fi

repo="$LTX25_HOME/repo"
if [[ -d "$repo/.git" ]]; then
    git -C "$repo" fetch -q --depth 1 origin "$LTX25_REF"
    git -C "$repo" checkout -q --detach FETCH_HEAD
else
    git clone -q --depth 1 --branch "$LTX25_REF" "$LTX25_REPO" "$repo"
fi
build="$repo/offline-pack/ltx25-pack-build.sh"
[[ -f "$build" ]] || { log "No offline-pack/ in $LTX25_REPO@$LTX25_REF; push it first."; exit 1; }
log "Repository at $(git -C "$repo" rev-parse --short HEAD)"

bash "$build" check-r2
[[ -n ${HF_TOKEN:-} ]] || { log 'HF_TOKEN is not set; add it to the Vast.ai account environment variables.'; exit 1; }
[[ "$LTX25_AUTOBUILD" == 1 ]] || { log 'LTX25_AUTOBUILD=0: tools ready, not building.'; exit 0; }

# The version is chosen once, so a restarted instance continues the same build.
[[ -s "$LTX25_HOME/version" ]] || printf '%s\n' "${PACK_VERSION:-$(date -u +%Y%m%d-%H%M%S)}" > "$LTX25_HOME/version"
version=$(<"$LTX25_HOME/version")
pack="$LTX25_HOME/pack-$version"
if [[ -f "$LTX25_HOME/uploaded-$version" ]]; then
    log "Pack $version is already uploaded. Destroy this instance."
    exit 0
fi

log "Building and uploading pack $version in the background; follow: tail -f $LTX25_HOME/build.log"
PACK_VERSION="$version" setsid nohup bash -c '
    set -e
    build=$1 pack=$2 marker=$3
    [[ -f "$pack/SHA256SUMS" ]] || bash "$build" create "$pack"
    bash "$build" upload "$pack"
    touch "$marker"
    echo "[ltx25-onstart] Done: pack $(basename "$pack") is in R2. Destroy this instance to stop billing and drop its secrets."
' _ "$build" "$pack" "$LTX25_HOME/uploaded-$version" >> "$LTX25_HOME/build.log" 2>&1 < /dev/null &
