//! Checks the TigerStyle rules a machine can check: line length, function length, and a reason
//! comment on every empty `catch` block. Run by `zig build lint` with paths as arguments.

const std = @import("std");
const assert = std.debug.assert;

const line_codepoints_max: u32 = 100;
const function_lines_max: u32 = 70;
const files_max: u32 = 4096;
const file_bytes_max: u32 = 1024 * 1024;

const Lint = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    files_checked: u32 = 0,
    violations: u32 = 0,

    fn report(lint: *Lint, path: []const u8, line: u32, rule: []const u8) void {
        assert(path.len > 0);
        assert(line >= 1);
        std.debug.print("{s}:{d}: {s}\n", .{ path, line, rule });
        lint.violations += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    var lint: Lint = .{ .io = init.io, .gpa = init.gpa };
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < 2) {
        std.debug.print("usage: lint <path>...\n", .{});
        std.process.exit(2);
    }
    for (arguments[1..]) |argument| {
        try check_path(&lint, argument);
    }
    assert(lint.files_checked <= files_max);
    if (lint.violations > 0) {
        std.debug.print("lint: {d} violation(s)\n", .{lint.violations});
        std.process.exit(1);
    }
}

fn check_path(lint: *Lint, path: []const u8) !void {
    assert(path.len > 0);
    const cwd = std.Io.Dir.cwd();
    const stat = try cwd.statFile(lint.io, path, .{});
    if (stat.kind != .directory) {
        assert(std.mem.endsWith(u8, path, ".zig"));
        return check_file(lint, cwd, path, path);
    }
    var dir = try cwd.openDir(lint.io, path, .{ .iterate = true });
    defer dir.close(lint.io);
    var walker = try dir.walk(lint.gpa);
    defer walker.deinit();
    while (try walker.next(lint.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const display = try std.fs.path.join(lint.gpa, &.{ path, entry.path });
        defer lint.gpa.free(display);
        try check_file(lint, entry.dir, entry.basename, display);
    }
}

fn check_file(lint: *Lint, dir: std.Io.Dir, sub_path: []const u8, display: []const u8) !void {
    assert(sub_path.len > 0);
    assert(display.len > 0);
    lint.files_checked += 1;
    if (lint.files_checked > files_max) {
        std.debug.print("lint: more than {d} files\n", .{files_max});
        std.process.exit(1);
    }
    const source = dir.readFileAllocOptions(
        lint.io,
        sub_path,
        lint.gpa,
        .limited(file_bytes_max),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.StreamTooLong => {
            std.debug.print("{s}: larger than {d} bytes\n", .{ display, file_bytes_max });
            std.process.exit(1);
        },
        else => return err,
    };
    defer lint.gpa.free(source);
    check_line_length(lint, display, source);
    try check_function_length(lint, display, source);
    try check_empty_catch(lint, display, source);
}

fn check_line_length(lint: *Lint, display: []const u8, source: []const u8) void {
    assert(display.len > 0);
    assert(source.len <= file_bytes_max);
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: u32 = 1;
    while (lines.next()) |line| : (line_number += 1) {
        const codepoints = std.unicode.utf8CountCodepoints(line) catch line.len;
        if (codepoints > line_codepoints_max) {
            lint.report(display, line_number, "line longer than 100 columns");
        }
    }
}

fn check_function_length(lint: *Lint, display: []const u8, source: [:0]const u8) !void {
    assert(display.len > 0);
    assert(source.len <= file_bytes_max);
    var tree = try std.zig.Ast.parse(lint.gpa, source, .{ .mode = .zig });
    defer tree.deinit(lint.gpa);
    const tags = tree.nodes.items(.tag);
    for (tags, 0..) |tag, index| {
        if (tag != .fn_decl) continue;
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(index));
        const first = tree.tokenLocation(0, tree.firstToken(node)).line;
        const last = tree.tokenLocation(0, tree.lastToken(node)).line;
        assert(last >= first);
        if (last - first + 1 > function_lines_max) {
            lint.report(display, @intCast(first + 1), "function longer than 70 lines");
        }
    }
}

fn check_empty_catch(lint: *Lint, display: []const u8, source: [:0]const u8) !void {
    assert(display.len > 0);
    assert(source.len <= file_bytes_max);
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    defer tokens.deinit(lint.gpa);
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        try tokens.append(lint.gpa, token);
        if (token.tag == .eof) break;
    }
    const list = tokens.items;
    for (list, 0..) |token, index| {
        if (token.tag != .keyword_catch) continue;
        var cursor = index + 1;
        if (list[cursor].tag == .pipe) {
            cursor += 1;
            while (list[cursor].tag != .pipe and list[cursor].tag != .eof) cursor += 1;
            cursor += 1;
        }
        if (cursor + 1 >= list.len) continue;
        if (list[cursor].tag != .l_brace or list[cursor + 1].tag != .r_brace) continue;
        if (!has_reason_comment(source, token.loc.start)) {
            const line = std.mem.countScalar(u8, source[0..token.loc.start], '\n') + 1;
            lint.report(display, @intCast(line), "empty catch without a reason comment");
        }
    }
}

fn has_reason_comment(source: []const u8, offset: usize) bool {
    assert(offset < source.len);
    const line_start = if (std.mem.findScalarLast(u8, source[0..offset], '\n')) |i| i + 1 else 0;
    const line_end = std.mem.findScalarPos(u8, source, offset, '\n') orelse source.len;
    assert(line_start <= offset);
    assert(line_end >= offset);
    if (std.mem.find(u8, source[line_start..line_end], "//") != null) return true;
    if (line_start == 0) return false;
    const above_end = line_start - 1;
    const above_start = if (std.mem.findScalarLast(u8, source[0..above_end], '\n')) |i|
        i + 1
    else
        0;
    const above = std.mem.trim(u8, source[above_start..above_end], " \t");
    return std.mem.startsWith(u8, above, "//");
}
