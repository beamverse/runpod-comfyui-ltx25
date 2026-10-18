# Shared by ltx25-pack-build.sh and ltx25-pack-deploy.sh. Sourced, not executed.
# Mirrors the helpers of setup-comfyui-ltx25.sh so a pack-installed tree keeps the
# same INSTALL_ROOT/DATA_ROOT layout (releases/, active-release, data/ links).

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n[comfyui-ltx25] %s\n' "$*"; }

PACK_FORMAT=1

require_ubuntu_2404() {
    [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'The offline pack targets Linux x86_64.'
    local id='' version=''
    if [[ -r /etc/os-release ]]; then
        id=$(. /etc/os-release && printf '%s' "${ID:-}")
        version=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
    fi
    [[ "$id" == ubuntu && "$version" == 24.04 ]] ||
        die "The offline pack supports Ubuntu 24.04 LTS only; this host is ${id:-unknown} ${version:-unknown}."
}

# PyTorch CUDA build selection; same policy as setup-comfyui-ltx25.sh.
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
torch_driver_mismatch() {
    local tag need driver
    tag=$("$1/.venv/bin/python" -c \
        'from importlib.metadata import version; print(version("torch").partition("+")[2])' 2>/dev/null) || return 1
    if need=$(min_driver_for_torch_cuda "$tag") && driver=$(host_driver_major) && (( driver < need )); then
        printf 'Installed PyTorch (%s) needs an R%s+ host driver; this host has R%s.\n' "$tag" "$need" "$driver"
        return 0
    fi
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

supports_permissions() {
    local probe ok=1
    mkdir -p "$1" 2>/dev/null || return 1
    probe=$(mktemp "$1/.permission-probe.XXXXXX" 2>/dev/null) || return 1
    if chmod 700 "$probe" 2>/dev/null && [[ $(stat -c %a "$probe") == 700 ]]; then ok=0; fi
    rm -f "$probe"
    return $ok
}
data_is_split() { [[ $(realpath -m "$DATA_ROOT") != $(realpath -m "$INSTALL_ROOT/data") ]]; }
# Same layout as setup-comfyui-ltx25.sh: models/input/output and user/default are
# symlinks into DATA_ROOT; custom_nodes and the rest of user stay under INSTALL_ROOT.
link_data_dirs() {
    local data="$INSTALL_ROOT/data" name
    mkdir -p "$data/custom_nodes"
    data_is_split || return 0
    [[ -L "$data/user" ]] && rm "$data/user"
    mkdir -p "$data/user"
    for name in models input output user/default; do
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

# Manager registry installs use the lowercase id (comfyui-kjnodes), git installs
# the repo name (ComfyUI-KJNodes); both count. A disabled pack returns 2.
node_key() { local n=${1,,}; printf '%s\n' "${n//_/-}"; }
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

write_manager_config() {
    MANAGER_CONFIG="$INSTALL_ROOT/data/user/__manager/config.ini" \
    NETWORK_MODE="$2" "$1" - <<'PY'
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
}

cuda_selftest() {
    "$1" - <<'PY'
import torch
if not torch.cuda.is_available():
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
        lines.append('No usable NVIDIA driver library; the GPU is not exposed to this host or container.')
        raise SystemExit('\n'.join(lines))
    code = libcuda.cuInit(0)
    name = ctypes.c_char_p()
    libcuda.cuGetErrorName(code, ctypes.byref(name))
    lines.append(f'  cuInit = {code} ({name.value.decode() if name.value else "unknown"})')
    if code != 0:
        lines.append('The CUDA driver itself fails to initialise, so this is not a PyTorch problem: '
                     'check /dev/nvidia-uvm, the driver installation and the GPU state.')
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
}

# Credentials never reach ComfyUI or its custom nodes.
strip_secrets() {
    local name
    unset HF_TOKEN HUGGING_FACE_HUB_TOKEN
    for name in $(compgen -e); do
        case "$name" in R2_*|RCLONE_CONFIG_R2_*|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN) unset "$name" ;; esac
    done
}

# Remote "r2" configured from environment variables only; nothing is written to disk.
r2_configure() {
    local name missing=()
    for name in R2_ACCOUNT_ID R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do
        [[ -n ${!name:-} ]] || missing+=("$name")
    done
    (( ${#missing[@]} == 0 )) || die "Set ${missing[*]} in the platform's environment variables."
    [[ "$R2_ACCOUNT_ID" =~ ^[a-f0-9]{32}$ ]] || die 'R2_ACCOUNT_ID must be the 32-character Cloudflare account ID.'
    [[ "$R2_BUCKET" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || die 'R2_BUCKET is not a valid bucket name.'
    R2_PREFIX=${R2_PREFIX:-ltx25}
    [[ "$R2_PREFIX" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "/$R2_PREFIX/" != */../* ]] ||
        die 'R2_PREFIX may contain only letters, digits, ".", "_", "-" and "/".'
    command -v rclone >/dev/null || die 'rclone is required; install it from https://rclone.org/install/.'
    export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
        RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
        RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
        RCLONE_CONFIG_R2_ENDPOINT="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com" \
        RCLONE_CONFIG_R2_ACL=private \
        RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
    # shellcheck disable=SC2034  # used by the sourcing script
    R2_BASE="r2:$R2_BUCKET/$R2_PREFIX"
}

r2_explain() {
    case "$1" in
        *InvalidAccessKeyId*) echo 'R2_ACCESS_KEY_ID is wrong, or its token was deleted or has expired.' ;;
        *SignatureDoesNotMatch*) echo 'R2_SECRET_ACCESS_KEY does not belong to R2_ACCESS_KEY_ID.' ;;
        *NoSuchBucket*) echo "Bucket $R2_BUCKET does not exist in this account (or it was created with EU jurisdiction)." ;;
        *AccessDenied*|*Forbidden*|*403*) echo "The token has no permission for this operation on bucket $R2_BUCKET; check its permission level and bucket scope." ;;
        *'no such host'*|*timeout*|*'connection refused'*) echo 'Cannot reach the R2 endpoint; check R2_ACCOUNT_ID and outbound HTTPS.' ;;
        *) echo 'Unexpected rclone error; see its output below.' ;;
    esac
}
# Writes, reads back and deletes a small object: the builder token needs Object Read & Write.
r2_check_write() {
    local probe body out
    probe="$R2_BASE/.check/builder-${HOSTNAME//[^A-Za-z0-9-]/}-$$.txt"
    body="ltx25 R2 check $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local quick=(--retries 1 --low-level-retries 1)
    out=$(printf '%s\n' "$body" | rclone rcat "${quick[@]}" "$probe" 2>&1) ||
        die "R2 write test failed. $(r2_explain "$out")"$'\n'"$out"
    out=$(rclone cat "${quick[@]}" "$probe" 2>&1) ||
        die "R2 read test failed. $(r2_explain "$out")"$'\n'"$out"
    [[ "$out" == "$body" ]] || die 'R2 returned different content for the test object.'
    out=$(rclone deletefile "${quick[@]}" "$probe" 2>&1) ||
        die "R2 delete test failed. $(r2_explain "$out")"$'\n'"$out"
    log "R2 OK: read/write access to $R2_BUCKET/$R2_PREFIX"
}

valid_pack_version() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; }

# Reads pack.env as data (KEY=value lines) into the PACK associative array.
declare -gA PACK=()
load_pack_env() {
    local file=$1 key value line
    [[ -f "$file" ]] || die "$file is missing; this is not a complete offline pack."
    PACK=()
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z $line || $line == \#* ]] && continue
        key=${line%%=*} value=${line#*=}
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ && "$line" == *=* && "$value" =~ ^[A-Za-z0-9._:+\ /-]*$ ]] ||
            die "Unexpected line in $file: $line"
        PACK[$key]=$value
    done < "$file"
    [[ ${PACK[PACK_FORMAT]:-} == "$PACK_FORMAT" ]] ||
        die "Pack format ${PACK[PACK_FORMAT]:-unknown} is not supported by this script (expects $PACK_FORMAT)."
    valid_pack_version "${PACK[PACK_VERSION]:-}" || die "Invalid PACK_VERSION in $file."
    [[ ${PACK[COMFYUI_COMMIT]:-} =~ ^[a-f0-9]{40}$ ]] || die "Invalid COMFYUI_COMMIT in $file."
}
