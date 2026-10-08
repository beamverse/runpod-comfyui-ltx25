#!/usr/bin/env bash
# RunPod / Ubuntu or Debian / NVIDIA RTX 5090. See the companion README.
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
      'install (default): install/update ComfyUI + CUDA 13.0 PyTorch + LTX-2.5 INT8' \
      'start: run the last successfully installed release; no token needed' \
      'startup: RunPod boot mode; start base services, install once if needed, then start ComfyUI' \
      'Environment:' \
      '  HF_TOKEN          Hugging Face read token; hidden prompt if omitted' \
      '  INSTALL_ROOT      Default: /workspace/comfyui-ltx25 (persistent volume)' \
      '  COMFYUI_REF       latest (default), master, or a release tag such as v0.32.0' \
      '  LISTEN / PORT     Default: 0.0.0.0 / 8188 (start/startup)' \
      '  RUNPOD_START_BASE_SERVICES  Default: 1; run /start.sh in startup mode when present' \
      'Requires a GPU-enabled Linux x86_64 container and a CUDA 13-capable host driver.' \
      'Accept the Lightricks/LTX-2.5 license on Hugging Face before installation.'
}

action=${1:-install}
if (($#)); then shift; fi
case "$action" in
    help|--help|-h) usage; exit 0 ;;
    install|start|startup) ;;
    *) usage >&2; die "Unknown action: $action" ;;
