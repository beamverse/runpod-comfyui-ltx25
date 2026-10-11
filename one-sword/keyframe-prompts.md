# 《一剑听雨》K 系列关键帧生成提示词

这些关键帧用于 `shots.json` 中还缺图的 16 个镜头。请用支持多张参考图的图像生成/编辑模型制作，并保存到 `古风水墨动画风格/`，文件名必须与下表一致。

## 通用规则

**尺寸**：16:9，**1672×941**，与 `3.png`–`6.png` 相同。不要用竖图。

**参考图**：每张都同时提供人物参考图和场景参考图。

| 简称 | 文件 | 用途 |
|---|---|---|
| 沈墨-设定 | `1.png` | 正面、侧面、背面全身，斗笠、残玉佩、剑 |
| 沈墨-脸 | `1-1.png` | 脸部细节 |
| 清漪-设定 | `2.png` | 正面、侧面、背面全身，油纸伞、发饰、玉佩 |
| 清漪-脸 | `2-1.png` | 脸部细节 |
| 石阶雨夜 | `3.png` | PART 1 场景与色调 |
| 茶亭内部 | `4.png` | PART 2 场景与色调 |
| 竹林 | `5.png` | PART 3 场景与色调 |
| 断桥黎明 | `6.png` | PART 4 场景与色调 |

**每条提示词末尾都加上这一段画风描述**：

```text
Traditional Chinese ink-wash wuxia animation keyframe, hand-painted ink and watercolor textures on xuan paper, painterly but clearly animated, not photorealistic. Match the character design, face, hairstyle, costume and accessories of the reference sheets exactly. Match the lighting, palette and rendering of the scene reference. 16:9 widescreen cinematic composition, no text, no captions, no watermark, no character-sheet layout.
```

**提示词里的人物写法**（保持固定，不要换说法）：

- 沈墨：`Shen Mo, the young swordsman in layered black and dark grey robes, long black hair half tied up, round bamboo hat on his back, long sword at his waist, broken jade pendant at his belt`
- 清漪：`Qingyi, the young woman in layered white and pale grey robes, long black hair with flower and pearl ornaments, white oil-paper umbrella, sword at her waist, jade ornaments`

## 生成后的检查

每张图都要和设定图逐项核对，任何一项不符就重新生成：

- [ ] 脸型、眼睛、眉毛与 `1-1.png` / `2-1.png` 是同一个人
- [ ] 发型、发饰
- [ ] 服装的颜色、层次和竹叶纹样
- [ ] 配饰：沈墨的斗笠、剑、残玉佩；清漪的油纸伞、剑、玉饰
- [ ] 场景的光线、时间、天气与相邻镜头一致
- [ ] 人脸足够大、清晰，没有被头发、伞、雨幕挡住（需要露脸的镜头）
- [ ] 1672×941，16:9

---

## PART 1 — 雨夜（参考：`3.png`）

### K1B.png — 手按剑柄（镜头 1B）

参考：沈墨-设定、石阶雨夜

```text
Close-up of Shen Mo's right hand at his waist beside the sword hilt, at night in heavy rain on the stone steps. Rain drips from the black sleeve and the wrist wrappings, fingers relaxed and slightly apart, about to move toward the hilt. The sword hilt, scabbard fittings and the broken jade pendant hanging at the belt are clearly visible. Dark blue-grey night, faint warm lantern glow from the distance on the wet fabric. Face not visible.
```

### K1C.png — 望向茶亭（镜头 1C）

参考：沈墨-设定、沈墨-脸、石阶雨夜

```text
Medium close-up of Shen Mo in three-quarter view from the front left, standing on the rainy stone steps at night, looking toward the distant lantern-lit tea pavilion off-screen right. Rain runs down his face and wet hair strands, eyes alert and slightly narrowed, mouth closed, calm and restrained expression. The round bamboo hat is on his back, visible behind his shoulder. Dark blue-grey night, bamboo and mist behind him, a faint warm glow on one side of his face. His face is large and clearly visible.
```

## PART 2 — 茶亭（参考：`4.png`）

### K2A.png — 入亭（镜头 2A）

参考：沈墨-设定、清漪-设定、茶亭内部

```text
Medium-wide shot inside the old wooden tea pavilion at night, same pavilion, lanterns and railing as the scene reference. Qingyi sits calmly at the wooden table on the right, her closed white oil-paper umbrella leaning beside her, half of a jade pendant lying on the table in front of her. Shen Mo stands at the pavilion entrance on the left, just stepped in from the rain, rain still streaming off his robe and hat. Heavy rain outside, warm lantern light inside. Both faces visible at medium size. No arrows.
```

### K2B.png — 看见玉佩（镜头 2B、2D 共用）

参考：沈墨-设定、沈墨-脸、茶亭内部

```text
Close-up of Shen Mo's face inside the tea pavilion at night, looking slightly down toward the table off-screen, eyes widening slightly in restrained shock, lips closed. Warm lantern light from one side, rain and dark blue-grey night outside behind him, wet hair strands on his forehead. His face is large and clearly visible, frontal three-quarter view.
```

### K2C.png — 清漪抬眼（镜头 2C）

参考：清漪-设定、清漪-脸、茶亭内部

```text
Medium close-up of Qingyi seated at the table inside the tea pavilion at night, gaze lifted toward someone off-screen left, a faint calm and gentle smile, lips closed. Flower and pearl hair ornaments clearly visible, the white umbrella handle beside her. Warm lantern light on her face, rain falling outside in the dark background. Her face and mouth are large and clearly visible, frontal three-quarter view.
```

