//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");

const Sampler = @import("Sampler.zig");
const Target = @import("Target.zig");
const Texture = @import("Texture.zig");
const Pipeline = @import("Pipeline.zig");
const Buffer = @import("buffer.zig").Buffer;

/// Options for beginning a render pass.
pub const Options = struct {
    /// Color attachments for this render pass.
    attachments: []const Attachment,
    /// Viewport width in pixels (needed for OpenGL viewport setup).
    viewport_width: u32 = 0,
    /// Viewport height in pixels (needed for OpenGL scissor Y-flip).
    viewport_height: u32 = 0,

    /// Describes a color attachment.
    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f32 = null,
    };
};

/// Describes a step in a render pass.
pub const Step = struct {
    pipeline: Pipeline,
    uniforms: ?gl.Buffer = null,
    buffers: []const ?gl.Buffer = &.{},
    textures: []const ?Texture = &.{},
    samplers: []const ?Sampler = &.{},
    draw: Draw,
    /// Optional scissor rect to clip rendering to a subregion.
    scissor: ?ScissorRect = null,
    /// Optional per-draw block parameters for command block rendering.
    block_params: ?BlockParams = null,

    pub const BlockParams = extern struct {
        block_y_offset: f32,
        block_first_row: f32,
        block_x_offset: f32 = 0,
        block_y_flat: f32 = 0,
        block_corner_radius: f32 = 0,
        block_scissor_x: f32 = 0,
        block_scissor_y: f32 = 0,
        block_scissor_w: f32 = 0,
        block_scissor_h: f32 = 0,
    };

    pub const ScissorRect = struct {
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    };

    /// Describes the draw call for this step.
    pub const Draw = struct {
        type: gl.Primitive,
        vertex_count: usize,
        instance_count: usize = 1,
        base_instance: usize = 0,
    };
};

attachments: []const Options.Attachment,
viewport_width: u32,
viewport_height: u32,

step_number: usize = 0,

/// Lazily-created UBO for block parameters, reused across steps in a pass.
block_params_ubo: ?gl.Buffer = null,

/// Begin a render pass.
pub fn begin(
    opts: Options,
) Self {
    return .{
        .attachments = opts.attachments,
        .viewport_width = opts.viewport_width,
        .viewport_height = opts.viewport_height,
    };
}

