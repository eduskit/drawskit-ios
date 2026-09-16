# DrawsKit 默认工具光标

单一真相源：本目录 PNG + `hotspots.json`。

| 文件 | 工具 |
|------|------|
| `cursor-pen.png` | 画笔 |
| `cursor-hightlight.png` | 荧光笔（文件名拼写保持） |
| `cursor-eraser.png` | 橡皮 |
| `cursor-move.png` | 平移 |
| `cursor-txt.png` | 文本 |

同步到各端：

```bash
python3 scripts/sync-cursor-assets.py
# 或
pnpm sync:cursors
```

源图可为高分辨率；脚本会缩放到 **≤32×32** 再写入各端 SDK（浏览器对 CSS `cursor: url()` 超大图会忽略并回退到 `crosshair` 等 fallback）。

`hotspots.json` 的热点坐标按 **32×32 逻辑尺寸** 填写。

已并入 Web SDK `build` / `prepack`。