esac
[[ "$action" == start || "$action" == startup || $# == 0 ]] || die 'Only start/startup accepts extra ComfyUI arguments.'
INSTALL_ROOT=${INSTALL_ROOT:-/workspace/comfyui-ltx25}
[[ "$INSTALL_ROOT" == /* && "$INSTALL_ROOT" != / ]] || die 'INSTALL_ROOT must be an absolute, non-root directory.'
export INSTALL_ROOT

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

    if [[ ! -f "$INSTALL_ROOT/active-release" ]]; then
        log 'First boot: no active release found; running one-time installation'
        "$script_self" install
    else
        log 'Existing installation found; skipping install'
    fi

    exec "$script_self" start "$@"
fi

if [[ "$action" == start ]]; then
    [[ -f "$INSTALL_ROOT/active-release" ]] || die 'Run install first.'
    release=$(<"$INSTALL_ROOT/active-release")
    [[ "$release" =~ ^[a-f0-9]{40}$ ]] || die 'Invalid active-release file.'
    app="$INSTALL_ROOT/releases/$release"
    [[ -x "$app/.venv/bin/python" && -f "$app/main.py" ]] || die 'Installed release is incomplete.'
    exec 9>"$INSTALL_ROOT/setup.lock"
    flock -n 9 || die 'An installation or ComfyUI process already holds the lock.'
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
    unset HF_TOKEN HUGGING_FACE_HUB_TOKEN
    cd "$app"
    log "Starting ComfyUI on ${LISTEN}:${PORT}; output: $INSTALL_ROOT/data/output"
    exec "$app/.venv/bin/python" main.py --base-directory "$INSTALL_ROOT/data" \
        --listen "$LISTEN" --port "$PORT" "$@"
fi

[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'This installer targets Linux x86_64.'
[[ $EUID == 0 ]] || die 'Install requires root inside the container (apt packages).'
command -v apt-get >/dev/null || die 'Use an Ubuntu/Debian container with apt-get.'
command -v nvidia-smi >/dev/null || die 'GPU is not exposed. Deploy a GPU-enabled Pod first.'
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n 1)
[[ ${driver%%.*} =~ ^[0-9]+$ ]] || die 'Cannot determine NVIDIA driver version.'
(( ${driver%%.*} >= 580 )) || die 'CUDA 13.0 needs an R580 or newer host driver. Select another Pod host.'

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

mkdir -p "$INSTALL_ROOT"
INSTALL_ROOT=$(realpath "$INSTALL_ROOT")
[[ "$INSTALL_ROOT" != / ]] || die 'INSTALL_ROOT resolves to /.'
export INSTALL_ROOT
exec 9>"$INSTALL_ROOT/setup.lock"
flock -n 9 || die 'Stop the ComfyUI process started by this script before installing/updating.'
mkdir -p "$INSTALL_ROOT"/{releases,data/models,data/user/default/workflows,logs}
df -h "$INSTALL_ROOT"

# Separate bootstrap tools from ComfyUI dependencies; use Python 3.12 even
# when the container's system Python is older.
python3 -m venv "$INSTALL_ROOT/bootstrap"
"$INSTALL_ROOT/bootstrap/bin/python" -m pip install --upgrade pip uv huggingface_hub
export UV_PYTHON_INSTALL_DIR="$INSTALL_ROOT/python"
export UV_CACHE_DIR="$INSTALL_ROOT/cache/uv"
uv="$INSTALL_ROOT/bootstrap/bin/uv"
"$uv" python install 3.12

log 'Checking model access before installing the GPU packages'
"$INSTALL_ROOT/bootstrap/bin/python" - <<'PY'
import os
from huggingface_hub import get_hf_file_metadata, hf_hub_url
try:
    get_hf_file_metadata(hf_hub_url(
        'Lightricks/LTX-2.5',
        'diffusion_models/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors'
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
log 'Installing CUDA 13.0 PyTorch and release-matched ComfyUI requirements'
"$uv" pip install --python "$py" --upgrade torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu130
# Keep the normal package index from replacing the selected CUDA wheels.
"$py" - <<'PY' > "$app/torch-constraints.txt"
from importlib.metadata import version
for name in ('torch', 'torchvision', 'torchaudio'):
    print(f'{name}=={version(name)}')
PY
"$uv" pip install --python "$py" -r "$app/requirements.txt" -c "$app/torch-constraints.txt"
"$uv" pip check --python "$py"
"$py" - <<'PY'
import torch
if not torch.cuda.is_available():
    raise SystemExit('CUDA is unavailable. Check the Pod GPU and host driver.')
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
log 'Downloading LTX-2.5 models (existing Hub downloads are reused)'
"$INSTALL_ROOT/bootstrap/bin/python" - <<'PY'
import json, os, shutil
from pathlib import Path, PurePosixPath
from urllib.parse import unquote, urlparse
from huggingface_hub import HfApi, get_hf_file_metadata, hf_hub_download, hf_hub_url

root = Path(os.environ['INSTALL_ROOT'])
workflow = json.loads(Path(os.environ['LTX_TEMPLATE']).read_text())
replacements = {
    'ltx-2.5-22b-distilled-transformer-bf16.safetensors':
        'ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors',
    'gemma4-12b-with-proj-ltx-2.5-bf16.safetensors':
        'gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors',
    'gemma4_e2b_it_bf16.safetensors': 'gemma4_e2b_it_int8_convrot.safetensors',
}
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
workflow = replace(workflow)

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
for required in (
    'ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors',
    'gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors',
    'ltx-2.5-video-vae-bf16.safetensors',
    'ltx-2.5-audio-vae-bf16.safetensors',
    'ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors',
):
    if required not in names:
        raise SystemExit(f'Upstream template changed: expected {required}. Review before proceeding.')

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
for repo, filename, sha, size in plan:
    print(f'Downloading {filename} ({size / 1024**3:.2f}GiB)', flush=True)
    dest = Path(hf_hub_download(repo, filename, revision=sha, token=token, local_dir=model_dir))
    if dest.stat().st_size != size:
        raise SystemExit(f'Incomplete download: {filename}')
    manifest.append(dict(repo=repo, filename=filename, revision=sha, bytes=size))

# Preserve the user's original workflow when installing again.
target = root / 'data/user/default/workflows/LTX-2.5-T2V-INT8.json'
if target.exists():
    target = target.with_name('LTX-2.5-T2V-INT8.upstream.json')
tmp = target.with_suffix('.json.tmp')
tmp.write_text(json.dumps(workflow, ensure_ascii=False, indent=2) + '\n')
tmp.replace(target)
manifest_path = root / 'models-manifest.json'
tmp = manifest_path.with_suffix('.json.tmp')
tmp.write_text(json.dumps(manifest, indent=2) + '\n')
tmp.replace(manifest_path)
print(f'{len(plan)} model files ready. Workflow: {target}')
PY

unset HF_TOKEN HUGGING_FACE_HUB_TOKEN
"$uv" pip freeze --python "$py" > "$app/installed-packages.txt"
printf '%s\n' "$release" > "$INSTALL_ROOT/active-release.tmp"
mv "$INSTALL_ROOT/active-release.tmp" "$INSTALL_ROOT/active-release"
log "Installation complete: $ref ($release)"
printf 'Models/output/workflows: %s/data\n' "$INSTALL_ROOT"
printf 'Start: INSTALL_ROOT=%q bash %q start\n' "$INSTALL_ROOT" "$0"
printf 'Expose HTTP port 8188 in RunPod, then open its HTTP service.\n'
