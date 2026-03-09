//! BlockLayout computes a stable, viewport-independent virtual document layout
//! from the BlockList. It maps between absolute pixel coordinates in the virtual
//! document and terminal buffer pins, handling inter-block gaps, collapsed blocks,
//! and separator placement.
//!
//! This is the single source of truth for block positioning. The scroll controller
//! (Terminal.scroll_offset_px) indexes into this layout, and the renderer consumes
//! it to compute scissor rects and fetch row data. There is no feedback loop —
//! the layout is computed once per invalidation and read by both.
const BlockLayout = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const PageList = @import("PageList.zig");
const Pin = PageList.Pin;
const Block = @import("Block.zig");
const size = @import("size.zig");

/// Per-block layout information in the virtual document.
pub const BlockLayoutInfo = struct {
    /// Absolute pixel Y where this block's visible content starts in the virtual
    /// document. This is AFTER the header padding of the gap above this block
    /// (if any). The first block starts at 0.
    virtual_y_px: u32,

    /// Visible content height in pixels. For expanded blocks, this is
    /// total_rows * cell_height. For collapsed blocks, this is
    /// visible_rows * cell_height.
    visible_height_px: u32,

    /// Number of visible content rows. For expanded blocks, equals total_rows.
    /// For collapsed blocks, equals min(total_rows, output_row_offset + preview_lines).
    visible_rows: u32,

    /// Total content rows in this block (from prompt_start to end, or to cursor
    /// for the active block). Used for "[N lines hidden]" indicator.
    total_rows: u32,

    /// Number of prompt/input rows before output_start. Always visible even
    /// when collapsed.
    output_row_offset: u16,

    /// Exit code from the block (-1 = running/unknown).
    exit_code: i32,

    /// Whether this block is collapsed.
    collapsed: bool,

    /// Whether this block has an active output filter.
    filtered: bool,

    /// Matched output row indices (0-based from output_start) when filtered.
    /// Null when not filtered.
    filter_match_rows: ?[]const u32,

    /// Index into BlockList.blocks. Stable across viewport changes.
    block_list_index: usize,

    /// The prompt_start pin for this block (for row data access).
    prompt_start_pin: Pin,

    /// The total visual extent of this block including the gap BELOW it
    /// (footer + separator + header), or just the visible height if this
    /// is the last block.
    /// Used for computing the next block's virtual_y_px.
    total_extent_px: u32,

    /// Number of hidden lines (total_rows - visible_rows). Used for
    /// the "[N lines hidden]" collapse indicator.
    pub fn hiddenLines(self: BlockLayoutInfo) u32 {
        return self.total_rows -| self.visible_rows;
    }
};

/// Configuration parameters for layout computation.
pub const LayoutConfig = struct {
    /// Height of a single cell/row in pixels.
    cell_height: u32,
    /// Footer padding in pixels (above separator line).
    footer_padding_px: u32,
    /// Header padding in pixels (below separator line).
    header_padding_px: u32,
    /// Separator line height in pixels (typically 2).
    separator_height_px: u32 = 2,
    /// Number of output preview lines when a block is collapsed.
    preview_lines: u16,
    /// Cursor row in the active block (rows from prompt_start), used to
    /// compute the active block's height without counting empty rows below.
    /// null means use full extent (e.g., when cursor position is unknown).
    active_block_cursor_row: ?u32 = null,

    /// Total inter-block gap in pixels.
    pub fn gapPx(self: LayoutConfig) u32 {
        return self.footer_padding_px + self.separator_height_px + self.header_padding_px;
    }
};

/// The block list this layout is derived from.
block_list: *Block.BlockList,

/// Cached per-block layout info for efficient lookups.
block_offsets: std.ArrayListUnmanaged(BlockLayoutInfo) = .empty,

/// Total height of the virtual document in pixels.
total_height_px: u32 = 0,

/// Whether the cache needs recomputation.
dirty: bool = true,

/// Last config used for layout computation (needed for lazy rebuild).
config: LayoutConfig = .{
    .cell_height = 16,
    .footer_padding_px = 25,
    .header_padding_px = 25,
    .preview_lines = 0,
},

