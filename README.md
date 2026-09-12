# book2png

把一整本书的文字排进**一张图片**里。

- `flow`：去掉所有换行/空格，把全书文字连续密排成一张超长 PNG（可缩放阅读）
- `pixel`：把一个文件的每个字节变成 1 个像素（不可读，但可**无损还原**）
- `decode`：`pixel` 的逆操作

输入支持 `.epub`、`.html/.xhtml`，以及任何纯文本文件（`.txt/.md`…）。
零系统依赖：Zig 标准库自带 EPUB(zip) 解析与 zlib 压缩，字体光栅化用内置的
[stb_truetype](https://github.com/nothings/stb)（public domain），因此三个平台都能一条命令编译。

```
$ book2png flow 红楼梦.epub hlm.png --width 2000 --size 13
book2png: kind=epub font=/usr/share/fonts/adobe-source-han-serif/SourceHanSerifCN-Regular.otf
book2png: chars=786356 bytes=2315149 lines=3511 image=2000x52665 mode=flow/gray8 elapsed=11126ms out=hlm.png
```

## 安装

**下载预编译二进制**：见 [Releases](../../releases)（Linux x86_64/aarch64、macOS x86_64/arm64、Windows x86_64）。

**从源码构建**（需要 Zig 0.16.0）：

```bash
git clone https://github.com/VKKKV/book2png
cd book2png
zig build -Doptimize=ReleaseFast      # 产物在 zig-out/bin/book2png
zig build test                        # 单元测试
```

交叉编译也是 Zig 的一等公民：

```bash
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-gnu
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos
```

## 用法

```
book2png flow   <输入> <输出.png> [选项]    把文字重排成一张超长图
book2png pixel  <输入> <输出.png>           每个字节一个像素（可逆）
book2png decode <输入.png> <输出文件>       pixel 的逆操作
book2png fonts                              列出候选系统字体
```

`flow` 选项：

| 选项 | 默认 | 说明 |
|---|---|---|
| `--width <px>` | 2000 | 图片宽度 |
| `--size <px>` | 16 | 字号 |
| `--font <path>` | 自动探测 | 字体文件（`.ttf/.otf/.ttc`）。缺失时按平台探测思源/Noto/文泉驿/微软雅黑/苹方 |
| `--margin <px>` | 0 | 四周留白 |
| `--leading <f>` | 1.15 | 行高 = size × leading（CJK 字体会自动取字体自身行框） |
| `--latin-space` | 关 | 保留空格（英文书建议开，否则单词会黏连） |
| `--bilevel` | 关 | 输出 1-bit 黑白 PNG，文件小约 5–10 倍，代价是无抗锯齿 |
| `--level <1\|6\|9>` | 6 | deflate 压缩级别 |
| `--quiet` | 关 | 不打印统计信息 |

### 例子

```bash
# 中文 epub → 一张长图（去空白、连续密排）
book2png flow 红楼梦.epub hlm.png --width 2000 --size 13

# 英文 epub（保留空格，否则 thequickbrownfox…）
book2png flow alice.epub alice.png --latin-space

# 要小体积：1-bit 黑白
book2png flow 红楼梦.epub hlm_bw.png --size 13 --bilevel

# 换个字体、加点留白
book2png flow book.epub out.png --font /usr/share/fonts/noto-cjk/NotoSerifCJK-Regular.ttc --size 14 --margin 40

# 把任意文件塞进一张方图，再原样取回
book2png pixel 红楼梦.epub hl_pixel.png
book2png decode hl_pixel.png restored.epub
sha256sum 红楼梦.epub restored.epub      # 一致
```

## 实测数据（`--bilevel` 关闭时是 8-bit 灰度）

| 输入 | 参数 | 输出 | 体积 | 耗时 |
|---|---|---|---|---|
| 红楼梦 epub（78.6 万字） | 2000px / 13px | 2000×52665 | 25 MB | 11 s |
| 红楼梦 epub（同上） | `--bilevel` | 2000×52665 | 4.5 MB | 10 s |
| Alice in Wonderland epub | 2000px / 13px `--latin-space` | 2000×5400 | 1.2 MB | 0.7 s |
| 红楼梦 epub（整本 1.1 MB） | `pixel` + `decode` | 1073×1073 | 1.1 MB | 30 ms，sha256 一致 |

## 设计要点

- **流式渲染**：先测量换行（只存行偏移），再逐行光栅化、逐行写 PNG 行数据；整本《红楼梦》峰值内存里没有整张图片，只有一行条带 + 压缩缓冲。
- **零依赖**：EPUB = 内存里解析 zip（EOCD → 中央目录 → 局部头 → flate 解压）+ 极简 XHTML 取文；PNG = 手写 chunk + `std.compress.flate`；文字 = vendored `stb_truetype`。没有任何系统库、没有包管理器。
- **`pixel` 可逆**：图像头部 12 字节（magic `B2P1` + u64 原始长度）记录长度，其余像素按行填充，所以 `decode` 不需要额外元数据。

## 限制与坑

- **尺寸上限**：PNG 单边上限 2^31-1 px，够用；但 **JPEG 只有 65535**，浏览器 canvas 单边上限 32767（Chrome 73+ 为 65535）、面积上限约 2.68 亿 px。8 万像素高的图想在线缩放浏览，需要切片（`vips dzsave` + OpenSeadragon/IIIF）。
- **`--bilevel` 会丢抗锯齿**：13px 字号下笔画边缘会有锯齿，放大看明显，但字仍可读。
- **`pixel` 输出是字节级无损**：请勿用有损格式（JPEG）中转，也不要用会改像素的平台压缩。
- **epub 只取文字层**：书里以图片形式存在的插图/公式不会进入长图；需要版面请走 PDF 渲染路线。
- **CJK 行框**：多数中文字体的 ascent+descent ≈ 1.4–1.5 em，所以 `--size 13` 的实际行高约 19px，这是正常的中文排版行为。
- 大图渲染耗时随宽度×字数增长（`--bilevel` 与灰度耗时接近，瓶颈在光栅化）。

## 许可

GPL-3.0（见 [LICENSE](LICENSE)）。内置的 `vendor/stb_truetype.h` 是 public domain / MIT，版权归 Sean Barrett。

---

## English

Render a whole book into a single image: `flow` reflows the text (all line breaks and
spaces stripped) into one very tall PNG, `pixel` stores one file byte per pixel
(reversible with `decode`). Inputs: `.epub`, `.html/.xhtml`, any plain text.

No system dependencies: EPUB/zip parsing and zlib come from the Zig standard library,
glyph rasterisation from vendored stb_truetype, so all three platforms build with a
single `zig build`. See the tables above for options and real measurements.

License: GPL-3.0.
