# RunPod：ComfyUI + LTX-2.5 安装与自动启动

适用环境：Ubuntu/Debian、Linux x86_64、root、已透传的 NVIDIA GPU。默认针对 RTX 5090，按宿主机驱动自动选择 PyTorch 的 CUDA 版本（见“宿主机驱动与 PyTorch CUDA 版本”），最低要求 R525 驱动。脚本不安装宿主机驱动，也不要求容器预装 CUDA Toolkit。

建议使用 Ubuntu 24.04 GPU 容器、32 GB 显存、约 64 GB 系统内存，并将至少 150–200 GB 持久化存储挂载到 `/workspace`。在 RunPod 暴露 HTTP 8188（ComfyUI）；如果基础镜像提供 Jupyter/SSH，可同时暴露 HTTP 8888 和 TCP 22。真正的 Docker `scratch` 镜像没有 Bash/apt，不能运行此脚本；这里的“空白容器”指尚未安装 ComfyUI 的 Ubuntu/Debian 容器。

## 推荐的 RunPod Template 配置

针对当前这套部署，推荐：

```text
Container image:
runpod/pytorch:1.0.3-cu1300-torch291-ubuntu2404

Container disk:
50 GB

Persistent storage:
150 GB 或更大

Persistent mount path:
/workspace

HTTP ports:
comfyui  8188
jupyter  8888   # 可选

TCP ports:
ssh      22     # 可选
```

环境变量建议：

```text
INSTALL_ROOT=                        # 留空自动选择，见“S3 网络卷（geesefs）”
DATA_ROOT=                           # 留空：/workspace/comfyui-ltx25/data
COMFYUI_REF=v0.39.0
LTX_VARIANT=int8                     # 或 bf16，见下文
LTX_TEXT_ENCODER=                    # 留空跟随 LTX_VARIANT；可单独设 bf16，见下文
LTX_FRAME_STRENGTH=0.9               # I2V/FLF2V 关键帧强度，见下文
TORCH_CUDA=auto                      # 或 cu130 / cu128 / cu126，一般保持 auto
COMFYUI_MANAGER=1                    # 默认安装并启用 ComfyUI-Manager；0 关闭
COMFYUI_MANAGER_NETWORK_MODE=personal_cloud  # 允许在网页中安装节点；public 则禁止
COMFYUI_CUSTOM_NODES=1               # 默认在 start 时补装音频驱动工作流所需节点包；0 关闭
LISTEN=0.0.0.0
PORT=8188
HF_HOME=/workspace/.cache/huggingface   # S3 网络卷上不要设置这两项（见下文）
PIP_CACHE_DIR=/workspace/.cache/pip
PYTHONUNBUFFERED=1
JUPYTER_PASSWORD=<your-password>     # 使用 Jupyter 时
HF_TOKEN=<RunPod Secret>             # 首次安装需要
```

`COMFYUI_MANAGER=1`（默认）时，`install` 按 ComfyUI 发布版自带的 `manager_requirements.txt` 安装固定版本的 ComfyUI-Manager，`start`/`startup` 自动加上 `--enable-manager`。由旧版脚本安装、尚未包含 Manager 的环境，会在下次 `start` 时就地补装，无需重新安装，也不需要 `HF_TOKEN`；补装失败只会打印警告，ComfyUI 照常启动，只是没有 Manager。没有 `manager_requirements.txt` 的旧 ComfyUI 版本不支持 `--enable-manager`，脚本会跳过。

ComfyUI 监听 `0.0.0.0` 时，Manager 默认的 `network_mode = public` 会拒绝所有节点安装（点 Install All 无效）。因此 `start` 每次启动都会把 `$DATA_ROOT/user/__manager/config.ini` 的 `network_mode` 设为 `COMFYUI_MANAGER_NETWORK_MODE`（默认 `personal_cloud`，Manager 文档推荐用于 RunPod 等云环境）。注意：ComfyUI 没有登录保护，任何拿到 RunPod 代理地址的人都能通过 Manager 安装并运行 custom nodes 代码；不希望如此时设为 `public`，改用 SSH 手动安装节点。

注意脚本读取的是 `COMFYUI_REF`，不是 `COMFYUI_VERSION`。如果希望固定 ComfyUI v0.39.0，请使用 `COMFYUI_REF=v0.39.0`。如果设置为 `latest`，每次手动执行 `install` 时会查询最新正式发布版。

