//! The "one image holds the whole book" renderer: strip whitespace, wrap the
//! endless character stream to a fixed pixel width, rasterise line by line and
//! stream the rows into a PNG.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Font = @import("font.zig").Font;
const png = @import("png.zig");

pub const Options = struct {
    width: u32 = 2000,
    size: f32 = 16,
    margin: u32 = 0,
    leading: f32 = 1.15,
    /// Keep ASCII spaces (readable for Latin text, irrelevant for CJK).
    latin_space: bool = false,
    /// 1-bit black/white output: ~10x smaller files, no antialiasing.
    bilevel: bool = false,
    /// deflate level: .fastest / .default / .best
    level: Level = .default,

    pub const Level = enum { fastest, default, best };

    pub fn flateOptions(self: Options) std.compress.flate.Compress.Options {
        return switch (self.level) {
            .fastest => std.compress.flate.Compress.Options.fastest,
            .default => std.compress.flate.Compress.Options.default,
            .best => std.compress.flate.Compress.Options.best,
        };
    }
};

pub const Stats = struct {
    bytes: usize,
    chars: usize,
    lines: usize,
    width: u32,
    height: u32,
};

/// Count Unicode codepoints (bytes that are not UTF-8 continuation bytes).
pub fn countChars(text: []const u8) usize {
    var n: usize = 0;
    for (text) |b| {
        if (b & 0xc0 != 0x80) n += 1;
    }
    return n;
}

/// Drop every newline/tab/ideographic space, and (unless kept) ASCII spaces.
pub fn stripWhitespace(alloc: Allocator, text: []const u8, keep_latin_space: bool) ![]u8 {
    var out = try alloc.alloc(u8, text.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b == '\n' or b == '\r' or b == '\t' or b == 0x0b or b == 0x0c) {
            i += 1;
            continue;
        }
        if (b == ' ') {
            if (keep_latin_space) {
                out[n] = ' ';
                n += 1;
            }
            i += 1;
            continue;
        }
        if (b == 0xe3 and std.mem.startsWith(u8, text[i..], "\u{3000}")) { // ideographic space
            i += 3;
            continue;
        }
        // Copy whole UTF-8 sequence (or a single stray byte) verbatim.
        const len = std.unicode.utf8ByteSequenceLength(b) catch 1;
        const take = @min(@as(usize, len), text.len - i);
        @memcpy(out[n .. n + take], text[i .. i + take]);
        n += take;
        i += take;
    }
    return alloc.realloc(out, n);
}

pub const Line = struct { start: usize, end: usize };

/// Wrap the stripped stream into lines of at most `usable` pixels.
pub fn layout(alloc: Allocator, font: *const Font, text: []const u8, usable: f32) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(alloc);

    var view = std.unicode.Utf8View.initUnchecked(text);
    var it = view.iterator();
    var line_start: usize = 0;
    var x: f32 = 0;
    var prev_cp: ?u21 = null;
    var last_end: usize = 0;

    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch 0xfffd;
        var adv = font.advance(cp);
        if (prev_cp) |p| adv += font.kern(p, cp);
        if (x + adv > usable and it.i > line_start + 1) {
            try lines.append(alloc, .{ .start = line_start, .end = last_end });
            line_start = last_end;
            x = 0;
            prev_cp = null;
            adv = font.advance(cp);
        }
        x += adv;
        last_end = it.i;
        prev_cp = cp;
    }
    if (last_end > line_start) try lines.append(alloc, .{ .start = line_start, .end = last_end });
    if (lines.items.len == 0 and text.len != 0) try lines.append(alloc, .{ .start = 0, .end = text.len });
    return lines.toOwnedSlice(alloc);
}

