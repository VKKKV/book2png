//! Turn XHTML/HTML chapter markup into plain text: drop tags, drop
//! script/style/head content, decode entities, keep block boundaries as
//! newlines (which `book.zig` later strips anyway, but they keep the plain
//! `--keep-newlines` path usable).

const std = @import("std");
const Allocator = std.mem.Allocator;

const block_tags = [_][]const u8{
    "p",     "div",    "br",   "h1",   "h2",    "h3",   "h4", "h5",
    "h6",    "li",     "tr",   "td",   "th",    "section", "article",
    "blockquote", "hr", "figcaption", "pre",
};

const skip_tags = [_][]const u8{ "script", "style", "head", "title" };

fn inList(comptime list: []const []const u8, needle: []const u8) bool {
    for (list) |item| {
        if (std.ascii.eqlIgnoreCase(item, needle)) return true;
    }
    return false;
}

/// Extract readable text: whitespace runs collapse, block tags become newlines.
pub fn extract(alloc: Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    var skip_depth: usize = 0;
    var pending_space = false;

    while (i < html.len) {
        const c = html[i];
        if (c == '<') {
            // Comment or tag
            if (std.mem.startsWith(u8, html[i..], "<!--")) {
                const end = std.mem.indexOf(u8, html[i..], "-->") orelse return out.toOwnedSlice(alloc);
                i += end + 3;
                continue;
            }
            const close = std.mem.indexOfScalar(u8, html[i..], '>') orelse {
                break;
            };
            const raw_tag = html[i + 1 .. i + close];
            const is_end = raw_tag.len > 0 and raw_tag[0] == '/';
            var name = if (is_end) raw_tag[1..] else raw_tag;
            var k: usize = 0;
            while (k < name.len and !std.ascii.isWhitespace(name[k]) and name[k] != '/') k += 1;
            name = name[0..k];

            if (inList(&skip_tags, name)) {
                if (is_end) {
                    if (skip_depth > 0) skip_depth -= 1;
                } else if (!isSelfClosing(raw_tag)) {
                    skip_depth += 1;
                }
            } else if (skip_depth == 0 and inList(&block_tags, name)) {
                try out.append(alloc, '\n');
                pending_space = false;
            }
            i += close + 1;
            continue;
        }

        if (c == '&') {
            const end = std.mem.indexOfScalarPos(u8, html, i, ';') orelse html.len;
            if (end != html.len and end - i <= 12) {
                const ent = html[i .. end + 1];
                if (decodeEntity(ent)) |decoded| {
                    if (skip_depth == 0) try appendChar(alloc, &out, decoded, &pending_space);
                    i = end + 1;
                    continue;
                }
            }
        }

        if (std.ascii.isWhitespace(c) or c >= 0x80 and isFullWidthSpace(html[i..])) {
            if (skip_depth == 0) pending_space = true;
            i += if (c >= 0x80 and isFullWidthSpace(html[i..])) @as(usize, 3) else 1;
            continue;
        }

        if (skip_depth == 0) {
            if (pending_space and out.items.len != 0) try out.append(alloc, ' ');
            pending_space = false;
            try out.append(alloc, c);
        }
        i += 1;
    }

    return trimEdges(alloc, try out.toOwnedSlice(alloc));
}

/// Collapse runs of blank lines and drop leading/trailing whitespace, while
/// keeping single interior spaces (so Latin text stays readable).
fn trimEdges(alloc: Allocator, text: []u8) ![]u8 {
    var w: usize = 0;
    var seen_content = false;
    var pending_break = false;
    var pending_space = false;
    for (text) |c| {
        if (c == '\n') {
            pending_break = true;
            pending_space = false;
            continue;
        }
        if (c == ' ' or c == '\t') {
            pending_space = true;
            continue;
        }
        if (seen_content) {
            if (pending_break) {
                text[w] = '\n';
                w += 1;
            } else if (pending_space and w > 0 and text[w - 1] != '\n') {
                text[w] = ' ';
                w += 1;
            }
        }
        pending_break = false;
        pending_space = false;
        seen_content = true;
        text[w] = c;
        w += 1;
    }
    return alloc.realloc(text, w);
}

fn appendChar(alloc: Allocator, out: *std.ArrayList(u8), c: u21, pending_space: *bool) !void {
    if (c == ' ' or c == '\n' or c == '\t') {
        pending_space.* = true;
        return;
    }
    if (pending_space.* and out.items.len != 0) try out.append(alloc, ' ');
    pending_space.* = false;
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(c, &buf) catch return;
    try out.appendSlice(alloc, buf[0..n]);
}

fn isFullWidthSpace(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "\u{3000}");
}

