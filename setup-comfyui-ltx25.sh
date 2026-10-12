#!/usr/bin/env bash
# RunPod / Ubuntu or Debian / NVIDIA GPU (RTX 5090, A100, ...). See the companion README.
# Source operations: git clone/fetch/worktree (isolated installer-owned releases).
set +x
set -Eeuo pipefail
umask 022

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n[comfyui-ltx25] %s\n' "$*"; }
trap 'printf "ERROR: setup stopped at line %s; correct the problem and rerun.\n" "$LINENO" >&2' ERR
usage() {
    printf '%s\n' \
      'Usage: bash setup-comfyui-ltx25.sh [install|start|startup|help] [ComfyUI arguments...]' \
      'install (default): install/update ComfyUI + CUDA PyTorch + LTX-2.5 models' \
      'start: run the last successfully installed release; no token needed' \
      'startup: RunPod boot mode; start base services, install once if needed, then start ComfyUI' \
      'Environment:' \
      '  HF_TOKEN          Hugging Face read token; hidden prompt if omitted' \
      '  INSTALL_ROOT      Code (ComfyUI, Python, venv). Default: /workspace/comfyui-ltx25, or' \
      '                    /opt/comfyui-ltx25 when /workspace rejects chmod (S3-backed network volume)' \
      '  DATA_ROOT         Models, input, output, user settings. Default: /workspace/comfyui-ltx25/data' \
      '                    when INSTALL_ROOT is unset, otherwise $INSTALL_ROOT/data' \
      '  COMFYUI_REF       latest (default), master, or a release tag such as v0.32.0' \
      '  LTX_VARIANT       int8 (default, fits 32GB VRAM) or bf16 (full precision, upstream template)' \
      '  LTX_TEXT_ENCODER  int8 or bf16 Gemma 4 text encoder; default: same as LTX_VARIANT' \
      '  LTX_FRAME_STRENGTH  I2V/FLF2V keyframe strength, 0-1; default 0.9 (upstream 0.7)' \
      '  COMFYUI_MANAGER   1 (default) installs ComfyUI-Manager and starts with --enable-manager; 0 disables' \
      '  COMFYUI_MANAGER_NETWORK_MODE  personal_cloud (default; lets Manager install nodes while' \
      '                    listening on 0.0.0.0), public, private or offline' \
      '  COMFYUI_CUSTOM_NODES  1 (default) installs the audio-drive workflow node packs on start; 0 disables' \
      '  LISTEN / PORT     Default: 0.0.0.0 / 8188 (start/startup)' \
      '  RUNPOD_START_BASE_SERVICES  Default: 1; run /start.sh in startup mode when present' \
      '  TORCH_CUDA        auto (default), cu130, cu128 or cu126 PyTorch build' \
      'Requires a GPU-enabled Linux x86_64 container and an R525 or newer host driver' \
      '(R580+ installs CUDA 13.0 PyTorch; R570+ is required for RTX 50-series GPUs).' \
      'Accept the Lightricks/LTX-2.5 license on Hugging Face before installation.'
}

