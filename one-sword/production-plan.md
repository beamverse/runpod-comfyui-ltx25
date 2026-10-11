# 《一剑听雨》ComfyUI 制作方案

基于 `onesword.md` 剧本，使用本仓库安装的 LTX-2.5 I2V / FLF2V 官方工作流。

## 1. 总体思路

不要每个 PART 只跑一次 15 秒。每个 PART 拆成 4–5 个 2–4 秒的镜头，每个镜头用自己的关键帧单独生成，最后硬切拼接：

```text
角色设定图 (shenmo_ref / qingyi / 1 / 2)
  → 用图像编辑模型生成每个镜头的关键帧（16:9，人物必须对照设定图核对）
  → 每个镜头跑 I2V（只有首帧）或 FLF2V（首帧 + 尾帧）
  → 每个镜头固定 seed，不满意只重跑该镜头
  → 剪辑软件或 ffmpeg 硬切拼接，后期加旁白、片名
```

这样做的原因：

- 剧本本身就是由多个硬切镜头组成的（PART 4 里还有一段闪回）。一次生成 15 秒，模型要在镜头内部自己"切镜头"，角色会漂移，很难控制。
- **每个镜头开头都有一张核对过的关键帧，人脸就不会离参考太远。** LTX 不负责"创造"角色，只负责让关键帧动起来。
- 镜头越短，漂移越少；某个镜头失败时，只需要重跑 3 秒，不用重跑 15 秒。

### 选择 I2V 还是 FLF2V

| 情况 | 用 |
|---|---|
| 镜头里人脸从头到尾可见，动作幅度小 | I2V |
| 人物从背面/遮挡转向正面 | FLF2V，尾帧要有正脸 |
| 镜头必须停在特定构图上（如 4.png、6.png） | FLF2V，把该图作为尾帧 |
| 剑气、伞挡箭、化墨等特效，需要控制结束状态 | FLF2V |

## 2. 工作流参数修改（提高人物一致性）

`setup-comfyui-ltx25.sh install` 现在会自动应用下表中的强度和缩放修改（`LTX_FRAME_STRENGTH`，默认 0.9，见 README"关键帧强度"一节）。下面的表格用于理解这些修改，或在 ComfyUI 中手动微调。

手动修改时，在 ComfyUI 中打开 `LTX-2.5-I2V-*.json` / `LTX-2.5-FLF2V-*.json`，**另存为**新工作流（例如 `onesword-I2V.json`），再修改。参数在子图内部：点击主节点底部的 **Enter subgraph**。

以下节点 ID 来自模板 `comfyui-workflow-templates 0.11.78`，你安装的版本可能不同，按节点类型查找即可。

### I2V（Image to Video）

| 节点 | 默认 | 改为 | 原因 |
|---|---|---|---|
| 第一阶段 `LTXVImgToVideoInplace`（#357，接 `EmptyLTXVLatentVideo`） | strength `0.7` | `0.9`–`1.0` | 0.7 允许模型改动首帧本身，第一帧人脸就可能已经变了 |
| 第二阶段 `LTXVImgToVideoInplace`（#349） | `1.0` | 不变 | |
| `prompt_enhance` | off | 保持 off | 增强器会改写外貌描述 |
| `width` × `height` | 1280×720 | 不变或更高 | 关键帧都是 16:9，不要降低分辨率 |
| seed | randomize | 每个镜头记录一个固定值 | 方便单独重跑 |

strength 调到 1.0 后，画面可能会更"定"、动作偏少；此时在提示词里把动作写得更明确，或者退回 0.85–0.9。

### FLF2V（First & Last Frame to Video）