allocator: Allocator,

pub fn init(allocator: Allocator, block_list: *Block.BlockList) BlockLayout {
    return .{
        .allocator = allocator,
        .block_list = block_list,
    };
}

pub fn deinit(self: *BlockLayout) void {
    self.block_offsets.deinit(self.allocator);
}

/// Update configuration and mark dirty if changed.
pub fn setConfig(self: *BlockLayout, new_config: LayoutConfig) void {
    // Always accept — the active block cursor row changes every frame.
    self.config = new_config;
    self.dirty = true;
}

/// Recompute `block_offsets` and `total_height_px` from the current block list.
pub fn rebuild(self: *BlockLayout) void {
    self.block_offsets.clearRetainingCapacity();
    self.total_height_px = 0;

    const blocks = self.block_list.blocks.items;
    if (blocks.len == 0) {
        self.dirty = false;
        return;
    }

    const cell_h = self.config.cell_height;
    if (cell_h == 0) {
        self.dirty = false;
        return;
    }
    const gap_px = self.config.gapPx();

    var cumulative_y: u32 = 0;
    for (blocks, 0..) |*block, i| {
        const is_last = (i + 1 == blocks.len);
        const is_active = is_last and block.end == null;

        // Get total row count (cached for completed blocks, computed for active).
        const total_rows = self.countBlockRows(block, is_active);

        // Compute output_row_offset (rows before output_start).
        const output_row_offset: u16 = self.countOutputOffset(block);

        // Compute visible rows (accounting for collapse and filter).
        // Filter takes priority: show prompt/input rows + matched output rows.
        // When collapsed (and no filter), show 1 prompt/input + preview_lines.
        const visible_rows: u32 = if (block.filter_match_rows) |matches|
            @min(total_rows, @as(u32, output_row_offset) + @as(u32, @intCast(matches.len)))
        else if (block.collapsed)
            @max(1, @min(total_rows, 1 + @as(u32, self.config.preview_lines)))
        else
            total_rows;

        const visible_height = visible_rows * cell_h;
        const trailing_gap: u32 = if (is_last) 0 else gap_px;
        const total_extent = visible_height + trailing_gap;

        self.block_offsets.append(self.allocator, .{
            .virtual_y_px = cumulative_y,
            .visible_height_px = visible_height,
            .visible_rows = visible_rows,
            .total_rows = total_rows,
            .output_row_offset = output_row_offset,
            .exit_code = block.exit_code orelse -1,
            .collapsed = block.collapsed,
            .filtered = block.filter_match_rows != null,
            .filter_match_rows = block.filter_match_rows,
            .block_list_index = i,
            .prompt_start_pin = block.prompt_start.*,
            .total_extent_px = total_extent,
        }) catch {
            // On allocation failure, clear and mark dirty so we retry next time.
            self.block_offsets.clearRetainingCapacity();
            self.total_height_px = 0;
            self.dirty = true;
            return;
        };

        cumulative_y += total_extent;
    }

    self.total_height_px = cumulative_y;
    self.dirty = false;
}

/// Ensure the layout is up to date (lazy rebuild).
pub fn ensureValid(self: *BlockLayout) void {
    if (self.dirty) self.rebuild();
}

/// Total height of the virtual document in pixels.
/// Triggers a rebuild if dirty.
pub fn totalDocHeightPx(self: *BlockLayout) u32 {
    self.ensureValid();
    return self.total_height_px;
}

/// Number of blocks in the layout.
pub fn blockCount(self: *BlockLayout) usize {
    self.ensureValid();
    return self.block_offsets.items.len;
}

/// Get the layout info for a specific block by index.
pub fn blockAt(self: *BlockLayout, index: usize) ?*const BlockLayoutInfo {
    self.ensureValid();
    if (index >= self.block_offsets.items.len) return null;
    return &self.block_offsets.items[index];
}