## 首次准备

先使用自己的 Hugging Face 账号打开 <https://huggingface.co/Lightricks/LTX-2.5> 并接受访问协议，然后创建能读取该受限仓库的 Token。

将脚本保存到持久化目录：

```text
/workspace/setup-comfyui-ltx25.sh
```

可选：赋予执行权限（脚本内部始终通过 `bash` 调用自身，没有执行权限也能运行 `startup`）：

```bash
chmod +x /workspace/setup-comfyui-ltx25.sh
```

`/workspace` 必须是持久化存储；否则 Pod 重建后脚本、ComfyUI、模型和输出都会丢失。

## RunPod Start Command：推荐方式

Template 的 **Start command** 直接设置为：

```bash
bash /workspace/setup-comfyui-ltx25.sh startup
```

`startup` 是专门为 RunPod 启动流程设计的幂等模式：

1. 如果镜像存在 `/start.sh`，默认先在后台启动 RunPod 基础服务，以保留 SSH/Jupyter。
2. 检查 `$INSTALL_ROOT/active-release`。
3. 第一次启动时自动执行 `install`，因此必须提供 `HF_TOKEN`。如果安装失败，脚本不会退出，而是打印错误后保持容器运行（`sleep infinity`），避免 Pod 反复重启，同时保留 SSH/Jupyter 用于排查；修复后手动执行 `install` 或重启 Pod。
4. 已安装后的 Stop → Start 会跳过安装和模型下载。
5. 最后以前台进程启动 ComfyUI，使 Pod 能正确跟踪主服务。

如果使用的镜像没有 `/start.sh`，脚本会自动跳过。若明确不希望启动 RunPod 基础服务，可设置：

```text
RUNPOD_START_BASE_SERVICES=0
```

### 首次启动

第一次运行：

```text
startup
  -> /start.sh（如存在）
  -> install
  -> start
  -> ComfyUI :8188
```

之后重启同一个持久化环境：

```text
startup
  -> /start.sh（如存在）
  -> 检测 active-release
  -> 跳过 install
  -> start
  -> ComfyUI :8188
```

因此不要把 `install` 本身直接作为 RunPod 的长期 Start command，否则每次重启都会再次进行更新检查、依赖安装和模型检查。

## 手动安装和启动

如果不使用 `startup`，也可以手动执行。

首次安装：

```bash
bash /workspace/setup-comfyui-ltx25.sh install
```

如果终端是交互式的且没有设置 `HF_TOKEN`，脚本会隐藏输入 Token。RunPod Start Command 属于非交互环境，因此自动启动场景必须通过 RunPod Secret/环境变量提供 `HF_TOKEN`。不要将 Token 直接写进脚本或 shell 命令历史。脚本不会调用 `hf auth login` 保存 Token，也不会把 Token 传给启动后的 ComfyUI 进程。

安装成功后：

```bash
bash /workspace/setup-comfyui-ltx25.sh start
```

`start` 是前台进程，适合作为容器主进程。仅在通过 SSH 手动启动且希望断开 SSH 后继续运行时，才建议：

```bash
nohup bash /workspace/setup-comfyui-ltx25.sh start \
  > /workspace/comfyui-ltx25/logs/server.log 2>&1 < /dev/null &
```

检查日志和服务：

```bash
tail -n 80 /workspace/comfyui-ltx25/logs/server.log
curl -fsS http://127.0.0.1:8188/system_stats
```

通过 RunPod 的 8188 HTTP Service 打开 ComfyUI，在 Workflows 中打开（`BF16` 安装对应 `-BF16.json`）：

```text
LTX-2.5-T2V-INT8.json     # 文生视频
LTX-2.5-I2V-INT8.json     # 图生视频：在 Load Image 节点上传首帧图片
LTX-2.5-FLF2V-INT8.json   # 首尾帧生视频：上传首帧和尾帧两张图片
LTX-2.5-AUDIO-DRIVE-INT8.json  # 音频驱动图生视频：上传首帧图片和音频
```

