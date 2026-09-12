//! book2png — turn a whole book into a single image.
//!
//!   book2png flow   <book> <out.png>   dense single-image flow of the text
//!   book2png pixel  <book> <out.png>   every byte becomes one pixel (reversible)
//!   book2png decode <in.png> <out>     reverse of `pixel`
//!   book2png fonts                     list candidate system fonts

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const book = @import("book.zig");
const html = @import("html.zig");
const render = @import("render.zig");
const png = @import("png.zig");
const font_mod = @import("font.zig");
const zmem = @import("zmem.zig");

const version = "0.1.0";

const PixelMagic = "B2P1";
const PixelHeaderLen = 4 + 8;

const Timer = struct {
    t0: Io.Clock.Timestamp,

    fn start(io: Io) Timer {
        return .{ .t0 = Io.Clock.Timestamp.now(io, .awake) };
    }

    fn ms(self: Timer, io: Io) u64 {
        const d = self.t0.untilNow(io);
        return @intCast(@divTrunc(d.raw.nanoseconds, std.time.ns_per_ms));
    }
};

const usage =
    \\book2png — put an entire book into one image
    \\
    \\Usage:
    \\  book2png flow   <input> <output.png> [options]   reflow text into one tall PNG
    \\  book2png pixel  <input> <output.png>             one file byte per pixel (reversible)
    \\  book2png decode <input.png> <output>             reverse of `pixel`
    \\  book2png fonts                                   list candidate system fonts
    \\
    \\Input: .epub, .html/.xhtml, or any plain-text file (.txt/.md/...)
    \\
    \\flow options:
    \\  --width <px>      image width (default 2000)
    \\  --size <px>       font pixel size (default 16)
    \\  --font <path>     font file (default: first usable system font)
    \\  --margin <px>     margin on all sides (default 0)
    \\  --leading <f>     line height = size * leading (default 1.15)
    \\  --latin-space     keep ASCII spaces (readable for Latin scripts)
    \\  --bilevel         1-bit black/white PNG (~10x smaller)
    \\  --level <1|6|9>   deflate level: 1 fast, 6 default, 9 best
    \\
    \\Examples:
    \\  book2png flow 红楼梦.epub hl.png --width 2000 --size 13
    \\  book2png flow alice.epub alice.png --latin-space
    \\  book2png pixel hongloumeng.epub hl_pixel.png && book2png decode hl_pixel.png back.epub
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        std.debug.print("{s}", .{usage});
        return;
    }
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        std.debug.print("book2png {s}\n", .{version});
        return;
    }
    if (std.mem.eql(u8, cmd, "fonts")) {
        try listFonts(arena, io);
        return;
    }

    var opts = Options{};
    var positional: std.ArrayList([]const u8) = .empty;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.startsWith(u8, a, "--")) {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const name = if (eq) |p| a[0..p] else a;
            const inline_value: ?[]const u8 = if (eq) |p| a[p + 1 ..] else null;
            const take = struct {
                fn f(argv: []const []const u8, idx: *usize, inl: ?[]const u8) ?[]const u8 {
                    if (inl) |v| return v;
                    if (idx.* + 1 >= argv.len) return null;
                    idx.* += 1;
                    return argv[idx.*];
                }
            }.f;

            if (std.mem.eql(u8, name, "--width")) {
                opts.render.width = try parseU32(take(args, &i, inline_value) orelse return argError(name));
            } else if (std.mem.eql(u8, name, "--size")) {
                opts.render.size = try parseF32(take(args, &i, inline_value) orelse return argError(name));
            } else if (std.mem.eql(u8, name, "--margin")) {
                opts.render.margin = try parseU32(take(args, &i, inline_value) orelse return argError(name));
            } else if (std.mem.eql(u8, name, "--leading")) {
                opts.render.leading = try parseF32(take(args, &i, inline_value) orelse return argError(name));
            } else if (std.mem.eql(u8, name, "--font")) {
                opts.font_path = take(args, &i, inline_value) orelse return argError(name);
            } else if (std.mem.eql(u8, name, "--level")) {
                const lv = try parseU32(take(args, &i, inline_value) orelse return argError(name));
                opts.render.level = switch (lv) {
                    1...4 => .fastest,
                    5...7 => .default,
                    8, 9 => .best,
                    else => .default,
                };
            } else if (std.mem.eql(u8, name, "--latin-space")) {
                opts.render.latin_space = true;
            } else if (std.mem.eql(u8, name, "--bilevel")) {
                opts.render.bilevel = true;
            } else if (std.mem.eql(u8, name, "--quiet")) {
                opts.quiet = true;
            } else {
                std.debug.print("book2png: unknown option {s}\n{s}", .{ a, usage });
                std.process.exit(2);
            }
        } else {
            try positional.append(arena, a);
        }
    }

    if (std.mem.eql(u8, cmd, "flow")) {
        if (positional.items.len != 2) return argError("flow <input> <output.png>");
        try runFlow(arena, io, positional.items[0], positional.items[1], opts);
    } else if (std.mem.eql(u8, cmd, "pixel")) {
        if (positional.items.len != 2) return argError("pixel <input> <output.png>");
        try runPixel(arena, io, positional.items[0], positional.items[1], opts);
    } else if (std.mem.eql(u8, cmd, "decode")) {
        if (positional.items.len != 2) return argError("decode <input.png> <output>");
        try runDecode(arena, io, positional.items[0], positional.items[1], opts);
    } else {
        std.debug.print("book2png: unknown command {s}\n{s}", .{ cmd, usage });
        std.process.exit(2);
    }
}

