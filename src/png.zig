//! Minimal PNG support: streaming grayscale writer (8-bit / 1-bit) plus a
//! grayscale reader used by the `decode` subcommand.
//!
//! Only what this tool needs: color type 0 (grayscale), no interlacing,
//! filter type 0 (None) when writing. When reading we accept all five standard
//! row filters, bit depths 8 and 1, and gray-only PNGs.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

pub const Error = error{
    NotPng,
    UnsupportedFormat,
    Truncated,
    BadChunk,
};

pub const signature = [8]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

fn putU32(dst: *[4]u8, v: u32) void {
    std.mem.writeInt(u32, dst, v, .big);
}

fn chunkCrc(tag: []const u8, data: []const u8) u32 {
    var h = std.hash.Crc32.init();
    h.update(tag);
    h.update(data);
    return h.final();
}

fn writeChunk(out: *Io.Writer, tag: *const [4]u8, data: []const u8) !void {
    var hdr: [8]u8 = undefined;
    putU32(hdr[0..4], @intCast(data.len));
    hdr[4..8].* = tag.*;
    try out.writeAll(&hdr);
    if (data.len != 0) try out.writeAll(data);
    var crc: [4]u8 = undefined;
    putU32(&crc, chunkCrc(tag, data));
    try out.writeAll(&crc);
}

/// Streaming grayscale PNG writer. Rows are pushed one at a time so we never
/// need the full image in memory.
pub const Writer = struct {
    alloc: Allocator,
    out: *Io.Writer,
    width: u32,
    height: u32,
    bit_depth: u8,
    row_bytes: usize,
    row: []u8 = &.{},
    idat: Io.Writer.Allocating = undefined,
    cmp: flate.Compress = undefined,
    zbuf: [flate.max_window_len]u8 = undefined,

    /// `out` must outlive the writer. Rows are streamed, so the image is never
    /// held in memory: only the compressed IDAT is buffered (needed because
    /// the PNG chunk header carries the compressed length).
    pub fn init(
        self: *Writer,
        alloc: Allocator,
        out: *Io.Writer,
        width: u32,
        height: u32,
        bit_depth: u8,
        level: flate.Compress.Options,
    ) !void {
        std.debug.assert(bit_depth == 8 or bit_depth == 1);
        self.* = .{
            .alloc = alloc,
            .out = out,
            .width = width,
            .height = height,
            .bit_depth = bit_depth,
            .row_bytes = if (bit_depth == 1) (width + 7) / 8 else width,
            .idat = try .initCapacity(alloc, 1 << 16),
        };
        self.row = try alloc.alloc(u8, self.row_bytes + 1);
        self.row[0] = 0; // filter type: None

        try out.writeAll(&signature);
        var ihdr: [13]u8 = undefined;
        putU32(ihdr[0..4], width);
        putU32(ihdr[4..8], height);
        ihdr[8] = bit_depth;
        ihdr[9] = 0; // color type: grayscale
        ihdr[10] = 0; // compression method: deflate
        ihdr[11] = 0; // filter method: adaptive
        ihdr[12] = 0; // interlace: none
        try writeChunk(out, "IHDR", &ihdr);

        self.cmp = try flate.Compress.init(&self.idat.writer, &self.zbuf, .zlib, level);
    }

    pub fn deinit(self: *Writer) void {
        self.alloc.free(self.row);
    }

    /// Push one row of grayscale samples (one byte per pixel). For 1-bit
    /// output the samples are thresholded and packed MSB-first.
    pub fn writeRow(self: *Writer, pixels: []const u8) !void {
        std.debug.assert(pixels.len == self.width);
        switch (self.bit_depth) {
            8 => {
                @memcpy(self.row[1 .. 1 + self.width], pixels);
            },
            1 => {
                // PNG grayscale: sample 0 is black, 1 is white, packed MSB-first.
                @memset(self.row[1..], 0xff);
                for (pixels, 0..) |p, i| {
                    if (p < 128) {
                        const byte = i >> 3;
                        const bit: u3 = @intCast(7 - (i & 7));
                        self.row[1 + byte] &= ~(@as(u8, 1) << bit);
                    }
                }
            },
            else => unreachable,
        }
        try self.cmp.writer.writeAll(self.row);
    }

    pub fn finish(self: *Writer) !void {
        try self.cmp.finish();
        try self.idat.writer.flush();
        var list = self.idat.toArrayList();
        defer list.deinit(self.alloc);
        try writeChunk(self.out, "IDAT", list.items);
        try writeChunk(self.out, "IEND", &.{});
        try self.out.flush();
    }
};

pub const Image = struct {
    width: u32,
    height: u32,
    /// Grayscale, 8 bits per pixel, `width` bytes per row.
    pixels: []u8,
};