/// Find which block contains the given virtual Y pixel coordinate.
/// Returns null if y_px is in a gap between blocks or past the end.
pub fn blockAtVirtualY(self: *BlockLayout, y_px: u32) ?*const BlockLayoutInfo {
    self.ensureValid();
    const idx = self.findBlockIndexAtY(y_px) orelse return null;
    const info = &self.block_offsets.items[idx];
    // Check if y_px is within the block's visible content (not in the trailing gap).
    if (y_px >= info.virtual_y_px and y_px < info.virtual_y_px + info.visible_height_px) {
        return info;
    }
    return null;
}

/// Find the block index for a gap at the given Y. Returns the block ABOVE the gap.
/// Returns null if y_px is not in a gap.
pub fn gapBlockAtVirtualY(self: *BlockLayout, y_px: u32) ?usize {
    self.ensureValid();
    const idx = self.findBlockIndexAtY(y_px) orelse return null;
    const info = &self.block_offsets.items[idx];
    // y_px is in the trailing gap if it's past the visible content.
    if (y_px >= info.virtual_y_px + info.visible_height_px) {
        return idx;
    }
    return null;
}

/// Return the range of block indices that overlap with the viewport defined by
/// [top_px, top_px + height_px). Caller should iterate from start_idx to
/// end_idx (exclusive).
pub const ViewportRange = struct {
    start_idx: usize,
    end_idx: usize,
};

pub fn viewportBlockRange(self: *BlockLayout, top_px: u32, height_px: u32) ViewportRange {
    self.ensureValid();
    const items = self.block_offsets.items;
    if (items.len == 0) return .{ .start_idx = 0, .end_idx = 0 };

    const bottom_px = top_px + height_px;

    // Find first block that overlaps the viewport (its extent reaches past top_px).
    var start: usize = 0;
    for (items, 0..) |info, i| {
        if (info.virtual_y_px + info.total_extent_px > top_px) {
            start = i;
            break;
        }
    } else {
        // All blocks are above the viewport.
        return .{ .start_idx = items.len, .end_idx = items.len };
    }

    // Find last block that overlaps (its start is before bottom_px).
    var end: usize = start;
    for (items[start..], start..) |info, i| {
        if (info.virtual_y_px >= bottom_px) break;
        end = i + 1;
    }

    return .{ .start_idx = start, .end_idx = end };
}

/// Compute the virtual Y for a given block index. This is the block's
/// virtual_y_px value. Useful for scrolling to a specific block.
pub fn virtualYForBlock(self: *BlockLayout, block_list_index: usize) ?u32 {
    self.ensureValid();
    for (self.block_offsets.items) |info| {
        if (info.block_list_index == block_list_index) {
            return info.virtual_y_px;
        }
    }
    return null;
}

/// Given a terminal pin, find its virtual Y pixel coordinate.
/// Returns null if the pin is in a collapsed block or not found.
pub fn virtualYForPin(self: *BlockLayout, pin: Pin) ?u32 {
    self.ensureValid();

    const blocks = self.block_list.blocks.items;
    const offsets = self.block_offsets.items;
    const cell_h = self.config.cell_height;
    if (cell_h == 0) return null;

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

        const row_offset = Block.countRowsBetweenPins(block_start, pin);
        return offsets[i].virtual_y_px + row_offset * cell_h;
    }

    return null;
}

/// Mark the layout as dirty so it will be recomputed on next access.
pub fn invalidate(self: *BlockLayout) void {
    self.dirty = true;
}

/// Get the Pin for a specific content row within a block.
pub fn pinAtBlockRow(self: *const BlockLayout, block_idx: usize, row_offset: u32) ?Pin {
    const blocks = self.block_list.blocks.items;
    if (block_idx >= blocks.len) return null;
    const block = &blocks[block_idx];

    if (block.prompt_start.garbage) return null;
    const start = block.prompt_start.*;

    if (row_offset == 0) return start;

    var count: u32 = 0;
    const limit: ?Pin = if (block.end) |e| if (!e.garbage) e.* else null else null;
    var it = start.rowIterator(.right_down, limit);
    while (it.next()) |row_pin| {
        if (block.end) |end_ptr| {
            if (!end_ptr.garbage and row_pin.node == end_ptr.node and row_pin.y == end_ptr.y) break;
        }
        if (count == row_offset) return row_pin;
        count += 1;
    }

    return null;
}