音频驱动工作流是社区工作流，保存在本仓库 `workflows/ltx25-audio-drive.json`。`install` 优先读取脚本同目录下的 `workflows/`，否则从 GitHub `main` 分支下载，并和官方工作流一样按 `LTX_VARIANT`/`LTX_TEXT_ENCODER` 替换模型文件名；下载失败只打印警告，不影响安装。它依赖 rgthree-comfy、comfy-mtb、ComfyUI-KJNodes 和 ComfyUI-Custom-Scripts 四个节点包。`COMFYUI_CUSTOM_NODES=1`（默认）时，每次 `start`/`startup` 启动 ComfyUI 前都会检查 `$INSTALL_ROOT/data/custom_nodes`：缺失的包从 GitHub 浅克隆，并把它的 `requirements.txt` 装进当前发布版的 `.venv`（已装过依赖的包记录在发布版目录的 `custom-nodes-installed` 中，之后启动不再重复）。通过 Manager 安装的同名包（如 `comfyui-kjnodes`）视为已安装；在 Manager 中禁用的包不会被重新装回。下载或依赖安装失败只打印警告，ComfyUI 照常启动，此时可在 Missing Node Packs 中点 Install All。

前三个工作流来自同一个官方模板包，与音频驱动工作流共用同一套模型，不需要额外下载。工作流文件位于：

```text
/workspace/comfyui-ltx25/data/user/default/workflows/
```

已用旧版脚本安装过的环境，重新执行一次 `install` 即可补上 I2V/FLF2V 工作流（模型和依赖会直接复用）。

首次测试建议 3 秒、0.4 megapixels、关闭 Prompt Enhance、单个视频。输出保存在：

```text
/workspace/comfyui-ltx25/data/output
```

模型下载时会显示当前文件序号、百分比、已下载/总大小、速度和预计剩余时间。Xet 存储的文件只显示写入磁盘的进度（按真实文件大小计算），不显示总量只是估算的网络传输进度条。交互终端原地刷新；RunPod 启动日志等非交互输出在下载进度更新时约每5秒记录一行。复用缓存的文件直接显示 `Ready`，不显示虚构的下载速度。

模型文件均存储在 Hugging Face Xet 上，`hf_xet` 本身就是多连接并发下载；脚本默认开启 `HF_XET_HIGH_PERFORMANCE=1` 以提高并发，若内存或 CPU 紧张可设为 `0`。

模型下载和 CUDA 自检成功不代表视频生成已经完整验收。

## 更新与重复使用

`startup` **不会在已有安装存在时自动升级 ComfyUI**。这是刻意设计的，以确保 Pod Stop → Start 快速且可预测。

需要升级时，先停止正在运行的 ComfyUI，然后手动执行：

```bash
COMFYUI_REF=v0.39.0 bash /workspace/setup-comfyui-ltx25.sh install
```

或者使用最新正式版：

```bash
COMFYUI_REF=latest bash /workspace/setup-comfyui-ltx25.sh install
```

开发分支：

```bash
COMFYUI_REF=master bash /workspace/setup-comfyui-ltx25.sh install
```

安装锁会拒绝一边运行 ComfyUI 一边更新。同一次安装成功后才会更新 `active-release`；随后 `startup`/`start` 会启动这个激活版本。

源码通过 `git clone/fetch/worktree` 获取，每个提交单独保存；脚本不会重置或覆盖用户修改，也不会自动删除旧版本。模型共用一个目录，Hugging Face 下载缓存允许复用完整文件并恢复中断下载。依赖安装或模型下载失败时不会切换当前激活版本，但更新同一提交的依赖不具备事务级回滚能力。重复安装同一版本时不会升级已安装的 PyTorch；新的 ComfyUI 版本使用新的 venv，会安装当时最新的 PyTorch。例外：已安装的 PyTorch 需要比本机更新的驱动（例如持久盘换到了驱动更旧的宿主机）、不支持本机 GPU 架构，或用 `TORCH_CUDA` 明确指定了其他版本时，会先卸载再重装匹配的版本。

旧版若不包含 LTX-2.5 模板会明确失败。ComfyUI 前端和模板使用其 `requirements.txt` 指定的匹配依赖，不单独强制升级到不匹配版本。

## 宿主机驱动与 PyTorch CUDA 版本

RunPod 同一种 GPU 也可能分到不同驱动版本的宿主机，容器内无法升级驱动。脚本读取 `nvidia-smi` 的驱动版本，自动选择能运行的最新 CUDA 版 PyTorch：

