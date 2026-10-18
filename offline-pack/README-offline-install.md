# LTX-2.5 offline pack

ComfyUI + LTX-2.5 for Ubuntu 24.04 GPU servers without internet access. A pack contains
everything the installer needs: system `.deb` packages, Python 3.12, PyTorch wheel pools
for `cu126`, `cu128` and `cu130`, ComfyUI and custom node sources, models, runtime assets
for annotator nodes, and workflows. No credentials are stored in a pack.

## Distribution flow

```text
builder (internet) --upload--> Cloudflare R2 --mirror--> LAN file server --copy--> GPU servers (offline)
```

| Step | Host | Script | Credentials |
|---|---|---|---|
| Build | Ubuntu 24.04 builder, internet, root | `ltx25-pack-build.sh create` | `HF_TOKEN` |
| Upload | builder | `ltx25-pack-build.sh upload` | R2 read/write key |
| Mirror | LAN file server, R2 access | `ltx25-pack-mirror.sh` | R2 read-only key |
| Install | Ubuntu 24.04 GPU server, no internet | `ltx25-pack-deploy.sh install` | none |

R2 keys come only from the platform's environment variables:
`R2_ACCOUNT_ID`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, optional `R2_PREFIX`
(default `ltx25`). Use a bucket-scoped read/write token on the builder and a read-only token
on the file server. The scripts configure rclone from these variables and write no config file.

## 1. Build (builder)

```bash
export HF_TOKEN=...            # read access to Lightricks/LTX-2.5 and the Ingredients LoRA
bash offline-pack/ltx25-pack-build.sh create /srv/build/ltx25-pack-20261018
# same as: bash setup-comfyui-ltx25.sh --create-offline-pack /srv/build/ltx25-pack-20261018
```

The build uses the same settings as `setup-comfyui-ltx25.sh` (`COMFYUI_REF`, `LTX_VARIANT`,
`LTX_TEXT_ENCODER`, `LTX_FRAME_STRENGTH`, `LTX_INGREDIENTS`, `LTX_UNION_CONTROL`,
`LTX_ALLINONE`, `COMFYUI_MANAGER`, `COMFYUI_CUSTOM_NODES`) and stops if an enabled workflow
or asset cannot be produced. `PACK_VERSION` names the version (default: UTC timestamp).
`<pack-dir>.work` caches downloads between builds; about 120 GiB free is needed the first time.

## 2. Upload (builder)

```bash
bash offline-pack/ltx25-pack-build.sh upload /srv/build/ltx25-pack-20261018
```

Uploads to `<bucket>/<prefix>/<version>/` in 128 MiB multipart chunks, checks every object,
then writes `<prefix>/latest.json`. A rerun skips objects that are already uploaded.

## 3. Mirror (LAN file server)

On Windows, use the dependency-free `ltx25-download.exe` from the release; paste the administrator-provided download code, select the SSD, and it writes the same verified version directory while resuming interrupted downloads. See `README-cn.md` for details.

```bash
bash ltx25-pack-mirror.sh /srv/ltx25            # version named by latest.json
bash ltx25-pack-mirror.sh /srv/ltx25 20261018-120000
```

Needs only `rclone` and `sha256sum`. Downloads into `<dest>/<version>.partial`, verifies
`SHA256SUMS`, renames to `<dest>/<version>` and then moves the `<dest>/current` link.
Interrupted runs resume. Older versions are kept until you remove them.

## 4. Install (GPU server)

Copy the pack from the file server, then install:

```bash
rsync -a --delete fileserver:/srv/ltx25/current/ /srv/ltx25-pack/
bash /srv/ltx25-pack/ltx25-pack-deploy.sh verify     # optional, full sha256 check
bash /srv/ltx25-pack/ltx25-pack-deploy.sh install
```

The pack can also be installed straight from a read-only NFS/SMB mount; install never
writes into the pack directory. Models are copied to local disk and verified there.

Install:

1. checks Ubuntu 24.04 x86_64, root, the NVIDIA driver and free disk space;
2. picks the newest PyTorch pool the driver supports (`cu130` R580+, `cu128` R570+,
   `cu126` R525+) or the one forced with `TORCH_CUDA`, and refuses a pool the driver cannot run;
