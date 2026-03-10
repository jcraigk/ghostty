const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const fastmem = @import("../fastmem.zig");
const color = @import("color.zig");
const cursor = @import("cursor.zig");
const highlight = @import("highlight.zig");
const point = @import("point.zig");
const size = @import("size.zig");
const page = @import("page.zig");
const BlockLayout = @import("BlockLayout.zig");
const PageList = @import("PageList.zig");
const Selection = @import("Selection.zig");
const Screen = @import("Screen.zig");
const ScreenSet = @import("ScreenSet.zig");
const Style = @import("style.zig").Style;
const Terminal = @import("Terminal.zig");

// Developer note: this is in src/terminal and not src/renderer because
// the goal is that this remains generic to multiple renderers. This can
// aid specifically with libghostty-vt with converting terminal state to
// a renderable form.

/// Contains the state required to render the screen, including optimizing
/// for repeated render calls and only rendering dirty regions.
///
/// Previously, our renderer would use `clone` to clone the screen within
/// the viewport to perform rendering. This worked well enough that we kept
/// it all the way up through the Ghostty 1.2.x series, but the clone time
/// was repeatedly a bottleneck blocking IO.
///
/// Rather than a generic clone that tries to clone all screen state per call
/// (within a region), a stateful approach that optimizes for only what a
/// renderer needs to do makes more sense.
///
/// To use this, initialize the render state to empty, then call `update`
/// on each frame to update the state to the latest terminal state.
///
///     var state: RenderState = .empty;
///     defer state.deinit(alloc);
///     state.update(alloc, &terminal);
///
/// Note: the render state retains as much memory as possible between updates
/// to prevent future allocations. If a very large frame is rendered once,
/// the render state will retain that much memory until deinit. To avoid
/// waste, it is recommended that the caller `deinit` and start with an
/// empty render state every so often.
pub const RenderState = struct {
    /// The current screen dimensions. It is possible that these don't match
    /// the renderer's current dimensions in grid cells because resizing
    /// can happen asynchronously. For example, for Metal, our NSView resizes
    /// at a different time than when our internal terminal state resizes.
    /// This can lead to a one or two frame mismatch a renderer needs to
    /// handle.
    ///
    /// The viewport is always exactly equal to the active area size so this
    /// is also the viewport size.
    rows: size.CellCountInt,
    cols: size.CellCountInt,

    /// The color state for the terminal.
    colors: Colors,

    /// Cursor state within the viewport.
    cursor: Cursor,

    /// The rows (y=0 is top) of the viewport. Guaranteed to be `rows` length.
    ///
    /// This is a MultiArrayList because only the update cares about
    /// the allocators. Callers care about all the other properties, and
    /// this better optimizes cache locality for read access for those
    /// use cases.
    row_data: std.MultiArrayList(Row),

    /// The dirty state of the render state. This is set by the update method.
    /// The renderer/caller should set this to false when it has handled
    /// the dirty state.
    dirty: Dirty,

    /// The screen type that this state represents. This is used primarily
    /// to detect changes.
    screen: ScreenSet.Key,

    /// The last viewport pin used to generate this state. This is NOT
    /// a tracked pin and is generally NOT safe to read other than the direct
    /// values for comparison.
    viewport_pin: ?PageList.Pin = null,

    /// Pixel scroll offset for block mode. 0 = following (at bottom).
    /// Positive values = scrolled up by that many pixels in the virtual document.
    scroll_offset_px: u32 = 0,

    /// Snapshot of BlockLayout data for the renderer. Populated from
    /// Terminal.block_layout during update(). This is the single source
    /// of truth for block positioning, exit codes, collapse state, etc.
    block_render_list: std.ArrayListUnmanaged(BlockRenderInfo) = .empty,

    /// Total virtual document height in pixels from BlockLayout.
    total_doc_height_px: u32 = 0,

    /// BlockLayout config snapshot for the renderer.
    block_layout_cell_height: u32 = 0,
    block_layout_gap_px: u32 = 0,

    /// Number of rows actually populated in row_data for block-aware rendering.
    /// When block_layout is active, row_data may hold more or fewer rows than
    /// self.rows (the terminal grid height). The renderer uses this as row_len
    /// instead of self.rows. 0 means use self.rows (standard viewport path).
    block_cell_row_count: u32 = 0,

    /// Temporary buffer used during update() to communicate per-block cell
    /// buffer offsets from populateBlockRows to the block_render_list builder.
    block_render_info_buf: std.ArrayListUnmanaged(BlockCellBufInfo) = .empty,

    /// Index into BlockList.blocks of the highlighted block, or null
    /// if no block is currently highlighted. Matches Terminal.highlighted_block_idx.
    highlighted_block_idx: ?usize = null,

    /// Index into BlockList.blocks of the block under the mouse cursor,
    /// or null if the mouse is not over any completed block.
    hovered_block_idx: ?usize = null,

    /// Index of the toolbar icon under the mouse cursor (0-based in display
    /// order), or null if not hovering over any icon.
    hovered_toolbar_icon: ?u32 = null,

    /// Index of the toolbar icon currently pressed (for click highlight).
    pressed_toolbar_icon: ?u32 = null,

    /// Block index that currently has active filter input, or null.
    filter_input_block_idx: ?usize = null,
    /// The current filter input text (snapshot from Terminal).
    filter_input_text: std.ArrayListUnmanaged(u8) = .empty,

    /// The cached selection so we can avoid expensive selection calculations
    /// if possible.
    selection_cache: ?SelectionCache = null,

    /// Initial state.
    pub const empty: RenderState = .{
        .rows = 0,
        .cols = 0,
        .colors = .{
            .background = .{},
            .foreground = .{},
            .cursor = null,
            .palette = color.default,
        },
        .cursor = .{
            .active = .{ .x = 0, .y = 0 },
            .viewport = null,
            .cell = .{},
            .style = undefined,
            .visual_style = .block,
            .password_input = false,
            .visible = true,
            .blinking = false,
        },
        .row_data = .empty,
        .dirty = .false,
        .screen = .primary,
    };

    /// The color state for the terminal.
    ///
    /// The background/foreground will be reversed if the terminal reverse
    /// color mode is on! You do not need to handle that manually!
    pub const Colors = struct {
        background: color.RGB,
        foreground: color.RGB,
        cursor: ?color.RGB,
        palette: color.Palette,
    };

    pub const Cursor = struct {
        /// The x/y position of the cursor within the active area.
        active: point.Coordinate,

        /// The x/y position of the cursor within the viewport. This
        /// may be null if the cursor is not visible within the viewport.
        viewport: ?Viewport,

        /// The cell data for the cursor position. Managed memory is not
        /// safe to access from this.
        cell: page.Cell,

        /// The style, always valid even if the cell is default style.
        style: Style,

        /// The visual style of the cursor itself, such as a block or
        /// bar.
        visual_style: cursor.Style,

        /// True if the cursor is detected to be at a password input field.
        password_input: bool,

        /// Cursor visibility state determined by the terminal mode.
        visible: bool,

        /// Cursor blink state determined by the terminal mode.
        blinking: bool,

        pub const Viewport = struct {
            /// The x/y position of the cursor within the viewport.
            x: size.CellCountInt,
            y: size.CellCountInt,

            /// Whether the cursor is part of a wide character and
            /// on the tail of it. If so, some renderers may use this
            /// to move the cursor back one.
            wide_tail: bool,
        };
    };

    /// A row within the viewport.
    pub const Row = struct {
        /// Arena used for any heap allocations for cell contents
        /// in this row. Importantly, this is NOT used for the MultiArrayList
        /// itself. We do this on purpose so that we can easily clear rows,
        /// but retain cached MultiArrayList capacities since grid sizes don't
        /// change often.
        arena: ArenaAllocator.State,

        /// The page pin. This is not safe to read unless you can guarantee
        /// the terminal state hasn't changed since the last `update` call.
        pin: PageList.Pin,

        /// Raw row data.
        raw: page.Row,

        /// The cells in this row. Guaranteed to be `cols` length.
        cells: std.MultiArrayList(Cell),

        /// A dirty flag that can be used by the renderer to track
        /// its own draw state. `update` will mark this true whenever
        /// this row is changed, too.
        dirty: bool,

        /// The x range of the selection within this row.
        selection: ?[2]size.CellCountInt,

        /// The highlights within this row.
        highlights: std.ArrayList(Highlight),
    };

    pub const Highlight = struct {
        /// A special tag that can be used by the caller to differentiate
        /// different highlight types. The value is opaque to the RenderState.
        tag: u8,

        /// The x ranges of highlights within this row.
        range: [2]size.CellCountInt,
    };

    pub const Cell = struct {
        /// Always set, this is the raw copied cell data from page.Cell.
        /// The managed memory (hyperlinks, graphames, etc.) is NOT safe
        /// to access from here. It is duplicated into the other fields if
        /// it exists.
        raw: page.Cell,

        /// Grapheme data for the cell. This is undefined unless the
        /// raw cell's content_tag is `codepoint_grapheme`.
        grapheme: []const u21,

        /// The style data for the cell. This is undefined unless
        /// the style_id is non-default on raw.
        style: Style,
    };

    // Dirty state
    pub const Dirty = enum {
        /// Not dirty at all. Can skip rendering if prior state was
        /// already rendered.
        false,

        /// Partially dirty. Some rows changed but not all. None of the
        /// global state changed such as colors.
        partial,

        /// Fully dirty. Global state changed or dimensions changed. All rows
        /// should be redrawn.
        full,
    };

    /// Snapshot of a single block's layout info for the renderer.
    /// Copied from BlockLayout.BlockLayoutInfo during update() so the
    /// renderer can read it outside the terminal mutex.
    pub const BlockRenderInfo = struct {
        /// Absolute pixel Y in the virtual document where content starts.
        virtual_y_px: u32,
        /// Visible content height in pixels.
        visible_height_px: u32,
        /// Number of visible content rows.
        visible_rows: u32,
        /// Total content rows (before collapse).
        total_rows: u32,
        /// Prompt/input rows before output_start.
        output_row_offset: u16,
        /// Exit code (-1 = running/unknown).
        exit_code: i32,
        /// Whether collapsed.
        collapsed: bool,
        /// Index into BlockList.blocks (stable).
        block_list_index: usize,
        /// The prompt_start pin for row data access.
        prompt_start_pin: PageList.Pin,
        /// Total extent including trailing gap.
        total_extent_px: u32,
        /// Whether this block has an active filter.
        filtered: bool = false,
        /// Matched output row indices when filtered (0-based from output_start).
        filter_match_rows: ?[]const u32 = null,
        /// First row of this block in the cell buffer (viewport-relative).
        /// Set to max(u16) if the block's prompt_start is not in the viewport.
        viewport_first_row: u16 = std.math.maxInt(u16),
        /// Number of rows populated in the cell buffer for this block.
        viewport_row_count: u16 = 0,
        /// Number of rows skipped at top due to viewport clipping.
        viewport_rows_skipped_top: u16 = 0,

        pub fn hiddenLines(self: BlockRenderInfo) u32 {
            return self.total_rows -| self.visible_rows;
        }
    };

    const SelectionCache = struct {
        selection: Selection,
        tl_pin: PageList.Pin,
        br_pin: PageList.Pin,
    };

    /// Per-block cell buffer mapping computed by populateBlockRows.
    pub const BlockCellBufInfo = struct {
        /// Index into BlockLayout.block_offsets / block_render_list.
        layout_idx: usize,
        /// First row in the cell buffer for this block's content.
        cell_buf_row: u16,
        /// Number of rows populated for this block.
        row_count: u16,
        /// Number of rows skipped at the top (for partial clip above viewport).
        rows_skipped_top: u16,
    };

    pub fn deinit(self: *RenderState, alloc: Allocator) void {
        for (
            self.row_data.items(.arena),
            self.row_data.items(.cells),
        ) |state, *cells| {
            var arena: ArenaAllocator = state.promote(alloc);
            arena.deinit();
            cells.deinit(alloc);
        }
        self.row_data.deinit(alloc);
        self.block_render_list.deinit(alloc);
        self.block_render_info_buf.deinit(alloc);
        self.filter_input_text.deinit(alloc);
    }

    /// Update the render state to the latest terminal state.
    ///
    /// This will reset the terminal dirty state since it is consumed
    /// by this render state update.
    pub fn update(
        self: *RenderState,
        alloc: Allocator,
        t: *Terminal,
    ) Allocator.Error!void {
        const s: *Screen = t.screens.active;
        const viewport_pin = s.pages.getTopLeft(.viewport);
        const redraw = redraw: {
            // If our screen key changed, we need to do a full rebuild
            // because our render state is viewport-specific.
            if (t.screens.active_key != self.screen) break :redraw true;

            // If our terminal is dirty at all, we do a full rebuild. These
            // dirty values are full-terminal dirty values.
            {
                const Int = @typeInfo(Terminal.Dirty).@"struct".backing_integer.?;
                const v: Int = @bitCast(t.flags.dirty);
                if (v > 0) break :redraw true;
            }

            // If our screen is dirty at all, we do a full rebuild. This is
            // a full screen dirty tracker.
            {
                const Int = @typeInfo(Screen.Dirty).@"struct".backing_integer.?;
                const v: Int = @bitCast(t.screens.active.dirty);
                if (v > 0) break :redraw true;
            }

            // If our dimensions changed, we do a full rebuild.
            if (self.rows != s.pages.rows or
                self.cols != s.pages.cols)
            {
                break :redraw true;
            }

            // If our viewport pin changed, we do a full rebuild.
            if (self.viewport_pin) |old| {
                if (!old.eql(viewport_pin)) break :redraw true;
            }

            // If the block scroll offset changed, we need a full rebuild
            // because block-aware row population depends on scroll position.
            if (t.block_layout != null and self.scroll_offset_px != t.scroll_offset_px) {
                break :redraw true;
            }

            break :redraw false;
        };

        // Always set our cheap fields, its more expensive to compare
        self.rows = s.pages.rows;
        self.cols = s.pages.cols;
        self.viewport_pin = viewport_pin;
        self.cursor.active = .{ .x = s.cursor.x, .y = s.cursor.y };
        self.cursor.cell = s.cursor.page_cell.*;
        self.cursor.style = s.cursor.style;
        self.cursor.visual_style = s.cursor.cursor_style;
        self.cursor.password_input = t.flags.password_input;
        self.cursor.visible = t.modes.get(.cursor_visible);
        self.cursor.blinking = t.modes.get(.cursor_blinking);

        // Always reset the cursor viewport position. In the future we can
        // probably cache this by comparing the cursor pin and viewport pin
        // but may not be worth it.
        self.cursor.viewport = null;

        // Colors.
        self.colors.cursor = t.colors.cursor.get();
        self.colors.palette = t.colors.palette.current;
        bg_fg: {
            // Background/foreground can be unset initially which would
            // depend on "default" background/foreground. The expected use
            // case of Terminal is that the caller set their own configured
            // defaults on load so this doesn't happen.
            const bg = t.colors.background.get() orelse break :bg_fg;
            const fg = t.colors.foreground.get() orelse break :bg_fg;
            if (t.modes.get(.reverse_colors)) {
                self.colors.background = fg;
                self.colors.foreground = bg;
            } else {
                self.colors.background = bg;
                self.colors.foreground = fg;
            }
        }

        // Determine the number of rows to populate in the cell buffer.
        // When block_layout is active, we populate rows from block pins
        // (decoupled from the PageList viewport) to enable true per-pixel
        // smooth scrolling. The cell buffer size may differ from self.rows.
        const use_block_rows = t.block_layout != null;
        const needed_rows: size.CellCountInt = if (use_block_rows)
            self.blockCellRowCount(t)
        else
            self.rows;

        // Ensure our row length matches what we need.
        if (self.row_data.len != needed_rows) {
            @branchHint(.unlikely);

            if (self.row_data.len < needed_rows) {
                const old_len = self.row_data.len;
                try self.row_data.resize(alloc, needed_rows);

                var row_data = self.row_data.slice();
                for (old_len..needed_rows) |y| {
                    row_data.set(y, .{
                        .arena = .{},
                        .pin = undefined,
                        .raw = undefined,
                        .cells = .empty,
                        .dirty = true,
                        .selection = null,
                        .highlights = .empty,
                    });
                }
            } else {
                const row_data = self.row_data.slice();
                for (
                    row_data.items(.arena)[needed_rows..],
                    row_data.items(.cells)[needed_rows..],
                ) |state, *cell| {
                    var arena: ArenaAllocator = state.promote(alloc);
                    arena.deinit();
                    cell.deinit(alloc);
                }
                self.row_data.shrinkRetainingCapacity(needed_rows);
            }
        }

        // Break down our row data
        const row_data = self.row_data.slice();
        const row_arenas = row_data.items(.arena);
        const row_pins = row_data.items(.pin);
        const row_rows = row_data.items(.raw);
        const row_cells = row_data.items(.cells);
        const row_sels = row_data.items(.selection);
        const row_highlights = row_data.items(.highlights);
        const row_dirties = row_data.items(.dirty);

        var any_dirty: bool = false;
        var last_dirty_page: ?*page.Page = null;

        if (use_block_rows) {
            // ── Block-aware row population ──────────────────────────────
            // Populate row_data directly from block pins, decoupled from
            // the PageList viewport. This enables true per-pixel scrolling
            // because the cell buffer contains exactly the rows needed by
            // each visible block (including +1 partial rows for clipping).
            any_dirty = try self.populateBlockRows(
                alloc,
                t,
                redraw,
                needed_rows,
                row_arenas,
                row_pins,
                row_rows,
                row_cells,
                row_sels,
                row_highlights,
                row_dirties,
                s,
            );
        } else {
            // ── Standard viewport row population (unchanged) ───────────

            // Go through and setup our rows.
            var row_it = s.pages.rowIterator(
                .right_down,
                .{ .viewport = .{} },
                null,
            );
            var y: size.CellCountInt = 0;
            while (row_it.next()) |row_pin| : (y = y + 1) {
                // Find our cursor if we haven't found it yet.
                if (self.cursor.viewport == null and
                    row_pin.node == s.cursor.page_pin.node and
                    row_pin.y == s.cursor.page_pin.y)
                {
                    self.cursor.viewport = .{
                        .y = y,
                        .x = s.cursor.x,
                        .wide_tail = if (s.cursor.x > 0)
                            s.cursorCellLeft(1).wide == .wide
                        else
                            false,
                    };
                }

                row_pins[y] = row_pin;

                const p: *page.Page = &row_pin.node.data;
                const page_rac = row_pin.rowAndCell();

                dirty: {
                    if (redraw) break :dirty;
                    if (p == last_dirty_page) break :dirty;
                    if (p.dirty) {
                        if (last_dirty_page) |last_p| last_p.dirty = false;
                        last_dirty_page = p;
                        break :dirty;
                    }
                    if (page_rac.row.dirty) break :dirty;
                    continue;
                }

                any_dirty = true;
                page_rac.row.dirty = false;

                var arena = row_arenas[y].promote(alloc);
                defer row_arenas[y] = arena.state;

                if (row_cells[y].len > 0) {
                    _ = arena.reset(.retain_capacity);
                    row_cells[y].clearRetainingCapacity();
                    row_sels[y] = null;
                    row_highlights[y] = .empty;
                }
                row_dirties[y] = true;

                const page_cells: []const page.Cell = p.getCells(page_rac.row);
                assert(page_cells.len == self.cols);
                row_rows[y] = page_rac.row.*;

                const cells: *std.MultiArrayList(Cell) = &row_cells[y];
                try cells.resize(alloc, self.cols);

                const cells_slice = cells.slice();
                fastmem.copy(
                    page.Cell,
                    cells_slice.items(.raw),
                    page_cells,
                );
                if (!page_rac.row.managedMemory()) continue;

                const arena_alloc = arena.allocator();
                const cells_grapheme = cells_slice.items(.grapheme);
                const cells_style = cells_slice.items(.style);
                for (page_cells, 0..) |*page_cell, x| {
                    if (page_cell.style_id > 0) cells_style[x] = p.styles.get(
                        p.memory,
                        page_cell.style_id,
                    ).*;

                    switch (page_cell.content_tag) {
                        .codepoint => {
                            @branchHint(.likely);
                        },
                        .codepoint_grapheme => {
                            @branchHint(.unlikely);
                            cells_grapheme[x] = try arena_alloc.dupe(
                                u21,
                                p.lookupGrapheme(page_cell) orelse &.{},
                            );
                        },
                        .bg_color_rgb => {
                            @branchHint(.unlikely);
                            cells_style[x] = .{ .bg_color = .{ .rgb = .{
                                .r = page_cell.content.color_rgb.r,
                                .g = page_cell.content.color_rgb.g,
                                .b = page_cell.content.color_rgb.b,
                            } } };
                        },
                        .bg_color_palette => {
                            @branchHint(.unlikely);
                            cells_style[x] = .{ .bg_color = .{
                                .palette = page_cell.content.color_palette,
                            } };
                        },
                    }
                }
            }
            assert(y == self.rows);
        }

        // Pass per-pixel scroll offset for block mode.
        self.scroll_offset_px = t.scroll_offset_px;

        // Snapshot BlockLayout data and detect highlight/collapse changes.
        if (t.block_layout) |*layout| {
            layout.ensureValid();
            const src = layout.block_offsets.items;

            // Detect highlight changes.
            const prev_highlighted = self.highlighted_block_idx;
            self.highlighted_block_idx = t.highlighted_block_idx;
            if (!std.meta.eql(prev_highlighted, self.highlighted_block_idx)) {
                self.dirty = .full;
            }

            // Detect hover changes (for toolbar rendering).
            const prev_hovered = self.hovered_block_idx;
            self.hovered_block_idx = t.hovered_block_idx;
            const prev_hovered_icon = self.hovered_toolbar_icon;
            self.hovered_toolbar_icon = t.hovered_toolbar_icon;
            if (!std.meta.eql(prev_hovered, self.hovered_block_idx) or
                !std.meta.eql(prev_hovered_icon, self.hovered_toolbar_icon))
            {
                self.dirty = .full;
            }

            // Pressed icon state for click highlight.
            const prev_pressed = self.pressed_toolbar_icon;
            self.pressed_toolbar_icon = t.pressed_toolbar_icon;
            if (!std.meta.eql(prev_pressed, self.pressed_toolbar_icon)) {
                self.dirty = .full;
            }

            // Filter input state.
            const prev_filter_idx = self.filter_input_block_idx;
            self.filter_input_block_idx = t.filter_input_block_idx;
            {
                const text = t.filter_input_buf.items;
                if (!std.mem.eql(u8, self.filter_input_text.items, text)) {
                    self.filter_input_text.clearRetainingCapacity();
                    self.filter_input_text.appendSlice(alloc, text) catch {};
                    self.dirty = .full;
                } else if (!std.meta.eql(prev_filter_idx, self.filter_input_block_idx)) {
                    self.dirty = .full;
                }
            }

            // Detect collapsed state or visible row count changes by comparing
            // against previous snapshot. visible_rows changes when the active
            // block grows (e.g., continuation lines), which requires a full
            // rebuild so cell buffer slots get refreshed with correct row data.
            const prev = self.block_render_list.items;
            if (prev.len == src.len) {
                for (prev, src) |old, new| {
                    if (old.collapsed != new.collapsed or old.visible_rows != new.visible_rows) {
                        self.dirty = .full;
                        break;
                    }
                }
            } else if (prev.len > 0) {
                self.dirty = .full;
            }

            // Copy layout data to block_render_list.
            // viewport_first_row is assigned by populateBlockRows (contiguous
            // cell buffer offsets) when block-aware rows are active. For the
            // fallback path, compute from PageList viewport coordinates.
            self.block_render_list.clearRetainingCapacity();
            self.block_render_list.ensureTotalCapacity(alloc, src.len) catch {};

            if (use_block_rows) {
                // Block-aware path: viewport_first_row was already set by
                // populateBlockRows via block_render_info_buf. Copy here.
                for (src) |info| {
                    self.block_render_list.append(alloc, .{
                        .virtual_y_px = info.virtual_y_px,
                        .visible_height_px = info.visible_height_px,
                        .visible_rows = info.visible_rows,
                        .total_rows = info.total_rows,
                        .output_row_offset = info.output_row_offset,
                        .exit_code = info.exit_code,
                        .collapsed = info.collapsed,
                        .block_list_index = info.block_list_index,
                        .prompt_start_pin = info.prompt_start_pin,
                        .total_extent_px = info.total_extent_px,
                        .filtered = info.filtered,
                        .filter_match_rows = info.filter_match_rows,
                        // Will be overwritten below from block_render_info_buf
                        .viewport_first_row = std.math.maxInt(u16),
                    }) catch {};
                }
                // Overwrite viewport_first_row for visible blocks from our
                // pre-computed buffer. populateBlockRows stored these in
                // block_render_info_buf keyed by layout index.
                for (self.block_render_info_buf.items) |bri| {
                    if (bri.layout_idx < self.block_render_list.items.len) {
                        self.block_render_list.items[bri.layout_idx].viewport_first_row = bri.cell_buf_row;
                        self.block_render_list.items[bri.layout_idx].viewport_row_count = bri.row_count;
                        self.block_render_list.items[bri.layout_idx].viewport_rows_skipped_top = bri.rows_skipped_top;
                    }
                }
            } else {
                // Standard path: compute viewport_first_row from PageList viewport.
                const vp_screen_y: usize = if (s.pages.pointFromPin(.screen, viewport_pin)) |pt|
                    pt.screen.y
                else
                    0;

                for (src) |info| {
                    const vp_row: u16 = vp_row_calc: {
                        const screen_pt = s.pages.pointFromPin(.screen, info.prompt_start_pin) orelse
                            break :vp_row_calc std.math.maxInt(u16);
                        const block_screen_y: usize = screen_pt.screen.y;
                        if (block_screen_y >= vp_screen_y) {
                            const offset = block_screen_y - vp_screen_y;
                            if (offset >= self.rows) {
                                break :vp_row_calc std.math.maxInt(u16);
                            }
                            break :vp_row_calc @intCast(@min(offset, std.math.maxInt(u16) - 1));
                        } else {
                            break :vp_row_calc 0;
                        }
                    };

                    self.block_render_list.append(alloc, .{
                        .virtual_y_px = info.virtual_y_px,
                        .visible_height_px = info.visible_height_px,
                        .visible_rows = info.visible_rows,
                        .total_rows = info.total_rows,
                        .output_row_offset = info.output_row_offset,
                        .exit_code = info.exit_code,
                        .collapsed = info.collapsed,
                        .block_list_index = info.block_list_index,
                        .prompt_start_pin = info.prompt_start_pin,
                        .total_extent_px = info.total_extent_px,
                        .filtered = info.filtered,
                        .filter_match_rows = info.filter_match_rows,
                        .viewport_first_row = vp_row,
                    }) catch {};
                }
            }
            self.total_doc_height_px = layout.total_height_px;
            self.block_layout_cell_height = layout.config.cell_height;
            self.block_layout_gap_px = layout.config.gapPx();
        } else {
            self.highlighted_block_idx = null;
            self.hovered_block_idx = null;
            self.hovered_toolbar_icon = null;
            self.pressed_toolbar_icon = null;
            self.filter_input_block_idx = null;
            self.filter_input_text.clearRetainingCapacity();
            self.block_render_list.clearRetainingCapacity();
            self.block_render_info_buf.clearRetainingCapacity();
            self.block_cell_row_count = 0;
            self.total_doc_height_px = 0;
            self.block_layout_cell_height = 0;
            self.block_layout_gap_px = 0;
        }

        // If our screen has a selection, then mark the rows with the
        // selection. We do this outside of the loop above because its unlikely
        // a selection exists and because the way our selections are structured
        // today is very inefficient.
        //
        // NOTE: To improve the performance of the block below, we'll need
        // to rethink how we model selections in general.
        //
        // There are performance improvements that can be made here, though.
        // For example, `containedRow` recalculates a bunch of information
        // we can cache.
        if (s.selection) |*sel| selection: {
            @branchHint(.unlikely);

            // Populate our selection cache to avoid some expensive
            // recalculation.
            const cache: *const SelectionCache = cache: {
                if (self.selection_cache) |*c| cache_check: {
                    // If we're redrawing, we recalculate the cache just to
                    // be safe.
                    if (redraw) break :cache_check;

                    // If our selection isn't equal, we aren't cached!
                    if (!c.selection.eql(sel.*)) break :cache_check;

                    // If we have no dirty rows, we can not recalculate.
                    if (!any_dirty) break :selection;

                    // We have dirty rows, we can utilize the cache.
                    break :cache c;
                }

                // Create a new cache
                const tl_pin = sel.topLeft(s);
                const br_pin = sel.bottomRight(s);
                self.selection_cache = .{
                    .selection = .init(tl_pin, br_pin, sel.rectangle),
                    .tl_pin = tl_pin,
                    .br_pin = br_pin,
                };
                break :cache &self.selection_cache.?;
            };

            // Grab the inefficient data we need from the selection. At
            // least we can cache it.
            const tl = s.pages.pointFromPin(.screen, cache.tl_pin).?.screen;
            const br = s.pages.pointFromPin(.screen, cache.br_pin).?.screen;

            // We need to determine if our selection is within the viewport.
            // The viewport is generally very small so the efficient way to
            // do this is to traverse the viewport pages and check for the
            // matching selection pages.
            for (
                row_pins,
                row_sels,
            ) |pin, *sel_bounds| {
                const p = s.pages.pointFromPin(.screen, pin).?.screen;
                const row_sel = sel.containedRowCached(
                    s,
                    cache.tl_pin,
                    cache.br_pin,
                    pin,
                    tl,
                    br,
                    p,
                ) orelse continue;
                const start = row_sel.start();
                const end = row_sel.end();
                assert(start.node == end.node);
                assert(start.x <= end.x);
                assert(start.y == end.y);
                sel_bounds.* = .{ start.x, end.x };
            }
        }

        // Handle dirty state.
        if (redraw) {
            // Fully redraw resets some other state.
            self.screen = t.screens.active_key;
            self.dirty = .full;

            // Note: we don't clear any row_data here because our rebuild
            // above did this.
        } else if (any_dirty and self.dirty == .false) {
            self.dirty = .partial;
        }

        // Finalize our final dirty page
        if (last_dirty_page) |last_p| last_p.dirty = false;

        // Clear our dirty flags
        t.flags.dirty = .{};
        s.dirty = .{};
    }

    /// Compute the total number of cell buffer rows needed for block-aware
    /// rendering. For each visible block, we include all rows from the first
    /// partially-visible row to the end of the block. Rows below the viewport
    /// are kept in the buffer (clipped by the GPU scissor rect) to avoid
    /// grey/empty row artifacts.
    fn blockCellRowCount(self: *const RenderState, t: *Terminal) size.CellCountInt {
        const layout = &(t.block_layout orelse return self.rows);
        layout.ensureValid();

        const cell_h = layout.config.cell_height;
        if (cell_h == 0) return self.rows;

        const doc_h = layout.total_height_px;
        const viewport_h = t.height_px;
        const scroll_px = t.scroll_offset_px;

        // Extend viewport by one cell_h on each side to cover window padding.
        // The renderer's visible area includes padding_top above and padding_bottom
        // below the grid area, so we need those rows in the cell buffer.
        const extended_top: u32 = if (doc_h > viewport_h + scroll_px + cell_h)
            doc_h - viewport_h - scroll_px - cell_h
        else
            0;
        const extended_h: u32 = viewport_h + cell_h * 2;

        const range = layout.viewportBlockRange(extended_top, extended_h);
        const items = layout.block_offsets.items;

        var total: u32 = 0;
        for (items[range.start_idx..@min(range.end_idx, items.len)]) |info| {
            const px_above: u32 = if (info.virtual_y_px < extended_top)
                extended_top - info.virtual_y_px
            else
                0;
            const rows_skip: u32 = if (cell_h > 0) px_above / cell_h else 0;
            const rows_in_buffer: u32 = info.visible_rows -| rows_skip;
            total += rows_in_buffer;
        }

        // Ensure at least self.rows so the cell buffer is never smaller than
        // the grid (needed for cursor rendering and scratch row indexing).
        // Clamp to a reasonable size. The renderer can handle at most u16 rows.
        return @intCast(@min(@max(total, self.rows), std.math.maxInt(size.CellCountInt)));
    }

    /// Populate row_data from block pins for all visible blocks.
    /// Returns true if any rows were dirty.
    ///
    /// This decouples cell buffer population from the PageList viewport,
    /// enabling true per-pixel smooth scrolling. Each visible block's rows
    /// are placed contiguously in the cell buffer. The block_render_info_buf
    /// records the cell buffer offset for each block so the renderer knows
    /// where each block's data starts.
    fn populateBlockRows(
        self: *RenderState,
        alloc: Allocator,
        t: *Terminal,
        redraw: bool,
        needed_rows: size.CellCountInt,
        row_arenas: []ArenaAllocator.State,
        row_pins: []PageList.Pin,
        row_rows: []page.Row,
        row_cells: []std.MultiArrayList(Cell),
        row_sels: []?[2]size.CellCountInt,
        row_highlights: []std.ArrayList(Highlight),
        row_dirties: []bool,
        s: *Screen,
    ) Allocator.Error!bool {
        const layout = &(t.block_layout orelse return false);
        layout.ensureValid();

        const cell_h = layout.config.cell_height;
        if (cell_h == 0) return false;

        const doc_h = layout.total_height_px;
        const viewport_h = t.height_px;
        const scroll_px = t.scroll_offset_px;

        // Extend viewport by one cell_h on each side to cover window padding.
        // The renderer's visible area includes padding_top above and padding_bottom
        // below the grid area, so we need those rows in the cell buffer.
        const extended_top: u32 = if (doc_h > viewport_h + scroll_px + cell_h)
            doc_h - viewport_h - scroll_px - cell_h
        else
            0;
        const extended_h: u32 = viewport_h + cell_h * 2;

        const range = layout.viewportBlockRange(extended_top, extended_h);
        const items = layout.block_offsets.items;

        self.block_render_info_buf.clearRetainingCapacity();
        self.block_cell_row_count = 0;

        var cell_buf_offset: u16 = 0;
        var any_dirty: bool = false;

        for (items[range.start_idx..@min(range.end_idx, items.len)], range.start_idx..) |info, layout_idx| {
            // Skip rows fully above the extended viewport. Floor division means
            // the partially-visible row at the boundary is always included.
            const px_above: u32 = if (info.virtual_y_px < extended_top)
                extended_top - info.virtual_y_px
            else
                0;
            const rows_skip_top: u32 = if (cell_h > 0) px_above / cell_h else 0;

            const rows_in_buffer: u16 = @intCast(@min(
                info.visible_rows -| rows_skip_top,
                @as(u32, needed_rows) -| @as(u32, cell_buf_offset),
            ));

            if (rows_in_buffer == 0) continue;

            // Record this block's cell buffer mapping.
            self.block_render_info_buf.append(alloc, .{
                .layout_idx = layout_idx,
                .cell_buf_row = cell_buf_offset,
                .row_count = rows_in_buffer,
                .rows_skipped_top = @intCast(@min(rows_skip_top, std.math.maxInt(u16))),
            }) catch {};

            // Iterate rows from the block's pin, starting at rows_skip_top.
            const block_idx = info.block_list_index;
            if (layout.pinAtBlockRow(block_idx, rows_skip_top)) |start_pin| {
                var row_it = start_pin.rowIterator(.right_down, null);
                var local: u16 = 0;
                while (row_it.next()) |row_pin| {
                    if (local >= rows_in_buffer) break;
                    const y = cell_buf_offset + local;
                    if (y >= needed_rows) break;

                    // Check for cursor in this row.
                    if (self.cursor.viewport == null and
                        row_pin.node == s.cursor.page_pin.node and
                        row_pin.y == s.cursor.page_pin.y)
                    {
                        self.cursor.viewport = .{
                            .y = y,
                            .x = s.cursor.x,
                            .wide_tail = if (s.cursor.x > 0)
                                s.cursorCellLeft(1).wide == .wide
                            else
                                false,
                        };
                    }

                    row_pins[y] = row_pin;

                    const p_page: *page.Page = &row_pin.node.data;
                    const page_rac = row_pin.rowAndCell();

                    // For block-aware path, always treat as dirty on redraw
                    // (block rows may have shifted in the cell buffer).
                    const is_dirty = redraw or p_page.dirty or page_rac.row.dirty;

                    if (is_dirty) {
                        any_dirty = true;
                        page_rac.row.dirty = false;

                        var arena = row_arenas[y].promote(alloc);
                        defer row_arenas[y] = arena.state;

                        if (row_cells[y].len > 0) {
                            _ = arena.reset(.retain_capacity);
                            row_cells[y].clearRetainingCapacity();
                            row_sels[y] = null;
                            row_highlights[y] = .empty;
                        }
                        row_dirties[y] = true;

                        const page_cells: []const page.Cell = p_page.getCells(page_rac.row);
                        if (page_cells.len == self.cols) {
                            row_rows[y] = page_rac.row.*;

                            const cells: *std.MultiArrayList(Cell) = &row_cells[y];
                            try cells.resize(alloc, self.cols);

                            const cells_slice = cells.slice();
                            fastmem.copy(
                                page.Cell,
                                cells_slice.items(.raw),
                                page_cells,
                            );

                            if (page_rac.row.managedMemory()) {
                                const arena_alloc = arena.allocator();
                                const cells_grapheme = cells_slice.items(.grapheme);
                                const cells_style = cells_slice.items(.style);
                                for (page_cells, 0..) |*page_cell, x| {
                                    if (page_cell.style_id > 0) cells_style[x] = p_page.styles.get(
                                        p_page.memory,
                                        page_cell.style_id,
                                    ).*;

                                    switch (page_cell.content_tag) {
                                        .codepoint => {},
                                        .codepoint_grapheme => {
                                            cells_grapheme[x] = try arena_alloc.dupe(
                                                u21,
                                                p_page.lookupGrapheme(page_cell) orelse &.{},
                                            );
                                        },
                                        .bg_color_rgb => {
                                            cells_style[x] = .{ .bg_color = .{ .rgb = .{
                                                .r = page_cell.content.color_rgb.r,
                                                .g = page_cell.content.color_rgb.g,
                                                .b = page_cell.content.color_rgb.b,
                                            } } };
                                        },
                                        .bg_color_palette => {
                                            cells_style[x] = .{ .bg_color = .{
                                                .palette = page_cell.content.color_palette,
                                            } };
                                        },
                                    }
                                }
                            }
                        }
                    }

                    local += 1;
                }
            }

            cell_buf_offset += rows_in_buffer;
        }

        self.block_cell_row_count = cell_buf_offset;
        return any_dirty;
    }

    /// Update the highlights in the render state from the given flattened
    /// highlights. Because this uses flattened highlights, it does not require
    /// reading from the terminal state so it should be done outside of
    /// any critical sections.
    ///
    /// This will not clear any previous highlights, so the caller must
    /// manually clear them if desired.
    pub fn updateHighlightsFlattened(
        self: *RenderState,
        alloc: Allocator,
        tag: u8,
        hls: []const highlight.Flattened,
    ) Allocator.Error!void {
        // Fast path, we have no highlights!
        if (hls.len == 0) return;

        // This is, admittedly, horrendous. This is some low hanging fruit
        // to optimize. In my defense, screens are usually small, the number
        // of highlights is usually small, and this only happens on the
        // viewport outside of a locked area. Still, I'd love to see this
        // improved someday.

        // We need to track whether any row had a match so we can mark
        // the dirty state.
        var any_dirty: bool = false;

        const row_data = self.row_data.slice();
        const row_arenas = row_data.items(.arena);
        const row_dirties = row_data.items(.dirty);
        const row_pins = row_data.items(.pin);
        const row_highlights_slice = row_data.items(.highlights);
        for (
            row_arenas,
            row_pins,
            row_highlights_slice,
            row_dirties,
        ) |*row_arena, row_pin, *row_highlights, *dirty| {
            for (hls) |hl| {
                const chunks_slice = hl.chunks.slice();
                const nodes = chunks_slice.items(.node);
                const starts = chunks_slice.items(.start);
                const ends = chunks_slice.items(.end);
                for (0.., nodes) |i, node| {
                    // If this node doesn't match or we're not within
                    // the row range, skip it.
                    if (node != row_pin.node or
                        row_pin.y < starts[i] or
                        row_pin.y >= ends[i]) continue;

                    // We're a match!
                    var arena = row_arena.promote(alloc);
                    defer row_arena.* = arena.state;
                    const arena_alloc = arena.allocator();
                    try row_highlights.append(
                        arena_alloc,
                        .{
                            .tag = tag,
                            .range = .{
                                if (i == 0 and
                                    row_pin.y == starts[0])
                                    hl.top_x
                                else
                                    0,
                                if (i == nodes.len - 1 and
                                    row_pin.y == ends[nodes.len - 1] - 1)
                                    hl.bot_x
                                else
                                    self.cols - 1,
                            },
                        },
                    );

                    dirty.* = true;
                    any_dirty = true;
                }
            }
        }

        // Mark our dirty state.
        if (any_dirty and self.dirty == .false) self.dirty = .partial;
    }

    pub const StringMap = std.ArrayListUnmanaged(point.Coordinate);

    /// Convert the current render state contents to a UTF-8 encoded
    /// string written to the given writer. This will unwrap all the wrapped
    /// rows. This is useful for a minimal viewport search.
    ///
    /// This currently writes empty cell contents as \x00 and writes all
    /// blank lines. This is fine for our current usage (link search) but
    /// we can adjust this later.
    ///
    /// NOTE: There is a limitation in that wrapped lines before/after
    /// the the top/bottom line of the viewport are not included, since
    /// the render state cuts them off.
    pub fn string(
        self: *const RenderState,
        writer: *std.Io.Writer,
        map: ?struct {
            alloc: Allocator,
            map: *StringMap,
        },
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        const row_slice = self.row_data.slice();
        const row_rows = row_slice.items(.raw);
        const row_cells = row_slice.items(.cells);

        for (
            0..,
            row_rows,
            row_cells,
        ) |y, row, cells| {
            const cells_slice = cells.slice();
            for (
                0..,
                cells_slice.items(.raw),
                cells_slice.items(.grapheme),
            ) |x, cell, graphemes| {
                var len: usize = std.unicode.utf8CodepointSequenceLength(cell.codepoint()) catch
                    return error.WriteFailed;
                try writer.print("{u}", .{cell.codepoint()});
                if (cell.hasGrapheme()) {
                    for (graphemes) |cp| {
                        len += std.unicode.utf8CodepointSequenceLength(cp) catch
                            return error.WriteFailed;
                        try writer.print("{u}", .{cp});
                    }
                }

                if (map) |m| try m.map.appendNTimes(m.alloc, .{
                    .x = @intCast(x),
                    .y = @intCast(y),
                }, len);
            }

            if (!row.wrap) {
                try writer.writeAll("\n");
                if (map) |m| try m.map.append(m.alloc, .{
                    .x = @intCast(cells_slice.len),
                    .y = @intCast(y),
                });
            }
        }
    }

    /// A set of coordinates representing cells.
    pub const CellSet = std.AutoArrayHashMapUnmanaged(point.Coordinate, void);

    /// Returns a map of the cells that match to an OSC8 hyperlink over the
    /// given point in the render state.
    ///
    /// IMPORTANT: The terminal must not have updated since the last call to
    /// `update`. If there is any chance the terminal has updated, the caller
    /// must first call `update` again to refresh the render state.
    ///
    /// For example, you may want to hold a lock for the duration of the
    /// update and hyperlink lookup to ensure no updates happen in between.
    pub fn linkCells(
        self: *const RenderState,
        alloc: Allocator,
        viewport_point: point.Coordinate,
    ) Allocator.Error!CellSet {
        var result: CellSet = .empty;
        errdefer result.deinit(alloc);

        const row_slice = self.row_data.slice();
        const row_pins = row_slice.items(.pin);
        const row_cells = row_slice.items(.cells);

        // Our viewport point is sent in by the caller and can't be trusted.
        // If it is outside the valid area then just return empty because
        // we can't possibly have a link there.
        if (viewport_point.x >= self.cols or
            viewport_point.y >= row_pins.len) return result;

        // Grab our link ID
        const link_pin: PageList.Pin = row_pins[viewport_point.y];
        const link_page: *page.Page = &link_pin.node.data;
        const link = link: {
            const rac = link_page.getRowAndCell(
                viewport_point.x,
                link_pin.y,
            );

            // The likely scenario is that our mouse isn't even over a link.
            if (!rac.cell.hyperlink) {
                @branchHint(.likely);
                return result;
            }

            const link_id = link_page.lookupHyperlink(rac.cell) orelse
                return result;
            break :link link_page.hyperlink_set.get(
                link_page.memory,
                link_id,
            );
        };

        for (
            0..,
            row_pins,
            row_cells,
        ) |y, pin, cells| {
            for (0.., cells.items(.raw)) |x, cell| {
                if (!cell.hyperlink) continue;

                const other_page: *page.Page = &pin.node.data;
                const other = link: {
                    const rac = other_page.getRowAndCell(x, pin.y);
                    const link_id = other_page.lookupHyperlink(rac.cell) orelse continue;
                    break :link other_page.hyperlink_set.get(
                        other_page.memory,
                        link_id,
                    );
                };

                if (link.eql(
                    link_page.memory,
                    other,
                    other_page.memory,
                )) try result.put(alloc, .{
                    .y = @intCast(y),
                    .x = @intCast(x),
                }, {});
            }
        }

        return result;
    }
};