// ── Internal helpers ────────────────────────────────────────────────────

/// Get the total row count for a block, using the cache for completed blocks
/// and computing for the active block.
fn countBlockRows(self: *const BlockLayout, block: *const Block, is_active: bool) u32 {
    if (block.prompt_start.garbage) return 1;

    if (!is_active) {
        // Completed block — use cached row count if available.
        if (block.cached_row_count) |cached| return cached;
        // Fall through to compute (shouldn't happen if addBlock cached it).
        if (block.end) |end_ptr| {
            if (!end_ptr.garbage) {
                return Block.countRowsBetweenPins(block.prompt_start.*, end_ptr.*);
            }
        }
        return 1;
    }

    // Active block — compute from cursor position if available.
    if (self.config.active_block_cursor_row) |cursor_row| {
        return cursor_row + 1;
    }

    // No cursor info — count to end of page list.
    return Block.countRowsFromPin(block.prompt_start.*);
}

/// Count the number of prompt/input rows before output_start.
fn countOutputOffset(self: *const BlockLayout, block: *const Block) u16 {
    _ = self;
    const output_pin = block.output_start orelse return 0;
    if (block.prompt_start.garbage or output_pin.garbage) return 0;

    var count: u16 = 0;
    var it = block.prompt_start.rowIterator(.right_down, output_pin.*);
    while (it.next()) |row_pin| {
        if (row_pin.node == output_pin.node and row_pin.y == output_pin.y) break;
        count +|= 1;
    }
    return count;
}

/// Binary search `block_offsets` for the block whose total extent contains `y_px`.
/// Returns the block index (into block_offsets) or null.
fn findBlockIndexAtY(self: *const BlockLayout, y_px: u32) ?usize {
    const offsets = self.block_offsets.items;
    if (offsets.len == 0) return null;

    var lo: usize = 0;
    var hi: usize = offsets.len;

    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const block_end = offsets[mid].virtual_y_px + offsets[mid].total_extent_px;

        if (y_px < offsets[mid].virtual_y_px) {
            hi = mid;
        } else if (y_px >= block_end) {
            lo = mid + 1;
        } else {
            return mid;
        }
    }

    return null;
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const Screen = @import("Screen.zig");

fn testConfig() LayoutConfig {
    return .{
        .cell_height = 16,
        .footer_padding_px = 10,
        .header_padding_px = 10,
        .separator_height_px = 2,
        .preview_lines = 0,
    };
}

test "BlockLayout: zero blocks" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();
    layout.setConfig(testConfig());

    try testing.expectEqual(@as(u32, 0), layout.totalDocHeightPx());
    try testing.expect(layout.blockAtVirtualY(0) == null);
}

test "BlockLayout: single active block" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    _ = try bl.addBlock(.{ .node = s.pages.pages.first.?, .y = 0 });

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    var config = testConfig();
    // Active block with cursor at row 5 (0-indexed).
    config.active_block_cursor_row = 5;
    layout.setConfig(config);

    // Single block, 6 rows (0..5), no trailing gap.
    // Height = 6 * 16 = 96px.
    try testing.expectEqual(@as(u32, 96), layout.totalDocHeightPx());
    try testing.expectEqual(@as(usize, 1), layout.blockCount());

    const info = layout.blockAt(0).?;
    try testing.expectEqual(@as(u32, 0), info.virtual_y_px);
    try testing.expectEqual(@as(u32, 96), info.visible_height_px);
    try testing.expectEqual(@as(u32, 6), info.visible_rows);
    try testing.expectEqual(false, info.collapsed);
}