fn decodeEntity(ent: []const u8) ?u21 {
    if (std.mem.eql(u8, ent, "&amp;")) return '&';
    if (std.mem.eql(u8, ent, "&lt;")) return '<';
    if (std.mem.eql(u8, ent, "&gt;")) return '>';
    if (std.mem.eql(u8, ent, "&quot;")) return '"';
    if (std.mem.eql(u8, ent, "&apos;")) return '\'';
    if (std.mem.eql(u8, ent, "&nbsp;")) return ' ';
    if (ent.len > 3 and ent[0] == '&' and ent[1] == '#') {
        const body = ent[2 .. ent.len - 1];
        if (body.len > 1 and (body[0] == 'x' or body[0] == 'X')) {
            return std.fmt.parseUnsigned(u21, body[1..], 16) catch null;
        }
        const v = std.fmt.parseUnsigned(u32, body, 10) catch return null;
        if (v > 0x10ffff) return null;
        return @intCast(v);
    }
    return null;
}

fn isSelfClosing(raw_tag: []const u8) bool {
    return raw_tag.len > 0 and raw_tag[raw_tag.len - 1] == '/';
}

/// Minimal XML attribute lookup: `name="value"` or `name='value'`.
pub fn attr(tag_text: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < tag_text.len) : (i += 1) {
        if (!std.mem.startsWith(u8, tag_text[i..], name)) continue;
        var j = i + name.len;
        if (j >= tag_text.len) return null;
        if (tag_text[j] != '=' and !std.ascii.isWhitespace(tag_text[j])) continue;
        while (j < tag_text.len and std.ascii.isWhitespace(tag_text[j])) j += 1;
        if (j >= tag_text.len or tag_text[j] != '=') continue;
        j += 1;
        while (j < tag_text.len and std.ascii.isWhitespace(tag_text[j])) j += 1;
        if (j >= tag_text.len) return null;
        const quote = tag_text[j];
        if (quote != '"' and quote != '\'') continue;
        j += 1;
        const end = std.mem.indexOfScalarPos(u8, tag_text, j, quote) orelse return null;
        return tag_text[j..end];
    }
    return null;
}

/// Iterate over tags whose name matches `tag` inside `xml`, yielding the tag body.
pub const TagIterator = struct {
    xml: []const u8,
    tag: []const u8,
    pos: usize = 0,

    pub fn next(self: *TagIterator) ?[]const u8 {
        while (self.pos < self.xml.len) {
            const lt = std.mem.indexOfScalarPos(u8, self.xml, self.pos, '<') orelse return null;
            if (lt + 1 >= self.xml.len) return null;
            var j = lt + 1;
            while (j < self.xml.len and std.ascii.isWhitespace(self.xml[j])) j += 1;
            const name_start = j;
            while (j < self.xml.len and !std.ascii.isWhitespace(self.xml[j]) and self.xml[j] != '>' and self.xml[j] != '/') j += 1;
            const name = self.xml[name_start..j];
            const gt = std.mem.indexOfScalarPos(u8, self.xml, lt, '>') orelse return null;
            const body = self.xml[name_start..gt];
            self.pos = gt + 1;
            if (std.mem.eql(u8, name, self.tag)) return body;
        }
        return null;
    }
};

test "extract drops markup and decodes entities" {
    const alloc = std.testing.allocator;
    const html = "<html><head><title>x</title></head><body><p>Hello &amp; world</p><p>第二段</p></body></html>";
    const text = try extract(alloc, html);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("Hello & world\n第二段", text);
}

test "extract skips script and style" {
    const alloc = std.testing.allocator;
    const html = "<p>keep</p><script>var x = 'drop me';</script><style>p{color:red}</style>";
    const text = try extract(alloc, html);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("keep", text);
}

test "entity decoding handles numeric forms" {
    try std.testing.expectEqual(@as(?u21, 'A'), decodeEntity("&#65;"));
    try std.testing.expectEqual(@as(?u21, '中'), decodeEntity("&#x4e2d;"));
    try std.testing.expectEqual(@as(?u21, null), decodeEntity("&notanentity;"));
}

test "attr picks quoted values" {
    try std.testing.expectEqualStrings("ch1", attr("item id=\"ch1\" href=\"a.xhtml\"", "id").?);
    try std.testing.expectEqualStrings("a.xhtml", attr("item id=\"ch1\" href='a.xhtml'", "href").?);
}

test "tag iterator finds matching tags only" {
    const xml = "<package><item id=\"a\"/><itemref idref=\"a\"/><item id=\"b\"/></package>";
    var it = TagIterator{ .xml = xml, .tag = "item" };
    var count: usize = 0;
    while (it.next()) |body| {
        _ = body;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}