test "styled" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    // This fills the screen up
    try t.decaln();

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
}

test "basic text" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("ABCD");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Verify we have the right number of rows
    const row_data = state.row_data.slice();
    try testing.expectEqual(3, row_data.len);

    // All rows should have cols cells
    const cells = row_data.items(.cells);
    try testing.expectEqual(10, cells[0].len);
    try testing.expectEqual(10, cells[1].len);
    try testing.expectEqual(10, cells[2].len);

    // Row zero should contain our text
    try testing.expectEqual('A', cells[0].get(0).raw.codepoint());
    try testing.expectEqual('B', cells[0].get(1).raw.codepoint());
    try testing.expectEqual('C', cells[0].get(2).raw.codepoint());
    try testing.expectEqual('D', cells[0].get(3).raw.codepoint());
    try testing.expectEqual(0, cells[0].get(4).raw.codepoint());
}

test "styled text" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("\x1b[1mA"); // Bold
    try s.nextSlice("\x1b[0;3mB"); // Italic
    try s.nextSlice("\x1b[0;4mC"); // Underline

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Verify we have the right number of rows
    const row_data = state.row_data.slice();
    try testing.expectEqual(3, row_data.len);

    // All rows should have cols cells
    const cells = row_data.items(.cells);
    try testing.expectEqual(10, cells[0].len);
    try testing.expectEqual(10, cells[1].len);
    try testing.expectEqual(10, cells[2].len);

    // Row zero should contain our text
    {
        const cell = cells[0].get(0);
        try testing.expectEqual('A', cell.raw.codepoint());
        try testing.expect(cell.style.flags.bold);
    }
    {
        const cell = cells[0].get(1);
        try testing.expectEqual('B', cell.raw.codepoint());
        try testing.expect(!cell.style.flags.bold);
        try testing.expect(cell.style.flags.italic);
    }
    try testing.expectEqual('C', cells[0].get(2).raw.codepoint());
    try testing.expectEqual(0, cells[0].get(3).raw.codepoint());
}