| 宿主机驱动 | PyTorch 源 | 说明 |
|---|---|---|
| R580+ | `cu130` | 默认目标，RTX 5090 推荐 |
| R570–R579 | `cu128` | RTX 50 系（Blackwell）最低要求 |
| R525–R569 | `cu126` | 通过 CUDA 12 小版本兼容运行，适用于 A100、H100、L40S、RTX 4090 等；例如 RunPod A100 PCIe 常见的 R550 主机 |
| 低于 R525 | — | 安装失败，请换宿主机 |

也可以用 `TORCH_CUDA=cu126|cu128|cu130` 手动指定；指定版本超过驱动支持范围时脚本会拒绝安装。RTX 50 系不能使用 `cu126`。

持久盘在不同宿主机之间挂载时，`start`/`startup` 启动前会检查已安装的 PyTorch 能否在本机运行：需要比本机更新的驱动，或者没有本机 GPU 架构的 kernel（例如在 R550 的 RTX 3070 主机上装成 `cu126`，`cu126` 只编译到 sm_90，换到 RTX 5090 / sm_120 无法运行）。`startup` 发现不匹配会自动重新执行 `install` 换成匹配的 PyTorch（模型复用已下载文件，仍需要 `HF_TOKEN`）；`start` 则直接报错并提示重新安装。

先用便宜的 GPU Pod 往网络卷下载模型、再挂到 RTX 5090 上运行时，建议安装时指定 `TORCH_CUDA=cu128`（要求该主机驱动 R570+），这样 5090 上无需重装 PyTorch；否则首次 `startup` 会自动重装一次。

## S3 网络卷（geesefs）

部分 RunPod 数据中心的网络卷是 S3 兼容存储，`mount` 显示为 `fuse.geesefs`。它不支持 `chmod`：所有文件固定为 `0666`、属主 `nobody`，因此其中的 venv、uv 管理的 Python 都无法执行；venv 和 Git 仓库的大量小文件放在对象存储上也非常慢。

脚本把目录分为两部分：

- `INSTALL_ROOT`：代码，包括 ComfyUI 发布版、Python、venv、uv 缓存、custom_nodes 和 ComfyUI 的 SQLite 数据库。
- `DATA_ROOT`：数据，包括 `models`、`input`、`output`、`user`（工作流、设置、Manager 配置）。ComfyUI 的 `--base-directory` 仍是 `$INSTALL_ROOT/data`，其中这四个目录是指向 `DATA_ROOT` 的软链接。

未设置 `INSTALL_ROOT` 时，脚本在 `/workspace/comfyui-ltx25` 试一次 `chmod`：

- 成功（普通卷）：代码和数据都放在 `/workspace/comfyui-ltx25`，与旧版本完全相同。
- 失败（S3 卷）：代码放在容器盘 `/opt/comfyui-ltx25`，数据仍在 `/workspace/comfyui-ltx25/data`。

明确设置的 `INSTALL_ROOT` 不支持权限时，脚本直接报错，不会开始安装。

S3 卷上的注意事项：

- 容器盘在 Pod 停止后清空，所以每次开机 `startup` 都会重新安装 ComfyUI 和 PyTorch（几分钟），**每次启动都需要 `HF_TOKEN`**。模型已在卷上，只做校验，不会重新下载。
- 容器盘建议至少 40 GB。
- 通过 Manager 安装的 custom nodes 在容器盘上，每次开机都会丢失；音频驱动工作流的四个节点包会自动补装。
- 不要把 `HF_HOME`、`PIP_CACHE_DIR` 指向 S3 卷。
- 在普通卷上从旧版本迁移时，若 `$INSTALL_ROOT/data` 下已有非空的 `models` 等目录，而 `DATA_ROOT` 指向别处，脚本会报错，请先手动移动这些目录的内容。

### 安装时报 "CUDA is unavailable"

安装过程中的 CUDA 自检失败时，脚本会打印诊断信息：`/dev/nvidia*` 设备是否存在、`libcuda.so.1` 能否加载，以及 `cuInit` 的返回码。

- **`cuInit` 不为 0**（常见的是 `999 CUDA_ERROR_UNKNOWN`），或 `/dev/nvidia-uvm` 显示 `MISSING`：宿主机的 GPU 没有完整透传到容器。此时 `nvidia-smi` 往往仍然正常，但这不是 PyTorch 或脚本的问题，容器里修不了。先重启 Pod；仍然失败就终止 Pod，重新部署到另一台机器。
- **`libcuda.so.1` 无法加载**：容器没有挂载 GPU，检查 Pod 是否选择了 GPU。
- **`cuInit = 0` 但 PyTorch 仍不可用**：PyTorch 的 CUDA 版本与驱动不匹配，用 `TORCH_CUDA` 指定合适的版本后重新安装。