3. installs missing system packages from the pack's local apt repository (the host's apt
   sources are not used or changed);
4. creates the release venv from local wheels only (`uv pip sync --offline --no-index --no-build`)
   and runs a CUDA self-test;
5. installs pinned custom nodes (a different existing copy is moved to `$INSTALL_ROOT/backup`),
   models, runtime assets and workflows (an edited workflow is kept; the pack's copy is saved
   as `*.upstream.json`);
6. sets ComfyUI-Manager to `offline`.

Rerunning install with a newer pack updates in place; files that are already present are skipped.

## Start

```bash
bash /opt/comfyui-ltx25/bin/ltx25-pack-deploy.sh start
```

`start` runs without the pack directory. It removes `HF_TOKEN` and all `R2_*` /
`RCLONE_CONFIG_R2_*` variables from the ComfyUI environment and sets `HF_HUB_OFFLINE=1`.
Check it with `curl http://127.0.0.1:8188/system_stats`.

Example systemd unit:

```ini
[Unit]
Description=ComfyUI LTX-2.5
After=network-online.target

[Service]
Environment=INSTALL_ROOT=/opt/comfyui-ltx25
ExecStart=/bin/bash /opt/comfyui-ltx25/bin/ltx25-pack-deploy.sh start
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

## Settings

| Variable | Default | Used by |
|---|---|---|
| `INSTALL_ROOT` | `/opt/comfyui-ltx25` | install, start |
| `DATA_ROOT` | `$INSTALL_ROOT/data` (remembered by install) | install, start |
| `TORCH_CUDA` | `auto` | install |
| `PACK_VERIFY` | `1`; `0` skips sha256 checks | install |
| `PACK_KEEP_STAGING` | `0`; `1` keeps the extracted runtime | install |
| `LISTEN` / `PORT` | `0.0.0.0` / `8188` | start |
| `COMFYUI_MANAGER` | `1`; `0` starts without Manager | start |
| `COMFYUI_MANAGER_NETWORK_MODE` | `offline` | start |

## Pack layout

```text
<version>/
  ltx25-pack-deploy.sh  ltx25-pack-mirror.sh  lib/ltx25-common.sh
  pack.env               # non-secret settings: version, ComfyUI commit, pools, flags
  manifest.json          # models, custom node revisions, packages per pool, .debs, every file's sha256
  SHA256SUMS
  README-offline-install.md
  models/                # one file per object, same layout as ComfyUI's models/
  runtime/linux-x86_64/
    base.tar             # ComfyUI, custom_nodes, workflows, Python 3.12, uv, .debs, locks, shared wheels
    wheels-cu126.tar  wheels-cu128.tar  wheels-cu130.tar
```

The archives are plain `.tar` because their contents (wheels, `.deb` files) are already
compressed, and so the target needs no `zstd`.

Installed layout (same as `setup-comfyui-ltx25.sh`):

```text
$INSTALL_ROOT/  bin/ python/ bootstrap/bin/uv releases/<commit>/.venv active-release
                pack.env manifest.json deploy.env backup/ cache/
$DATA_ROOT/     models/ input/ output/ user/default/workflows/
```

## Troubleshooting

| Message | Action |
|---|---|
| `supports Ubuntu 24.04 LTS only` | Use an Ubuntu 24.04 host or container image. |
| `Host driver R… is too old` | Update the host NVIDIA driver (R525+, R570+ for RTX 50-series). |
| `needs an R… or newer host driver` | Unset `TORCH_CUDA` or choose an older pool. |
| `Incomplete pack: … is missing` | Copy the whole pack directory again from the file server. |
| `Pack verification failed` | Copy the files `sha256sum` listed as FAILED again, then rerun. |
| `Corrupt model files removed` | Rerun install; it copies those files again. |
| `The … package pool is incomplete` | Rebuild the pack; the wheel pool does not match its lock. |
| `Insufficient disk` | Free space or move `DATA_ROOT` to a larger disk. |
| `CUDA is unavailable` | Read the diagnostics: usually a missing `/dev/nvidia-uvm` or GPU not passed to the container. |
| A node tries to download a model at runtime | `HF_HUB_OFFLINE=1` makes it fail fast. Add the file to `RUNTIME_ASSETS` in `ltx25-pack-build.sh` and rebuild. |