test "grapheme" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("A");
    try s.nextSlice("👨‍"); // this has a ZWJ

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Verify we have the right number of rows
    const row_data = state.row_data.slice();
    try testing.expectEqual(3, row_data.len);

    // All rows should have cols cells
    const cells = row_data.items(.cells);
    try testing.expectEqual(10, cells[0].len);
    try testing.expectEqual(10, cells[1].len);
    try testing.expectEqual(10, cells[2].len);

    // Row zero should contain our text
    {
        const cell = cells[0].get(0);
        try testing.expectEqual('A', cell.raw.codepoint());
    }
    {
        const cell = cells[0].get(1);
        try testing.expectEqual(0x1F468, cell.raw.codepoint());
        try testing.expectEqual(.wide, cell.raw.wide);
        try testing.expectEqualSlices(u21, &.{0x200D}, cell.grapheme);
    }
    {
        const cell = cells[0].get(2);
        try testing.expectEqual(0, cell.raw.codepoint());
        try testing.expectEqual(.spacer_tail, cell.raw.wide);
    }
}

test "cursor state in viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("A\x1b[H");

    var state: RenderState = .empty;
    defer state.deinit(alloc);

    // Initial update
    try state.update(alloc, &t);
    try testing.expectEqual(0, state.cursor.active.x);
    try testing.expectEqual(0, state.cursor.active.y);
    try testing.expectEqual(0, state.cursor.viewport.?.x);
    try testing.expectEqual(0, state.cursor.viewport.?.y);
    try testing.expectEqual('A', state.cursor.cell.codepoint());
    try testing.expect(state.cursor.style.default());

    // Set a style on the cursor
    try s.nextSlice("\x1b[1m"); // Bold
    try state.update(alloc, &t);
    try testing.expect(!state.cursor.style.default());
    try testing.expect(state.cursor.style.flags.bold);
    try s.nextSlice("\x1b[0m"); // Reset style

    // Move cursor to 2,1
    try s.nextSlice("\x1b[2;3H");
    try state.update(alloc, &t);
    try testing.expectEqual(2, state.cursor.active.x);
    try testing.expectEqual(1, state.cursor.active.y);
    try testing.expectEqual(2, state.cursor.viewport.?.x);
    try testing.expectEqual(1, state.cursor.viewport.?.y);
}

