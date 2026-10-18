#!/usr/bin/env bash
# Installs and starts ComfyUI + LTX-2.5 from an offline pack on Ubuntu 24.04.
# Never touches the network: system packages, Python wheels, models and custom
# nodes all come from the pack. See README-offline-install.md.
set +x
set -Eeuo pipefail
umask 022

here=$(dirname "$(readlink -f "$0")")
# shellcheck source=lib/ltx25-common.sh
source "$here/lib/ltx25-common.sh"
trap 'printf "ERROR: stopped at line %s; correct the problem and rerun.\n" "$LINENO" >&2' ERR

usage() {
    printf '%s\n' \
      'Usage: bash ltx25-pack-deploy.sh [install|start|verify|help] [ComfyUI arguments...]' \
      'install: install or update from this pack (root, NVIDIA GPU, Ubuntu 24.04)' \
      'start:   run the installed release; also works from $INSTALL_ROOT/bin after the pack is removed' \
      'verify:  check every pack file against SHA256SUMS (e.g. after copying from the file server)' \
      'Environment:' \
      '  INSTALL_ROOT   Code, Python, venv. Default: /opt/comfyui-ltx25' \
      '  DATA_ROOT      Models, input, output, workflows. Default: $INSTALL_ROOT/data;' \
      '                 remembered by install, so start needs only INSTALL_ROOT' \
      '  TORCH_CUDA     auto (default: newest pool the driver supports), cu130, cu128 or cu126' \
      '  PACK_VERIFY    1 (default) checks sha256 of pack files and installed models; 0 skips' \
      '  LISTEN / PORT  Default: 0.0.0.0 / 8188 (start)' \
      '  COMFYUI_MANAGER               0 starts without ComfyUI-Manager (start)' \
      '  COMFYUI_MANAGER_NETWORK_MODE  Default: offline (start)'
}

action=${1:-help}
(( $# )) && shift
case "$action" in
    help|--help|-h) usage; exit 0 ;;
    install|verify) (( $# == 0 )) || die "$action takes no arguments." ;;
    start) ;;
    *) usage >&2; die "Unknown action: $action" ;;
esac

if [[ "$action" == verify ]]; then
    load_pack_env "$here/pack.env"
    log "Verifying pack ${PACK[PACK_VERSION]} in $here"
    (cd "$here" && sha256sum -c --quiet --strict SHA256SUMS) ||
        die 'Pack verification failed; copy the listed files again from the file server.'
    log 'All pack files match SHA256SUMS.'
    exit 0
fi

