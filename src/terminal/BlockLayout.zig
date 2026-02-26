//! BlockLayout maps between terminal buffer rows and virtual screen rows,
//! inserting padding and separator rows between command blocks. It sits
//! between the terminal buffer and the renderer, providing a virtual
//! coordinate system that accounts for spacing between blocks, collapsed
//! blocks, and separator lines.
const BlockLayout = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const PageList = @import("PageList.zig");
const Pin = PageList.Pin;
const Block = @import("Block.zig");
const size = @import("size.zig");

const COLLAPSED_PREVIEW_ROWS: u32 = 3;
const COLLAPSED_SUMMARY_ROWS: u32 = 1;
const COLLAPSED_TOTAL_ROWS: u32 = COLLAPSED_PREVIEW_ROWS + COLLAPSED_SUMMARY_ROWS;

/// A VirtualRow represents one row in the virtual layout. It can be a real
/// terminal content row, empty padding between blocks, or a visual separator.
pub const VirtualRow = union(enum) {
    content: ContentRow,
    padding: PaddingRow,
    separator: SeparatorRow,

    pub const ContentRow = struct {
        pin: Pin,
        block_index: usize,
    };

    pub const PaddingRow = struct {
        block_above_index: ?usize,
        block_below_index: ?usize,
    };

    pub const SeparatorRow = struct {
        block_above_index: usize,
    };
};

/// The block list this layout is derived from.
block_list: *Block.BlockList,

/// Number of padding rows inserted between blocks.
padding_rows: u8 = 1,

/// Whether to show separator lines between blocks.
show_separators: bool = true,

/// Cached per-block layout info for efficient lookups.
block_offsets: std.ArrayList(BlockLayoutInfo),

/// Whether the cache needs recomputation.
dirty: bool = true,

allocator: Allocator,

const BlockLayoutInfo = struct {
    /// Virtual row where this block's content starts.
    virtual_start: u32,
    /// Number of content rows in this block.
    content_rows: u32,
    /// Total virtual rows this block contributes, including any
    /// trailing padding and separator before the next block.
    total_virtual_rows: u32,
};

pub fn init(allocator: Allocator, block_list: *Block.BlockList) BlockLayout {
    return .{
        .allocator = allocator,
        .block_list = block_list,
        .block_offsets = std.ArrayList(BlockLayoutInfo).init(allocator),
    };
}

pub fn deinit(self: *BlockLayout) void {
    self.block_offsets.deinit();
}

/// Recompute `block_offsets` from the current block list state.
pub fn rebuild(self: *BlockLayout) void {
    self.block_offsets.clearRetainingCapacity();

    const blocks = self.block_list.blocks.items;
    if (blocks.len == 0) {
        self.dirty = false;
        return;
    }

    const inter_block_rows: u32 = self.interBlockRows();

    var cumulative: u32 = 0;
    for (blocks, 0..) |*block, i| {
        const content = self.countBlockRows(block);
        const trailing = if (i + 1 < blocks.len) inter_block_rows else 0;
        const total = content + trailing;

        self.block_offsets.append(.{
            .virtual_start = cumulative,
            .content_rows = content,
            .total_virtual_rows = total,
        }) catch {
            self.block_offsets.clearRetainingCapacity();
            self.dirty = true;
            return;
        };

        cumulative += total;
    }

    self.dirty = false;
}

/// Total number of virtual rows across all blocks.
pub fn totalVirtualRows(self: *BlockLayout) u32 {
    if (self.dirty) self.rebuild();

    const offsets = self.block_offsets.items;
    if (offsets.len == 0) return 0;

    const last = offsets[offsets.len - 1];
    return last.virtual_start + last.total_virtual_rows;
}

/// Given a virtual row offset, return what occupies that position.
pub fn virtualRowAt(self: *BlockLayout, virtual_y: u32) ?VirtualRow {
    if (self.dirty) self.rebuild();

    const offsets = self.block_offsets.items;
    if (offsets.len == 0) return null;

    const block_idx = self.findBlockIndex(virtual_y) orelse return null;
    const info = offsets[block_idx];
    const offset_in_block = virtual_y - info.virtual_start;

    if (offset_in_block < info.content_rows) {
        const pin = self.pinAtBlockRow(block_idx, offset_in_block) orelse return null;
        return .{ .content = .{
            .pin = pin,
            .block_index = block_idx,
        } };
    }

    const past_content = offset_in_block - info.content_rows;
    const blocks = self.block_list.blocks.items;

    if (self.show_separators) {
        if (past_content == 0) {
            return .{ .separator = .{ .block_above_index = block_idx } };
        }
        return .{ .padding = .{
            .block_above_index = block_idx,
            .block_below_index = if (block_idx + 1 < blocks.len) block_idx + 1 else null,
        } };
    }

    return .{ .padding = .{
        .block_above_index = block_idx,
        .block_below_index = if (block_idx + 1 < blocks.len) block_idx + 1 else null,
    } };
}

