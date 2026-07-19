//! Split layout tree (GTK class/split_tree.zig counterpart).
//! Spike used a single ratio + drag bar; this module will own recursive splits.

const std = @import("std");

pub const Orientation = enum { horizontal, vertical };

pub const Node = union(enum) {
    leaf: usize, // surface index
    branch: struct {
        orientation: Orientation,
        ratio: f64,
        first: *Node,
        second: *Node,
    },
};

pub const SplitTree = @This();

allocator: std.mem.Allocator,
root: ?Node = null,

pub fn init(allocator: std.mem.Allocator) SplitTree {
    return .{ .allocator = allocator };
}

/// Default #82 layout: two side-by-side leaves.
pub fn initSideBySide(allocator: std.mem.Allocator) !SplitTree {
    return .{
        .allocator = allocator,
        .root = .{ .leaf = 0 }, // real tree filled when apprt is wired
    };
}