| 节点 | 默认 | 改为 | 原因 |
|---|---|---|---|
| `LTXVAddGuide` frame_idx `0`（#206，首帧） | strength `0.7` | `0.9`–`1.0` | 首帧人脸更贴近关键帧 |
| `LTXVAddGuide` frame_idx `-1`（#204，尾帧） | strength `0.7` | `0.85`–`1.0` | 镜头必须落在尾帧构图上 |
| 两个 `ResizeImageMaskNode`（#213、#214） | `nearest-exact` | `lanczos` | nearest 缩小会产生锯齿，损失面部细节 |

FLF2V 会把两张图按 `width`/`height` **居中裁切**，所以首帧和尾帧都必须是 16:9。`1-1.png`、`1-2.png` 这类竖版设定图不能直接当关键帧用。

### 进阶：一次生成内放多个关键帧

FLF2V 子图里的 `LTXVAddGuide` 可以串联多个：复制一个 `LTXVAddGuide`，接在 #204 后面，`frame_idx` 填中间帧号（24fps 下第 3 秒 ≈ 72，建议取 8 的倍数），`image` 接另一张关键帧（同样经过 `ResizeImageMaskNode` → `LTXVPreprocess`）。末尾的 `LTXVCropGuides` 已经存在，不需要再加。

这样可以在一个 6–8 秒的镜头中放 3 个锚点（例如：背影 → 侧脸 → 正脸）。建议先把按镜头单独生成的流程跑通，再尝试这种方式。

## 3. 关键帧清单

现有图片：

| 文件 | 用途 |
|---|---|
| `shenmo_ref.png`、`1.png`、`1-1.png`、`1-2.png` | 沈墨设定，**只作为生成关键帧的参考，不直接送进 LTX** |
| `qingyi.png`、`2.png`、`2-1.png`、`2-2.png` | 清漪设定，同上 |
| `3.png` | 镜头 1A 首帧（石阶背影） |
| `4.png` | 镜头 2E 尾帧（伞挡箭） |
| `5.png` | 镜头 3C 首帧（一剑） |
| `6.png` | 镜头 4E 尾帧（化墨） |

需要补做的关键帧（16:9，1672×941 或 1280×720，与现有图片同一画风）：

| 编号 | 内容 | 人脸 |
|---|---|---|
| K1B | 沈墨右手特写，手指靠近剑柄，雨水打在袖口 | 无 |
| K1C | 沈墨四分之三侧脸中近景，望向远处茶亭灯火，雨夜 | 沈墨 |
| K2A | 茶亭内中景：清漪坐在桌旁，白伞靠在身侧，桌上半枚玉佩；沈墨站在亭口 | 两人 |
| K2B | 沈墨面部近景，目光向下看着玉佩，神情震动 | 沈墨 |
| K2C | 清漪中近景，抬眼看向镜头左侧 | 清漪 |
| K2E-start | 与 `4.png` 同机位，但没有箭、伞还未举起，清漪坐着 | 两人 |
| K3A | 竹林雨夜远景：沈墨和清漪冲出茶亭，四周竹林中出现黑衣斗笠追兵 | 小 |
| K3B | 沈墨握剑柄拔剑特写，剑身出鞘一半，黑白水墨强对比 | 无 |
| K3D | 沈墨中景，剑尖即将入鞘，身后追兵僵立 | 沈墨 |
| K4A | 断桥黎明中景：清漪伸手递出半枚玉佩，沈墨伸手去接 | 两人 |
| K4B | 沈墨手掌特写，两半玉佩合拢 | 无 |
| K4C | 闪回：燃烧的山庄，年轻的清漪把年幼的沈墨推出火海，暖橙火光 | 清漪（年轻） |
| K4D | 沈墨面部近景，眼眶微红，嘴唇微张 | 沈墨 |
| K4E-start | 与 `6.png` 同机位，清漪完整未消散，白伞还握在手中 | 两人 |
| K4F | 沈墨独自站在断桥上，白伞落在桥边，手握完整玉佩 | 沈墨 |

每张关键帧的生成提示词和参考图搭配见 `keyframe-prompts.md`。

