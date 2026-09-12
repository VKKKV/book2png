# book2png

把文本、HTML 或 EPUB 排进一张很长的 PNG；也可以把任意文件无损编码成 PNG，再还原回来。

- `flow`：提取文字并连续排版成一张长图。默认去掉换行和空格，适合 CJK；英文输入可用 `--latin-space` 保留 ASCII 空格。
- `pixel`：把文件头和每个字节编码进一张方形灰度 PNG。
- `decode`：还原 `pixel` 生成的 PNG，恢复原文件字节。
- `fonts`：列出程序会自动探测的字体路径。

输入支持 `.epub`、`.html`、`.htm`、`.xhtml` 和任意纯文本文件。程序没有第三方运行时依赖；构建只需要 Zig 0.16.0，目标平台需要可用的 libc。EPUB/ZIP、zlib 和 PNG 处理使用 Zig 标准库或项目内代码，字体光栅化使用 vendored [stb_truetype](https://github.com/nothings/stb)。

## 快速开始

下载预编译版本：进入 [Releases](../../releases)，选择 Linux x86_64/aarch64、macOS x86_64/arm64 或 Windows x86_64 的压缩包。

从源码构建：

```bash
git clone https://github.com/VKKKV/book2png.git
cd book2png
zig build -Doptimize=ReleaseFast
```

产物位于 `zig-out/bin/book2png`。先查看实际命令和选项：

```bash
zig-out/bin/book2png --help
zig-out/bin/book2png fonts
```

## 用法

```text
book2png flow   <input> <output.png> [options]
book2png pixel  <input> <output.png>
book2png decode <input.png> <output>
book2png fonts
```

最短示例：

```bash
# EPUB → 一张长图
book2png flow book.epub book.png

# 英文文本保留单词之间的空格
book2png flow alice.epub alice.png --latin-space

# 缩小体积，但关闭抗锯齿
book2png flow book.epub book-1bit.png --bilevel

# 任意文件 → PNG → 原文件
book2png pixel book.epub book-pixel.png
book2png decode book-pixel.png restored.epub
sha256sum book.epub restored.epub
```

`pixel`/`decode` 是字节级 round trip。PNG 不能经过 JPEG 或会改动像素的图片平台，否则无法保证还原。

### `flow` 选项

- `--width <px>`：图片宽度，默认 `2000`。
- `--size <px>`：字号，默认 `16`；必须是正数。
- `--font <path>`：字体文件路径，支持绝对路径和相对路径；支持 `.ttf`、`.otf`、`.ttc`。省略时按平台顺序探测思源、Noto、文泉驿、DejaVu、苹方和 Windows 字体。
- `--margin <px>`：四周留白，默认 `0`。
- `--leading <f>`：行高倍率，默认 `1.15`；必须是正的有限数值。
- `--latin-space`：保留 ASCII 空格。英文输入建议开启；CJK 输入通常保持关闭。
- `--bilevel`：输出 1-bit 黑白 PNG，通常比灰度图小很多，但没有抗锯齿。
- `--level <n>`：deflate 压缩级别，接受 `1` 到 `9`；`1–4` 使用 fast、`5–7` 使用 default、`8–9` 使用 best。默认 `6`。
- `--quiet`：不打印统计信息。

程序会把 HTML/XML 标签转换为文字，跳过 `script`、`style`、`head` 和 `title`，并解码常见 HTML entity。EPUB 按 spine 顺序读取正文文档；插图、公式图片和原始页面布局不会进入 `flow` 输出。

## 从源码测试与交叉编译

```bash
zig build test
zig fmt --check build.zig src/*.zig

# 示例：生成其他平台的二进制
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-gnu
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos
```

GitHub Actions 会在 Linux、macOS 和 Windows 上构建测试，并检查 Linux arm64、Windows x86_64 和 macOS arm64 交叉编译。带 `v*` tag 时，release workflow 会生成五个平台的压缩包。

## 实测数据

以下数据来自本项目已有样例；实际耗时和体积取决于字体、输入内容、CPU、压缩级别和文件系统。

- 《红楼梦》EPUB，78.6 万字，`--width 2000 --size 13`：`2000 × 52665`，灰度 PNG 约 25 MB，约 11 s。
- 同一输入加 `--bilevel`：`2000 × 52665`，约 4.5 MB，约 10 s。
- *Alice in Wonderland* EPUB，`--width 2000 --size 13 --latin-space`：`2000 × 5400`，约 1.2 MB，约 0.7 s。
- 1.1 MB 文件执行 `pixel` + `decode`：`1073 × 1073`，PNG 约 1.1 MB，约 30 ms，SHA-256 一致。

## 示例：整个 Arch Wiki → 一张 PNG

这个示例使用 Arch 官方离线文档包，不逐页抓取网站。文档包包含 39 种语言、5,822 个 HTML 页面，下载包约 206 MB。

```bash
# 1. 下载并解出官方离线文档包
curl -L -o arch-wiki-docs.pkg.tar.zst \
  https://archlinux.org/packages/extra/any/arch-wiki-docs/download/
bsdtar -xf arch-wiki-docs.pkg.tar.zst usr/share/doc/arch-wiki/html

# 2. 按路径顺序拼成一个 HTML 文件
find usr/share/doc/arch-wiki/html -name '*.html' -print0 \
  | sort -z \
  | xargs -0 cat > archwiki.html

# 3. 渲染为灰度图，或渲染为 1-bit 小文件
book2png flow archwiki.html archwiki.png \
  --width 12000 --size 8
book2png flow archwiki.html archwiki-1bit.png \
  --width 12000 --size 8 --bilevel
```

已有实测结果：`12000 × 101110`。

- 灰度版本约 184 MB，约 179 s；放大后可用于机器识别（OCR），人眼阅读吃力。
- `--bilevel` 版本约 24 MB，约 195 s；8px 下拉丁字母会失去可读性。
- 全部语言合计约 40,122,659 个字符。

预览（4× 放大）：

![4× 放大：近邻插值放大后的 8px 文字](docs/archwiki-zoom.png)

## 设计与限制

- 渲染分两遍进行：第一遍只记录换行位置，第二遍逐行光栅化并写入 PNG。程序不会为整张长图分配一块同等大小的像素缓冲，但会把输入文本、字体和压缩数据保存在内存中。
- `pixel` 在 PNG 像素数据开头写入 12 字节头：magic `B2P1` 加原始文件长度；剩余像素按行填充，`decode` 因此不需要旁车元数据。
- `flow` 只保留文字层。EPUB 中的插图、公式图片、CSS 布局和原始页面样式不会被渲染；需要保留版面时应使用 PDF 渲染工具。
- `--bilevel` 使用黑白阈值替代灰度抗锯齿。它适合压缩和海报式输出，阅读小字号时应使用默认灰度模式。
- 输出高度随文字量和行高增长。浏览器、图片查看器和 canvas 对超大图片有自己的单边或面积限制；几十万像素高的图片适合切片后浏览，例如使用 `vips dzsave` 配合 OpenSeadragon 或 IIIF。
- CJK 字体的 ascent/descent 通常比 Latin 字体占用更多行框空间，因此 `--size 13` 的实际行高可能接近 19px，这是字体度量的正常结果。

## 许可证

项目使用 GPL-3.0，见 [LICENSE](LICENSE)。

`vendor/stb_truetype.h` 为 Sean Barrett 的 public domain / MIT 许可代码；相关许可说明见该文件头部。

## English

`book2png` turns EPUB, HTML, XHTML, or plain text into one very tall PNG. It also provides a reversible byte-to-PNG format for arbitrary files.

```bash
book2png flow book.epub book.png
book2png flow alice.epub alice.png --latin-space
book2png pixel book.epub book-pixel.png
book2png decode book-pixel.png restored.epub
```

Build with Zig 0.16.0:

```bash
zig build -Doptimize=ReleaseFast
zig build test
```

`flow` strips line breaks and spaces by default. Use `--latin-space` for Latin text. `--bilevel` produces a smaller 1-bit PNG without antialiasing. `--font` accepts absolute or relative `.ttf`, `.otf`, and `.ttc` paths. `--level` accepts compression levels `1` through `9`.

EPUB rendering follows the spine and extracts the text layer only; images, formulas, CSS layout, and page styling are not preserved. `pixel` and `decode` preserve bytes exactly as long as the PNG pixels are not modified in transit.

The project has no third-party runtime dependency. It uses Zig's standard library and vendored `stb_truetype`; building on a target still requires the target's libc. The license is GPL-3.0.