test "BlockLayout: two completed blocks with gap" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    _ = try bl.addBlock(.{ .node = s.pages.pages.first.?, .y = 0 });
    _ = try bl.addBlock(.{ .node = s.pages.pages.first.?, .y = 4 });
    // Add a third block to close the second.
    _ = try bl.addBlock(.{ .node = s.pages.pages.first.?, .y = 10 });

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    var config = testConfig();
    config.active_block_cursor_row = 2; // cursor 2 rows into active block
    layout.setConfig(config);

    // Block 0: rows 0-3 (4 rows), 4*16=64px, gap=22px, total_extent=86px
    // Block 1: rows 4-9 (6 rows), 6*16=96px, gap=22px, total_extent=118px
    // Block 2 (active): 3 rows, 3*16=48px, no trailing gap
    const gap_px: u32 = 10 + 2 + 10; // 22px
    try testing.expectEqual(@as(usize, 3), layout.blockCount());

    const b0 = layout.blockAt(0).?;
    try testing.expectEqual(@as(u32, 0), b0.virtual_y_px);
    try testing.expectEqual(@as(u32, 64), b0.visible_height_px);
    try testing.expectEqual(@as(u32, 64 + gap_px), b0.total_extent_px);

    const b1 = layout.blockAt(1).?;
    try testing.expectEqual(@as(u32, 86), b1.virtual_y_px);
    try testing.expectEqual(@as(u32, 96), b1.visible_height_px);

    const b2 = layout.blockAt(2).?;
    try testing.expectEqual(@as(u32, 86 + 96 + gap_px), b2.virtual_y_px);
    try testing.expectEqual(@as(u32, 48), b2.visible_height_px);

    // Total: 86 + 118 + 48 = 252px
    try testing.expectEqual(@as(u32, 86 + 96 + gap_px + 48), layout.totalDocHeightPx());
}

test "BlockLayout: collapsed block reduces height" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    _ = try bl.addBlock(.{ .node = node, .y = 0 });
    _ = try bl.addBlock(.{ .node = node, .y = 10 });

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    var config = testConfig();
    config.active_block_cursor_row = 2;
    layout.setConfig(config);

    const expanded_height = layout.totalDocHeightPx();

    // Collapse the first block. It has 10 rows total. With output_row_offset=0
    // and preview_lines=0, visible_rows = max(1, min(10, 0+0)) = 1.
    bl.blocks.items[0].collapsed = true;
    layout.invalidate();

    const collapsed_height = layout.totalDocHeightPx();
    try testing.expect(collapsed_height < expanded_height);

    const b0 = layout.blockAt(0).?;
    try testing.expect(b0.collapsed);
    try testing.expectEqual(@as(u32, 1), b0.visible_rows);
    try testing.expectEqual(@as(u32, 10), b0.total_rows);
    try testing.expectEqual(@as(u32, 9), b0.hiddenLines());
}

test "BlockLayout: collapsed block with preview lines" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    const b1 = try bl.addBlock(.{ .node = node, .y = 0 });
    // Set output_start at row 2 (2 prompt/input rows).
    b1.output_start = try bl.pages.trackPin(Pin{ .node = node, .y = 2 });
    _ = try bl.addBlock(.{ .node = node, .y = 10 });

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    var config = testConfig();
    config.preview_lines = 3;
    config.active_block_cursor_row = 2;
    layout.setConfig(config);

    // Collapse: 1 prompt line + preview_lines=3.
    // visible_rows = max(1, min(10, 1+3)) = 4.
    bl.blocks.items[0].collapsed = true;
    layout.invalidate();

    const b0 = layout.blockAt(0).?;
    try testing.expectEqual(@as(u16, 2), b0.output_row_offset);
    try testing.expectEqual(@as(u32, 4), b0.visible_rows);
    try testing.expectEqual(@as(u32, 10), b0.total_rows);
}