生成关键帧时，每张都把对应人物的设定图作为参考图输入（Qwen-Image-Edit、FLUX Kontext 等支持多参考图的编辑模型都可以）。**生成后先人工核对脸、发型、发饰、服装、斗笠、玉佩，不合格的不进入 LTX。**

## 4. 分镜与提示词

通用设置：1280×720，24fps，prompt_enhance 关闭。下面每段提示词都以同一句风格描述开头，保证四个 PART 的画风一致。旁白统一在后期配音，提示词中只写环境声和对白。

风格句（每条提示词开头都加上）：

```text
Traditional Chinese ink-wash wuxia animation, hand-painted ink and watercolor textures on xuan paper, black, grey and cold blue-grey palette with warm lantern light.
```

### PART 1 — 雨夜入江湖（15 秒）

**1A｜I2V｜首帧 `3.png`｜7 秒**

```text
[风格句] The young swordsman in black walks slowly up the wet stone steps toward the lit tea pavilion, seen from behind, his bamboo hat on his back and long sword at his side. Rain falls steadily, mist drifts between the cliffs, bamboo leaves and the hem of his robe sway in the wind. Halfway up, a flock of crows bursts out of the bamboo on the right and scatters into the dark sky. He slows his pace. The camera follows behind him in a slow, steady tracking shot. Sound of heavy rain, wind in the bamboo, crows cawing.
```

沈墨全程背对镜头，不要写"转身"——脸在首帧里不可见，转过来就会变成陌生人。

**1B｜I2V｜K1B｜3 秒**

```text
[风格句] Close-up of the swordsman's right hand at his side. Rain drips from his sleeve. His fingers slowly move toward the sword hilt and rest on it, tightening slightly. Locked camera. Sound of rain and a faint creak of leather.
```

**1C｜I2V｜K1C｜5 秒**

```text
[风格句] Medium close-up of the young swordsman in three-quarter view, rain running down his face and hair. He stands still and looks toward the distant lantern-lit pavilion, eyes narrowing. A slow push-in toward his face. He keeps the same face and hairstyle throughout. Sound of rain and distant thunder.
```

### PART 2 — 亭中故人（15 秒）

**2A｜I2V｜K2A｜4 秒**

```text
[风格句] Inside the old tea pavilion at night. The swordsman in black steps in from the rain and stops at the entrance. The woman in white sits calmly at the table, a white oil-paper umbrella beside her and half a jade pendant on the table. Rain pours outside, lanterns sway gently. Locked medium-wide shot. Sound of rain on the roof and footsteps on wet wood.
```

**2B｜I2V｜K2B｜2 秒**

```text
[风格句] Close-up of the swordsman's face. He looks down at the jade pendant on the table, and his eyes widen slightly in shock. Minimal head movement. Locked camera. Sound of rain.
```

**2C｜I2V｜K2C｜3 秒（对白）**

```text
[风格句] Medium close-up of the woman in white. She slowly lifts her gaze, a faint calm smile, and says softly in Mandarin, "你终于来了。" Locked camera, her face and mouth clearly visible. Sound of rain in the background.
```

**2D｜I2V｜K2B 或新近景｜2 秒（对白）**

```text
[风格句] Close-up of the swordsman. He frowns slightly and asks in a low, guarded voice in Mandarin, "你是谁？" Locked camera. Sound of rain.
```

**2E｜FLF2V｜首帧 K2E-start，尾帧 `4.png`｜4 秒**

```text
[风格句] Inside the tea pavilion, the woman in white slowly turns her head toward the rain. Suddenly a volley of arrows flies out of the rain toward the pavilion. She grabs the white oil-paper umbrella, opens it and spins it; a circular barrier of swirling ink-like sword energy forms and deflects the arrows. The swordsman stands beside the table. Locked camera, ending on the final frame composition. Sound of arrows whistling, the umbrella snapping open, arrows striking and shattering.
```

### PART 3 — 竹林一剑（15 秒）

**3A｜I2V｜K3A｜4 秒**

