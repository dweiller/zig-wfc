const std = @import("std");

pub const overlapping = @import("overlapping.zig");

usingnamespace @import("core.zig");

test {
    std.testing.refAllDecls(@This());
}
