const std = @import("std");

/// Runtime is the runtime to use for Ghostty. All runtimes do not provide
/// equivalent feature sets.
pub const Runtime = enum {
    /// Will not produce an executable at all when `zig build` is called.
    /// This is only useful if you're only interested in the lib only (macOS).
    none,

    /// GTK4. Rich windowed application. This uses a full GObject-based
    /// approach to building the application.
    gtk,

    /// Native Win32 + DX12 (Windows). See docs/windows/SPIKE82-DECISION.md.
    win32,

    pub fn default(target: std.Target) Runtime {
        return switch (target.os.tag) {
            .linux, .freebsd => .gtk,
            .windows => .win32,
            else => .none,
        };
    }
};

test {
    _ = Runtime;
}
