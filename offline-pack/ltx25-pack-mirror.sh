#!/usr/bin/env bash
# Mirrors an offline pack version from Cloudflare R2 to a LAN file server.
# Standalone: needs only rclone and sha256sum, no GPU, Ubuntu or Python.
# GPU servers then copy <dest>/current (or a version directory) from the file server.
set +x
set -Eeuo pipefail
umask 022

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n[ltx25-mirror] %s\n' "$*"; }
trap 'printf "ERROR: mirror stopped at line %s; rerun to resume.\n" "$LINENO" >&2' ERR

usage() {
    printf '%s\n' \
      'Usage: bash ltx25-pack-mirror.sh <dest-dir> [version]' \
      'Downloads a pack version (default: the one latest.json names) into <dest-dir>/<version>,' \
      'verifies it against SHA256SUMS, then points <dest-dir>/current at it.' \
      'A rerun after an interruption resumes: finished files are skipped.' \
      'Environment: R2_ACCOUNT_ID, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY' \
      '  (read-only key), optional R2_PREFIX (default ltx25).'
}

case ${1:-} in
    help|--help|-h) usage; exit 0 ;;
    '') usage >&2; exit 2 ;;
esac
(( $# <= 2 )) || { usage >&2; exit 2; }
dest=$(realpath -m "$1")
[[ "$dest" != / ]] || die 'The destination must not be /.'

missing=()
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
command -v sha256sum >/dev/null || die 'sha256sum (coreutils) is required.'
export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
    RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
    RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
    RCLONE_CONFIG_R2_ENDPOINT="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com" \
    RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
base="r2:$R2_BUCKET/$R2_PREFIX"

# Git Bash on Windows has no flock, and its ln -s copies the whole directory.
windows=
case $(uname -s) in MINGW*|MSYS*|CYGWIN*) windows=1 ;; esac

mkdir -p "$dest"
if command -v flock >/dev/null; then
    exec 9>"$dest/.mirror.lock"
    flock -n 9 || die "Another mirror run is using $dest."
fi

latest=$(rclone cat "$base/latest.json") || die "Cannot read $R2_PREFIX/latest.json from R2."
version=${2:-$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$latest" | head -n 1)}
[[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "Invalid pack version: ${version:-<empty>}"

if [[ -f "$dest/$version/SHA256SUMS" && ! -e "$dest/$version.partial" ]]; then
    log "Version $version is already mirrored in $dest/$version"
else
    log "Downloading pack $version to $dest/$version.partial"
    rclone copy "$base/$version" "$dest/$version.partial" --transfers 4 --checkers 16 \
        --multi-thread-streams 8 --multi-thread-cutoff 256Mi \
        --retries 5 --low-level-retries 20 --stats 30s --stats-one-line --stats-log-level NOTICE
    log 'Verifying the download against SHA256SUMS'
    [[ -f "$dest/$version.partial/SHA256SUMS" ]] || die "$R2_PREFIX/$version has no SHA256SUMS; it is not a finished pack."
    (cd "$dest/$version.partial" && sha256sum -c --quiet --strict SHA256SUMS) ||
        die 'Verification failed; delete the files listed above from the .partial directory and rerun.'
    rm -rf "${dest:?}/${version:?}"
    mv "$dest/$version.partial" "$dest/$version"
fi
if [[ -z ${2:-} ]]; then printf '%s\n' "$latest" > "$dest/latest.json.tmp" && mv "$dest/latest.json.tmp" "$dest/latest.json"; fi
# Swap the pointer atomically so GPU servers never copy a half-updated "current".
# Windows and exFAT/FAT drives cannot hold symlinks; the version directory is used directly.
if [[ -z $windows ]] && ln -sfn "$version" "$dest/.current.tmp" 2>/dev/null; then
    mv -T "$dest/.current.tmp" "$dest/current"
    log "Mirror ready: $dest/$version (current -> $version)"
else
    rm -rf "$dest/.current.tmp"
    log "Mirror ready: $dest/$version"
fi
printf 'Older versions are kept; remove them from %s when no server needs them.\n' "$dest"
printf 'Install on a GPU server: sudo bash <pack-path>/%s/ltx25-pack-deploy.sh install\n' "$version"