```text
[风格句] Wide shot of a bamboo forest in heavy rain at night. The swordsman in black and the woman in white run out of the tea pavilion along the path. Black-clad pursuers in conical bamboo hats emerge from between the bamboo on all sides. Rain, bamboo leaves and ink splashes fly. Slow pan following the two. Sound of rain, running footsteps, rustling bamboo.
```

**3B｜I2V｜K3B｜3 秒**

```text
[风格句] Close-up of the swordsman's hand drawing the long sword from its scabbard. As the blade comes out, the image turns into stark black-and-white ink, raindrops freezing in the air. Locked camera. Sound of the blade sliding out, rain suddenly muffled.
```

**3C｜I2V｜首帧 `5.png`｜4 秒**

```text
[风格句] The swordsman holds his follow-through pose, sword arm extended, body and face unchanged and not turning. The arc of sword light keeps sweeping outward across the bamboo forest, bamboo stalks shudder, leaves and ink splashes scatter. The pursuers freeze mid-motion. The woman in white stays still behind him. Locked camera. Sound of a sharp sword whoosh, then only rain.
```

`5.png` 已经是挥剑完成的定格画面。如果提示词再让他"挥一剑"，模型只能自己编后续动作，常见结果是人物转身，脸和服装随之漂移。所以这里只让剑光、竹叶和墨迹动，人物保持姿势不变。

**3D｜I2V｜K3D｜4 秒**

```text
[风格句] Medium shot of the swordsman standing still in the rain. Behind him, sword marks appear across the pursuers' bamboo hats and clothes, and they collapse one by one. He slowly slides the sword back into its scabbard. Locked camera. Sound of bodies falling into water, then a clear metallic "zheng" as the sword sheathes.
```

### PART 4 — 十年前的答案（15 秒）

**4A｜I2V｜K4A｜4 秒**

```text
[风格句] Dawn on a broken stone bridge after the rain, distant mountains wrapped in morning mist, soft warm light. The woman in white holds out half a jade pendant; the swordsman in black reaches out and takes it. Slow, gentle movements. Locked medium shot. Sound of a light mountain breeze and dripping water.
```

**4B｜I2V｜K4B｜2 秒**

```text
[风格句] Close-up of the swordsman's palm. He brings the two halves of the jade pendant together; they fit into one complete pendant and glow faintly. Locked camera. Sound of a soft jade click.
```

**4C｜I2V｜K4C｜3 秒（闪回）**

```text
[风格句] Flashback, warm orange firelight. A manor burns at night, flames and ink smoke rising. A young woman in white pushes a small boy out through a burning doorway; he falls onto the ground outside and looks back as she stays inside the fire. Locked camera. Sound of roaring fire and crackling wood.
```

**4D｜I2V｜K4D｜2 秒（对白）**

```text
[风格句] Close-up of the swordsman at dawn, his eyes reddened. He looks at the woman in front of him and says quietly in Mandarin, "师姐……" Locked camera, his face and mouth clearly visible. Soft breeze.
```

**4E｜FLF2V｜首帧 K4E-start，尾帧 `6.png`｜4 秒**

```text
[风格句] On the broken bridge at dawn, the woman in white smiles gently at the swordsman. A gust of mountain wind blows. The edges of her body begin to dissolve into ink and mist, her white robe turning translucent, ink drifting away with the wind. The swordsman reaches out but cannot touch her. Her umbrella falls to the bridge. Locked camera, ending on the final frame composition. Sound of wind and a soft fading chime.
```

**4F｜I2V｜K4F｜3 秒（可选，用于结尾）**

```text
[风格句] The swordsman stands alone on the broken bridge, holding the complete jade pendant, the white umbrella lying by the railing. Mist drifts, morning light grows. Very slow push-in. Sound of quiet wind.
```

结尾"一滴墨落在宣纸上 → 墨迹扩散 → 黑屏 → 片名"建议在剪辑软件里用素材或 T2V 单独生成后接上，不要放进人物镜头。