## 完整精度（BF16）版本

默认安装 INT8 量化模型（`LTX_VARIANT=int8`），适合 32 GB 显存。如需 BF16 完整精度模型（22B 主模型、Gemma 4 12B 文本编码器和 Prompt Enhancer 均为 BF16）：

```bash
LTX_VARIANT=bf16 bash /workspace/setup-comfyui-ltx25.sh install
```

- 工作流保存为 `LTX-2.5-T2V-BF16.json`，与 INT8 工作流并存；两套模型共用 `data/models`，可以同时保留。
- 模型下载量约 76 GiB（INT8 约 42 GiB）；其中主模型 39 GiB、文本编码器 24 GiB、Prompt Enhancer 10 GiB。脚本会在下载前按实际文件大小检查剩余空间。
- BF16 权重远大于 32 GB 显存；在 RTX 5090 上 ComfyUI 会把部分权重放到系统内存，需要明显更多的内存，速度也更慢。建议使用 96 GB 显存的 RTX PRO 6000 或 80 GB 以上的 GPU（如 A100 80GB）。
- `startup` 只在首次启动时安装。要在已有安装上加装 BF16，请停止 ComfyUI 后手动执行上面的命令。

## 文本编码器单独使用 BF16

`LTX_TEXT_ENCODER` 可以单独指定 Gemma 4 12B 文本编码器的精度（`int8` 或 `bf16`），不设置时跟随 `LTX_VARIANT`。常见用法是在 RTX 5090 上保留 INT8 主模型、文本编码器改用 BF16：

```bash
LTX_TEXT_ENCODER=bf16 bash /workspace/setup-comfyui-ltx25.sh install
```

- 只影响文本编码器；主模型和 Prompt Enhancer 仍按 `LTX_VARIANT`，视频/音频 VAE 和空间放大器始终为 BF16。
- 文本编码器每次生成只运行一次，ComfyUI 会在采样前按需把它移出显存，BF16 版（约 24 GiB）单独可放入 32 GB 显存；代价是下载量和磁盘占用增加，加载更慢，系统内存压力更大（建议 64 GB 以上）。
- 精度与 `LTX_VARIANT` 不同时，工作流文件名带后缀，例如 `LTX-2.5-T2V-INT8-TE-BF16.json`，与其他组合的工作流并存。
- 已有安装上切换：停止 ComfyUI 后用上面的命令重新执行 `install`，已下载的模型会复用。

## 关键帧强度（人物一致性）

官方 I2V 工作流第一阶段的首帧强度、FLF2V 的首尾帧强度都是 `0.7`，模型可以改动关键帧本身，人脸从第一帧起就可能偏离参考图。脚本生成 I2V/FLF2V 工作流时会做两项调整：

- 把这些强度改为 `LTX_FRAME_STRENGTH`（默认 `0.9`）。I2V 第二阶段原本就是 `1.0`，保持不变。
- 关键帧缩放从 `nearest-exact` 改为 `lanczos`，保留面部细节。

```bash
LTX_FRAME_STRENGTH=1.0 bash /workspace/setup-comfyui-ltx25.sh install
```

- 强度越高越贴近关键帧，但动作可能变少；画面太"定"时可降到 `0.8`–`0.85`。设为 `0.7` 即恢复官方强度（缩放仍为 lanczos）。
- 已安装过的环境再次执行 `install` 时，为保护你修改过的工作流，原文件不会被覆盖，新工作流写入 `*.upstream.json`。要直接替换，先删除或改名旧的 `LTX-2.5-I2V-*.json` / `LTX-2.5-FLF2V-*.json`。
- 不想重新安装，也可以在 ComfyUI 中进入子图手动修改：`LTXVImgToVideoInplace`（strength 小于 1 的那个）、`LTXVAddGuide` 的 strength，以及 `ResizeImageMaskNode` 的缩放方法。

## 自定义目录、端口和 ComfyUI 参数

自定义目录：

```bash
INSTALL_ROOT=/workspace/my-ltx bash /workspace/setup-comfyui-ltx25.sh install
INSTALL_ROOT=/workspace/my-ltx bash /workspace/setup-comfyui-ltx25.sh start
```

