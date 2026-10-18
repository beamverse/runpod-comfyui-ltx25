# LTX2.5离线安装
用一台联网电脑把离线安装包下载到移动硬盘（SSD）再插到GPU服务器上安装
服务器全程不需要联网

## 服务器要求

| 项目 | 要求 |
|---|---|
| 系统 | ubuntu 24.04 x64 有root或sudo权限 物理机或容器 |
| GPU | n卡（英伟达） 最少32G显存  推荐rtx5090 |
| 显卡驱动 | 最低r525，rtx50系需要r570+，建议r580+ |
| 内存 | 最少64G |
| 内置硬盘 | 最少150G可用（模型约63G、运行环境约20 G 其余留给生成的视频） |
| 网络 | 不用 |

驱动要提前装好 用 `nvidia-smi` 确认能看到显卡 
(如果在docker或者k8s里运行 还需要英伟达container toolkit)

## 移动硬盘要求

- 容量128 G以上（安装包约63G） 
- **exFAT** NTFS ext4 格式 **不支持FAT32**（放不下模型）

## 0. 下载离线安装包

### Windows（推荐）

下载发布页里的 `ltx25-download.exe`，把它放在任意位置后双击运行。Windows 可能显示 SmartScreen 提示：选择「更多信息」→「仍要运行」。程序会列出磁盘，推荐选择 exFAT 或 NTFS 的移动 SSD，并把安装包写到 `<磁盘>:\ltx25\<版本号>`。双击后只需粘贴管理员发给你的下载码，再选择磁盘并等待完成；也可以设置 `LTX25_DOWNLOAD_CODE` 环境变量跳过提示。下载码只代表一个只读 R2 token，程序不会把它或解码后的凭据写入注册表、日志或硬盘。下载中断后再次运行即可续传。

也可以在 PowerShell 中使用 `ltx25-download.exe --dest E:\ltx25 --yes`。下载完成后先在任务栏中「安全删除硬件」再拔出硬盘。

### 管理员：生成下载码

建议每位操作员使用一个独立的只读 token，人员离开时只需吊销对应 token。生成下载码：

```bash
printf '%s:%s' "$ID" "$SECRET" | base64 -w0
```

PowerShell：

```powershell
[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${ID}:${SECRET}"))
```

也可运行 `ltx25-download.exe --make-code` 交互生成。

### Git Bash（备用）

