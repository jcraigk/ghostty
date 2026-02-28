//! A Block represents a single command block in the terminal — one prompt,
//! its input, and its output. Blocks are a read-only view over the existing
//! Screen/PageList and use tracked Pins for stable boundary references that
//! survive scrollback changes.
const Block = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const PageList = @import("PageList.zig");
const pagepkg = @import("page.zig");
const size = @import("size.zig");
const Pin = PageList.Pin;

/// Tracked pin to the first row of this block's prompt (OSC 133 A).
prompt_start: *Pin,

/// Tracked pin to the first row of user input (OSC 133 B).
/// Null if the user has not yet pressed enter / input hasn't started.
input_start: ?*Pin = null,

/// Tracked pin to the first row of command output (OSC 133 C).
/// Null if no output has been produced yet.
output_start: ?*Pin = null,

/// Tracked pin to the row AFTER the last row of this block. This is
/// effectively the prompt_start of the *next* block. Null for the
/// active (last) block whose extent is still growing.
end: ?*Pin = null,

/// Exit code from OSC 133 D. Null while the command is still running.
exit_code: ?i32 = null,

/// Whether this block has been manually collapsed by the user.
collapsed: bool = false,

/// Extract the user's input command text from the terminal buffer.
///
/// Reads cell codepoints between `input_start` and `output_start`
/// (or `end` if no output). Returns the filled portion of `buf`.
pub fn commandText(self: Block, pages: *PageList, buf: []u8) []const u8 {
    const start_pin = self.input_start orelse return buf[0..0];
    const limit_pin = self.output_start orelse (self.end orelse return buf[0..0]);
    return readPinRangeText(pages, start_pin.*, limit_pin.*, buf);
}

/// Extract command output text from the terminal buffer.
///
/// Reads cell codepoints between `output_start` and `end`. Returns the
/// filled portion of `buf`.
pub fn outputText(self: Block, pages: *PageList, buf: []u8) []const u8 {
    const start_pin = self.output_start orelse return buf[0..0];
    const limit_pin = self.end orelse return buf[0..0];
    return readPinRangeText(pages, start_pin.*, limit_pin.*, buf);
}

/// Read text from cells between two pins, writing UTF-8 into `buf`.
/// The range is inclusive of `start` and exclusive of `limit`.
fn readPinRangeText(pages: *PageList, start: Pin, limit: Pin, buf: []u8) []const u8 {
    _ = pages;

    if (buf.len == 0) return buf[0..0];

    var written: usize = 0;
    var row_it = start.rowIterator(.right_down, limit);

    while (row_it.next()) |row_pin| {
        // Don't include the limit row itself.
        if (row_pin.node == limit.node and row_pin.y == limit.y) break;

        const row_cells = row_pin.cells(.all);
        for (row_cells) |cell| {
            if (!cell.hasText()) continue;
            if (cell.wide == .spacer_tail) continue;

            const cp = cell.content.codepoint;
            const len = std.unicode.utf8CodepointSequenceLength(cp) catch continue;
            if (written + len > buf.len) return buf[0..written];
            _ = std.unicode.utf8Encode(cp, buf[written..]) catch continue;
            written += len;
        }

        // Insert a newline between rows (unless we'd overflow).
        if (written + 1 <= buf.len) {
            buf[written] = '\n';
            written += 1;
        } else {
            return buf[0..written];
        }
    }

    // Trim trailing newline if present.
    if (written > 0 and buf[written - 1] == '\n') written -= 1;
    return buf[0..written];
}