## 5. 批量提交（`submit_shots.py`）

第 4 节的分镜和提示词也保存在 `shots.json` 里，`submit_shots.py` 会按这个文件把所有镜头提交给 ComfyUI。脚本只用 Python 标准库，可以在本机运行（通过 RunPod 的 8188 代理），也可以在 Pod 上运行。

**准备（只需一次）：**

1. 在 ComfyUI 中打开 `LTX-2.5-I2V-*.json`，菜单 **Workflow → Export (API)**，保存到 `one-sword/api/`，保留原文件名即可（如 `LTX-2.5-I2V-INT8-TE-BF16.json`），脚本会按文件名中的 `I2V` / `FLF2V` 自动识别。
2. 对 `LTX-2.5-FLF2V-*.json` 做同样操作。同类文件只能放一个，否则用 `--i2v` / `--flf2v` 指定。
3. 把补做的关键帧放进 `古风水墨动画风格/`，文件名与第 3 节编号一致：`K1B.png`、`K2E-start.png`……

**运行：**

```bash
cd one-sword
# 先检查：关键帧是否齐全、API 工作流能否识别。不连接服务器，填好的工作流写到 output/dry-run/
python3 submit_shots.py --dry-run

# 全部提交，等待完成并下载到 output/<镜头>.mp4
python3 submit_shots.py --runpod-server <pod-id>

# 只跑已经有关键帧的镜头
python3 submit_shots.py --runpod-server <pod-id> --only 1A,3C

# 对某个镜头不满意：换 seed 重跑，--force 覆盖已有结果
python3 submit_shots.py --runpod-server <pod-id> --only 2C --seed 2024 --force
```

- `--runpod-server <pod-id>` 会自动拼成 `https://<pod-id>-8188.proxy.runpod.net`。pod id 在 RunPod 控制台的 Pod 名称下方。在 Pod 上运行，或用其他地址时，改用 `--server <URL>`；两者都不填时默认 `http://127.0.0.1:8188`。
- 每个镜头都会设置：关键帧、风格句 + 提示词、时长、1280×720、24fps、seed，同时强制关闭 Prompt Enhance。
- 提交时按 `shots.json` 的 `frame_strength`（默认 0.9）设置关键帧强度，并把缩放改为 lanczos。所以即使从旧安装导出的工作流（强度 0.7），也不需要重新安装、重新导出。设为 `null` 则按导出时的原样提交。
- `output/` 里已有结果的镜头会被跳过，加 `--force` 才会重新生成。
- `--seed` 只在本次运行中生效。选到满意的 seed 后，把它写回 `shots.json`，以后就能复现。
- 改提示词、时长或关键帧，直接编辑 `shots.json`。
- `--no-wait` 只提交不等待，适合提交后关掉本机；结果保存在 Pod 上的 `data/output/onesword/`。

## 6. 拼接

所有镜头的分辨率、帧率一致（1280×720、24fps）时，可以直接用 ffmpeg 无损硬切拼接：

```bash
cat > list.txt <<'EOF'
file '1A.mp4'
file '1B.mp4'
file '1C.mp4'
file '2A.mp4'
EOF
ffmpeg -f concat -safe 0 -i list.txt -c copy onesword.mp4
```

旁白（"江湖的雨，已经下了十年。"、"有些人等你十年，只为送你走完最后一程。"）和片名在剪辑软件中添加。

## 7. 检查清单

- [ ] 每张关键帧都对照设定图核对过脸、发型、发饰、服装、配饰
- [ ] 所有关键帧都是 16:9
- [ ] 没有任何镜头需要模型"凭空画出"首帧里看不到的脸
- [ ] I2V 第一阶段 strength ≥ 0.9，FLF2V 两个 guide 的 strength ≥ 0.85
- [ ] prompt_enhance 关闭
- [ ] 每个镜头都记录了 seed