const Options = struct {
    render: render.Options = .{},
    font_path: ?[]const u8 = null,
    quiet: bool = false,
};

fn argError(what: []const u8) noreturn {
    std.debug.print("book2png: bad arguments for {s}\n", .{what});
    std.process.exit(2);
}

fn parseU32(s: []const u8) !u32 {
    return std.fmt.parseUnsigned(u32, s, 10) catch argError("a number");
}

fn parseF32(s: []const u8) !f32 {
    return std.fmt.parseFloat(f32, s) catch argError("a number");
}

fn log(quiet: bool, comptime fmt: []const u8, args: anytype) void {
    if (!quiet) std.debug.print(fmt, args);
}

fn runFlow(alloc: Allocator, io: Io, input_path: []const u8, output_path: []const u8, opts: Options) !void {
    const timer = Timer.start(io);

    const raw = std.Io.Dir.cwd().readFileAlloc(io, input_path, alloc, .limited(1 << 31)) catch |err| {
        std.debug.print("book2png: cannot read {s}: {s}\n", .{ input_path, @errorName(err) });
        std.process.exit(1);
    };
    defer alloc.free(raw);

    const loaded = book.load(alloc, input_path, raw) catch |err| {
        std.debug.print("book2png: cannot parse {s}: {s}\n", .{ input_path, @errorName(err) });
        std.process.exit(1);
    };
    defer alloc.free(loaded.text);

    const text = try render.stripWhitespace(alloc, loaded.text, opts.render.latin_space);
    defer alloc.free(text);
    if (text.len == 0) {
        std.debug.print("book2png: {s} has no text after whitespace stripping\n", .{input_path});
        std.process.exit(1);
    }

    const font_path = try resolveFont(alloc, io, opts.font_path);
    const font_data = try std.Io.Dir.cwd().readFileAlloc(io, font_path, alloc, .limited(1 << 30));
    defer alloc.free(font_data);
    var font = font_mod.Font.init(alloc, font_data, opts.render.size) catch {
        std.debug.print("book2png: cannot load font {s}\n", .{font_path});
        std.process.exit(1);
    };
    defer font.deinit(alloc);

    const usable = @as(f32, @floatFromInt(opts.render.width)) - 2 * @as(f32, @floatFromInt(opts.render.margin));
    const lines = try render.layout(alloc, &font, text, usable);
    defer alloc.free(lines);

    var out_file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer out_file.close(io);
    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);

    var renderer = try render.Renderer.init(alloc, &font, opts.render);
    defer renderer.deinit();
    const stats = try renderer.render(text, &out_writer.interface, lines);

    const ms = timer.ms(io);
    log(opts.quiet, "book2png: kind={s} font={s}\n", .{ @tagName(loaded.kind), font_path });
    log(opts.quiet, "book2png: chars={d} bytes={d} lines={d} image={d}x{d} mode={s} elapsed={d}ms out={s}\n", .{
        stats.chars,
        stats.bytes,
        stats.lines,
        stats.width,
        stats.height,
        if (opts.render.bilevel) "flow/1bit" else "flow/gray8",
        ms,
        output_path,
    });
}