test "BlockLayout: viewportBlockRange" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    _ = try bl.addBlock(.{ .node = node, .y = 0 });
    _ = try bl.addBlock(.{ .node = node, .y = 4 });
    _ = try bl.addBlock(.{ .node = node, .y = 8 });
    _ = try bl.addBlock(.{ .node = node, .y = 12 });

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    var config = testConfig();
    config.active_block_cursor_row = 5;
    layout.setConfig(config);

    // Query a viewport that covers some middle region.
    const b1 = layout.blockAt(1).?;
    const range = layout.viewportBlockRange(b1.virtual_y_px, 200);

    // Should include at least block 1 and possibly blocks around it.
    try testing.expect(range.start_idx <= 1);
    try testing.expect(range.end_idx > 1);
}

test "BlockLayout: blockAtVirtualY in gap returns null" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    _ = try bl.addBlock(.{ .node = node, .y = 0 });
    _ = try bl.addBlock(.{ .node = node, .y = 4 });

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    var config = testConfig();
    config.active_block_cursor_row = 10;
    layout.setConfig(config);

    const b0 = layout.blockAt(0).?;
    // Just past the block's visible content, in the gap.
    const gap_y = b0.virtual_y_px + b0.visible_height_px + 1;
    try testing.expect(layout.blockAtVirtualY(gap_y) == null);

    // But gapBlockAtVirtualY should return block 0.
    const gap_block = layout.gapBlockAtVirtualY(gap_y);
    try testing.expectEqual(@as(?usize, 0), gap_block);
}

test "BlockLayout: virtualYForBlock" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    _ = try bl.addBlock(.{ .node = node, .y = 0 });
    _ = try bl.addBlock(.{ .node = node, .y = 6 });

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    var config = testConfig();
    config.active_block_cursor_row = 5;
    layout.setConfig(config);

    // Block 0 is at BlockList index 0, should be at virtual_y_px = 0.
    try testing.expectEqual(@as(?u32, 0), layout.virtualYForBlock(0));

    // Block 1 is at BlockList index 1.
    const b1_y = layout.virtualYForBlock(1);
    try testing.expect(b1_y != null);
    try testing.expect(b1_y.? > 0);

    // Non-existent index.
    try testing.expect(layout.virtualYForBlock(99) == null);
}

test "BlockLayout: virtualYForPin" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    _ = try bl.addBlock(.{ .node = node, .y = 0 });
    _ = try bl.addBlock(.{ .node = node, .y = 6 });

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    var config = testConfig();
    config.active_block_cursor_row = 5;
    layout.setConfig(config);

    // Pin at block 0, row 3 → virtual_y = 0 + 3*16 = 48
    const test_pin: Pin = .{ .node = node, .y = 3 };
    const virtual_y = layout.virtualYForPin(test_pin);
    try testing.expect(virtual_y != null);
    try testing.expectEqual(@as(u32, 48), virtual_y.?);

    // Pin in a collapsed block should return null.
    bl.blocks.items[0].collapsed = true;
    layout.invalidate();
    try testing.expect(layout.virtualYForPin(test_pin) == null);
}

test "BlockLayout: cached_row_count used for completed blocks" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    _ = try bl.addBlock(.{ .node = node, .y = 0 });
    _ = try bl.addBlock(.{ .node = node, .y = 8 });

    // The first block should have been closed by addBlock, caching its row count.
    try testing.expect(bl.blocks.items[0].cached_row_count != null);
    try testing.expectEqual(@as(u32, 8), bl.blocks.items[0].cached_row_count.?);

    // The second (active) block should not have a cache.
    try testing.expect(bl.blocks.items[1].cached_row_count == null);
}

test "BlockLayout: invalidate forces rebuild" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    _ = try bl.addBlock(.{ .node = s.pages.pages.first.?, .y = 0 });

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    var config = testConfig();
    config.active_block_cursor_row = 5;
    layout.setConfig(config);

    const h1 = layout.totalDocHeightPx();
    try testing.expect(!layout.dirty);

    layout.invalidate();
    try testing.expect(layout.dirty);

    // Accessing totalDocHeightPx triggers rebuild.
    const h2 = layout.totalDocHeightPx();
    try testing.expect(!layout.dirty);
    try testing.expectEqual(h1, h2);
}