/// Manages an ordered list of Blocks backed by tracked pins.
pub const BlockList = struct {
    blocks: std.ArrayListUnmanaged(Block) = .empty,
    pages: *PageList,
    alloc: Allocator,

    pub fn init(allocator: Allocator, pages: *PageList) BlockList {
        return .{
            .pages = pages,
            .alloc = allocator,
        };
    }

    pub fn deinit(self: *BlockList) void {
        for (self.blocks.items) |block| {
            self.pages.untrackPin(block.prompt_start);
            if (block.input_start) |p| self.pages.untrackPin(p);
            if (block.output_start) |p| self.pages.untrackPin(p);
            if (block.end) |p| self.pages.untrackPin(p);
        }
        self.blocks.deinit(self.alloc);
    }

    /// Create a new block starting at `prompt_pin`. The pin is tracked so
    /// it remains valid across scrollback mutations. If a previous block
    /// exists and has no `end`, it is closed by pointing its `end` at the
    /// new block's prompt.
    pub fn addBlock(self: *BlockList, prompt_pin: Pin) Allocator.Error!*Block {
        const tracked = try self.pages.trackPin(prompt_pin);
        errdefer self.pages.untrackPin(tracked);

        // Close the previous block if it has no end yet.
        if (self.blocks.items.len > 0) {
            const prev = &self.blocks.items[self.blocks.items.len - 1];
            if (prev.end == null) {
                const end_pin = try self.pages.trackPin(prompt_pin);
                prev.end = end_pin;
            }
        }

        try self.blocks.append(self.alloc, .{ .prompt_start = tracked });
        return &self.blocks.items[self.blocks.items.len - 1];
    }

    /// Returns the last (active) block, or null if there are no blocks.
    pub fn activeBlock(self: *BlockList) ?*Block {
        if (self.blocks.items.len == 0) return null;
        return &self.blocks.items[self.blocks.items.len - 1];
    }

    /// Find which block contains the given pin position. Uses Pin ordering
    /// to locate the enclosing block via linear scan (blocks are ordered).
    pub fn blockAtPin(self: *BlockList, pin: Pin) ?*Block {
        // Walk blocks in reverse so we hit the most recent (and most
        // likely) block first.
        var i = self.blocks.items.len;
        while (i > 0) {
            i -= 1;
            const block = &self.blocks.items[i];
            if (block.prompt_start.garbage) continue;

            const block_start = block.prompt_start.*;
            // Pin is before this block's start — can't be in this block
            // or any earlier one.
            if (pin.before(block_start)) continue;

            // Pin is at or after this block's start. Check the end bound.
            if (block.end) |end_ptr| {
                if (end_ptr.garbage) return block;
                if (pin.before(end_ptr.*) or pin.eql(end_ptr.*)) return block;
                // Pin is past this block's end — not here.
                continue;
            }

            // No end means this is the active block; pin is in it.
            return block;
        }
        return null;
    }

    /// Returns the number of blocks.
    pub fn blockCount(self: *const BlockList) usize {
        return self.blocks.items.len;
    }

    /// Remove blocks whose `prompt_start` has been garbage-collected
    /// (their backing page was freed from scrollback).
    pub fn pruneGarbage(self: *BlockList) void {
        var i: usize = 0;
        while (i < self.blocks.items.len) {
            const block = &self.blocks.items[i];
            if (block.prompt_start.garbage) {
                // Untrack all pins owned by this block.
                self.pages.untrackPin(block.prompt_start);
                if (block.input_start) |p| self.pages.untrackPin(p);
                if (block.output_start) |p| self.pages.untrackPin(p);
                if (block.end) |p| self.pages.untrackPin(p);

                _ = self.blocks.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const Screen = @import("Screen.zig");

test "BlockList: init and deinit" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    try testing.expectEqual(@as(usize, 0), bl.blockCount());
    try testing.expect(bl.activeBlock() == null);
}

test "BlockList: add blocks and query" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    // Add first block at the top of the screen.
    const first_pin: Pin = .{ .node = s.pages.pages.first.? };
    const b1 = try bl.addBlock(first_pin);
    try testing.expectEqual(@as(usize, 1), bl.blockCount());

    // Active block should be the first block.
    try testing.expect(bl.activeBlock().? == b1);

    // Add a second block a few rows down.
    var second_pin = first_pin;
    second_pin.y = 5;
    const b2 = try bl.addBlock(second_pin);
    try testing.expectEqual(@as(usize, 2), bl.blockCount());

    // Active block should now be the second block.
    try testing.expect(bl.activeBlock().? == b2);

    // First block should have been closed with an end pin.
    try testing.expect(b1.end != null);
}

test "BlockList: activeBlock returns last block" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const pin: Pin = .{ .node = s.pages.pages.first.? };
    _ = try bl.addBlock(pin);
    _ = try bl.addBlock(.{ .node = s.pages.pages.first.?, .y = 3 });
    const b3 = try bl.addBlock(.{ .node = s.pages.pages.first.?, .y = 6 });

    try testing.expectEqual(@as(usize, 3), bl.blockCount());
    try testing.expect(bl.activeBlock().? == b3);
}

test "BlockList: blockAtPin" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    _ = try bl.addBlock(.{ .node = node, .y = 0 });
    _ = try bl.addBlock(.{ .node = node, .y = 5 });
    _ = try bl.addBlock(.{ .node = node, .y = 10 });

    // Pin in the first block.
    const found0 = bl.blockAtPin(.{ .node = node, .y = 2 });
    try testing.expect(found0 != null);
    try testing.expectEqual(@as(size.CellCountInt, 0), found0.?.prompt_start.y);

    // Pin in the second block.
    const found1 = bl.blockAtPin(.{ .node = node, .y = 7 });
    try testing.expect(found1 != null);
    try testing.expectEqual(@as(size.CellCountInt, 5), found1.?.prompt_start.y);

    // Pin in the third (active) block.
    const found2 = bl.blockAtPin(.{ .node = node, .y = 15 });
    try testing.expect(found2 != null);
    try testing.expectEqual(@as(size.CellCountInt, 10), found2.?.prompt_start.y);
}

test "BlockList: pruneGarbage removes blocks with garbage pins" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    const b1 = try bl.addBlock(.{ .node = node, .y = 0 });
    _ = try bl.addBlock(.{ .node = node, .y = 5 });

    try testing.expectEqual(@as(usize, 2), bl.blockCount());

    // Simulate garbage collection of first block's page.
    b1.prompt_start.garbage = true;

    bl.pruneGarbage();

    try testing.expectEqual(@as(usize, 1), bl.blockCount());
    // Remaining block should be the one starting at y=5.
    try testing.expectEqual(@as(size.CellCountInt, 5), bl.blocks.items[0].prompt_start.y);
}

test "Block: commandText stub" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    const b = try bl.addBlock(.{ .node = node, .y = 0 });

    // No input_start set — should return empty.
    var buf: [256]u8 = undefined;
    const text = b.commandText(&s.pages, &buf);
    try testing.expectEqual(@as(usize, 0), text.len);
}

test "Block: outputText stub" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    const b = try bl.addBlock(.{ .node = node, .y = 0 });

    // No output_start set — should return empty.
    var buf: [256]u8 = undefined;
    const text = b.outputText(&s.pages, &buf);
    try testing.expectEqual(@as(usize, 0), text.len);
}