/// Decode a grayscale PNG (bit depth 1 or 8, no interlace) into 8-bit pixels.
pub fn decode(alloc: Allocator, bytes: []const u8) !Image {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &signature)) return Error.NotPng;

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var interlace: u8 = 0;
    var have_ihdr = false;

    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(alloc);

    var pos: usize = 8;
    while (pos + 8 <= bytes.len) {
        const len: usize = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const tag = bytes[pos + 4 ..][0..4];
        if (pos + 12 + len > bytes.len) return Error.Truncated;
        const data = bytes[pos + 8 ..][0..len];

        if (std.mem.eql(u8, tag, "IHDR")) {
            if (len != 13) return Error.BadChunk;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            bit_depth = data[8];
            color_type = data[9];
            interlace = data[12];
            have_ihdr = true;
        } else if (std.mem.eql(u8, tag, "IDAT")) {
            try idat.appendSlice(alloc, data);
        } else if (std.mem.eql(u8, tag, "IEND")) {
            break;
        }
        pos += 12 + len;
    }

    if (!have_ihdr) return Error.BadChunk;
    if (color_type != 0) return Error.UnsupportedFormat; // grayscale only
    if (interlace != 0) return Error.UnsupportedFormat;
    if (bit_depth != 8 and bit_depth != 1) return Error.UnsupportedFormat;
    if (width == 0 or height == 0) return Error.BadChunk;

    const raw = try inflate(alloc, idat.items, width, height, bit_depth);
    defer alloc.free(raw);

    const out = try alloc.alloc(u8, @as(usize, width) * @as(usize, height));
    errdefer alloc.free(out);
    try unfilter(alloc, raw, out, width, height, bit_depth);
    return .{ .width = width, .height = height, .pixels = out };
}

fn inflate(alloc: Allocator, compressed: []const u8, width: u32, height: u32, bit_depth: u8) ![]u8 {
    const row_bytes = if (bit_depth == 1) (@as(usize, width) + 7) / 8 else width;
    const expected = (@as(usize, row_bytes) + 1) * @as(usize, height);

    var src = Io.Reader.fixed(compressed);
    const win = try alloc.alloc(u8, flate.max_window_len);
    defer alloc.free(win);
    var dec = flate.Decompress.init(&src, .zlib, win);
    return dec.reader.allocRemaining(alloc, .limited(expected + 1)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.Truncated,
    };
}

const bpp = 1; // bytes per pixel in the filtered stream (grayscale, <= 8 bit)

fn unfilter(
    alloc: Allocator,
    raw: []const u8,
    out: []u8,
    width: u32,
    height: u32,
    bit_depth: u8,
) !void {
    const row_bytes = if (bit_depth == 1) (@as(usize, width) + 7) / 8 else width;
    const stride = @as(usize, width);

    var prev = try alloc.alloc(u8, row_bytes);
    defer alloc.free(prev);
    var cur = try alloc.alloc(u8, row_bytes);
    defer alloc.free(cur);
    @memset(prev, 0);
    @memset(cur, 0);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const start = y * (row_bytes + 1);
        if (start + 1 + row_bytes > raw.len) return; // truncated: stop early
        const filter = raw[start];
        const line = raw[start + 1 ..][0..row_bytes];

        var x: usize = 0;
        while (x < row_bytes) : (x += 1) {
            const a: u8 = if (x >= bpp) cur[x - bpp] else 0;
            const b: u8 = prev[x];
            const c: u8 = if (x >= bpp) prev[x - bpp] else 0;
            cur[x] = switch (filter) {
                1 => line[x] +% a,
                2 => line[x] +% b,
                3 => line[x] +% @as(u8, @truncate((@as(u16, a) + b) / 2)),
                4 => line[x] +% paeth(a, b, c),
                else => line[x],
            };
        }

        const dst_row = out[y * stride ..][0..stride];
        if (bit_depth == 8) {
            @memcpy(dst_row, cur);
        } else {
            for (0..width) |i| {
                const byte = cur[i >> 3];
                const bit: u3 = @intCast(7 - (i & 7));
                dst_row[i] = if ((byte >> bit) & 1 == 1) 255 else 0;
            }
        }
        std.mem.swap([]u8, &prev, &cur);
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const pa = @abs(@as(i32, a) + @as(i32, b) - 2 * @as(i32, c));
    const pb = @abs(@as(i32, b) - @as(i32, c));
    const pc = @abs(@as(i32, a) - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

test "writer -> decode round trip (gray8)" {
    const alloc = std.testing.allocator;
    var sink: Io.Writer.Allocating = try .initCapacity(alloc, 1 << 12);
    defer sink.deinit();

    const w = 13;
    const h = 7;
    var pixels: [w * h]u8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @truncate(i * 7);

    var wr: Writer = undefined;
    try wr.init(alloc, &sink.writer, w, h, 8, flate.Compress.Options.default);
    defer wr.deinit();
    var y: usize = 0;
    while (y < h) : (y += 1) try wr.writeRow(pixels[y * w ..][0..w]);
    try wr.finish();

    const img = try decode(alloc, sink.writer.buffered());
    defer alloc.free(img.pixels);
    try std.testing.expectEqual(@as(u32, w), img.width);
    try std.testing.expectEqual(@as(u32, h), img.height);
    try std.testing.expectEqualSlices(u8, &pixels, img.pixels);
}

test "writer -> decode round trip (1-bit)" {
    const alloc = std.testing.allocator;
    var sink: Io.Writer.Allocating = try .initCapacity(alloc, 1 << 12);
    defer sink.deinit();

    const w = 10;
    const h = 3;
    var pixels: [w * h]u8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = if (i % 3 == 0) 0 else 255;

    var wr: Writer = undefined;
    try wr.init(alloc, &sink.writer, w, h, 1, flate.Compress.Options.default);
    defer wr.deinit();
    var y: usize = 0;
    while (y < h) : (y += 1) try wr.writeRow(pixels[y * w ..][0..w]);
    try wr.finish();

    const img = try decode(alloc, sink.writer.buffered());
    defer alloc.free(img.pixels);
    try std.testing.expectEqualSlices(u8, &pixels, img.pixels);
}
