//! Tiny in-memory ZIP reader, just enough for EPUB: central directory lookup,
//! stored + deflated entries. Everything stays in RAM, which is fine for books
//! (a few MB at most).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

pub const Error = error{
    NotZip,
    BadZip,
    EntryNotFound,
    UnsupportedCompression,
};

pub const Entry = struct {
    name: []const u8,
    method: u16,
    compressed_size: u64,
    uncompressed_size: u64,
    local_header_offset: u64,
};

pub const Zip = struct {
    data: []const u8,
    entries: []Entry,
    arena: std.heap.ArenaAllocator,

    pub fn parse(alloc: Allocator, data: []const u8) !Zip {
        if (data.len < 22) return Error.NotZip;

        // End of central directory: scan backwards over the (possibly long) comment.
        const max_back = @min(data.len, 22 + 0xffff);
        var eocd: ?usize = null;
        var i = data.len - 22;
        const limit = data.len - max_back;
        while (true) : (i -%= 1) {
            if (std.mem.readInt(u32, data[i..][0..4], .little) == 0x06054b50) {
                eocd = i;
                break;
            }
            if (i == limit) break;
        }
        const e = eocd orelse return Error.NotZip;

        const count = std.mem.readInt(u16, data[e + 10 ..][0..2], .little);
        const cd_offset: usize = std.mem.readInt(u32, data[e + 16 ..][0..4], .little);
        if (cd_offset >= data.len) return Error.BadZip;

        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();
        var list: std.ArrayList(Entry) = .empty;

        var pos = cd_offset;
        var n: usize = 0;
        while (n < count) : (n += 1) {
            if (pos + 46 > data.len) break;
            if (std.mem.readInt(u32, data[pos..][0..4], .little) != 0x02014b50) break;
            const method = std.mem.readInt(u16, data[pos + 10 ..][0..2], .little);
            const comp = std.mem.readInt(u32, data[pos + 20 ..][0..4], .little);
            const uncomp = std.mem.readInt(u32, data[pos + 24 ..][0..4], .little);
            const name_len = std.mem.readInt(u16, data[pos + 28 ..][0..2], .little);
            const extra_len = std.mem.readInt(u16, data[pos + 30 ..][0..2], .little);
            const comment_len = std.mem.readInt(u16, data[pos + 32 ..][0..2], .little);
            const local_off = std.mem.readInt(u32, data[pos + 42 ..][0..4], .little);
            if (pos + 46 + name_len > data.len) break;
            const name = try a.dupe(u8, data[pos + 46 ..][0..name_len]);
            try list.append(a, .{
                .name = name,
                .method = method,
                .compressed_size = comp,
                .uncompressed_size = uncomp,
                .local_header_offset = local_off,
            });
            pos += 46 + name_len + extra_len + comment_len;
        }

        return .{ .data = data, .entries = try list.toOwnedSlice(a), .arena = arena };
    }

    pub fn deinit(self: *Zip) void {
        self.arena.deinit();
    }

    pub fn find(self: *const Zip, name: []const u8) ?Entry {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    /// Copy (or inflate) an entry into a fresh allocation.
    pub fn readEntry(self: *const Zip, alloc: Allocator, entry: Entry) ![]u8 {
        const off: usize = @intCast(entry.local_header_offset);
        if (off + 30 > self.data.len) return Error.BadZip;
        if (std.mem.readInt(u32, self.data[off..][0..4], .little) != 0x04034b50) return Error.BadZip;
        const name_len = std.mem.readInt(u16, self.data[off + 26 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, self.data[off + 28 ..][0..2], .little);
        const start = off + 30 + name_len + extra_len;
        const size: usize = @intCast(entry.compressed_size);
        if (start + size > self.data.len) return Error.BadZip;
        const payload = self.data[start..][0..size];

        switch (entry.method) {
            0 => return alloc.dupe(u8, payload),
            8 => {
                var src = Io.Reader.fixed(payload);
                const win = try alloc.alloc(u8, flate.max_window_len);
                defer alloc.free(win);
                var dec = flate.Decompress.init(&src, .raw, win);
                const expected: usize = @intCast(entry.uncompressed_size);
                return dec.reader.allocRemaining(alloc, .limited(expected + 64)) catch |err| switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => Error.BadZip,
                };
            },
            else => return Error.UnsupportedCompression,
        }
    }
};
