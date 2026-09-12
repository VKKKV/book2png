//! Text rendering on top of the vendored stb_truetype (public domain), so the
//! tool has no system font-library dependency and cross-compiles cleanly.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const c = @cImport({
    @cInclude("stb_truetype.h");
});

/// stb's fontinfo lives in caller-provided storage; we never touch its fields.
const FontInfoStorage = extern struct {
    bytes: [8 * 1024]u8 align(16),
};

pub const Font = struct {
    storage: *FontInfoStorage,
    info: *c.stbtt_fontinfo,
    data: []const u8,
    scale: f32,
    ascent: f32,
    descent: f32,
    line_gap: f32,

    pub fn init(alloc: Allocator, data: []const u8, pixel_height: f32) !Font {
        const storage = try alloc.create(FontInfoStorage);
        errdefer alloc.destroy(storage);
        if (data.len == 0) return error.BadFont;
        @memset(&storage.bytes, 0);
        const info: *c.stbtt_fontinfo = @ptrCast(&storage.bytes[0]);

        const offset = c.stbtt_GetFontOffsetForIndex(data.ptr, 0);
        if (offset < 0) return error.BadFont;
        if (c.stbtt_InitFont(info, data.ptr, offset) == 0) return error.BadFont;

        const scale = c.stbtt_ScaleForPixelHeight(info, pixel_height);
        var a: c_int = 0;
        var d: c_int = 0;
        var gap: c_int = 0;
        c.stbtt_GetFontVMetrics(info, &a, &d, &gap);
        return .{
            .storage = storage,
            .info = info,
            .data = data,
            .scale = scale,
            .ascent = @as(f32, @floatFromInt(a)) * scale,
            .descent = @as(f32, @floatFromInt(d)) * scale,
            .line_gap = @as(f32, @floatFromInt(gap)) * scale,
        };
    }

    pub fn deinit(self: *Font, alloc: Allocator) void {
        alloc.destroy(self.storage);
    }

    /// Horizontal advance of a codepoint in pixels.
    pub fn advance(self: *const Font, cp: u21) f32 {
        var adv: c_int = 0;
        var lsb: c_int = 0;
        c.stbtt_GetCodepointHMetrics(self.info, @intCast(cp), &adv, &lsb);
        return @as(f32, @floatFromInt(adv)) * self.scale;
    }

    pub fn kern(self: *const Font, a: u21, b: u21) f32 {
        const k = c.stbtt_GetCodepointKernAdvance(self.info, @intCast(a), @intCast(b));
        return @as(f32, @floatFromInt(k)) * self.scale;
    }

    pub const Box = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

    pub fn bitmapBox(self: *const Font, cp: u21) Box {
        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        c.stbtt_GetCodepointBitmapBox(self.info, @intCast(cp), self.scale, self.scale, &x0, &y0, &x1, &y1);
        return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
    }

    /// Rasterise one codepoint into `scratch`, returning an 8-bit alpha bitmap.
    pub fn rasterize(self: *const Font, cp: u21, scratch: []u8) ?Bitmap {
        const box = self.bitmapBox(cp);
        const w: usize = @intCast(@max(box.x1 - box.x0, 0));
        const h: usize = @intCast(@max(box.y1 - box.y0, 0));
        if (w == 0 or h == 0) return null;
        if (w * h > scratch.len) return null;
        c.stbtt_MakeCodepointBitmap(self.info, scratch.ptr, @intCast(w), @intCast(h), @intCast(w), self.scale, self.scale, @intCast(cp));
        return .{ .width = w, .height = h, .x0 = box.x0, .y0 = box.y0, .data = scratch[0 .. w * h] };
    }
};

pub const Bitmap = struct {
    width: usize,
    height: usize,
    x0: i32,
    y0: i32,
    data: []const u8,
};

/// Default font candidates per platform, searched in order.
pub fn defaultFontPaths(alloc: Allocator, out: *std.ArrayList([]const u8)) !void {
    const common: []const []const u8 = &.{
        "/usr/share/fonts/adobe-source-han-serif/SourceHanSerifCN-Regular.otf",
        "/usr/share/fonts/adobe-source-han-sans/SourceHanSansCN-Regular.otf",
        "/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc",
        "/usr/share/fonts/noto-cjk/NotoSerifCJK-Regular.ttc",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
        "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
        "/usr/share/fonts/TTF/DejaVuSerif.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf",
    };
    const macos: []const []const u8 = &.{
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/Supplemental/Songti.ttc",
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    };
    const windows: []const []const u8 = &.{
        "C:\\Windows\\Fonts\\msyh.ttc",
        "C:\\Windows\\Fonts\\simsun.ttc",
        "C:\\Windows\\Fonts\\simhei.ttf",
        "C:\\Windows\\Fonts\\segoeui.ttf",
    };

    const os = @import("builtin").os.tag;
    const list: []const []const u8 = switch (os) {
        .windows => windows,
        .macos, .ios => macos,
        else => common,
    };
    for (list) |p| try out.append(alloc, p);
}

test "default font list is non-empty" {
    const alloc = std.testing.allocator;
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(alloc);
    try defaultFontPaths(alloc, &list);
    try std.testing.expect(list.items.len > 0);
}