# PyTorch CUDA build selection. CUDA 12.x wheels also run on R525+ drivers via
# minor-version compatibility (e.g. RunPod A100 hosts on R550); Blackwell GPUs
# such as the RTX 5090 need cu128 or newer and therefore an R570+ driver.
host_driver_major() {
    local driver
    driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1) || return 1
    driver=${driver%%.*}
    [[ "$driver" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$driver"
}
min_driver_for_torch_cuda() {
    case "$1" in
        cu130) echo 580 ;;
        cu128) echo 570 ;;
        cu126) echo 525 ;;
        *) return 1 ;;
    esac
}
torch_cuda_for_driver() {
    local tag
    for tag in cu130 cu128 cu126; do
        if (( $1 >= $(min_driver_for_torch_cuda "$tag") )); then echo "$tag"; return 0; fi
    done
    return 1
}
# Prints why the release's PyTorch cannot run on this host (e.g. a persistent
# volume installed on an R580 host, now attached to an R550 host).
torch_driver_mismatch() {
    local tag need driver
    tag=$("$1/.venv/bin/python" -c \
        'from importlib.metadata import version; print(version("torch").partition("+")[2])' 2>/dev/null) || return 1
    if need=$(min_driver_for_torch_cuda "$tag") && driver=$(host_driver_major) && (( driver < need )); then
        printf 'Installed PyTorch (%s) needs an R%s+ host driver; this host has R%s.\n' "$tag" "$need" "$driver"
        return 0
    fi
    # A build can suit the driver yet lack kernels for the GPU: cu126 wheels stop
    # at sm_90, so a volume installed on an Ampere host fails on an RTX 5090.
    # Same rule as torch's own warning: a GPU runs cubins of its major version.
    "$1/.venv/bin/python" - 2>/dev/null <<'PY'
import re, torch
if not torch.cuda.is_available():
    raise SystemExit(1)
built = {int(re.sub(r'\D', '', a)) // 10 for a in torch.cuda.get_arch_list() if a.startswith('sm_')}
for i in range(torch.cuda.device_count()):
    major, minor = torch.cuda.get_device_capability(i)
    if built and major not in built:
        print(f'Installed PyTorch ({torch.__version__}) has no kernels for '
              f'{torch.cuda.get_device_name(i)} (sm_{major}{minor}).')
        raise SystemExit(0)
raise SystemExit(1)
PY
}

# ComfyUI-Manager ships as a pip package pinned by the release's
# manager_requirements.txt; releases without that file predate --enable-manager.
manager_installed() {
    "$1/.venv/bin/python" -c \
        'import importlib.util, sys; sys.exit(importlib.util.find_spec("comfyui_manager") is None)' 2>/dev/null
}
install_manager() {
    UV_CACHE_DIR="$INSTALL_ROOT/cache/uv" "$INSTALL_ROOT/bootstrap/bin/uv" pip install \
        --python "$1/.venv/bin/python" -r "$1/manager_requirements.txt" -c "$1/torch-constraints.txt"
}

# S3-backed RunPod network volumes (fuse.geesefs) store every file as 0666 and
# reject chmod, so a venv or uv-managed Python there could never execute.
supports_permissions() {
    local probe ok=1
    mkdir -p "$1" 2>/dev/null || return 1
    probe=$(mktemp "$1/.permission-probe.XXXXXX" 2>/dev/null) || return 1
    if chmod 700 "$probe" 2>/dev/null && [[ $(stat -c %a "$probe") == 700 ]]; then ok=0; fi
    rm -f "$probe"
    return $ok
}
data_is_split() { [[ $(realpath -m "$DATA_ROOT") != $(realpath -m "$INSTALL_ROOT/data") ]]; }
# ComfyUI's base directory is always $INSTALL_ROOT/data. With DATA_ROOT elsewhere,
# models/input/output/user there are symlinks into DATA_ROOT, while custom_nodes
# (code) and temp stay on the local disk next to the release.
link_data_dirs() {
    local data="$INSTALL_ROOT/data" name
    mkdir -p "$data/custom_nodes"
    data_is_split || return 0
    for name in models input output user; do
        mkdir -p "$DATA_ROOT/$name"
        if [[ -L "$data/$name" ]]; then
            [[ $(readlink "$data/$name") == "$DATA_ROOT/$name" ]] && continue
            rm "$data/$name"
        elif [[ -e "$data/$name" ]]; then
            rmdir "$data/$name" 2>/dev/null ||
                die "$data/$name is a non-empty directory; move its contents to $DATA_ROOT/$name first."
        fi
        ln -s "$DATA_ROOT/$name" "$data/$name"
    done
}

# Custom node packs used by workflows/ltx25-audio-drive.json. They live in the
# persistent data/custom_nodes, but their Python dependencies go into the
# release's .venv, so each release records which packs it already has.
CUSTOM_NODE_REPOS=(
    https://github.com/rgthree/rgthree-comfy
    https://github.com/melMass/comfy_mtb
    https://github.com/kijai/ComfyUI-KJNodes
    https://github.com/pythongosssss/ComfyUI-Custom-Scripts
)
node_key() { local n=${1,,}; printf '%s\n' "${n//_/-}"; }
# Prints the pack's directory. Manager registry installs use the lowercase id
# (comfyui-kjnodes), git installs the repo name (ComfyUI-KJNodes); both count.
# A pack disabled in Manager (.disabled/<id>@<version>) returns 2: leave it alone.
custom_node_dir() {
    local want dir name
    want=$(node_key "$2")
    for dir in "$1"/*/ "$1"/.disabled/*/; do
        [[ -d "$dir" ]] || continue
        name=$(basename "$dir")
        [[ $(node_key "${name%@*}") == "$want" ]] || continue
        [[ "$dir" == "$1/.disabled/"* ]] && return 2
        printf '%s\n' "${dir%/}"
        return 0
    done
    return 1
}
install_custom_nodes() {
    local app=$1 nodes="$INSTALL_ROOT/data/custom_nodes" marker="$1/custom-nodes-installed"
    local uv="$INSTALL_ROOT/bootstrap/bin/uv" url name dir rc changed= constraints=()
    [[ -f "$app/torch-constraints.txt" ]] && constraints=(-c "$app/torch-constraints.txt")
    for url in "${CUSTOM_NODE_REPOS[@]}"; do
        name=${url##*/}
        rc=0; dir=$(custom_node_dir "$nodes" "$name") || rc=$?
        (( rc == 2 )) && continue
        if (( rc == 1 )); then
            log "Installing custom node pack $name"
            dir="$nodes/$name"
            rm -rf "$nodes/.$name.tmp"
            # Close the lock fd: git may leave background maintenance running.
            if ! command git clone --depth 1 "$url" "$nodes/.$name.tmp" 9>&- ||
               ! mv "$nodes/.$name.tmp" "$dir"; then
                rm -rf "$nodes/.$name.tmp"
                printf 'WARNING: could not download %s; install it from Manager instead.\n' "$name" >&2
                continue
            fi
        fi
        grep -qxF "$name" "$marker" 2>/dev/null && continue
        if [[ -s "$dir/requirements.txt" ]]; then
            log "Installing Python dependencies of $name"
            if ! UV_CACHE_DIR="$INSTALL_ROOT/cache/uv" "$uv" pip install --python "$app/.venv/bin/python" \
                    -r "$dir/requirements.txt" "${constraints[@]}"; then
                printf 'WARNING: dependencies of %s failed to install; its nodes may not load.\n' "$name" >&2
                continue
            fi
            changed=1
        fi
        printf '%s\n' "$name" >> "$marker"
    done
    if [[ -n $changed ]]; then
        "$uv" pip freeze --python "$app/.venv/bin/python" > "$app/installed-packages.txt"
    fi
}

action=${1:-install}
if (($#)); then shift; fi
case "$action" in
    help|--help|-h) usage; exit 0 ;;
    install|start|startup) ;;
    *) usage >&2; die "Unknown action: $action" ;;
esac
[[ "$action" == start || "$action" == startup || $# == 0 ]] || die 'Only start/startup accepts extra ComfyUI arguments.'
if [[ -z ${INSTALL_ROOT:-} ]]; then
    DATA_ROOT=${DATA_ROOT:-/workspace/comfyui-ltx25/data}
    if supports_permissions /workspace/comfyui-ltx25; then
        INSTALL_ROOT=/workspace/comfyui-ltx25
    else
        # The container disk is wiped when the Pod stops, so startup reinstalls
        # the code on each boot; models in DATA_ROOT are verified and reused.
        INSTALL_ROOT=/opt/comfyui-ltx25
        log "/workspace rejects chmod (S3-backed network volume?); code goes to $INSTALL_ROOT on the container disk, data stays in $DATA_ROOT"
    fi
fi
DATA_ROOT=${DATA_ROOT:-$INSTALL_ROOT/data}
[[ "$INSTALL_ROOT" == /* && "$INSTALL_ROOT" != / ]] || die 'INSTALL_ROOT must be an absolute, non-root directory.'
[[ "$DATA_ROOT" == /* && "$DATA_ROOT" != / ]] || die 'DATA_ROOT must be an absolute, non-root directory.'
supports_permissions "$INSTALL_ROOT" ||
    die "$INSTALL_ROOT does not support file permissions (S3-backed network volume?); set INSTALL_ROOT to a container-disk path and DATA_ROOT to the volume."
export INSTALL_ROOT DATA_ROOT
COMFYUI_MANAGER=${COMFYUI_MANAGER:-1}
[[ "$COMFYUI_MANAGER" == 0 || "$COMFYUI_MANAGER" == 1 ]] || die 'COMFYUI_MANAGER must be 0 or 1.'
COMFYUI_MANAGER_NETWORK_MODE=${COMFYUI_MANAGER_NETWORK_MODE:-personal_cloud}
[[ "$COMFYUI_MANAGER_NETWORK_MODE" =~ ^(personal_cloud|public|private|offline)$ ]] ||
    die 'COMFYUI_MANAGER_NETWORK_MODE must be personal_cloud, public, private or offline.'
COMFYUI_CUSTOM_NODES=${COMFYUI_CUSTOM_NODES:-1}
[[ "$COMFYUI_CUSTOM_NODES" == 0 || "$COMFYUI_CUSTOM_NODES" == 1 ]] || die 'COMFYUI_CUSTOM_NODES must be 0 or 1.'

# RunPod template boot mode. This keeps the startup command idempotent:
# - start the image's built-in services (SSH/Jupyter) when /start.sh exists;
# - install only when no successfully installed release exists;
# - then replace this process with the normal ComfyUI start path.
if [[ "$action" == startup ]]; then
    if [[ ${RUNPOD_START_BASE_SERVICES:-1} == 1 && -x /start.sh ]]; then
        log 'Starting RunPod base services via /start.sh'
        /start.sh &
    fi

    script_self=$(readlink -f "$0")
    [[ -f "$script_self" ]] || die 'Cannot resolve installer script path.'

    # Invoke through bash: the script may lack the executable bit after upload/clone.
    need_install=
    if [[ ! -f "$INSTALL_ROOT/active-release" ]]; then
        log 'First boot: no active release found; running one-time installation'
        need_install=1
    elif mismatch=$(torch_driver_mismatch "$INSTALL_ROOT/releases/$(<"$INSTALL_ROOT/active-release")"); then
        log "$mismatch Reinstalling a matching PyTorch build"
        need_install=1
    fi
    if [[ -n $need_install ]]; then
        if ! bash "$script_self" install; then
            # Exiting would stop the container, kill SSH/Jupyter and restart into
            # the same failure. Stay alive so the problem can be inspected.
            printf 'ERROR: first-boot installation failed. Pod kept alive for SSH/Jupyter;\n' >&2
            printf 'fix the cause, then rerun: bash %q install, or restart the Pod.\n' "$script_self" >&2
            exec sleep infinity
        fi
    else
        log 'Existing installation found; skipping install'
    fi

    exec bash "$script_self" start "$@"
fi

if [[ "$action" == start ]]; then
    [[ -f "$INSTALL_ROOT/active-release" ]] || die 'Run install first.'
    release=$(<"$INSTALL_ROOT/active-release")
    [[ "$release" =~ ^[a-f0-9]{40}$ ]] || die 'Invalid active-release file.'
    app="$INSTALL_ROOT/releases/$release"
    [[ -x "$app/.venv/bin/python" && -f "$app/main.py" ]] || die 'Installed release is incomplete.'
    if mismatch=$(torch_driver_mismatch "$app"); then
        die "$mismatch Rerun install on this host for a matching PyTorch build."
    fi
    exec 9>"$INSTALL_ROOT/setup.lock"
    flock -n 9 || die 'An installation or ComfyUI process already holds the lock.'
    # ComfyUI scans custom_nodes before starting the server, even when empty.
    # Create it (and the DATA_ROOT links) on every start to repair older installations.
    link_data_dirs
    db_args=()
    # The assets database defaults to the user directory; keep SQLite off the
    # network volume, whose FUSE layer handles its locks and small writes poorly.
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
    if [[ "$COMFYUI_MANAGER" == 1 && -f "$app/manager_requirements.txt" ]]; then
        # Releases installed by older scripts lack the package; add it in place.
        if ! manager_installed "$app"; then
            log 'Installing ComfyUI-Manager into the active release'
            if install_manager "$app"; then
                "$INSTALL_ROOT/bootstrap/bin/uv" pip freeze --python "$app/.venv/bin/python" > "$app/installed-packages.txt"
            else
                printf 'WARNING: ComfyUI-Manager installation failed; starting without it.\n' >&2
            fi
        fi
        if manager_installed "$app"; then manager_args=(--enable-manager); fi
        # With --listen 0.0.0.0, Manager's default network_mode (public) rejects
        # every node install; personal_cloud is its documented mode for RunPod.
        MANAGER_CONFIG="$INSTALL_ROOT/data/user/__manager/config.ini" \
        NETWORK_MODE="$COMFYUI_MANAGER_NETWORK_MODE" "$app/.venv/bin/python" - <<'PY'
import configparser, os
path = os.environ['MANAGER_CONFIG']
config = configparser.ConfigParser(strict=False)
config.read(path)
if not config.has_section('default'):
    config.add_section('default')
if config['default'].get('network_mode') != os.environ['NETWORK_MODE']:
    config['default']['network_mode'] = os.environ['NETWORK_MODE']
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        config.write(f)
PY
    fi
    # Packs missing from data/custom_nodes (or deps missing from a new release's
    # .venv) are added here, so existing installations get them without reinstalling.
    if [[ "$COMFYUI_CUSTOM_NODES" == 1 ]]; then install_custom_nodes "$app"; fi
    unset HF_TOKEN HUGGING_FACE_HUB_TOKEN
    cd "$app"
    log "Starting ComfyUI on ${LISTEN}:${PORT}; output: $DATA_ROOT/output"
    exec "$app/.venv/bin/python" main.py --base-directory "$INSTALL_ROOT/data" \
        --listen "$LISTEN" --port "$PORT" "${manager_args[@]}" "${db_args[@]}" "$@"
fi

[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'This installer targets Linux x86_64.'
[[ $EUID == 0 ]] || die 'Install requires root inside the container (apt packages).'
command -v apt-get >/dev/null || die 'Use an Ubuntu/Debian container with apt-get.'
command -v nvidia-smi >/dev/null || die 'GPU is not exposed. Deploy a GPU-enabled Pod first.'
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
driver=$(host_driver_major) || die 'Cannot determine NVIDIA driver version.'
TORCH_CUDA=${TORCH_CUDA:-auto}
torch_cuda_explicit=
if [[ "$TORCH_CUDA" == auto ]]; then
    TORCH_CUDA=$(torch_cuda_for_driver "$driver") || die "Host driver R$driver is too old; R525 or newer is required. Select another Pod host."
else
    need=$(min_driver_for_torch_cuda "$TORCH_CUDA") || die 'TORCH_CUDA must be auto, cu130, cu128 or cu126.'
    (( driver >= need )) || die "TORCH_CUDA=$TORCH_CUDA needs an R$need or newer host driver; this host has R$driver."
    torch_cuda_explicit=1
fi
log "Host driver R$driver: using the $TORCH_CUDA PyTorch build"
LTX_VARIANT=${LTX_VARIANT:-int8}
[[ "$LTX_VARIANT" == int8 || "$LTX_VARIANT" == bf16 ]] || die 'LTX_VARIANT must be int8 or bf16.'
LTX_TEXT_ENCODER=${LTX_TEXT_ENCODER:-$LTX_VARIANT}
[[ "$LTX_TEXT_ENCODER" == int8 || "$LTX_TEXT_ENCODER" == bf16 ]] || die 'LTX_TEXT_ENCODER must be int8 or bf16.'
LTX_FRAME_STRENGTH=${LTX_FRAME_STRENGTH:-0.9}
[[ "$LTX_FRAME_STRENGTH" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ && ! "$LTX_FRAME_STRENGTH" =~ ^0(\.0*)?$ ]] ||
    die 'LTX_FRAME_STRENGTH must be a number greater than 0 and at most 1.'
export LTX_VARIANT LTX_TEXT_ENCODER LTX_FRAME_STRENGTH
log "Models: $LTX_VARIANT transformer, $LTX_TEXT_ENCODER text encoder"

if [[ -z ${HF_TOKEN:-} ]]; then
    [[ -t 0 ]] || die 'Set HF_TOKEN for non-interactive installation.'
    read -r -s -p 'Hugging Face read token: ' HF_TOKEN
    printf '\n'
fi
[[ -n "$HF_TOKEN" ]] || die 'An HF_TOKEN is required.'
export HF_TOKEN

log 'Installing OS dependencies'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git python3 \
    python3-venv ffmpeg libgl1 libglib2.0-0 libgomp1 build-essential pkg-config util-linux

mkdir -p "$INSTALL_ROOT" "$DATA_ROOT"
INSTALL_ROOT=$(realpath "$INSTALL_ROOT")
DATA_ROOT=$(realpath "$DATA_ROOT")
[[ "$INSTALL_ROOT" != / && "$DATA_ROOT" != / ]] || die 'INSTALL_ROOT or DATA_ROOT resolves to /.'
export INSTALL_ROOT DATA_ROOT
exec 9>"$INSTALL_ROOT/setup.lock"
flock -n 9 || die 'Stop the ComfyUI process started by this script before installing/updating.'
# Git may detach background gc/maintenance; keep it from inheriting the lock fd,
# or the lock would outlive this installer and block the following start.
git() { command git "$@" 9>&-; }
mkdir -p "$INSTALL_ROOT"/{releases,logs}
link_data_dirs
mkdir -p "$INSTALL_ROOT"/data/{models,user/default/workflows}
df -h "$INSTALL_ROOT" "$DATA_ROOT"

# Separate bootstrap tools from ComfyUI dependencies; use Python 3.12 even
# when the container's system Python is older.
python3 -m venv "$INSTALL_ROOT/bootstrap"
# hf_hub_download(tqdm_class=...) needs huggingface_hub >= 1.1.
"$INSTALL_ROOT/bootstrap/bin/python" -m pip install --upgrade pip uv 'huggingface_hub>=1.1,<3'
export UV_PYTHON_INSTALL_DIR="$INSTALL_ROOT/python"
export UV_CACHE_DIR="$INSTALL_ROOT/cache/uv"
uv="$INSTALL_ROOT/bootstrap/bin/uv"
"$uv" python install 3.12

log 'Checking model access before installing the GPU packages'
"$INSTALL_ROOT/bootstrap/bin/python" - <<'PY'
import os
from huggingface_hub import get_hf_file_metadata, hf_hub_url
quant = {'int8': 'comfy-int8-convrot', 'bf16': 'bf16'}[os.environ['LTX_VARIANT']]
try:
    get_hf_file_metadata(hf_hub_url(
        'Lightricks/LTX-2.5',
        f'diffusion_models/ltx-2.5-22b-distilled-transformer-{quant}.safetensors'
    ), token=os.environ['HF_TOKEN'])
except Exception as exc:
    raise SystemExit(f'Model access failed ({type(exc).__name__}). Accept the LTX-2.5 license '
                     'and give your token read access to this gated repository.') from None
print('LTX-2.5 model access OK.')
PY

ref=${COMFYUI_REF:-latest}
if [[ "$ref" == latest ]]; then
    ref=$(curl --fail --silent --show-error --location --retry 3 \
        https://api.github.com/repos/Comfy-Org/ComfyUI/releases/latest |
        "$INSTALL_ROOT/bootstrap/bin/python" -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')
fi
[[ "$ref" == master || "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'COMFYUI_REF must be latest, master, or a vX.Y.Z release tag.'
log "Fetching ComfyUI $ref"
repo="$INSTALL_ROOT/source"
if [[ ! -e "$repo" ]]; then
    git clone --no-checkout --filter=blob:none https://github.com/Comfy-Org/ComfyUI.git "$repo"
fi
[[ -d "$repo/.git" ]] || die 'Installer source directory is not a Git checkout.'
[[ $(git -C "$repo" remote get-url origin) == https://github.com/Comfy-Org/ComfyUI.git ]] || die 'Unexpected source remote; refusing to update.'
if [[ "$ref" == master ]]; then
    git -C "$repo" fetch origin refs/heads/master
else
    git -C "$repo" fetch origin "refs/tags/$ref"
fi
release=$(git -C "$repo" rev-parse 'FETCH_HEAD^{commit}')
[[ "$release" =~ ^[a-f0-9]{40}$ ]] || die 'Invalid upstream commit.'
app="$INSTALL_ROOT/releases/$release"
if [[ ! -e "$app" ]]; then
    git -C "$repo" worktree add --detach "$app" "$release"
fi
[[ $(git -C "$app" rev-parse HEAD) == "$release" ]] || die 'Release directory was changed externally.'
[[ -z $(git -C "$app" status --porcelain --untracked-files=no) ]] || die 'ComfyUI source has local changes; refusing to update dependencies.'

if [[ ! -x "$app/.venv/bin/python" ]]; then
    "$uv" venv --python 3.12 "$app/.venv"
fi
py="$app/.venv/bin/python"
log "Installing $TORCH_CUDA PyTorch and release-matched ComfyUI requirements"
# Swap an installed torch only when its CUDA build cannot run on this host
# (venv built on a newer-driver host) or TORCH_CUDA explicitly asks for another.
installed_torch=$("$py" -c 'from importlib.metadata import version; print(version("torch"))' 2>/dev/null) || installed_torch=
if [[ -n "$installed_torch" && "$installed_torch" != *"+$TORCH_CUDA" ]] &&
   { [[ -n $torch_cuda_explicit ]] || mismatch=$(torch_driver_mismatch "$app"); }; then
    log "Replacing PyTorch $installed_torch with the $TORCH_CUDA build"
    "$uv" pip uninstall --python "$py" torch torchvision torchaudio
fi
# No --upgrade: reinstalling a release must not swap the torch build under the
# active ComfyUI. New releases get a fresh venv and thus the current torch.
"$uv" pip install --python "$py" torch torchvision torchaudio \
    --index-url "https://download.pytorch.org/whl/$TORCH_CUDA"
# Keep the normal package index from replacing the selected CUDA wheels.
"$py" - <<'PY' > "$app/torch-constraints.txt"
from importlib.metadata import version
for name in ('torch', 'torchvision', 'torchaudio'):
    print(f'{name}=={version(name)}')
PY
"$uv" pip install --python "$py" -r "$app/requirements.txt" -c "$app/torch-constraints.txt"
if [[ "$COMFYUI_MANAGER" == 1 ]]; then
    if [[ -f "$app/manager_requirements.txt" ]]; then
        log 'Installing release-matched ComfyUI-Manager'
        install_manager "$app"
    else
        log "ComfyUI $ref has no manager_requirements.txt; skipping ComfyUI-Manager"
    fi
fi
"$uv" pip check --python "$py"
"$py" - <<'PY'
import torch
if not torch.cuda.is_available():
    # Tell a broken host (nvidia-smi works, CUDA does not) apart from a PyTorch problem.
    import ctypes, os
    lines = ['CUDA is unavailable. Diagnostics:']
    visible = os.environ.get('CUDA_VISIBLE_DEVICES')
    if visible is not None:
        lines.append(f'  CUDA_VISIBLE_DEVICES={visible!r}')
    for dev in ('/dev/nvidiactl', '/dev/nvidia-uvm', '/dev/nvidia0'):
        lines.append(f'  {dev}: {"present" if os.path.exists(dev) else "MISSING"}')
    try:
        libcuda = ctypes.CDLL('libcuda.so.1')
    except OSError as e:
        lines.append(f'  libcuda.so.1: cannot load ({e})')
        lines.append('The container has no usable NVIDIA driver library; the GPU is not attached to this Pod.')
        raise SystemExit('\n'.join(lines))
    code = libcuda.cuInit(0)
    name = ctypes.c_char_p()
    libcuda.cuGetErrorName(code, ctypes.byref(name))
    lines.append(f'  cuInit = {code} ({name.value.decode() if name.value else "unknown"})')
    if code != 0:
        lines.append('The CUDA driver itself fails to initialise, so this is not a PyTorch problem: '
                     'the host GPU is not usable from this container (often a missing /dev/nvidia-uvm '
                     'or a GPU in a bad state). Restart the Pod; if it persists, terminate it and '
                     'deploy on another machine.')
    else:
        lines.append('The CUDA driver works but PyTorch cannot use it. Check that the PyTorch build '
                     f'({torch.__version__}) matches the host driver, or set TORCH_CUDA.')
    raise SystemExit('\n'.join(lines))
x = torch.randn((128, 128), device='cuda', dtype=torch.bfloat16)
result = x @ x
torch.cuda.synchronize()
assert torch.isfinite(result).all().item(), 'CUDA calculation failed.'
print('CUDA calculation OK:', torch.cuda.get_device_name(0), torch.__version__, torch.version.cuda)
PY

log 'Locating the release-matched LTX-2.5 template'
template=$("$py" - <<'PY'
from importlib.metadata import distributions
for dist in distributions():
    name = dist.metadata.get('Name', '').lower().replace('_', '-')
    if name.startswith('comfyui-workflow-templates'):
        for path in dist.files or []:
            if path.name == 'video_ltx2_5_t2v.json':
                print(dist.locate_file(path))
                raise SystemExit(0)
raise SystemExit('This release has no LTX-2.5 T2V template. Try COMFYUI_REF=master or a newer release.')
PY
)
export LTX_TEMPLATE="$template"
log "Downloading LTX-2.5 ${LTX_VARIANT^^} models (existing Hub downloads are reused)"
# All model files are Xet-backed; hf_xet already fetches chunks concurrently.
# High-performance mode raises that concurrency for fast datacenter links.
export HF_XET_HIGH_PERFORMANCE=${HF_XET_HIGH_PERFORMANCE:-1}
SCRIPT_DIR=$(dirname "$(readlink -f "$0")") "$INSTALL_ROOT/bootstrap/bin/python" - <<'PY'
import json, os, shutil, sys, urllib.request
from pathlib import Path, PurePosixPath
from urllib.parse import unquote, urlparse
from huggingface_hub import HfApi, get_hf_file_metadata, hf_hub_download, hf_hub_url
from tqdm.auto import tqdm

class ModelDownloadProgress(tqdm):
    def __init__(self, *args, **kwargs):
        # Force progress on, including in RunPod's non-interactive startup logs.
        kwargs.pop('name', None)
        kwargs.pop('position', None)
        # huggingface_hub 2.x adds a second Xet bar for network bytes whose total is
        # only an estimate (dedup/compression), so its percentage and ETA mislead.
        # Hide it; the reconstruction bar counts bytes on disk against the real size.
        desc = kwargs.get('desc') or ''
        transfer = desc.endswith(': downloading bytes')
        kwargs['desc'] = desc.removesuffix(': reconstructing file')
        self.log_output = not sys.stderr.isatty()
        kwargs.update(
            file=sys.stderr, disable=transfer, leave=True,
            mininterval=5.0 if self.log_output else 0.5, miniters=1,
            unit='B', unit_scale=True, unit_divisor=1024,
            bar_format='{desc}: {percentage:5.1f}% | {n_fmt}/{total_fmt} '
                       '| {rate_fmt} | ETA {remaining}',
        )
        super().__init__(*args, **kwargs)

    def display(self, msg=None, pos=None):
        if self.log_output:
            # Plain lines survive log collectors that do not render carriage returns.
            if msg != '':
                self.fp.write((str(self) if msg is None else msg) + '\n')
                self.fp.flush()
            return
        return super().display(msg=msg, pos=pos)

    def close(self):
        if self.log_output and not self.disable:
            # Print the final line here; leave=True would add a blank line after it.
            self.display()
            self.leave = False
        super().close()

root = Path(os.environ['INSTALL_ROOT'])
variant = os.environ['LTX_VARIANT']
text_encoder = os.environ['LTX_TEXT_ENCODER']
# (precision, bf16 file, int8 file) for the transformer, text encoder and prompt
# enhancer. The upstream template has shipped either precision, so map both directions.
pairs = [
    (variant, 'ltx-2.5-22b-distilled-transformer-bf16.safetensors',
     'ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors'),
    (text_encoder, 'gemma4-12b-with-proj-ltx-2.5-bf16.safetensors',
     'gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors'),
    (variant, 'gemma4_e2b_it_bf16.safetensors', 'gemma4_e2b_it_int8_convrot.safetensors'),
]
replacements = {}
for precision, bf16, int8 in pairs:
    replacements.update({int8: bf16} if precision == 'bf16' else {bf16: int8})
def replace(value):
    if isinstance(value, str):
        for old, new in replacements.items():
            value = value.replace(old, new)
        return value
    if isinstance(value, list):
        return [replace(v) for v in value]
    if isinstance(value, dict):
        return {k: replace(v) for k, v in value.items()}
    return value

# T2V is required; the image-to-video and first/last-frame templates ship in the
# same package, use a subset of its models, and are added when present.
template_dir = Path(os.environ['LTX_TEMPLATE']).parent
workflows = {}
for kind in ('t2v', 'i2v', 'flf2v'):
    path = template_dir / f'video_ltx2_5_{kind}.json'
    if path.exists():
        workflows[kind] = replace(json.loads(path.read_text()))

# Keyframe fidelity: the upstream I2V first pass and FLF2V guides use strength 0.7,
# which lets the model repaint the keyframe itself, so faces drift from frame 0.
# Nearest-neighbour resizing of the keyframes also discards facial detail.
frame_strength = float(os.environ['LTX_FRAME_STRENGTH'])
def tune(workflow):
    graphs = [workflow] + workflow.get('definitions', {}).get('subgraphs', [])
    changed = 0
    for node in (node for graph in graphs for node in graph.get('nodes', [])):
        values = node.get('widgets_values')
        if not isinstance(values, list):
            continue
        kind = node.get('type')
        # Newer frontends also save widgets_values_named; keep it in step.
        named = node.get('widgets_values_named')
        named = named if isinstance(named, dict) else {}
        # [strength, bypass]; the second pass is already 1.0 and stays there.
        if kind == 'LTXVImgToVideoInplace' and isinstance(values[0], (int, float)) and values[0] < 1:
            values[0] = frame_strength
            if 'strength' in named:
                named['strength'] = frame_strength
            changed += 1
        # [frame_idx, strength]
        elif kind == 'LTXVAddGuide' and len(values) > 1 and isinstance(values[1], (int, float)):
            values[1] = frame_strength
            if 'strength' in named:
                named['strength'] = frame_strength
            changed += 1
        elif kind == 'ResizeImageMaskNode' and 'nearest-exact' in values:
            node['widgets_values'] = ['lanczos' if v == 'nearest-exact' else v for v in values]
            for key, value in named.items():
                if value == 'nearest-exact':
                    named[key] = 'lanczos'
            changed += 1
    return changed
for kind in ('i2v', 'flf2v'):
    if kind in workflows and not tune(workflows[kind]):
        print(f'WARNING: no keyframe settings found in the {kind.upper()} template; left as upstream.',
              file=sys.stderr)

models = {}
def collect(value):
    if isinstance(value, dict):
        for model in value.get('models', []):
            if isinstance(model, dict) and 'url' in model:
                models[model['url']] = model
        for item in value.values():
            collect(item)
    elif isinstance(value, list):
        for item in value:
            collect(item)
for workflow in workflows.values():
    collect(workflow)
if not models:
    raise SystemExit('The template has no model download metadata; refusing an incomplete setup.')

token = os.environ['HF_TOKEN']
api = HfApi(token=token)
revisions, plan = {}, []
for model in models.values():
    url = urlparse(model['url'])
    parts = unquote(url.path).strip('/').split('/')
    if url.scheme != 'https' or url.netloc != 'huggingface.co' or len(parts) < 6 or parts[2] != 'resolve':
        raise SystemExit('Unsupported model URL in the upstream template.')
    repo = '/'.join(parts[:2])
    if repo not in {'Lightricks/LTX-2.5', 'Comfy-Org/gemma-4'}:
        raise SystemExit(f'Unexpected model repository: {repo}. Review the new template before downloading.')
    filename = '/'.join(parts[4:])
    path = PurePosixPath(filename)
    if '..' in path.parts or path.suffix != '.safetensors':
        raise SystemExit('Unsafe or unsupported model path.')
    if str(path.parent) != model.get('directory') or path.name != model.get('name'):
        raise SystemExit('Model metadata directory/name mismatch.')
    key = (repo, parts[3])
    if key not in revisions:
        revisions[key] = api.model_info(repo, revision=parts[3]).sha
    sha = revisions[key]
    info = get_hf_file_metadata(hf_hub_url(repo, filename, revision=sha), token=token)
    if not info.size:
        raise SystemExit(f'Missing model size for {filename}.')
    plan.append((repo, filename, sha, info.size))

names = {PurePosixPath(item[1]).name for item in plan}
quant = {'int8': 'comfy-int8-convrot', 'bf16': 'bf16'}
for required in (
    f'ltx-2.5-22b-distilled-transformer-{quant[variant]}.safetensors',
    f'gemma4-12b-with-proj-ltx-2.5-{quant[text_encoder]}.safetensors',
    'ltx-2.5-video-vae-bf16.safetensors',
    'ltx-2.5-audio-vae-bf16.safetensors',
    'ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors',
):
    if required not in names:
        raise SystemExit(f'Upstream template changed: expected {required}. Review before proceeding.')

# Not referenced by the official templates, but many community workflows use
# the lighter Conv VAE; fetch it from the same pinned repository revision.
for repo, filename in (('Lightricks/LTX-2.5', 'vae/ltx-2.5-video-vae-conv-bf16.safetensors'),):
    if PurePosixPath(filename).name in names:
        continue
    sha = next(s for (r, _), s in revisions.items() if r == repo)
    info = get_hf_file_metadata(hf_hub_url(repo, filename, revision=sha), token=token)
    if not info.size:
        raise SystemExit(f'Missing model size for {filename}.')
    plan.append((repo, filename, sha, info.size))

model_dir = root / 'data/models'
needed = 0
for _, filename, _, size in plan:
    dest = model_dir / filename
    if not dest.exists() or dest.stat().st_size != size:
        needed += size
free = shutil.disk_usage(model_dir).free
if free < needed + 10 * 1024**3:
    raise SystemExit(f'Insufficient disk: {free / 1024**3:.1f}GiB free, need approximately '
                     f'{needed / 1024**3 + 10:.1f}GiB including headroom.')
manifest = []
for index, (repo, filename, sha, size) in enumerate(plan, start=1):
    print(f'[{index}/{len(plan)}] Downloading {filename} ({size / 1024**3:.2f}GiB)', flush=True)
    dest = Path(hf_hub_download(
        repo, filename, revision=sha, token=token, local_dir=model_dir,
        tqdm_class=ModelDownloadProgress,
    ))
    if dest.stat().st_size != size:
        raise SystemExit(f'Incomplete download: {filename}')
    print(f'[{index}/{len(plan)}] Ready: {filename} (100%; downloaded or reused from cache)', flush=True)
    manifest.append(dict(repo=repo, filename=filename, revision=sha, bytes=size))

# Community audio-driven I2V workflow kept in this repository. It needs custom
# nodes (rgthree, mtb, KJNodes, Custom-Scripts; installed by start) and only
# models downloaded above, so it is added after the download plan and is optional.
name = 'ltx25-audio-drive.json'
local = Path(os.environ['SCRIPT_DIR']) / 'workflows' / name
try:
    if local.is_file():
        workflow = json.loads(local.read_text())
    else:
        url = f'https://raw.githubusercontent.com/beamverse/runpod-comfyui-ltx25/main/workflows/{name}'
        with urllib.request.urlopen(url, timeout=60) as resp:
            workflow = json.load(resp)
    if not isinstance(workflow, dict) or not isinstance(workflow.get('nodes'), list):
        raise ValueError('not a ComfyUI UI-format workflow')
    workflows['audio-drive'] = replace(workflow)
    # Same first-frame setup as I2V (strength 0.7 first pass), same face drift.
    if not tune(workflows['audio-drive']):
        print('WARNING: no keyframe settings found in the audio-drive workflow.', file=sys.stderr)
except Exception as exc:
    print(f'WARNING: skipped the audio-drive workflow ({type(exc).__name__}: {exc}).', file=sys.stderr)

# Preserve the user's original workflows when installing again.
targets = []
for kind, workflow in workflows.items():
    stem = f'LTX-2.5-{kind.upper()}-{variant.upper()}'
    if text_encoder != variant:
        stem += f'-TE-{text_encoder.upper()}'
    target = root / f'data/user/default/workflows/{stem}.json'
    if target.exists():
        target = target.with_name(f'{stem}.upstream.json')
    tmp = target.with_suffix('.json.tmp')
    tmp.write_text(json.dumps(workflow, ensure_ascii=False, indent=2) + '\n')
    tmp.replace(target)
    targets.append(target.name)
manifest_path = root / 'models-manifest.json'
tmp = manifest_path.with_suffix('.json.tmp')
tmp.write_text(json.dumps(manifest, indent=2) + '\n')
tmp.replace(manifest_path)
print(f'{len(plan)} model files ready. Workflows in {target.parent}: {", ".join(targets)}')
PY

unset HF_TOKEN HUGGING_FACE_HUB_TOKEN
"$uv" pip freeze --python "$py" > "$app/installed-packages.txt"
printf '%s\n' "$release" > "$INSTALL_ROOT/active-release.tmp"
mv "$INSTALL_ROOT/active-release.tmp" "$INSTALL_ROOT/active-release"
log "Installation complete: $ref ($release)"
printf 'Models/output/workflows: %s\n' "$DATA_ROOT"
printf 'Start: INSTALL_ROOT=%q DATA_ROOT=%q bash %q start\n' "$INSTALL_ROOT" "$DATA_ROOT" "$0"
printf 'Expose HTTP port 8188 in RunPod, then open its HTTP service.\n'
