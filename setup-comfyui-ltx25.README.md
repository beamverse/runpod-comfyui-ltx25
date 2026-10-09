# RunPod：ComfyUI + LTX-2.5 安装与自动启动

适用环境：Ubuntu/Debian、Linux x86_64、root、已透传的 NVIDIA GPU。默认针对 RTX 5090 安装 CUDA 13.0 版 PyTorch，要求宿主机驱动支持 CUDA 13.0。脚本不安装宿主机驱动，也不要求容器预装 CUDA Toolkit。

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
INSTALL_ROOT=/workspace/comfyui-ltx25
COMFYUI_REF=v0.39.0
LTX_VARIANT=int8                     # 或 bf16，见下文
LISTEN=0.0.0.0
PORT=8188
HF_HOME=/workspace/.cache/huggingface
PIP_CACHE_DIR=/workspace/.cache/pip
PYTHONUNBUFFERED=1
JUPYTER_PASSWORD=<your-password>     # 使用 Jupyter 时
HF_TOKEN=<RunPod Secret>             # 首次安装需要
```

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

通过 RunPod 的 8188 HTTP Service 打开 ComfyUI，在 Workflows 中打开：

```text
LTX-2.5-T2V-INT8.json
```

工作流文件位于：

```text
/workspace/comfyui-ltx25/data/user/default/workflows/LTX-2.5-T2V-INT8.json
```

首次测试建议 3 秒、0.4 megapixels、关闭 Prompt Enhance、单个视频。输出保存在：

```text
/workspace/comfyui-ltx25/data/output
```

模型下载时会显示当前文件序号、百分比、已下载/总大小、速度和预计剩余时间。Xet 存储的文件只显示写入磁盘的进度（按真实文件大小计算），不显示总量只是估算的网络传输进度条。交互终端原地刷新；RunPod 启动日志等非交互输出在下载进度更新时约每5秒记录一行。复用缓存的文件直接显示 `Ready`，不显示虚构的下载速度。

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

源码通过 `git clone/fetch/worktree` 获取，每个提交单独保存；脚本不会重置或覆盖用户修改，也不会自动删除旧版本。模型共用一个目录，Hugging Face 下载缓存允许复用完整文件并恢复中断下载。依赖安装或模型下载失败时不会切换当前激活版本，但更新同一提交的依赖不具备事务级回滚能力。重复安装同一版本时不会升级已安装的 PyTorch；新的 ComfyUI 版本使用新的 venv，会安装当时最新的 CUDA 13.0 PyTorch。

旧版若不包含 LTX-2.5 模板会明确失败。ComfyUI 前端和模板使用其 `requirements.txt` 指定的匹配依赖，不单独强制升级到不匹配版本。

## 完整精度（BF16）版本

默认安装 INT8 量化模型（`LTX_VARIANT=int8`），适合 32 GB 显存。如需 BF16 完整精度模型（22B 主模型、Gemma 4 12B 文本编码器和 Prompt Enhancer 均为 BF16）：

```bash
LTX_VARIANT=bf16 bash /workspace/setup-comfyui-ltx25.sh install
```

- 工作流保存为 `LTX-2.5-T2V-BF16.json`，与 INT8 工作流并存；两套模型共用 `data/models`，可以同时保留。
- 模型下载量约 76 GiB（INT8 约 42 GiB）；其中主模型 39 GiB、文本编码器 24 GiB、Prompt Enhancer 10 GiB。脚本会在下载前按实际文件大小检查剩余空间。
- BF16 权重远大于 32 GB 显存；在 RTX 5090 上 ComfyUI 会把部分权重放到系统内存，需要明显更多的内存，速度也更慢。建议使用 96 GB 显存的 RTX PRO 6000 或 80 GB 以上的 GPU。
- `startup` 只在首次启动时安装。要在已有安装上加装 BF16，请停止 ComfyUI 后手动执行上面的命令。

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

- 独立 Python 3.12、CUDA 13.0 版 PyTorch、ComfyUI 及其匹配依赖。
- 从已安装模板包中提取官方 LTX-2.5 文生视频工作流，按 `LTX_VARIANT` 把主模型、文本编码器和 Prompt Enhancer 统一替换为 INT8（默认）或 BF16 版本；上游模板无论发布哪种精度都能处理。
- 按工作流元数据下载主模型、文本编码器、标准视频 VAE、音频 VAE、空间放大器和 Prompt Enhancer；不安装 Manager 或额外 custom nodes，基础工作流使用 ComfyUI 原生节点。
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