/// Given a terminal pin, find its virtual Y coordinate.
/// Returns null if the pin is in a collapsed block.
pub fn virtualYForPin(self: *BlockLayout, pin: Pin) ?u32 {
    if (self.dirty) self.rebuild();

    const blocks = self.block_list.blocks.items;
    const offsets = self.block_offsets.items;

    for (blocks, 0..) |*block, i| {
        if (block.prompt_start.garbage) continue;

        const block_start = block.prompt_start.*;
        if (pin.before(block_start)) continue;

        const in_block = blk: {
            if (block.end) |end_ptr| {
                if (end_ptr.garbage) break :blk true;
                if (pin.before(end_ptr.*) or pin.eql(end_ptr.*)) break :blk true;
                break :blk false;
            }
            break :blk true;
        };

        if (!in_block) continue;

        if (block.collapsed) return null;

        if (i >= offsets.len) return null;

        const row_offset = self.countRowsBetweenPins(block_start, pin);
        return offsets[i].virtual_start + row_offset;
    }

    return null;
}

/// Mark the layout as dirty so it will be recomputed on next access.
pub fn invalidate(self: *BlockLayout) void {
    self.dirty = true;
}

// ── Iterator ────────────────────────────────────────────────────────────

pub const VirtualRowIterator = struct {
    layout: *BlockLayout,
    current_virtual_y: u32,
    end_virtual_y: u32,

    pub fn next(self: *VirtualRowIterator) ?VirtualRow {
        if (self.current_virtual_y >= self.end_virtual_y) return null;
        const row = self.layout.virtualRowAt(self.current_virtual_y);
        self.current_virtual_y += 1;
        return row;
    }
};

/// Create an iterator over virtual rows in a range (for rendering a viewport).
pub fn visibleRows(self: *BlockLayout, start_y: u32, count: u32) VirtualRowIterator {
    if (self.dirty) self.rebuild();
    return .{
        .layout = self,
        .current_virtual_y = start_y,
        .end_virtual_y = start_y + count,
    };
}

// ── Coordinate transformation helpers ───────────────────────────────────

/// Convert a screen (mouse) Y position to a terminal Pin.
/// Returns null if the position is on padding or a separator.
pub fn screenToPin(self: *BlockLayout, viewport_start: u32, screen_y: u32) ?Pin {
    const virtual_y = viewport_start + screen_y;
    const vrow = self.virtualRowAt(virtual_y) orelse return null;
    return switch (vrow) {
        .content => |c| c.pin,
        .padding, .separator => null,
    };
}

/// Get the block index at a given screen Y position.
/// Returns the block index even for padding/separator rows.
pub fn blockIndexAtScreenY(self: *BlockLayout, viewport_start: u32, screen_y: u32) ?usize {
    const virtual_y = viewport_start + screen_y;
    const vrow = self.virtualRowAt(virtual_y) orelse return null;
    return switch (vrow) {
        .content => |c| c.block_index,
        .padding => |p| p.block_above_index orelse p.block_below_index,
        .separator => |s| s.block_above_index,
    };
}

// ── Internal helpers ────────────────────────────────────────────────────

/// Number of virtual rows inserted between two adjacent blocks
/// (separator + padding).
fn interBlockRows(self: *const BlockLayout) u32 {
    var rows: u32 = self.padding_rows;
    if (self.show_separators) rows += 1;
    return rows;
}

/// Count content rows for a block: collapsed blocks use a fixed size,
/// expanded blocks count actual rows from prompt_start to end.
fn countBlockRows(self: *const BlockLayout, block: *const Block) u32 {
    _ = self;
    if (block.collapsed) return COLLAPSED_TOTAL_ROWS;

    const start = block.prompt_start.*;
    if (block.end) |end_ptr| {
        if (end_ptr.garbage) return 1;
        return countRowsBetweenPins(start, end_ptr.*);
    }

    // Active block (no end): walk to the end of the page list.
    return countRowsFromPin(start);
}

/// Count the number of rows from `start` up to but not including `limit`,
/// where both pins are compared by (node, y) only.
fn countRowsBetweenPins(start: Pin, limit: Pin) u32 {
    if (start.node == limit.node and start.y == limit.y) return 0;

    var count: u32 = 0;
    var it = start.rowIterator(.right_down, limit);
    while (it.next()) |row_pin| {
        if (row_pin.node == limit.node and row_pin.y == limit.y) break;
        count += 1;
    }
    return if (count == 0) 1 else count;
}