pub const Renderer = struct {
    alloc: Allocator,
    font: *const Font,
    opts: Options,
    line_height: u32,
    baseline: i32,
    line_buf: []u8,
    scratch: []u8 = &.{},

    pub fn init(alloc: Allocator, font: *const Font, opts: Options) !Renderer {
        const line_height_f = opts.size * opts.leading;
        const content = font.ascent - font.descent;
        const pad = @max(0.0, (line_height_f - content) / 2.0);
        return .{
            .alloc = alloc,
            .font = font,
            .opts = opts,
            .line_height = @intFromFloat(@ceil(@max(line_height_f, content + 1))),
            .baseline = @intFromFloat(@ceil(pad + font.ascent)),
            .line_buf = try alloc.alloc(u8, @as(usize, opts.width) * @as(usize, @intFromFloat(@ceil(@max(line_height_f, content + 1))))),
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.alloc.free(self.line_buf);
        if (self.scratch.len != 0) self.alloc.free(self.scratch);
    }

    /// Draw one line of text (already stripped) into the line strip buffer
    /// (`width * line_height` bytes; glyph y offsets are line-relative).
    fn drawLine(self: *Renderer, text: []const u8, line: Line) void {
        @memset(self.line_buf, 255);
        var pen: f32 = @floatFromInt(self.opts.margin);
        const baseline: i32 = self.baseline;

        var view = std.unicode.Utf8View.initUnchecked(text[line.start..line.end]);
        var it = view.iterator();
        var prev_cp: ?u21 = null;
        while (it.nextCodepointSlice()) |slice| {
            const cp = std.unicode.utf8Decode(slice) catch 0xfffd;
            var adv = self.font.advance(cp);
            if (prev_cp) |p| adv += self.font.kern(p, cp);
            prev_cp = cp;

            if (cp != ' ') {
                const bmp = self.font.rasterize(cp, self.scratch) orelse {
                    pen += adv;
                    continue;
                };
                const dst_x0: i64 = @as(i64, @intFromFloat(@floor(pen))) + bmp.x0;
                const dst_y0: i64 = @as(i64, baseline) + bmp.y0;
                var gy: usize = 0;
                while (gy < bmp.height) : (gy += 1) {
                    const y = dst_y0 + @as(i64, @intCast(gy));
                    if (y < 0 or y >= self.line_height) continue;
                    const src_row = bmp.data[gy * bmp.width ..][0..bmp.width];
                    var gx: usize = 0;
                    while (gx < bmp.width) : (gx += 1) {
                        const alpha = src_row[gx];
                        if (alpha == 0) continue;
                        const x = dst_x0 + @as(i64, @intCast(gx));
                        if (x < 0 or x >= self.opts.width) continue;
                        const dst: usize = @intCast(y);
                        const col: usize = @intCast(x);
                        const idx = dst * self.opts.width + col;
                        self.line_buf[idx] = self.line_buf[idx] -| alpha; // black on white
                    }
                }
            }
            pen += adv;
        }
    }

    fn ensureScratch(self: *Renderer, needed: usize) !void {
        if (self.scratch.len >= needed) return;
        const size = @max(needed, 1024);
        if (self.scratch.len != 0) self.alloc.free(self.scratch);
        self.scratch = try self.alloc.alloc(u8, size);
    }

    /// Render `text` (already stripped) into `out` as a single tall PNG.
    pub fn render(self: *Renderer, text: []const u8, out: *Io.Writer, lines: []const Line) !Stats {
        const usable = @as(f32, @floatFromInt(self.opts.width)) - 2 * @as(f32, @floatFromInt(self.opts.margin));
        if (usable <= 1) return error.ImageTooNarrow;

        // glyph scratch: worst case is roughly size^2 per glyph
        try self.ensureScratch(@as(usize, @intFromFloat(self.opts.size * self.opts.size)) * 4 + 64);

        const height: u64 = @as(u64, self.line_height) * lines.len +
            2 * @as(u64, self.opts.margin);
        if (height == 0 or height > std.math.maxInt(u32)) return error.ImageTooLarge;

        var writer: png.Writer = undefined;
        try writer.init(
            self.alloc,
            out,
            self.opts.width,
            @intCast(height),
            if (self.opts.bilevel) 1 else 8,
            self.opts.flateOptions(),
        );
        defer writer.deinit();

        const blank = try self.alloc.alloc(u8, self.opts.width);
        defer self.alloc.free(blank);
        @memset(blank, 255);

        var y: u64 = 0;
        while (y < self.opts.margin) : (y += 1) try writer.writeRow(blank);
        for (lines) |line| {
            self.drawLine(text, line);
            var row: u32 = 0;
            while (row < self.line_height) : (row += 1) {
                const strip = self.line_buf[@as(usize, row) * self.opts.width ..][0..self.opts.width];
                try writer.writeRow(strip);
            }
        }
        y = 0;
        while (y < self.opts.margin) : (y += 1) try writer.writeRow(blank);

        try writer.finish();
        return .{
            .bytes = text.len,
            .chars = countChars(text),
            .lines = lines.len,
            .width = self.opts.width,
            .height = @intCast(height),
        };
    }
};

test "stripWhitespace removes all breaks and spaces" {
    const alloc = std.testing.allocator;
    const s = try stripWhitespace(alloc, "a b\nc\td\u{3000}e\r\n", false);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("abcde", s);

    const kept = try stripWhitespace(alloc, "a b\nc", true);
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("a bc", kept);
}