test "cursor state out of viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 2,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("A\r\nB\r\nC\r\nD\r\n");

    var state: RenderState = .empty;
    defer state.deinit(alloc);

    // Initial update
    try state.update(alloc, &t);
    try testing.expectEqual(0, state.cursor.active.x);
    try testing.expectEqual(1, state.cursor.active.y);
    try testing.expectEqual(0, state.cursor.viewport.?.x);
    try testing.expectEqual(1, state.cursor.viewport.?.y);

    // Scroll the viewport
    t.scrollViewport(.top);
    try state.update(alloc, &t);

    // Set a style on the cursor
    try testing.expectEqual(0, state.cursor.active.x);
    try testing.expectEqual(1, state.cursor.active.y);
    try testing.expect(state.cursor.viewport == null);
}

test "dirty state" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    var state: RenderState = .empty;
    defer state.deinit(alloc);

    // First update should trigger redraw due to resize
    try state.update(alloc, &t);
    try testing.expectEqual(.full, state.dirty);

    // Reset dirty flag and dirty rows
    state.dirty = .false;
    {
        const row_data = state.row_data.slice();
        const dirty = row_data.items(.dirty);
        @memset(dirty, false);
    }

    // Second update with no changes - no dirty rows
    try state.update(alloc, &t);
    try testing.expectEqual(.false, state.dirty);
    {
        const row_data = state.row_data.slice();
        const dirty = row_data.items(.dirty);
        for (dirty) |d| try testing.expect(!d);
    }

    // Write to first line
    try s.nextSlice("A");
    try state.update(alloc, &t);
    try testing.expectEqual(.partial, state.dirty);
    {
        const row_data = state.row_data.slice();
        const dirty = row_data.items(.dirty);
        try testing.expect(dirty[0]); // First row dirty
        try testing.expect(!dirty[1]); // Second row clean
    }
}

