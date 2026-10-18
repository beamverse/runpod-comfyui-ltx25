#!/usr/bin/env bash
# Builds the offline ComfyUI + LTX-2.5 pack on an internet-connected Ubuntu 24.04
# builder and uploads it to a private Cloudflare R2 bucket. See README-offline-install.md.
# Models and workflows come from setup-comfyui-ltx25.sh download, so the pack holds
# exactly what the online installer would install.
set +x
set -Eeuo pipefail
umask 022

here=$(dirname "$(readlink -f "$0")")
repo_root=$(dirname "$here")
# shellcheck source=lib/ltx25-common.sh
source "$here/lib/ltx25-common.sh"
trap 'printf "ERROR: pack build stopped at line %s; correct the problem and rerun.\n" "$LINENO" >&2' ERR

usage() {
    printf '%s\n' \
      'Usage: bash ltx25-pack-build.sh create <pack-dir>' \
      '       bash ltx25-pack-build.sh upload <pack-dir>' \
      '       bash ltx25-pack-build.sh check-r2' \
      'create:   build a new offline pack directory (internet, root, HF_TOKEN);' \
      '          checks R2 access first when R2_ACCOUNT_ID is set' \
      'upload:   copy a finished pack to R2 (multipart, resumable), then publish latest.json' \
      'check-r2: write, read and delete a test object with the builder token' \
      'Environment (create):' \
      '  HF_TOKEN            Hugging Face read token; hidden prompt if omitted' \
      '  PACK_VERSION        Pack version name; default: UTC timestamp such as 20261018-120000' \
      '  PACK_WORK           Download/build cache, reused by later builds; default: <pack-dir>.work' \
      '  PACK_TORCH_POOLS    PyTorch pools to build; default: "cu130 cu128 cu126"' \
      '  PACK_MIN_FREE_GIB   Free space required for PACK_WORK on a first build; default: 120' \
      '  COMFYUI_REF, LTX_VARIANT, LTX_TEXT_ENCODER, LTX_FRAME_STRENGTH, LTX_INGREDIENTS,' \
      '  LTX_UNION_CONTROL, LTX_ALLINONE, COMFYUI_MANAGER, COMFYUI_CUSTOM_NODES' \
      '                      Same meaning and defaults as setup-comfyui-ltx25.sh' \
      'Environment (upload): R2_ACCOUNT_ID, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY' \
      '  (read/write key), optional R2_PREFIX (default ltx25). Set them in the platform'"'"'s' \
      '  environment variables; they are never written to the pack.'
}

# Runtime libraries for ComfyUI, OpenCV, FFmpeg (VideoHelperSuite) and git-based
# custom node metadata, bundled as Ubuntu 24.04 .deb files with their dependencies.
DEB_PACKAGES=(ffmpeg libgl1 libglib2.0-0t64 libgomp1 git ca-certificates)

# Files custom nodes would otherwise download on first use: flags|repo|file|models/ subdir.
# controlnet_aux reads models/annotators through AUX_ANNOTATOR_CKPTS_PATH (set at start)
# and expects <repo>/<file> below it; Video-Depth-Anything reads models/videodepthanything.
RUNTIME_ASSETS=(
    'LTX_UNION_CONTROL|depth-anything/Video-Depth-Anything-Small|video_depth_anything_vits.pth|videodepthanything'
    'LTX_UNION_CONTROL LTX_ALLINONE|yzd-v/DWPose|yolox_l.onnx|annotators/yzd-v/DWPose'
    'LTX_UNION_CONTROL LTX_ALLINONE|hr16/DWPose-TorchScript-BatchSize5|dw-ll_ucoco_384_bs5.torchscript.pt|annotators/hr16/DWPose-TorchScript-BatchSize5'
    'LTX_ALLINONE|depth-anything/Depth-Anything-V2-Large|depth_anything_v2_vitl.pth|annotators/depth-anything/Depth-Anything-V2-Large'
)

