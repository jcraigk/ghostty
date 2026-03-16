//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");

const Renderer = @import("../generic.zig").Renderer(OpenGL);
const OpenGL = @import("../OpenGL.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const Health = @import("../../renderer.zig").Health;

const log = std.log.scoped(.opengl);

/// Options for beginning a frame.
pub const Options = struct {};

renderer: *Renderer,
target: *Target,

/// Begin encoding a frame.
pub fn begin(
    opts: Options,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Self {
    _ = opts;

    return .{
        .renderer = renderer,
        .target = target,
    };
}

/// Add a render pass to this frame with the provided attachments.
/// Returns a RenderPass which allows render steps to be added.
pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    return RenderPass.begin(.{
        .attachments = attachments,
        .viewport_width = self.renderer.size.screen.width,
        .viewport_height = self.renderer.size.screen.height,
    });
}

/// Complete this frame and present the target.
///
/// If `sync` is true, this will block until the frame is presented.
///
/// NOTE: For OpenGL, `sync` is ignored and we always block.
pub fn complete(self: *const Self, sync: bool) void {
    _ = sync;
    gl.finish();

    // Drain all GL errors. A single getError() only returns one error;
    // if multiple errors accumulated we must loop to clear them all.
    // Otherwise a stale error from a previous step could leak into the
    // next frame's health check and cause alternating frame drops.
    var health: Health = .healthy;
    var error_count: u32 = 0;
    while (error_count < 100) : (error_count += 1) {
        if (gl.errors.getError()) {
            break;
        } else |err| {
            log.warn("GL error during frame: {}", .{err});
            health = .unhealthy;
        }
    }

    // If the frame is healthy, present it.
    if (health == .healthy) {
        self.renderer.api.present(self.target.*) catch |err| {
            log.err("Failed to present render target: err={}", .{err});
        };
    }

    // Report the health to the renderer.
    self.renderer.frameCompleted(health);
}