准备一台联网的电脑 先装好 [rclone](https://rclone.org/install/)：

- Linux：`sudo -v && curl https://rclone.org/install.sh | sudo bash`
- Windows：`winget install Rclone.Rclone` 或者下载 `rclone.exe` 放到PATH里

然后打开终端（Linux用终端 Windows用Git Bash） 把最后的路径换成移动硬盘上的目录 运行：

```bash
# Linux 硬盘挂载在 /media/$USER/SSD
curl -fsSL https://raw.githubusercontent.com/beamverse/runpod-comfyui-ltx25/refs/heads/main/offline-pack/ltx25-pack-mirror.sh | bash -s -- /media/$USER/SSD/ltx25

# Windows Git Bash 硬盘是E: 盘
curl -fsSL https://raw.githubusercontent.com/beamverse/runpod-comfyui-ltx25/refs/heads/main/offline-pack/ltx25-pack-mirror.sh | bash -s -- /e/ltx25
```

- 默认下载最新版本 要指定版本 在路径后面加版本号 如 `... | bash -s -- /e/ltx25 20261018-130539` 
- 下载中的文件放在 `<版本号>.partial` 目录里 全部下载并校验通过后才改名为 `<版本号>` 
- 中途断了重新运行同一条命令即可 已下载完的文件会跳过 
- 看到 `Mirror ready: .../ltx25/<版本号>` 就完成了 安装包就是这个 `<版本号>` 目录 

在Windows上拔硬盘前 先在任务栏点"安全删除硬件" 避免文件没写完 

## 1. 在服务器上挂载硬盘

把硬盘插到服务器上：

```bash
lsblk -f                            # 找到移动硬盘的分区 比如sdb1（看大小和FSTYPE）
sudo mkdir -p /mnt/ssd
sudo mount /dev/sdb1 /mnt/ssd       # exFAT / ext4
# sudo mount -t ntfs3 /dev/sdb1 /mnt/ssd   # NTFS用这条
ls /mnt/ssd/ltx25/                  # 能看到版本号目录 如20261018-130539
```

下面用 `PACK=/mnt/ssd/ltx25/20261018-130539` 代表安装包目录 换成你的实际版本号：

```bash
PACK=/mnt/ssd/ltx25/20261018-130539
```

## 2. 校验（建议）

硬盘经过搬运或在别的电脑上插拔过 先完整校验一遍 需要几分钟：

```bash
sudo bash $PACK/ltx25-pack-deploy.sh verify
```

看到 `All pack files match SHA256SUMS.` 即可 如果有文件显示FAILED 回到下载电脑上删掉这些文件 重新运行第0步的命令 

## 3. 安装

**直接从移动硬盘安装 不用先复制到服务器硬盘上 ** 安装程序不会往硬盘里写东西 它会把需要的文件全部复制到服务器的内置硬盘 并逐个校验：

```bash
sudo bash $PACK/ltx25-pack-deploy.sh install
```

- 默认安装到 `/opt/comfyui-ltx25` 模型、输入、输出和工作流也放在这里的 `data/` 下 
- 想把模型和输出放到另一块大硬盘上 可以设置 `DATA_ROOT`：
  ```bash
  sudo DATA_ROOT=/data/ltx25 bash $PACK/ltx25-pack-deploy.sh install
  ```
- 安装程序会根据显卡驱动自动选择PyTorch版本（cu130 / cu128 / cu126） 缺少的系统软件也会从安装包里补装 
- 看到 `Installation complete` 就完成了 

安装完成后就可以拔掉硬盘：

```bash
sudo umount /mnt/ssd
```

如果想在服务器上留一份安装包 方便以后重装 可以复制一份：`sudo cp -r $PACK /srv/ltx25-pack` 这会额外占用约63 G 

## 4. 启动

```bash
sudo bash /opt/comfyui-ltx25/bin/ltx25-pack-deploy.sh start
```

启动后 在浏览器打开 `http://<服务器IP>:8188` 在服务器本机上可以用 `curl http://127.0.0.1:8188/system_stats` 检查服务是否正常 

- 改端口：`sudo PORT=8190 bash /opt/comfyui-ltx25/bin/ltx25-pack-deploy.sh start`
- 安装时指定了 `DATA_ROOT` 的话 启动时不用再写 安装程序已经记住了 
- 工作流在ComfyUI左侧的Workflows里 名字以 `LTX-2.5-` 开头 共7个 
- 要开机自动启动 见 `README-offline-install.md` 里的systemd示例 

## 5. 更新到新版本

1. 在联网电脑上重新运行第0步的命令 会下载新版本到新的 `<版本号>` 目录 
2. 在服务器上对新版本目录重复第1–4步 

更新会在原来的基础上进行：已有且没有变化的模型会跳过；你改过的工作流会保留 新版本的工作流另存为 `*.upstream.json` 

确认新版本没问题后 可以删掉硬盘上的旧版本目录 

## 常见问题

| 提示 | 处理 |
|---|---|
| `supports Ubuntu 24.04 LTS only` | 服务器系统不是Ubuntu 24.04 需要换系统或换容器镜像 |
| `nvidia-smi not found` / `Host driver R… is too old` | 安装或升级英伟达驱动 |
| `Incomplete pack` / `Pack verification failed` | 硬盘里的文件不全或损坏 回到第0步重新下载（会自动续传） |
| `Corrupt model files removed` | 再运行一次install 会重新复制这些文件 |
| `Insufficient disk` | 清理服务器硬盘 或用 `DATA_ROOT` 指定更大的硬盘 |
| `CUDA is unavailable` | 按提示检查驱动和 `/dev/nvidia*`；容器里检查GPU是否已映射进去 |
| `mount: unknown filesystem type 'ntfs'` | NTFS硬盘改用 `sudo mount -t ntfs3 ...` |

更多说明见同目录的 `README-offline-install.md` 