test "colors" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    var state: RenderState = .empty;
    defer state.deinit(alloc);

    // Default colors
    try state.update(alloc, &t);

    // Change cursor color
    try s.nextSlice("\x1b]12;#FF0000\x07");
    try state.update(alloc, &t);

    const c = state.colors.cursor.?;
    try testing.expectEqual(0xFF, c.r);
    try testing.expectEqual(0, c.g);
    try testing.expectEqual(0, c.b);

    // Change palette color 0 to White
    try s.nextSlice("\x1b]4;0;#FFFFFF\x07");
    try state.update(alloc, &t);
    const p0 = state.colors.palette[0];
    try testing.expectEqual(0xFF, p0.r);
    try testing.expectEqual(0xFF, p0.g);
    try testing.expectEqual(0xFF, p0.b);
}

test "selection single line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    const screen: *Screen = t.screens.active;
    try screen.select(.init(
        screen.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 2, .y = 1 } }).?,
        false,
    ));

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const row_data = state.row_data.slice();
    const sels = row_data.items(.selection);
    try testing.expectEqual(null, sels[0]);
    try testing.expectEqualSlices(size.CellCountInt, &.{ 0, 2 }, &sels[1].?);
    try testing.expectEqual(null, sels[2]);

    // Clear the selection
    try screen.select(null);
    try state.update(alloc, &t);
    try testing.expectEqual(null, sels[0]);
    try testing.expectEqual(null, sels[1]);
    try testing.expectEqual(null, sels[2]);
}

