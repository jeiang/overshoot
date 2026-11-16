//! Overshoot core: a CPU pipeline that makes photos look like late-2000s compact cameras.

pub const profiles = @import("profiles.zig");
pub const exposure = @import("exposure.zig");
pub const pipeline = @import("pipeline.zig");
pub const Pipeline = pipeline.Pipeline;

test {
    _ = @import("profiles.zig");
    _ = @import("exposure.zig");
    _ = @import("filters.zig");
    _ = @import("workers.zig");
    _ = @import("pipeline.zig");
    _ = @import("c_api.zig");
}