test "BlockLayout: pinAtBlockRow" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    _ = try bl.addBlock(.{ .node = node, .y = 0 });
    _ = try bl.addBlock(.{ .node = node, .y = 6 });

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    var config = testConfig();
    config.active_block_cursor_row = 5;
    layout.setConfig(config);
    layout.ensureValid();

    // Row 0 of block 0 should be at y=0.
    const p0 = layout.pinAtBlockRow(0, 0);
    try testing.expect(p0 != null);
    try testing.expectEqual(@as(size.CellCountInt, 0), p0.?.y);

    // Row 3 of block 0 should be at y=3.
    const p3 = layout.pinAtBlockRow(0, 3);
    try testing.expect(p3 != null);
    try testing.expectEqual(@as(size.CellCountInt, 3), p3.?.y);

    // Row 0 of block 1 should be at y=6.
    const p1_0 = layout.pinAtBlockRow(1, 0);
    try testing.expect(p1_0 != null);
    try testing.expectEqual(@as(size.CellCountInt, 6), p1_0.?.y);
}

test "BlockLayout: tall content scrolling math" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    // Create 3 completed blocks + active, each using 6 rows = 24 rows total.
    _ = try bl.addBlock(.{ .node = node, .y = 0 });
    _ = try bl.addBlock(.{ .node = node, .y = 6 });
    _ = try bl.addBlock(.{ .node = node, .y = 12 });
    _ = try bl.addBlock(.{ .node = node, .y = 18 });

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    var config = testConfig();
    config.active_block_cursor_row = 5; // 6 rows in active
    layout.setConfig(config);

    // 3 completed blocks: 6 rows = 96px each, + 22px gap = 118px extent
    // Active block: 6 rows = 96px, no gap
    // Total: 3 * 118 + 96 = 450px
    const doc_h = layout.totalDocHeightPx();
    try testing.expectEqual(@as(u32, 450), doc_h);

    // Viewport = 10 rows * 16 = 160px (small viewport)
    const viewport_h: u32 = 160;
    // max_scroll = 450 - 160 = 290px
    const max_scroll = doc_h -| viewport_h;
    try testing.expectEqual(@as(u32, 290), max_scroll);

    // Verify blocks are positioned correctly.
    const b0 = layout.blockAt(0).?;
    try testing.expectEqual(@as(u32, 0), b0.virtual_y_px);
    try testing.expectEqual(@as(u32, 96), b0.visible_height_px);

    const b1 = layout.blockAt(1).?;
    try testing.expectEqual(@as(u32, 118), b1.virtual_y_px);

    const b2 = layout.blockAt(2).?;
    try testing.expectEqual(@as(u32, 236), b2.virtual_y_px);

    const b3 = layout.blockAt(3).?;
    try testing.expectEqual(@as(u32, 354), b3.virtual_y_px);
}

test "BlockLayout: collapse reduces document height" {
    var s = try Screen.init(testing.allocator, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    var bl = Block.BlockList.init(testing.allocator, &s.pages);
    defer bl.deinit();

    const node = s.pages.pages.first.?;
    _ = try bl.addBlock(.{ .node = node, .y = 0 });
    _ = try bl.addBlock(.{ .node = node, .y = 6 });
    _ = try bl.addBlock(.{ .node = node, .y = 12 });

    var layout = BlockLayout.init(testing.allocator, &bl);
    defer layout.deinit();

    var config = testConfig();
    config.active_block_cursor_row = 5;
    layout.setConfig(config);

    const expanded_h = layout.totalDocHeightPx();

    // Collapse block 1 (6 rows → 1 visible row).
    bl.blocks.items[1].collapsed = true;
    layout.invalidate();

    const collapsed_h = layout.totalDocHeightPx();

    // Savings = (6 - 1) * 16 = 80px.
    try testing.expectEqual(expanded_h - 80, collapsed_h);

    // Block 2 should have moved up by the savings.
    const b2 = layout.blockAt(2).?;
    const b2_expanded_y: u32 = 118 + 96 + 22; // b0 extent + b1 visible + gap
    try testing.expect(b2.virtual_y_px < b2_expanded_y);
}