test "selection multiple lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    const screen: *Screen = t.screens.active;
    try screen.select(.init(
        screen.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 2, .y = 2 } }).?,
        false,
    ));

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const row_data = state.row_data.slice();
    const sels = row_data.items(.selection);
    try testing.expectEqual(null, sels[0]);
    try testing.expectEqualSlices(
        size.CellCountInt,
        &.{ 0, screen.pages.cols - 1 },
        &sels[1].?,
    );
    try testing.expectEqualSlices(
        size.CellCountInt,
        &.{ 0, 2 },
        &sels[2].?,
    );
}

test "linkCells" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    var state: RenderState = .empty;
    defer state.deinit(alloc);

    // Create a hyperlink
    try s.nextSlice("\x1b]8;;http://example.com\x1b\\LINK\x1b]8;;\x1b\\");
    try state.update(alloc, &t);

    // Query link at 0,0
    var cells = try state.linkCells(alloc, .{ .x = 0, .y = 0 });
    defer cells.deinit(alloc);

    try testing.expectEqual(4, cells.count());
    try testing.expect(cells.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(cells.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(cells.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(cells.contains(.{ .x = 3, .y = 0 }));

    // Query no link
    var cells2 = try state.linkCells(alloc, .{ .x = 4, .y = 0 });
    defer cells2.deinit(alloc);
    try testing.expectEqual(0, cells2.count());
}

test "string" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 5,
        .rows = 2,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("AB");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var w = std.Io.Writer.Allocating.init(alloc);
    defer w.deinit();

    try state.string(&w.writer, null);

    const result = try w.toOwnedSlice();
    defer alloc.free(result);

    const expected = "AB\x00\x00\x00\n\x00\x00\x00\x00\x00\n";
    try testing.expectEqualStrings(expected, result);
}

test "linkCells with scrollback spanning pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const viewport_rows: size.CellCountInt = 10;
    const tail_rows: size.CellCountInt = 5;

    var t = try Terminal.init(alloc, .{
        .cols = page.std_capacity.cols,
        .rows = viewport_rows,
        .max_scrollback = 10_000,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    const pages = &t.screens.active.pages;
    const first_page_cap = pages.pages.first.?.data.capacity.rows;

    // Fill first page
    for (0..first_page_cap - 1) |_| try s.nextSlice("\r\n");

    // Create second page with hyperlink
    try s.nextSlice("\r\n");
    try s.nextSlice("\x1b]8;;http://example.com\x1b\\LINK\x1b]8;;\x1b\\");
    for (0..(tail_rows - 1)) |_| try s.nextSlice("\r\n");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const expected_viewport_y: usize = viewport_rows - tail_rows;
    // BUG: This crashes without the fix
    var cells = try state.linkCells(alloc, .{
        .x = 0,
        .y = expected_viewport_y,
    });
    defer cells.deinit(alloc);
    try testing.expectEqual(@as(usize, 4), cells.count());
}

test "linkCells with invalid viewport point" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Row out of bound
    {
        var cells = try state.linkCells(
            alloc,
            .{ .x = 0, .y = t.rows + 10 },
        );
        defer cells.deinit(alloc);
        try testing.expectEqual(0, cells.count());
    }

    // Col out of bound
    {
        var cells = try state.linkCells(
            alloc,
            .{ .x = t.cols + 10, .y = 0 },
        );
        defer cells.deinit(alloc);
        try testing.expectEqual(0, cells.count());
    }
}

test "dirty row resets highlights" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("ABC");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Reset dirty state
    state.dirty = .false;
    {
        const row_data = state.row_data.slice();
        const dirty = row_data.items(.dirty);
        @memset(dirty, false);
    }

    // Manually add a highlight to row 0
    {
        const row_data = state.row_data.slice();
        const row_arenas = row_data.items(.arena);
        const row_highlights = row_data.items(.highlights);
        var arena = row_arenas[0].promote(alloc);
        defer row_arenas[0] = arena.state;
        try row_highlights[0].append(arena.allocator(), .{
            .tag = 1,
            .range = .{ 0, 2 },
        });
    }

    // Verify we have a highlight
    {
        const row_data = state.row_data.slice();
        const row_highlights = row_data.items(.highlights);
        try testing.expectEqual(1, row_highlights[0].items.len);
    }

    // Write to row 0 to make it dirty
    try s.nextSlice("\x1b[H"); // Move to home
    try s.nextSlice("X");
    try state.update(alloc, &t);

    // Verify the highlight was reset on the dirty row
    {
        const row_data = state.row_data.slice();
        const row_highlights = row_data.items(.highlights);
        try testing.expectEqual(0, row_highlights[0].items.len);
    }
}