/// Count rows from a pin to the end of the page list (for active blocks).
fn countRowsFromPin(start: Pin) u32 {
    var count: u32 = 0;
    var it = start.rowIterator(.right_down, null);
    while (it.next()) |_| {
        count += 1;
    }
    return if (count == 0) 1 else count;
}

/// Binary search `block_offsets` for the block that contains `virtual_y`.
fn findBlockIndex(self: *const BlockLayout, virtual_y: u32) ?usize {
    const offsets = self.block_offsets.items;
    if (offsets.len == 0) return null;

    var lo: usize = 0;
    var hi: usize = offsets.len;

    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const block_end = offsets[mid].virtual_start + offsets[mid].total_virtual_rows;

        if (virtual_y < offsets[mid].virtual_start) {
            hi = mid;
        } else if (virtual_y >= block_end) {
            lo = mid + 1;
        } else {
            return mid;
        }
    }

    return null;
}

/// Get the Pin for a specific content row within a block.
fn pinAtBlockRow(self: *const BlockLayout, block_idx: usize, row_offset: u32) ?Pin {
    const blocks = self.block_list.blocks.items;
    if (block_idx >= blocks.len) return null;
    const block = &blocks[block_idx];

    if (block.prompt_start.garbage) return null;
    const start = block.prompt_start.*;

    if (row_offset == 0) return start;

    var count: u32 = 0;
    var it = start.rowIterator(.right_down, if (block.end) |e| if (!e.garbage) e.* else null else null);
    while (it.next()) |row_pin| {
        if (block.end) |end_ptr| {
            if (!end_ptr.garbage and row_pin.node == end_ptr.node and row_pin.y == end_ptr.y) break;
        }
        if (count == row_offset) return row_pin;
        count += 1;
    }

    return null;
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const Screen = @import("Screen.zig");

test "BlockLayout: zero blocks" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    try testing.expectEqual(@as(u32, 0), layout.totalVirtualRows());
    try testing.expect(layout.virtualRowAt(0) == null);
}

test "BlockLayout: single block no separators" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    _ = try bl.addBlock(.{ .node = node, .y = 0 });

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    const total = layout.totalVirtualRows();
    try testing.expect(total > 0);

    // First row should be content.
    const first = layout.virtualRowAt(0);
    try testing.expect(first != null);
    try testing.expect(first.? == .content);
    try testing.expectEqual(@as(usize, 0), first.?.content.block_index);
}

test "BlockLayout: three blocks with padding and separators" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    _ = try bl.addBlock(.{ .node = node, .y = 0 });
    _ = try bl.addBlock(.{ .node = node, .y = 8 });
    _ = try bl.addBlock(.{ .node = node, .y = 16 });

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    const total = layout.totalVirtualRows();

    // Total should be greater than just content rows because of separators/padding.
    // Block 1: rows 0-7 (8 content) + 1 sep + 1 pad = 10
    // Block 2: rows 8-15 (8 content) + 1 sep + 1 pad = 10
    // Block 3: rows 16-23 (8 content) = 8
    // Total = 28
    try testing.expectEqual(@as(u32, 28), total);

    // Verify we have separator and padding rows between blocks.
    const offsets = layout.block_offsets.items;
    try testing.expectEqual(@as(usize, 3), offsets.len);

    // First block starts at 0.
    try testing.expectEqual(@as(u32, 0), offsets[0].virtual_start);
    try testing.expectEqual(@as(u32, 8), offsets[0].content_rows);

    // Second block starts after first's content + separator + padding.
    try testing.expectEqual(@as(u32, 10), offsets[1].virtual_start);
    try testing.expectEqual(@as(u32, 8), offsets[1].content_rows);

    // Third block starts after second's content + separator + padding.
    try testing.expectEqual(@as(u32, 20), offsets[2].virtual_start);
}

test "BlockLayout: virtualRowAt boundary types" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    _ = try bl.addBlock(.{ .node = node, .y = 0 });
    _ = try bl.addBlock(.{ .node = node, .y = 4 });

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    // Block 1: 4 content rows (y=0..3), then separator at 4, padding at 5.
    // Block 2 starts at virtual_y=6.

    // Row 0-3: content from block 0.
    const r0 = layout.virtualRowAt(0).?;
    try testing.expect(r0 == .content);
    try testing.expectEqual(@as(usize, 0), r0.content.block_index);

    const r3 = layout.virtualRowAt(3).?;
    try testing.expect(r3 == .content);
    try testing.expectEqual(@as(usize, 0), r3.content.block_index);

    // Row 4: separator between block 0 and block 1.
    const r4 = layout.virtualRowAt(4).?;
    try testing.expect(r4 == .separator);
    try testing.expectEqual(@as(usize, 0), r4.separator.block_above_index);

    // Row 5: padding.
    const r5 = layout.virtualRowAt(5).?;
    try testing.expect(r5 == .padding);
    try testing.expectEqual(@as(?usize, 0), r5.padding.block_above_index);
    try testing.expectEqual(@as(?usize, 1), r5.padding.block_below_index);

    // Row 6: content from block 1.
    const r6 = layout.virtualRowAt(6).?;
    try testing.expect(r6 == .content);
    try testing.expectEqual(@as(usize, 1), r6.content.block_index);
}