action=${1:-}
(( $# )) && shift
case "$action" in
    create|upload) (( $# == 1 )) || { usage >&2; exit 2; } ;;
    check-r2)
        (( $# == 0 )) || { usage >&2; exit 2; }
        r2_configure
        r2_check_write
        exit 0 ;;
    help|--help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
pack=$(realpath -m "$1")
[[ "$pack" != / ]] || die 'The pack directory must not be /.'

upload() {
    load_pack_env "$pack/pack.env"
    [[ -f "$pack/SHA256SUMS" && -f "$pack/manifest.json" ]] || die "$pack is not a finished pack."
    r2_configure
    local version=${PACK[PACK_VERSION]} dest
    dest="$R2_BASE/$version"
    log "Uploading $pack to $dest"
    # Completed objects are skipped on a rerun; large files go up as 128MiB parts.
    rclone copy "$pack" "$dest" --transfers 4 --checkers 16 \
        --s3-upload-cutoff 200Mi --s3-chunk-size 128Mi --s3-upload-concurrency 8 \
        --retries 5 --low-level-retries 20 --stats 30s --stats-one-line --stats-log-level NOTICE
    log 'Verifying the uploaded objects'
    rclone check "$pack" "$dest" --one-way --checkers 16
    # Published last, so servers never see a version whose objects are still uploading.
    python3 -I - "$pack/manifest.json" "$R2_PREFIX/$version" <<'PY' | rclone rcat "$R2_BASE/latest.json"
import json, sys
m = json.load(open(sys.argv[1]))
print(json.dumps({
    'format': m['format'], 'version': m['version'], 'path': sys.argv[2], 'created': m['created'],
    'comfyui': m['comfyui'], 'bytes': sum(f['bytes'] for f in m['files']),
    'torch_pools': sorted(m['torch_pools']),
}, indent=2))
PY
    log "Published $R2_PREFIX/latest.json -> $version"
}

if [[ "$action" == upload ]]; then
    upload
    exit 0
fi

# ---- create ----------------------------------------------------------------
require_ubuntu_2404
[[ $EUID == 0 ]] || die 'Pack creation requires root (apt packages and the online installer).'
[[ ! -e "$pack" ]] || die "$pack already exists; choose a new pack directory."
partial="$pack.partial"
work=$(realpath -m "${PACK_WORK:-$pack.work}")
version=${PACK_VERSION:-$(date -u +%Y%m%d-%H%M%S)}
valid_pack_version "$version" || die 'PACK_VERSION may contain only letters, digits, ".", "_" and "-".'
read -r -a pools <<< "${PACK_TORCH_POOLS:-cu130 cu128 cu126}"
(( ${#pools[@]} )) || die 'PACK_TORCH_POOLS is empty.'
for pool in "${pools[@]}"; do
    min_driver_for_torch_cuda "$pool" >/dev/null || die "Unknown PyTorch pool $pool; use cu130, cu128 or cu126."
done

LTX_VARIANT=${LTX_VARIANT:-int8}
[[ "$LTX_VARIANT" == int8 || "$LTX_VARIANT" == bf16 ]] || die 'LTX_VARIANT must be int8 or bf16.'
LTX_TEXT_ENCODER=${LTX_TEXT_ENCODER:-$LTX_VARIANT}
[[ "$LTX_TEXT_ENCODER" == int8 || "$LTX_TEXT_ENCODER" == bf16 ]] || die 'LTX_TEXT_ENCODER must be int8 or bf16.'
LTX_FRAME_STRENGTH=${LTX_FRAME_STRENGTH:-0.9}
for name in LTX_INGREDIENTS LTX_UNION_CONTROL LTX_ALLINONE COMFYUI_MANAGER COMFYUI_CUSTOM_NODES; do
    printf -v "$name" '%s' "${!name:-1}"
    [[ ${!name} == 0 || ${!name} == 1 ]] || die "$name must be 0 or 1."
done
export LTX_VARIANT LTX_TEXT_ENCODER LTX_FRAME_STRENGTH LTX_INGREDIENTS LTX_UNION_CONTROL LTX_ALLINONE

if [[ -z ${HF_TOKEN:-} ]]; then
    [[ -t 0 ]] || die 'Set HF_TOKEN for non-interactive pack creation.'
    read -r -s -p 'Hugging Face read token: ' HF_TOKEN
    printf '\n'
fi
[[ -n "$HF_TOKEN" ]] || die 'An HF_TOKEN is required.'
export HF_TOKEN
# Fail now rather than after hours of building; the subshell keeps the rclone
# configuration out of the build environment.
if [[ -n ${R2_ACCOUNT_ID:-} ]]; then
    ( r2_configure && r2_check_write )
else
    log 'R2 variables are not set; set them before running upload.'
fi

mkdir -p "$work"
models_dir="$work/data/models"
cached=0
[[ -d "$models_dir" ]] && cached=$(du -sb "$models_dir" | cut -f1)
need=$(( ${PACK_MIN_FREE_GIB:-120} * 1024**3 - cached ))
(( need > 40 * 1024**3 )) || need=$(( 40 * 1024**3 ))
free=$(df --output=avail -B1 "$work" | tail -n 1)
(( free >= need )) || die "Insufficient disk for $work: $(( free / 1024**3 ))GiB free, need about $(( need / 1024**3 ))GiB."

log 'Installing builder tools'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git python3 apt-utils
git() { command git "$@"; }

ref=${COMFYUI_REF:-latest}
if [[ "$ref" == latest ]]; then
    ref=$(curl --fail --silent --show-error --location --retry 3 \
        https://api.github.com/repos/Comfy-Org/ComfyUI/releases/latest |
        python3 -I -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')
fi
[[ "$ref" == master || "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'COMFYUI_REF must be latest, master, or a vX.Y.Z release tag.'
log "Building pack $version for ComfyUI $ref"

# Custom node packs: the list in setup-comfyui-ltx25.sh is the single source of truth.
mapfile -t node_repos < <(sed -n '/^CUSTOM_NODE_REPOS=(/,/^)/{s/^[[:space:]]*\(https:[^[:space:]]*\).*/\1/p}' \
    "$repo_root/setup-comfyui-ltx25.sh")
(( ${#node_repos[@]} )) || die 'No CUSTOM_NODE_REPOS found in setup-comfyui-ltx25.sh.'
nodes_dir="$work/data/custom_nodes"
node_names=()
: > "$work/custom-nodes.tsv"
if [[ "$COMFYUI_CUSTOM_NODES" == 1 ]]; then
    mkdir -p "$nodes_dir"
    for entry in "${node_repos[@]}"; do
        [[ "$entry" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(#[A-Za-z0-9._/-]+)?$ ]] ||
            die "Unexpected custom node entry: $entry"
        url=${entry%%#*} branch=${entry#"$url"} branch=${branch#\#}
        name=${url##*/} dir="$nodes_dir/${url##*/}"
        log "Fetching custom node pack $name"
        if [[ -d "$dir/.git" ]]; then
            git -C "$dir" fetch -q --depth 1 origin "${branch:-HEAD}"
            if [[ -n $branch ]]; then
                git -C "$dir" checkout -q -B "$branch" FETCH_HEAD
            else
                git -C "$dir" checkout -q --detach FETCH_HEAD
            fi
            git -C "$dir" reset -q --hard
            git -C "$dir" clean -q -ffdx
        else
            rm -rf "$dir"
            git clone -q --depth 1 ${branch:+--branch "$branch"} "$url" "$dir"
        fi
        printf '%s\t%s\t%s\t%s\n' "$name" "$url" "${branch:--}" "$(git -C "$dir" rev-parse HEAD)" >> "$work/custom-nodes.tsv"
        node_names+=("$name")
    done
fi

log 'Downloading models and generating workflows with setup-comfyui-ltx25.sh download'
rm -rf "$work/data/user/default/workflows" "$work/models-manifest.json"
INSTALL_ROOT="$work" DATA_ROOT="$work/data" COMFYUI_REF="$ref" \
    bash "$repo_root/setup-comfyui-ltx25.sh" download
commit=$(git -C "$work/source" rev-parse 'FETCH_HEAD^{commit}')
[[ "$commit" =~ ^[a-f0-9]{40}$ ]] || die 'Cannot determine the ComfyUI commit.'

# The online installer skips optional workflows with a warning; a pack must not.
stem_suffix=${LTX_VARIANT^^}
[[ "$LTX_TEXT_ENCODER" != "$LTX_VARIANT" ]] && stem_suffix+="-TE-${LTX_TEXT_ENCODER^^}"
kinds=(T2V I2V FLF2V AUDIO-DRIVE)
[[ "$LTX_INGREDIENTS" == 1 ]] && kinds+=(INGREDIENTS)
[[ "$LTX_UNION_CONTROL" == 1 ]] && kinds+=(UNION-CONTROL)
[[ "$LTX_ALLINONE" == 1 ]] && kinds+=(ALLINONE)
for kind in "${kinds[@]}"; do
    [[ -f "$work/data/user/default/workflows/LTX-2.5-$kind-$stem_suffix.json" ]] ||
        die "The $kind workflow was not generated (see the warnings above); disable its flag or fix access, then rerun."
done

log 'Downloading custom node runtime assets'
assets=()
if [[ "$COMFYUI_CUSTOM_NODES" == 1 ]]; then
    for entry in "${RUNTIME_ASSETS[@]}"; do
        for name in ${entry%%|*}; do
            if [[ ${!name} == 1 ]]; then assets+=("${entry#*|}"); break; fi
        done
    done
fi
python3 -I - "$work/models-manifest.json" > "$work/models.tsv" <<'PY'
import json, sys
for m in json.load(open(sys.argv[1])):
    if 'path' not in m:
        raise SystemExit('models-manifest.json has no "path" field; update setup-comfyui-ltx25.sh.')
    print(f"{m['path']}\tmodel\t{m['repo']}\t{m['revision']}")
PY
if (( ${#assets[@]} )); then
    "$work/bootstrap/bin/python" - "$models_dir" "${assets[@]}" >> "$work/models.tsv" <<'PY'
import os, sys
from pathlib import Path
from huggingface_hub import HfApi, hf_hub_download
models = Path(sys.argv[1])
api = HfApi(token=os.environ['HF_TOKEN'])
for entry in sys.argv[2:]:
    repo, filename, subdir = entry.split('|')
    sha = api.model_info(repo).sha
    path = Path(hf_hub_download(repo, filename, revision=sha, token=os.environ['HF_TOKEN'],
                                local_dir=models / subdir))
    if path.stat().st_size == 0:
        raise SystemExit(f'Empty runtime asset: {repo}/{filename}')
    print(f'{path.relative_to(models)}\truntime-asset\t{repo}\t{sha}')
PY
fi
unset HF_TOKEN HUGGING_FACE_HUB_TOKEN

models_bytes=0
while IFS=$'\t' read -r path _; do
    [[ -s "$models_dir/$path" ]] || die "Model file missing after download: $path"
    models_bytes=$(( models_bytes + $(stat -c %s "$models_dir/$path") ))
done < "$work/models.tsv"
mkdir -p "$(dirname "$pack")"
if [[ $(stat -c %d "$work") != $(stat -c %d "$(dirname "$pack")") ]]; then
    free=$(df --output=avail -B1 "$(dirname "$pack")" | tail -n 1)
    (( free >= models_bytes + 30 * 1024**3 )) ||
        die "Insufficient disk for $pack: $(( free / 1024**3 ))GiB free, need about $(( models_bytes / 1024**3 + 30 ))GiB."
fi

log 'Staging the runtime'
stage="$work/stage"
rm -rf "$stage" "$work/pools" "$work/resolve" "$partial"
mkdir -p "$stage"/{comfyui,custom_nodes,workflows,python,bin,requirements,wheels/common,debs} "$work/pools/wheels"
git -C "$work/source" archive "$commit" | tar -x -C "$stage/comfyui"
for name in "${node_names[@]}"; do cp -a "$nodes_dir/$name" "$stage/custom_nodes/"; done
cp "$work/data/user/default/workflows/"*.json "$stage/workflows/"
pydir=$(find "$work/python" -mindepth 1 -maxdepth 1 -type d -name 'cpython-3.12.*-linux-x86_64-gnu' -printf '%f\n' |
    sort -V | tail -n 1)
[[ -n "$pydir" ]] || die 'No uv-managed Python 3.12 found in the build cache.'
cp -a "$work/python/$pydir" "$stage/python/"
uv="$work/bootstrap/bin/uv"
install -m 0755 "$uv" "$stage/bin/uv"
export UV_CACHE_DIR="$work/cache/uv" UV_PYTHON_INSTALL_DIR="$work/python"

# One fully resolved environment per CUDA pool, installed the way the online
# installer does it; its freeze is the lock the offline installer syncs to.
build_pool() {
    local pool=$1 venv="$work/resolve/$1" out="$work/pools/wheels/$1" req="$stage/requirements"
    local py="$work/resolve/$1/bin/python" name
    log "Resolving the $pool environment"
    mkdir -p "$out"
    "$uv" venv --seed --python "$work/python/$pydir/bin/python3.12" "$venv"
    "$uv" pip install --python "$py" torch torchvision torchaudio \
        --index-url "https://download.pytorch.org/whl/$pool"
    "$py" - > "$req/torch-$pool.txt" <<'PY'
from importlib.metadata import version
for name in ('torch', 'torchvision', 'torchaudio'):
    print(f'{name}=={version(name)}')
PY
    "$uv" pip install --python "$py" -r "$stage/comfyui/requirements.txt" -c "$req/torch-$pool.txt"
    if [[ "$COMFYUI_MANAGER" == 1 && -f "$stage/comfyui/manager_requirements.txt" ]]; then
        "$uv" pip install --python "$py" -r "$stage/comfyui/manager_requirements.txt" -c "$req/torch-$pool.txt"
    fi
    for name in "${node_names[@]}"; do
        [[ -s "$stage/custom_nodes/$name/requirements.txt" ]] || continue
        "$uv" pip install --python "$py" -r "$stage/custom_nodes/$name/requirements.txt" \
            -c "$req/torch-$pool.txt" || die "Python dependencies of $name failed to resolve for $pool."
    done
    "$uv" pip check --python "$py"
    "$uv" pip freeze --python "$py" > "$req/lock-$pool.txt"
    ! grep -qE '^-e|@ file:' "$req/lock-$pool.txt" || die "The $pool lock contains local or editable packages."
    log "Collecting $pool wheels"
    # Downloads published wheels and builds the rest (sdists, git URLs) into wheels.
    "$py" -m pip wheel --no-deps --no-cache-dir --disable-pip-version-check -q \
        -r "$req/lock-$pool.txt" -w "$out" --extra-index-url "https://download.pytorch.org/whl/$pool"
    sed -E 's/^([A-Za-z0-9._-]+) @ .*/\1/' "$req/lock-$pool.txt" > "$req/offline-$pool.txt"
    rm -rf "$venv"
}
for pool in "${pools[@]}"; do build_pool "$pool"; done

# Wheels every pool shares go to wheels/common inside base.tar.
if (( ${#pools[@]} > 1 )); then
    for file in "$work/pools/wheels/${pools[0]}"/*.whl; do
        whl=${file##*/} shared=1
        for pool in "${pools[@]:1}"; do [[ -f "$work/pools/wheels/$pool/$whl" ]] || shared=; done
        [[ -n $shared ]] || continue
        mv "$file" "$stage/wheels/common/"
        for pool in "${pools[@]:1}"; do rm "$work/pools/wheels/$pool/$whl"; done
    done
fi

log "Collecting Ubuntu 24.04 packages: ${DEB_PACKAGES[*]}"
mapfile -t debs < <(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
    --no-breaks --no-replaces --no-enhances "${DEB_PACKAGES[@]}" | grep -E '^[a-z0-9][a-z0-9+.-]*$' | sort -u)
(( ${#debs[@]} )) || die 'Cannot resolve the .deb dependency closure.'
(cd "$stage/debs" && apt-get download -q "${debs[@]}" &&
    apt-ftparchive packages . > Packages && apt-ftparchive release . > Release)

log 'Assembling the pack'
runtime="$partial/runtime/linux-x86_64"
mkdir -p "$runtime" "$partial/lib" "$partial/models"
tar --owner=0 --group=0 --numeric-owner -cf "$runtime/base.tar" -C "$stage" .
for pool in "${pools[@]}"; do
    tar --owner=0 --group=0 --numeric-owner -cf "$runtime/wheels-$pool.tar" -C "$work/pools" "wheels/$pool"
done
while IFS=$'\t' read -r path _; do
    mkdir -p "$(dirname "$partial/models/$path")"
    # Hard links avoid a second copy of the models when the pack shares the cache's disk.
    ln "$models_dir/$path" "$partial/models/$path" 2>/dev/null ||
        cp --reflink=auto "$models_dir/$path" "$partial/models/$path"
done < "$work/models.tsv"
install -m 0755 "$here/ltx25-pack-deploy.sh" "$here/ltx25-pack-mirror.sh" "$partial/"
install -m 0644 "$here/lib/ltx25-common.sh" "$partial/lib/"
install -m 0644 "$here/README-offline-install.md" "$partial/"
{
    printf 'PACK_FORMAT=%s\n' "$PACK_FORMAT"
    printf 'PACK_VERSION=%s\n' "$version"
    printf 'PACK_CREATED=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'PACK_PLATFORM=linux-x86_64\n'
    printf 'PACK_OS=ubuntu-24.04\n'
    printf 'COMFYUI_TAG=%s\n' "$ref"
    printf 'COMFYUI_COMMIT=%s\n' "$commit"
    printf 'PYTHON_DIR=%s\n' "$pydir"
    printf 'TORCH_POOLS=%s\n' "${pools[*]}"
    printf 'DEB_PACKAGES=%s\n' "${DEB_PACKAGES[*]}"
    for name in LTX_VARIANT LTX_TEXT_ENCODER LTX_FRAME_STRENGTH LTX_INGREDIENTS LTX_UNION_CONTROL \
                LTX_ALLINONE COMFYUI_MANAGER COMFYUI_CUSTOM_NODES; do
        printf '%s=%s\n' "$name" "${!name}"
    done
} > "$partial/pack.env"

log 'Verifying the pack and writing manifest.json and SHA256SUMS'
PARTIAL="$partial" STAGE="$stage" WORK="$work" python3 -I - <<'PY'
import hashlib, json, os, re
from pathlib import Path

partial, stage, work = (Path(os.environ[k]) for k in ('PARTIAL', 'STAGE', 'WORK'))
env = dict(line.split('=', 1) for line in (partial / 'pack.env').read_text().splitlines() if '=' in line)
pools = env['TORCH_POOLS'].split()
canon = lambda name: re.sub(r'[-_.]+', '-', name).lower()

def wheels(folder):
    found = {}
    for f in folder.glob('*.whl'):
        name, ver = f.name.split('-')[:2]
        found.setdefault(canon(name), set()).add(ver)
    return found

common = wheels(stage / 'wheels/common')
torch_pools = {}
for pool in pools:
    have = {k: set(v) for k, v in common.items()}
    for k, v in wheels(work / 'pools/wheels' / pool).items():
        have.setdefault(k, set()).update(v)
    packages = []
    for line in (stage / f'requirements/lock-{pool}.txt').read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if ' @ ' in line:
            name, ver = line.split(' @ ')[0].strip(), None
        else:
            name, _, ver = line.partition('==')
        if canon(name) not in have or (ver and ver not in have[canon(name)]):
            raise SystemExit(f'{pool}: no wheel for {line}')
        packages.append(line)
    torch = dict(l.split('==') for l in (stage / f'requirements/torch-{pool}.txt').read_text().split())
    torch_pools[pool] = dict(archive=f'runtime/linux-x86_64/wheels-{pool}.tar', torch=torch,
                             min_driver={'cu130': 580, 'cu128': 570, 'cu126': 525}[pool], packages=packages)

def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        while chunk := f.read(8 << 20):
            h.update(chunk)
    return h.hexdigest()

files = []
for path in sorted(p for p in partial.rglob('*') if p.is_file() and p.name != 'SHA256SUMS'):
    if path.name == 'manifest.json' and path.parent == partial:
        continue
    files.append(dict(path=path.relative_to(partial).as_posix(), bytes=path.stat().st_size, sha256=sha256(path)))
by_path = {f['path']: f for f in files}
models = []
for line in (work / 'models.tsv').read_text().splitlines():
    path, role, repo, revision = line.split('\t')
    entry = by_path[f'models/{path}']
    models.append(dict(path=entry['path'], role=role, repo=repo, revision=revision,
                       bytes=entry['bytes'], sha256=entry['sha256']))
nodes = []
for line in (work / 'custom-nodes.tsv').read_text().splitlines():
    name, url, branch, revision = line.split('\t')
    nodes.append(dict(name=name, url=url, branch=None if branch == '-' else branch, revision=revision))
debs = []
for f in sorted((stage / 'debs').glob('*.deb')):
    name, ver, arch = f.stem.split('_')
    debs.append(dict(package=name, version=ver.replace('%3a', ':'), arch=arch))
manifest = dict(
    format=int(env['PACK_FORMAT']), version=env['PACK_VERSION'], created=env['PACK_CREATED'],
    platform=env['PACK_PLATFORM'], os=env['PACK_OS'], python=env['PYTHON_DIR'],
    comfyui=dict(ref=env['COMFYUI_TAG'], commit=env['COMFYUI_COMMIT']),
    settings={k: env[k] for k in ('LTX_VARIANT', 'LTX_TEXT_ENCODER', 'LTX_FRAME_STRENGTH', 'LTX_INGREDIENTS',
                                  'LTX_UNION_CONTROL', 'LTX_ALLINONE', 'COMFYUI_MANAGER', 'COMFYUI_CUSTOM_NODES')},
    torch_pools=torch_pools, custom_nodes=nodes, models=models,
    workflows=sorted(p.name for p in (stage / 'workflows').glob('*.json')),
    deb_packages=env['DEB_PACKAGES'].split(), debs=debs, files=files,
)
(partial / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
files.append(dict(path='manifest.json', sha256=sha256(partial / 'manifest.json')))
with open(partial / 'SHA256SUMS', 'w') as f:
    for entry in sorted(files, key=lambda e: e['path']):
        f.write(f"{entry['sha256']}  {entry['path']}\n")
total = sum(e.get('bytes', 0) for e in files) / 1024**3
print(f'{len(models)} model files, {len(nodes)} custom node packs, {len(debs)} .deb files, '
      f'pools {", ".join(pools)}; {total:.1f}GiB in total.')
PY

mv "$partial" "$pack"
rm -rf "$stage" "$work/pools"
log "Pack ready: $pack (version $version, ComfyUI $ref $commit)"
printf 'Upload:  bash %q upload %q\n' "$0" "$pack"
printf 'Install: bash %q install   (on the Ubuntu 24.04 GPU server)\n' "$pack/ltx25-pack-deploy.sh"
printf 'The build cache %s can be kept to speed up the next build, or deleted.\n' "$work"