fn resolveFont(alloc: Allocator, io: Io, explicit: ?[]const u8) ![]const u8 {
    if (explicit) |p| {
        if (!fileExists(io, p)) {
            std.debug.print("book2png: font not found: {s}\n", .{p});
            std.process.exit(1);
        }
        return p;
    }
    var candidates: std.ArrayList([]const u8) = .empty;
    defer candidates.deinit(alloc);
    try font_mod.defaultFontPaths(alloc, &candidates);
    for (candidates.items) |p| {
        if (fileExists(io, p)) return p;
    }
    std.debug.print("book2png: no system font found, pass --font <path>\n", .{});
    std.process.exit(1);
}

fn runPixel(alloc: Allocator, io: Io, input_path: []const u8, output_path: []const u8, opts: Options) !void {
    const timer = Timer.start(io);
    const payload = try std.Io.Dir.cwd().readFileAlloc(io, input_path, alloc, .limited(1 << 31));
    defer alloc.free(payload);

    const total = PixelHeaderLen + payload.len;
    const side: u32 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(total))) + 1);
    const px_total = @as(usize, side) * @as(usize, side);

    var pixels = try alloc.alloc(u8, px_total);
    defer alloc.free(pixels);
    @memset(pixels, 0);
    @memcpy(pixels[0..4], PixelMagic);
    std.mem.writeInt(u64, pixels[4..12], payload.len, .big);
    @memcpy(pixels[PixelHeaderLen..][0..payload.len], payload);

    var out_file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer out_file.close(io);
    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);

    var writer: png.Writer = undefined;
    try writer.init(alloc, &out_writer.interface, side, side, 8, opts.render.flateOptions());
    defer writer.deinit();
    var y: usize = 0;
    while (y < side) : (y += 1) try writer.writeRow(pixels[y * side ..][0..side]);
    try writer.finish();

    const ms = timer.ms(io);
    log(opts.quiet, "book2png: bytes={d} image={d}x{d} mode=pixel/gray8 elapsed={d}ms out={s}\n", .{
        payload.len, side, side, ms, output_path,
    });
}

fn runDecode(alloc: Allocator, io: Io, input_path: []const u8, output_path: []const u8, opts: Options) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, input_path, alloc, .limited(1 << 31));
    defer alloc.free(bytes);
    const img = png.decode(alloc, bytes) catch |err| {
        std.debug.print("book2png: cannot decode {s}: {s}\n", .{ input_path, @errorName(err) });
        std.process.exit(1);
    };
    defer alloc.free(img.pixels);

    if (img.pixels.len < PixelHeaderLen or !std.mem.eql(u8, img.pixels[0..4], PixelMagic)) {
        std.debug.print("book2png: {s} is not a book2png pixel image\n", .{input_path});
        std.process.exit(1);
    }
    const len: usize = @intCast(std.mem.readInt(u64, img.pixels[4..12], .big));
    if (len > img.pixels.len - PixelHeaderLen) {
        std.debug.print("book2png: header says {d} bytes but image holds {d}\n", .{ len, img.pixels.len - PixelHeaderLen });
        std.process.exit(1);
    }
    var out_file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer out_file.close(io);
    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);
    try out_writer.interface.writeAll(img.pixels[PixelHeaderLen..][0..len]);
    try out_writer.interface.flush();
    log(opts.quiet, "book2png: restored {d} bytes from {d}x{d} image -> {s}\n", .{ len, img.width, img.height, output_path });
}

fn fileExists(io: Io, path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    if (std.Io.Dir.accessAbsolute(io, path, .{ .read = true })) |_| return true else |_| return false;
}

fn listFonts(alloc: Allocator, io: Io) !void {
    var candidates: std.ArrayList([]const u8) = .empty;
    defer candidates.deinit(alloc);
    try font_mod.defaultFontPaths(alloc, &candidates);
    var stdout_buf: [8192]u8 = undefined;
    var stdout_file = Io.File.stdout();
    var stdout = stdout_file.writer(io, &stdout_buf);
    for (candidates.items) |p| {
        const exists = fileExists(io, p);
        try stdout.interface.print("{s} {s}\n", .{ if (exists) "[x]" else "[ ]", p });
    }
    try stdout.interface.flush();
}

test {
    std.testing.refAllDecls(@This());
    _ = book;
    _ = html;
    _ = zmem;
    _ = png;
}