test "BlockLayout: coordinate roundtrip virtualYForPin" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    _ = try bl.addBlock(.{ .node = node, .y = 0 });
    _ = try bl.addBlock(.{ .node = node, .y = 6 });

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    // Pin at block 0, row 3.
    const test_pin: Pin = .{ .node = node, .y = 3 };
    const virtual_y = layout.virtualYForPin(test_pin) orelse {
        return error.TestUnexpectedResult;
    };

    // virtualRowAt at that virtual_y should give us back a content row
    // whose pin matches.
    const vrow = layout.virtualRowAt(virtual_y) orelse {
        return error.TestUnexpectedResult;
    };

    try testing.expect(vrow == .content);
    try testing.expectEqual(test_pin.node, vrow.content.pin.node);
    try testing.expectEqual(test_pin.y, vrow.content.pin.y);
}

test "BlockLayout: collapsed block reduces row count" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    _ = try bl.addBlock(.{ .node = node, .y = 0 });
    const b2 = try bl.addBlock(.{ .node = node, .y = 10 });

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    const total_expanded = layout.totalVirtualRows();

    // Collapse first block (which has 10 content rows expanded).
    bl.blocks.items[0].collapsed = true;
    layout.invalidate();

    const total_collapsed = layout.totalVirtualRows();

    // Collapsed block uses COLLAPSED_TOTAL_ROWS (4) instead of 10.
    try testing.expect(total_collapsed < total_expanded);
    try testing.expectEqual(
        total_expanded - 10 + COLLAPSED_TOTAL_ROWS,
        total_collapsed,
    );

    // virtualYForPin should return null for a pin inside the collapsed region.
    const collapsed_pin: Pin = .{ .node = node, .y = 5 };
    try testing.expect(layout.virtualYForPin(collapsed_pin) == null);

    _ = b2;
}

test "BlockLayout: iterator walks all rows" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    _ = try bl.addBlock(.{ .node = node, .y = 0 });
    _ = try bl.addBlock(.{ .node = node, .y = 4 });

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    const total = layout.totalVirtualRows();
    var it = layout.visibleRows(0, total);

    var content_count: u32 = 0;
    var sep_count: u32 = 0;
    var pad_count: u32 = 0;

    while (it.next()) |row| {
        switch (row) {
            .content => content_count += 1,
            .separator => sep_count += 1,
            .padding => pad_count += 1,
        }
    }

    // 4 rows (block 0) + remaining rows (block 1) for content.
    // 1 separator + 1 padding between the two blocks.
    try testing.expectEqual(@as(u32, 1), sep_count);
    try testing.expectEqual(@as(u32, 1), pad_count);
    try testing.expect(content_count > 0);
    try testing.expectEqual(total, content_count + sep_count + pad_count);
}

test "BlockLayout: screenToPin and blockIndexAtScreenY" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    _ = try bl.addBlock(.{ .node = node, .y = 0 });
    _ = try bl.addBlock(.{ .node = node, .y = 4 });

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    // Content row: should return a pin.
    const pin = layout.screenToPin(0, 0);
    try testing.expect(pin != null);
    try testing.expectEqual(@as(size.CellCountInt, 0), pin.?.y);

    // Separator row (virtual_y = 4): should return null.
    const sep_pin = layout.screenToPin(0, 4);
    try testing.expect(sep_pin == null);

    // Block index at content row.
    const idx0 = layout.blockIndexAtScreenY(0, 0);
    try testing.expectEqual(@as(?usize, 0), idx0);

    // Block index at separator should still return the block above.
    const idx_sep = layout.blockIndexAtScreenY(0, 4);
    try testing.expectEqual(@as(?usize, 0), idx_sep);

    // Block index in second block.
    const idx1 = layout.blockIndexAtScreenY(0, 6);
    try testing.expectEqual(@as(?usize, 1), idx1);
}

test "BlockLayout: invalidate forces rebuild" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    _ = try bl.addBlock(.{ .node = node, .y = 0 });

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    const total1 = layout.totalVirtualRows();
    try testing.expect(!layout.dirty);

    layout.invalidate();
    try testing.expect(layout.dirty);

    // Accessing totalVirtualRows should trigger rebuild.
    const total2 = layout.totalVirtualRows();
    try testing.expect(!layout.dirty);
    try testing.expectEqual(total1, total2);
}