INSTALL_ROOT=${INSTALL_ROOT:-/opt/comfyui-ltx25}
[[ "$INSTALL_ROOT" == /* && "$INSTALL_ROOT" != / ]] || die 'INSTALL_ROOT must be an absolute, non-root directory.'
if [[ -z ${DATA_ROOT:-} && -f "$INSTALL_ROOT/deploy.env" ]]; then
    DATA_ROOT=$(sed -n 's/^DATA_ROOT=//p' "$INSTALL_ROOT/deploy.env")
fi
DATA_ROOT=${DATA_ROOT:-$INSTALL_ROOT/data}
[[ "$DATA_ROOT" == /* && "$DATA_ROOT" != / ]] || die 'DATA_ROOT must be an absolute, non-root directory.'
export INSTALL_ROOT DATA_ROOT

manager_installed() {
    "$1/.venv/bin/python" -c \
        'import importlib.util, sys; sys.exit(importlib.util.find_spec("comfyui_manager") is None)' 2>/dev/null
}

if [[ "$action" == start ]]; then
    [[ -f "$INSTALL_ROOT/active-release" ]] || die "No installation in $INSTALL_ROOT; run install first."
    load_pack_env "$INSTALL_ROOT/pack.env"
    release=$(<"$INSTALL_ROOT/active-release")
    [[ "$release" =~ ^[a-f0-9]{40}$ ]] || die 'Invalid active-release file.'
    app="$INSTALL_ROOT/releases/$release"
    [[ -x "$app/.venv/bin/python" && -f "$app/main.py" ]] || die 'Installed release is incomplete; run install again.'
    if mismatch=$(torch_driver_mismatch "$app"); then
        die "$mismatch Run install again on this host to select a matching PyTorch pool."
    fi
    exec 9>"$INSTALL_ROOT/setup.lock"
    flock -n 9 || die 'An installation or ComfyUI process already holds the lock.'
    link_data_dirs
    db_args=()
    if data_is_split && grep -q -- '--database-url' "$app/comfy/cli_args.py"; then
        db_args=(--database-url "sqlite:///$INSTALL_ROOT/comfyui.db")
    fi
    export LISTEN=${LISTEN:-0.0.0.0} PORT=${PORT:-8188}
    "$app/.venv/bin/python" - <<'PY'
import os, socket
port = int(os.environ['PORT'])
if not 1 <= port <= 65535:
    raise SystemExit('PORT must be between 1 and 65535.')
host = os.environ['LISTEN']
with socket.socket(socket.AF_INET6 if ':' in host else socket.AF_INET) as s:
    s.bind((host, port))
PY
    manager_args=()
    if [[ ${PACK[COMFYUI_MANAGER]} == 1 && ${COMFYUI_MANAGER:-1} != 0 ]] && manager_installed "$app"; then
        mode=${COMFYUI_MANAGER_NETWORK_MODE:-offline}
        [[ "$mode" =~ ^(personal_cloud|public|private|offline)$ ]] ||
            die 'COMFYUI_MANAGER_NETWORK_MODE must be offline, private, public or personal_cloud.'
        write_manager_config "$app/.venv/bin/python" "$mode"
        manager_args=(--enable-manager)
    fi
    strip_secrets
    # Fail fast instead of hanging on a download a node was not expected to need.
    export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 HF_DATASETS_OFFLINE=1 \
        AUX_ANNOTATOR_CKPTS_PATH="$INSTALL_ROOT/data/models/annotators"
    cd "$app"
    log "Starting ComfyUI ${PACK[COMFYUI_TAG]} (pack ${PACK[PACK_VERSION]}) on ${LISTEN}:${PORT}; output: $DATA_ROOT/output"
    exec "$app/.venv/bin/python" main.py --base-directory "$INSTALL_ROOT/data" \
        --listen "$LISTEN" --port "$PORT" "${manager_args[@]}" "${db_args[@]}" "$@"
fi

# ---- install ---------------------------------------------------------------
load_pack_env "$here/pack.env"
require_ubuntu_2404
[[ $EUID == 0 ]] || die 'Install requires root (system packages from the pack).'
runtime="$here/runtime/linux-x86_64"
for file in SHA256SUMS manifest.json runtime/linux-x86_64/base.tar; do
    [[ -f "$here/$file" ]] || die "Incomplete pack: $file is missing. Copy the whole pack directory again."
done
[[ -d "$here/models" ]] || die 'Incomplete pack: models/ is missing. Copy the whole pack directory again.'

command -v nvidia-smi >/dev/null || die 'nvidia-smi not found: install the NVIDIA driver on the host and expose the GPU.'
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
driver=$(host_driver_major) || die 'Cannot determine the NVIDIA driver version.'
read -r -a pools <<< "${PACK[TORCH_POOLS]:-}"
TORCH_CUDA=${TORCH_CUDA:-auto}
pool=
if [[ "$TORCH_CUDA" == auto ]]; then
    for tag in cu130 cu128 cu126; do
        [[ " ${pools[*]} " == *" $tag "* ]] || continue
        if (( driver >= $(min_driver_for_torch_cuda "$tag") )); then pool=$tag; break; fi
    done
    [[ -n $pool ]] || die "Host driver R$driver is too old for every PyTorch pool in this pack (${pools[*]}); R525 or newer is required."
else
    need=$(min_driver_for_torch_cuda "$TORCH_CUDA") || die 'TORCH_CUDA must be auto, cu130, cu128 or cu126.'
    [[ " ${pools[*]} " == *" $TORCH_CUDA "* ]] || die "This pack has no $TORCH_CUDA pool (it has: ${pools[*]})."
    (( driver >= need )) || die "TORCH_CUDA=$TORCH_CUDA needs an R$need or newer host driver; this host has R$driver."
    pool=$TORCH_CUDA
fi
[[ -f "$runtime/wheels-$pool.tar" ]] || die "Incomplete pack: runtime/linux-x86_64/wheels-$pool.tar is missing."
log "Host driver R$driver: using the $pool PyTorch pool"

supports_permissions "$INSTALL_ROOT" ||
    die "$INSTALL_ROOT does not support file permissions; choose a local-disk INSTALL_ROOT."
mkdir -p "$INSTALL_ROOT" "$DATA_ROOT"
INSTALL_ROOT=$(realpath "$INSTALL_ROOT")
DATA_ROOT=$(realpath "$DATA_ROOT")
[[ "$INSTALL_ROOT" != / && "$DATA_ROOT" != / ]] || die 'INSTALL_ROOT or DATA_ROOT resolves to /.'
[[ "$INSTALL_ROOT/" != "$here/"* && "$DATA_ROOT/" != "$here/"* ]] || die 'Install outside the pack directory.'
export INSTALL_ROOT DATA_ROOT
exec 9>"$INSTALL_ROOT/setup.lock"
flock -n 9 || die 'Stop the ComfyUI process started by this script before installing/updating.'

# Disk: extracted runtime plus a venv (about twice the wheels), and models not yet copied.
models_need=0
while IFS= read -r -d '' file; do
    rel=${file#"$here/models/"} size=$(stat -c %s "$file")
    dest="$DATA_ROOT/models/$rel"
    [[ -f "$dest" && $(stat -c %s "$dest") == "$size" ]] || models_need=$(( models_need + size ))
done < <(find "$here/models" -type f -print0)
runtime_need=$(( $(stat -c %s "$runtime/base.tar") * 2 + $(stat -c %s "$runtime/wheels-$pool.tar") * 3 + 10 * 1024**3 ))
free_install=$(df --output=avail -B1 "$INSTALL_ROOT" | tail -n 1)
free_data=$(df --output=avail -B1 "$DATA_ROOT" | tail -n 1)
if [[ $(stat -c %d "$INSTALL_ROOT") == $(stat -c %d "$DATA_ROOT") ]]; then
    (( free_install >= runtime_need + models_need )) ||
        die "Insufficient disk: $(( free_install / 1024**3 ))GiB free in $INSTALL_ROOT, need about $(( (runtime_need + models_need) / 1024**3 ))GiB."
else
    (( free_install >= runtime_need )) ||
        die "Insufficient disk: $(( free_install / 1024**3 ))GiB free in $INSTALL_ROOT, need about $(( runtime_need / 1024**3 ))GiB."
    (( free_data >= models_need + 1024**3 )) ||
        die "Insufficient disk: $(( free_data / 1024**3 ))GiB free in $DATA_ROOT, need about $(( models_need / 1024**3 + 1 ))GiB."
fi

if [[ ${PACK_VERIFY:-1} == 1 ]]; then
    log 'Verifying the pack runtime files'
    (cd "$here" && grep -v '  models/' SHA256SUMS | sha256sum -c --quiet --strict) ||
        die 'Pack verification failed; copy the listed files again from the file server.'
fi

staging="$INSTALL_ROOT/cache/pack-staging"
log "Extracting the runtime of pack ${PACK[PACK_VERSION]}"
rm -rf "$staging"
mkdir -p "$staging"
tar -xf "$runtime/base.tar" -C "$staging" --no-same-owner
tar -xf "$runtime/wheels-$pool.tar" -C "$staging" --no-same-owner

install_debs() {
    local pkg missing=() apt_dir="$INSTALL_ROOT/cache/apt" opts
    for pkg in ${PACK[DEB_PACKAGES]}; do
        [[ $(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null) == installed ]] || missing+=("$pkg")
    done
    if (( ${#missing[@]} == 0 )); then
        log 'System packages already installed'
        return 0
    fi
    log "Installing system packages from the pack: ${missing[*]}"
    # A private apt configuration that sees only the pack's local repository:
    # no network, and the host's own sources and package lists stay untouched.
    rm -rf "$apt_dir"
    mkdir -p "$apt_dir/lists/partial" "$apt_dir/sources.list.d"
    printf 'deb [trusted=yes] file:%s ./\n' "$staging/debs" > "$apt_dir/sources.list"
    opts=(-o Dir::Etc::SourceList="$apt_dir/sources.list" -o Dir::Etc::SourceParts="$apt_dir/sources.list.d"
          -o Dir::State::Lists="$apt_dir/lists" -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache=
          -o Acquire::Languages=none -o APT::Get::List-Cleanup=0)
    DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" -q update
    DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" -q -y install --no-install-recommends "${missing[@]}" ||
        die 'System packages from the pack failed to install; see the apt messages above.'
    rm -rf "$apt_dir"
}
install_debs

link_data_dirs
mkdir -p "$INSTALL_ROOT"/{releases,logs,python,bootstrap/bin} "$INSTALL_ROOT"/data/{models,user/default/workflows}
pydir=${PACK[PYTHON_DIR]}
if [[ ! -x "$INSTALL_ROOT/python/$pydir/bin/python3.12" ]]; then
    rm -rf "$INSTALL_ROOT/python/.$pydir.tmp"
    cp -a "$staging/python/$pydir" "$INSTALL_ROOT/python/.$pydir.tmp"
    mv "$INSTALL_ROOT/python/.$pydir.tmp" "$INSTALL_ROOT/python/$pydir"
fi
install -m 0755 "$staging/bin/uv" "$INSTALL_ROOT/bootstrap/bin/uv"
uv="$INSTALL_ROOT/bootstrap/bin/uv"
export UV_OFFLINE=1 UV_NO_PROGRESS=1 UV_CACHE_DIR="$INSTALL_ROOT/cache/uv" UV_PYTHON_DOWNLOADS=never

release=${PACK[COMFYUI_COMMIT]}
app="$INSTALL_ROOT/releases/$release"
if [[ ! -e "$app" ]]; then
    rm -rf "$INSTALL_ROOT/releases/.$release.tmp"
    cp -a "$staging/comfyui" "$INSTALL_ROOT/releases/.$release.tmp"
    mv "$INSTALL_ROOT/releases/.$release.tmp" "$app"
fi
[[ -f "$app/main.py" ]] || die "$app exists but is not a ComfyUI release; remove it and rerun."

py="$app/.venv/bin/python"
if [[ -x "$py" ]]; then
    tag=$("$py" -c 'from importlib.metadata import version; print(version("torch").partition("+")[2])' 2>/dev/null) || tag=
    if [[ "$tag" != "$pool" ]]; then
        log "Replacing the ${tag:-incomplete} environment with the $pool pool"
        rm -rf "$app/.venv"
    fi
fi
[[ -x "$py" ]] || "$uv" venv --python "$INSTALL_ROOT/python/$pydir/bin/python3.12" "$app/.venv"
log "Installing $pool PyTorch and ComfyUI dependencies from local wheels"
"$uv" pip sync --python "$py" --offline --no-index --no-build \
    --find-links "$staging/wheels/common" --find-links "$staging/wheels/$pool" \
    "$staging/requirements/offline-$pool.txt" ||
    die "The $pool package pool is incomplete; rebuild the pack or copy it again."
cp "$staging/requirements/torch-$pool.txt" "$app/torch-constraints.txt"
"$uv" pip check --python "$py"
cuda_selftest "$py"

install_custom_nodes() {
    local nodes="$INSTALL_ROOT/data/custom_nodes" marker="$app/custom-nodes-installed" src name dir rc
    local backup="$INSTALL_ROOT/backup/custom_nodes"
    for src in "$staging/custom_nodes"/*/; do
        [[ -d "$src" ]] || continue
        src=${src%/} name=${src##*/}
        rc=0; dir=$(custom_node_dir "$nodes" "$name") || rc=$?
        if (( rc == 2 )); then
            log "Custom node pack $name is disabled in Manager; leaving it alone"
            continue
        fi
        if (( rc == 0 )); then
            if [[ "$dir" == "$nodes/$name" &&
                  $(git -C "$dir" rev-parse HEAD 2>/dev/null) == $(git -C "$src" rev-parse HEAD) ]]; then
                grep -qxF "$name" "$marker" 2>/dev/null || printf '%s\n' "$name" >> "$marker"
                continue
            fi
            mkdir -p "$backup"
            mv "$dir" "$backup/${dir##*/}.$(date +%Y%m%d-%H%M%S)"
            log "Moved the previous ${dir##*/} to $backup"
        fi
        log "Installing custom node pack $name"
        rm -rf "$nodes/.$name.tmp"
        cp -a "$src" "$nodes/.$name.tmp"
        mv "$nodes/.$name.tmp" "$nodes/$name"
        grep -qxF "$name" "$marker" 2>/dev/null || printf '%s\n' "$name" >> "$marker"
    done
}
install_custom_nodes

log 'Copying models'
while IFS= read -r -d '' file; do
    rel=${file#"$here/models/"} dest="$DATA_ROOT/models/$rel"
    size=$(stat -c %s "$file")
    [[ -f "$dest" && $(stat -c %s "$dest") == "$size" ]] && continue
    printf '  %s (%s)\n' "$rel" "$(numfmt --to=iec-i --suffix=B "$size")"
    mkdir -p "$(dirname "$dest")"
    cp "$file" "$dest.ltx25-partial"
    # A read-only pack (NFS/SMB mount) would otherwise leave read-only copies.
    chmod 0644 "$dest.ltx25-partial"
    mv "$dest.ltx25-partial" "$dest"
done < <(find "$here/models" -type f -print0 | sort -z)
if [[ ${PACK_VERIFY:-1} == 1 ]]; then
    log 'Verifying installed models'
    failed=$(cd "$DATA_ROOT" && grep '  models/' "$here/SHA256SUMS" | sha256sum -c --strict 2>/dev/null |
             sed -n 's/: FAILED.*$//p' || true)
    if [[ -n $failed ]]; then
        while IFS= read -r rel; do rm -f "$DATA_ROOT/$rel"; done <<< "$failed"
        die "Corrupt model files removed; rerun install to copy them again: $(tr '\n' ' ' <<< "$failed")"
    fi
fi

log 'Installing workflows'
workflows="$INSTALL_ROOT/data/user/default/workflows"
for file in "$staging/workflows"/*.json; do
    target="$workflows/${file##*/}"
    if [[ -e "$target" ]]; then
        cmp -s "$file" "$target" && continue
        # Preserve the user's edited copy, as setup-comfyui-ltx25.sh does.
        target=${target%.json}.upstream.json
    fi
    cp "$file" "$target.tmp"
    mv "$target.tmp" "$target"
done

if [[ ${PACK[COMFYUI_MANAGER]} == 1 ]] && manager_installed "$app"; then
    write_manager_config "$py" offline
fi
# Keep start usable after the pack directory is removed.
install -D -m 0755 "$here/ltx25-pack-deploy.sh" "$INSTALL_ROOT/bin/ltx25-pack-deploy.sh"
install -D -m 0644 "$here/lib/ltx25-common.sh" "$INSTALL_ROOT/bin/lib/ltx25-common.sh"
install -m 0644 "$here/pack.env" "$here/manifest.json" "$INSTALL_ROOT/"
printf 'DATA_ROOT=%s\n' "$DATA_ROOT" > "$INSTALL_ROOT/deploy.env"
"$uv" pip freeze --python "$py" > "$app/installed-packages.txt"
printf '%s\n' "$release" > "$INSTALL_ROOT/active-release.tmp"
mv "$INSTALL_ROOT/active-release.tmp" "$INSTALL_ROOT/active-release"
[[ ${PACK_KEEP_STAGING:-0} == 1 ]] || rm -rf "$staging"

log "Installation complete: pack ${PACK[PACK_VERSION]}, ComfyUI ${PACK[COMFYUI_TAG]} ($release), $pool"
printf 'Models/output/workflows: %s\n' "$DATA_ROOT"
printf 'Start: INSTALL_ROOT=%q bash %q start\n' "$INSTALL_ROOT" "$INSTALL_ROOT/bin/ltx25-pack-deploy.sh"
