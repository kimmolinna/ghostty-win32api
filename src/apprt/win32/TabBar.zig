//! Owner-draw / GDI tab strip (GTK class/tab.zig counterpart).
//! Post-spike chrome — not required for #82 success criteria.

const std = @import("std");

pub const Tab = struct {
    title: []const u8,
    surface_index: usize,
};

pub const TabBar = @This();

allocator: std.mem.Allocator,
tabs: std.ArrayListUnmanaged(Tab) = .{},
active: usize = 0,

pub fn init(allocator: std.mem.Allocator) TabBar {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *TabBar) void {
    self.tabs.deinit(self.allocator);
}

pub fn addTab(self: *TabBar, title: []const u8, surface_index: usize) !void {
    try self.tabs.append(self.allocator, .{ .title = title, .surface_index = surface_index });
    self.active = self.tabs.items.len - 1;
}