/// Add a step to this render pass.
///
/// TODO: Errors are silently ignored in this function, maybe they shouldn't be?
pub fn step(self: *Self, s: Step) void {
    if (s.draw.instance_count == 0) return;

    const pbind = s.pipeline.program.use() catch return;
    defer pbind.unbind();

    const vaobind = s.pipeline.vao.bind() catch return;
    defer vaobind.unbind();

    const fbobind = switch (self.attachments[0].target) {
        .target => |t| t.framebuffer.bind(.framebuffer) catch return,
        .texture => |t| bind: {
            const fbobind = s.pipeline.fbo.bind(.framebuffer) catch return;
            fbobind.texture2D(.color0, t.target, t.texture, 0) catch {
                fbobind.unbind();
                return;
            };
            break :bind fbobind;
        },
    };
    defer fbobind.unbind();

    defer self.step_number += 1;

    // If we have a clear color and this is the
    // first step in the pass, go ahead and clear.
    // Disable scissor test first so glClear affects the entire framebuffer
    // (a previous frame's last step may have left scissor enabled).
    // Also set the viewport to match the render target dimensions so that
    // scissor rects and draw coordinates are correct for our FBO, not
    // whatever viewport GTK may have set for its own framebuffer.
    if (self.step_number == 0) {
        if (self.viewport_width > 0 and self.viewport_height > 0) {
            // Set viewport to match our render target.
            gl.viewport(0, 0, @intCast(self.viewport_width), @intCast(self.viewport_height)) catch {};
        }
        if (self.attachments[0].clear_color) |clr| {
            gl.disable(gl.c.GL_SCISSOR_TEST) catch {};
            gl.clearColor(clr[0], clr[1], clr[2], clr[3]);
            gl.clear(gl.c.GL_COLOR_BUFFER_BIT);
        }
    }

    // Bind the uniform buffer we bind at index 1 to align with Metal.
    if (s.uniforms) |ubo| {
        _ = ubo.bindBase(.uniform, 1) catch return;
    }

    // Bind relevant texture units.
    for (s.textures, 0..) |t, i| if (t) |tex| {
        gl.Texture.active(@intCast(i)) catch return;
        _ = tex.texture.bind(tex.target) catch return;
    };

    // Bind relevant samplers.
    for (s.samplers, 0..) |s_, i| if (s_) |sampler| {
        _ = sampler.sampler.bind(@intCast(i)) catch return;
    };

    // Bind 0th buffer as the vertex buffer,
    // and bind the rest as storage buffers.
    if (s.buffers.len > 0) {
        if (s.buffers[0]) |vbo| vaobind.bindVertexBuffer(
            0,
            vbo.id,
            0,
            @intCast(s.pipeline.stride),
        ) catch return;

        for (s.buffers[1..], 1..) |b, i| if (b) |buf| {
            _ = buf.bindBase(.storage, @intCast(i)) catch return;
        };
    }

    if (s.pipeline.blending_enabled) {
        gl.enable(gl.c.GL_BLEND) catch return;
        gl.blendFunc(gl.c.GL_ONE, gl.c.GL_ONE_MINUS_SRC_ALPHA) catch return;
    } else {
        gl.disable(gl.c.GL_BLEND) catch return;
    }

    if (s.scissor) |sc| {
        gl.enable(gl.c.GL_SCISSOR_TEST) catch return;
        // OpenGL scissor Y is measured from the bottom-left, but our
        // screen_y_px is measured from the top. Flip the Y coordinate.
        const flipped_y = if (self.viewport_height > 0)
            self.viewport_height -| sc.y -| sc.height
        else
            sc.y;
        gl.scissor(
            @intCast(sc.x),
            @intCast(flipped_y),
            @intCast(sc.width),
            @intCast(sc.height),
        ) catch return;
    } else {
        gl.disable(gl.c.GL_SCISSOR_TEST) catch return;
    }

    // Bind block parameters UBO at binding index 3, matching Metal convention.
    // Always bind block params (default zeros when null) to prevent stale UBO state.
    {
        const bp = s.block_params orelse Step.BlockParams{
            .block_y_offset = 0,
            .block_first_row = 0,
            .block_x_offset = 0,
            .block_y_flat = 0,
            .block_corner_radius = 0,
            .block_scissor_x = 0,
            .block_scissor_y = 0,
            .block_scissor_w = 0,
            .block_scissor_h = 0,
        };
        if (self.block_params_ubo == null) {
            self.block_params_ubo = gl.Buffer.create() catch return;
        }
        const ubo = self.block_params_ubo.?;
        const binding = ubo.bind(.uniform) catch return;
        binding.setData(&bp, .dynamic_draw) catch {
            binding.unbind();
            return;
        };
        binding.unbind();
        ubo.bindBase(.uniform, 3) catch return;
    }

    if (s.draw.base_instance > 0) {
        gl.drawArraysInstancedBaseInstance(
            s.draw.type,
            0,
            @intCast(s.draw.vertex_count),
            @intCast(s.draw.instance_count),
            @intCast(s.draw.base_instance),
        ) catch return;
    } else {
        gl.drawArraysInstanced(
            s.draw.type,
            0,
            @intCast(s.draw.vertex_count),
            @intCast(s.draw.instance_count),
        ) catch return;
    }
}

/// Complete this render pass.
/// This struct can no longer be used after calling this.
pub fn complete(self: *Self) void {
    // Disable scissor test so it doesn't leak into the next pass or frame.
    gl.disable(gl.c.GL_SCISSOR_TEST) catch {};
    // Clean up the block parameters UBO if it was created.
    // Unbind from index 3 before destroying to avoid dangling binding on some drivers.
    if (self.block_params_ubo) |ubo| {
        gl.glad.context.BindBufferBase.?(gl.c.GL_UNIFORM_BUFFER, 3, 0);
        ubo.destroy();
        self.block_params_ubo = null;
    }
    gl.flush();
}
