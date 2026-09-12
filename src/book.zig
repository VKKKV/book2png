//! Book loading: EPUB / HTML / plain text -> a single text buffer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zmem = @import("zmem.zig");
const html = @import("html.zig");

pub const Error = error{
    NoContainer,
    NoRootfile,
    NoSpine,
    EmptyBook,
};

pub const Input = struct {
    /// Plain text of the whole book (block boundaries preserved as newlines).
    text: []u8,
    kind: enum { epub, html, text },
};

pub fn load(alloc: Allocator, path: []const u8, bytes: []const u8) !Input {
    if (zmem.Zip.parse(alloc, bytes)) |zip_val| {
        var zip = zip_val;
        defer zip.deinit();
        if (zip.find("META-INF/container.xml") == null) return error.NoContainer;
        return .{ .text = try epubText(alloc, &zip), .kind = .epub };
    } else |_| {}

    if (std.ascii.endsWithIgnoreCase(path, ".html") or std.ascii.endsWithIgnoreCase(path, ".htm") or
        std.ascii.endsWithIgnoreCase(path, ".xhtml"))
    {
        return .{ .text = try html.extract(alloc, bytes), .kind = .html };
    }
    return .{ .text = try alloc.dupe(u8, bytes), .kind = .text };
}

/// Ordered list of content documents from the EPUB spine (nav/TOC skipped).
pub fn spine(alloc: Allocator, zip: *const zmem.Zip) ![][]const u8 {
    const container = try zip.readEntry(alloc, zip.find("META-INF/container.xml") orelse return Error.NoContainer);
    defer alloc.free(container);
    const opf_path = html.attr(container, "full-path") orelse return Error.NoRootfile;

    const opf = try zip.readEntry(alloc, zip.find(opf_path) orelse return Error.NoRootfile);
    defer alloc.free(opf);
    const base = std.fs.path.dirname(opf_path) orelse "";

    var manifest = std.StringHashMap([2][]const u8).init(alloc); // id -> {href, properties}
    defer manifest.deinit();
    var it = html.TagIterator{ .xml = opf, .tag = "item" };
    while (it.next()) |body| {
        const id = html.attr(body, "id") orelse continue;
        const href = html.attr(body, "href") orelse continue;
        const props = html.attr(body, "properties") orelse "";
        try manifest.put(id, .{ href, props });
    }

    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(alloc);
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();

    var itref = html.TagIterator{ .xml = opf, .tag = "itemref" };
    while (itref.next()) |body| {
        const idref = html.attr(body, "idref") orelse continue;
        const entry = manifest.get(idref) orelse continue;
        const href = entry[0];
        const props = entry[1];
        if (std.mem.indexOf(u8, props, "nav") != null) continue;
        const bare = href[0 .. std.mem.indexOfScalar(u8, href, '#') orelse href.len];
        if (std.mem.endsWith(u8, bare, ".ncx")) continue;
        if (std.ascii.indexOfIgnoreCase(bare, "toc") != null) continue;
        const full = try joinPath(alloc, base, bare);
        if (seen.contains(full)) {
            alloc.free(full);
            continue;
        }
        try seen.put(full, {});
        try list.append(alloc, full);
    }
    if (list.items.len == 0) return Error.NoSpine;

    // Hand ownership of the file names to the caller; they live in the arena.
    return list.toOwnedSlice(alloc);
}

pub fn joinPathPublic(alloc: Allocator, base: []const u8, rel: []const u8) ![]u8 {
    return joinPath(alloc, base, rel);
}

fn joinPath(alloc: Allocator, base: []const u8, rel: []const u8) ![]u8 {
    const joined = if (base.len == 0)
        try alloc.dupe(u8, rel)
    else
        try std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, rel });
    defer alloc.free(joined);
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(alloc);
    var it = std.mem.tokenizeScalar(u8, joined, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len != 0) _ = parts.pop();
            continue;
        }
        try parts.append(alloc, part);
    }
    return std.mem.join(alloc, "/", parts.items);
}

pub fn epubText(alloc: Allocator, zip: *const zmem.Zip) ![]u8 {
    const names = try spine(alloc, zip);
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (names) |name| {
        const entry = zip.find(name) orelse continue;
        const raw = zip.readEntry(alloc, entry) catch continue;
        defer alloc.free(raw);
        const text = try html.extract(alloc, raw);
        defer alloc.free(text);
        try out.appendSlice(alloc, text);
        try out.append(alloc, '\n');
    }
    if (out.items.len == 0) return Error.EmptyBook;
    return out.toOwnedSlice(alloc);
}

test "joinPath normalises" {
    const alloc = std.testing.allocator;
    const a = try joinPath(alloc, "OEBPS", "text/ch1.xhtml");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("OEBPS/text/ch1.xhtml", a);
    const b = try joinPath(alloc, "", "./ch1.xhtml");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("ch1.xhtml", b);
}