自定义端口：

```bash
PORT=8189 bash /workspace/setup-comfyui-ltx25.sh start
```

自定义目录后，所有后续命令和 RunPod Template 都必须使用相同的 `INSTALL_ROOT`。

可以给 `start` 或 `startup` 继续追加 ComfyUI 参数，例如：

```bash
bash /workspace/setup-comfyui-ltx25.sh start --lowvram
bash /workspace/setup-comfyui-ltx25.sh startup --lowvram
```

## SSH / Jupyter

在推荐的 RunPod PyTorch 基础镜像中，`startup` 默认尝试执行：

```bash
/start.sh &
```

用于保留镜像提供的基础服务。8188 仍由本脚本启动的 ComfyUI 监听。

SSH 公钥更建议添加到 RunPod Account 的 SSH Keys，而不是硬编码进 Template 的普通环境变量。如果必须使用 `PUBLIC_KEY`，多个 key 应按 `authorized_keys` 格式逐行填写，每行一个完整公钥。

## 安装内容和边界

- 独立 Python 3.12、按驱动选择 CUDA 版本的 PyTorch、ComfyUI 及其匹配依赖。
- 从已安装模板包中提取官方 LTX-2.5 文生视频工作流，按 `LTX_VARIANT` 把主模型、文本编码器和 Prompt Enhancer 统一替换为 INT8（默认）或 BF16 版本；上游模板无论发布哪种精度都能处理。I2V/FLF2V 工作流另按 `LTX_FRAME_STRENGTH` 调整关键帧强度和缩放方法。
- 按工作流元数据下载主模型、文本编码器、标准视频 VAE、音频 VAE、空间放大器和 Prompt Enhancer；另外下载官方模板未使用、但社区工作流常用的 Conv VAE（`ltx-2.5-video-vae-conv-bf16.safetensors`，约 1.4 GiB，更快更轻）；默认安装 ComfyUI-Manager；基础工作流只用 ComfyUI 原生节点，`start` 另外补装音频驱动工作流需要的四个节点包（见上文）。
- 通过 Manager 安装的 custom nodes 位于 `$INSTALL_ROOT/data/custom_nodes`，可跨版本保留；但它们的 Python 依赖装在当前发布版的 `.venv` 里。`install` 升级到新的 ComfyUI 版本会新建 `.venv`，之后需要在 Manager 中修复或重装这些节点的依赖（音频驱动工作流的四个节点包除外，`start` 会自动为新 `.venv` 补装依赖）。
- 检查 Hugging Face 授权、下载前剩余空间、模型文件大小、Python 依赖和实际 CUDA BF16 矩阵运算。
- 记录源码 commit、已安装依赖版本和模型仓库 revision，便于复查。
- 当前模型组合会占用大量空间；Python、PyTorch、缓存、旧源码环境和输出也会持续占用持久盘，脚本不会自动清理旧版本。
- `LISTEN` 默认 `0.0.0.0`，供 RunPod HTTP Proxy 访问。ComfyUI 本身不提供登录保护，应依赖 RunPod 的访问控制或使用 SSH 转发。
- `startup` 的自动安装判定依据是 `$INSTALL_ROOT/active-release`。如果持久盘损坏或手工删除关键文件，`start` 会拒绝运行；此时应检查环境后重新执行 `install`，而不是静默覆盖。
- 上游模板、模型仓库或依赖未来发生结构变化时，脚本会尽量停止并要求复核，而不是静默安装不完整环境。

## 脚本命令速查

```bash
# 查看帮助
bash /workspace/setup-comfyui-ltx25.sh help

# 首次安装 / 手动更新
bash /workspace/setup-comfyui-ltx25.sh install

# 仅启动，不安装、不下载
bash /workspace/setup-comfyui-ltx25.sh start

# RunPod Template 推荐：首次安装，后续直接启动
bash /workspace/setup-comfyui-ltx25.sh startup
```

依据：[ComfyUI 手动安装](https://github.com/Comfy-Org/ComfyUI#manual-install-windows-linux)、[LTX 官方 ComfyUI 说明](https://docs.ltx.io/open-source-model/integration-tools/comfy-ui)、[Hugging Face 下载接口](https://huggingface.co/docs/huggingface_hub/guides/download)。