### K2E-start.png — 箭雨之前（镜头 2E 首帧）

参考：`4.png`（作为要编辑的底图）、清漪-设定、沈墨-设定

这张最好用**编辑 `4.png`** 的方式做，保证与 2E 尾帧（`4.png`）同一机位、同一构图：

```text
Edit this image: keep the exact same camera angle, composition, pavilion, lanterns, table, tea set, jade pendant and Shen Mo's position and pose. Remove all arrows and the swirling ink barrier. Qingyi sits upright at the table in the same place, calm, her closed white oil-paper umbrella resting beside her, not yet raised, her face turned slightly toward the rain outside. Calm moment before an attack, heavy rain outside.
```

## PART 3 — 竹林（参考：`5.png`）

### K3A.png — 冲出茶亭（镜头 3A）

参考：沈墨-设定、清漪-设定、竹林、石阶雨夜

```text
Wide shot of a dense bamboo forest in heavy rain at night, a narrow muddy path leading away from the lit tea pavilion in the background. Shen Mo and Qingyi run along the path toward the camera's right, Shen Mo in front, Qingyi holding her white oil-paper umbrella. Black-clad pursuers in conical bamboo hats with covered faces emerge from between the bamboo stalks on both sides. Rain, flying bamboo leaves and ink splashes. Monochrome black, grey and white palette with cold blue-grey tones. Characters at small to medium size.
```

### K3B.png — 拔剑（镜头 3B）

参考：沈墨-设定、竹林

```text
Close-up of Shen Mo's right hand gripping the sword hilt and drawing the long sword halfway out of its black scabbard at his waist, the steel blade gleaming. Stark high-contrast black-and-white ink style, raindrops suspended in the air around the blade, ink splashes. The sleeve wrappings and broken jade pendant visible. Face not visible.
```

### K3D.png — 收剑（镜头 3D）

参考：沈墨-设定、沈墨-脸、竹林

```text
Medium shot of Shen Mo standing still in the rainy bamboo forest, facing the camera in three-quarter view, sliding the long sword back into the scabbard at his waist, the tip of the blade just entering the scabbard. Calm, cold expression. Behind him, several black-clad pursuers in conical bamboo hats stand frozen in mid-motion. Same monochrome black, grey and white palette as the scene reference, rain falling. His face clearly visible.
```

## PART 4 — 断桥黎明（参考：`6.png`）

### K4A.png — 递玉佩（镜头 4A）

参考：沈墨-设定、清漪-设定、断桥黎明

```text
Medium shot on the broken stone bridge at dawn after the rain, the same bridge, misty mountains and soft warm sunrise light as the scene reference. Qingyi on the right holds out half of a jade pendant in her open palm toward Shen Mo; Shen Mo on the left reaches out to take it. Her white umbrella is closed in her other hand. Both in profile to three-quarter view, faces visible. Qingyi is fully solid, not dissolving. Wet stones, light mist.
```

### K4B.png — 玉佩合一（镜头 4B）

参考：沈墨-设定（残玉佩细节）、断桥黎明

```text
Close-up of Shen Mo's open palm at dawn, holding two halves of a pale green jade pendant just touching edge to edge to form one complete round pendant, a faint soft glow along the seam, red bead cord and tassel hanging down. Black sleeve and wrist wrapping at the edge of the frame. Warm sunrise light, soft misty background. No faces.
```

### K4C.png — 闪回（镜头 4C）

参考：清漪-设定、清漪-脸、沈墨-设定

```text
Flashback, ten years earlier, at night. A large traditional manor engulfed in fire, burning beams and ink smoke. A younger Qingyi, about seventeen, with the same face and long black hair, in white robes stained with soot, pushes a small boy of about eight out through a burning doorway. The boy, young Shen Mo, wears simple dark clothes and has a broken half jade pendant at his waist; he stumbles out onto the courtyard ground and looks back at her. Warm orange firelight and red embers dominate, contrasting with the black ink of the night. Her face clearly visible inside the doorway.
```

小时候的沈墨和年轻的清漪需要额外核对：年轻清漪必须一眼认得出是清漪，只是年纪更小。

### K4D.png — "师姐……"（镜头 4D）

参考：沈墨-设定、沈墨-脸、断桥黎明

```text
Close-up of Shen Mo's face at dawn on the broken bridge, eyes reddened and glistening, lips slightly parted as if about to speak, sorrowful but restrained expression, looking at someone just off-screen right. Warm soft sunrise light on his face, misty mountains blurred behind him. His face and mouth are large and clearly visible, frontal three-quarter view.
```

### K4E-start.png — 消散之前（镜头 4E 首帧）

参考：`6.png`（作为要编辑的底图）、清漪-设定

这张用**编辑 `6.png`** 的方式做，保证与 4E 尾帧（`6.png`）同一机位：

```text
Edit this image: keep the exact same camera angle, composition, bridge, landscape, sunrise and Shen Mo's position and pose. Qingyi stands complete and solid in the same place, not dissolving, no ink particles or mist flowing from her body, her robes fully opaque. She holds her closed white oil-paper umbrella in her hand; there is no umbrella lying on the bridge. She smiles gently at Shen Mo.
```

### K4F.png — 独立断桥（镜头 4F）

参考：沈墨-设定、断桥黎明

```text
Medium-wide shot on the broken stone bridge at dawn. Shen Mo stands alone near the railing, holding the complete jade pendant in one hand at his chest, looking down at it. Qingyi's white oil-paper umbrella lies open on its side by the railing, the same position as in the scene reference. No one else is present. Morning mist drifts over the mountains, sunrise light growing warmer. His face visible in three-quarter view.
```
