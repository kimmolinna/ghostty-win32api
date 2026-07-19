//! Top-level Win32 window. Hosts 1–2 Surface children (side-by-side split).
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");

const App = @import("App.zig");
const Surface = @import("Surface.zig");
const key = @import("key.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

const SPLITTER_GAP: i32 = 5;
const MAX_SURFACES: usize = 2;

app: *App,
hwnd: ?w32.HWND = null,
scale: f32 = 1.0,

/// Up to two surfaces; surfaces[0] is always present after addSurface.
surfaces: [MAX_SURFACES]?*Surface = .{ null, null },
surface_count: usize = 0,
active_index: usize = 0,

/// Horizontal split ratio (left pane fraction). Used when surface_count == 2.
split_ratio: f32 = 0.5,
dragging_split: bool = false,
closing: bool = false,

pub fn init(self: *Window, app: *App) !void {
    self.* = .{ .app = app };

    const cascade_step: i32 = 30;
    var cx: i32 = w32.CW_USEDEFAULT;
    var cy: i32 = w32.CW_USEDEFAULT;
    if (app.windows.items.len > 0) {
        const prev = app.windows.items[app.windows.items.len - 1];
        if (prev.hwnd) |ph| {
            var prev_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            if (w32.GetWindowRect(ph, &prev_rect) != 0) {
                cx = prev_rect.left + cascade_step;
                cy = prev_rect.top + cascade_step;
                if (cx + 800 > w32.GetSystemMetrics(0) or
                    cy + 600 > w32.GetSystemMetrics(1))
                {
                    cx = w32.CW_USEDEFAULT;
                    cy = w32.CW_USEDEFAULT;
                }
            }
        }
    }

    const hwnd = w32.CreateWindowExW(
        0,
        App.WINDOW_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        w32.WS_OVERLAPPEDWINDOW,
        cx,
        cy,
        800,
        600,
        null,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;

    self.hwnd = hwnd;
    errdefer {
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }

    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Immersive dark title bar.
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );

    const dpi = w32.GetDpiForWindow(hwnd);
    if (dpi != 0) self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
}

pub fn deinit(self: *Window) void {
    self.closing = true;
    self.destroyAllSurfaces();
    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }
}

pub fn onConfigChange(self: *Window) void {
    if (self.hwnd) |hwnd| {
        const dark_mode: u32 = 1;
        _ = w32.DwmSetWindowAttribute(
            hwnd,
            w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
            @ptrCast(&dark_mode),
            @sizeOf(u32),
        );
    }
}

fn clientRect(self: *const Window) w32.RECT {
    const hwnd = self.hwnd orelse return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) {
        return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    }
    return rect;
}

/// Rect available for surfaces (full client area for MVWT — no tab chrome).
pub fn surfaceRect(self: *const Window) w32.RECT {
    return self.clientRect();
}

pub fn getActiveSurface(self: *Window) ?*Surface {
    if (self.surface_count == 0) return null;
    return self.surfaces[self.active_index];
}

pub fn setActiveSurface(self: *Window, surface: *Surface) void {
    for (self.surfaces[0..self.surface_count], 0..) |s, i| {
        if (s == surface) {
            self.active_index = i;
            return;
        }
    }
}

pub fn focusPane(self: *Window, index: usize) void {
    if (index >= self.surface_count) return;
    self.active_index = index;
    if (self.surfaces[index]) |s| {
        if (s.hwnd) |h| _ = w32.SetFocus(h);
    }
}

/// Create the first (or only) surface, or a second side-by-side surface.
pub fn addSurface(self: *Window, context: apprt.surface.NewSurfaceContext) !*Surface {
    if (self.closing) return error.WindowClosing;
    if (self.surface_count >= MAX_SURFACES) return error.TooManySurfaces;

    const alloc = self.app.core_app.alloc;
    const surface = try alloc.create(Surface);
    errdefer alloc.destroy(surface);

    try surface.init(self.app, self, context);
    self.surfaces[self.surface_count] = surface;
    self.surface_count += 1;
    self.active_index = self.surface_count - 1;

    if (self.surface_count == 1) {
        if (self.hwnd) |h| {
            _ = w32.ShowWindow(h, w32.SW_SHOW);
            _ = w32.UpdateWindow(h);
        }
    }

    self.layoutSurfaces();
    if (surface.hwnd) |h| _ = w32.SetFocus(h);
    return surface;
}

/// Create a second surface side-by-side at ratio 0.5.
pub fn splitSideBySide(self: *Window) !void {
    if (self.surface_count >= MAX_SURFACES) return;
    self.split_ratio = 0.5;
    _ = try self.addSurface(.split);
}

pub fn closeSurface(self: *Window, surface: *Surface) void {
    const alloc = self.app.core_app.alloc;
    var idx: ?usize = null;
    for (self.surfaces[0..self.surface_count], 0..) |s, i| {
        if (s == surface) {
            idx = i;
            break;
        }
    }
    const i = idx orelse return;

    // Hide + deinit the surface.
    if (surface.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
    surface.deinit();
    alloc.destroy(surface);

    // Compact array.
    var j: usize = i;
    while (j + 1 < self.surface_count) : (j += 1) {
        self.surfaces[j] = self.surfaces[j + 1];
    }
    self.surfaces[self.surface_count - 1] = null;
    self.surface_count -= 1;

    if (self.surface_count == 0) {
        self.closing = true;
        if (self.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
        return;
    }

    if (self.active_index >= self.surface_count) {
        self.active_index = self.surface_count - 1;
    } else if (self.active_index > i) {
        self.active_index -= 1;
    }

    self.split_ratio = 0.5;
    self.layoutSurfaces();
    if (self.surfaces[self.active_index]) |s| {
        if (s.hwnd) |h| _ = w32.SetFocus(h);
    }
}

fn destroyAllSurfaces(self: *Window) void {
    const alloc = self.app.core_app.alloc;
    var i: usize = self.surface_count;
    while (i > 0) {
        i -= 1;
        if (self.surfaces[i]) |s| {
            self.surfaces[i] = null;
            s.deinit();
            alloc.destroy(s);
        }
    }
    self.surface_count = 0;
}

pub fn layoutSurfaces(self: *Window) void {
    if (self.surface_count == 0) return;
    const rect = self.surfaceRect();
    const gap: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(SPLITTER_GAP)) * self.scale));

    if (self.surface_count == 1) {
        if (self.surfaces[0]) |s| {
            s.setVisible(true);
            if (s.hwnd) |h| {
                const w = @max(rect.right - rect.left, 1);
                const ht = @max(rect.bottom - rect.top, 1);
                _ = w32.MoveWindow(h, rect.left, rect.top, @intCast(w), @intCast(ht), 1);
                _ = w32.ShowWindow(h, w32.SW_SHOW);
            }
        }
        return;
    }

    // Two surfaces side by side.
    const total_w = rect.right - rect.left;
    const split_x = rect.left + @as(i32, @intFromFloat(self.split_ratio * @as(f32, @floatFromInt(total_w))));
    const left = w32.RECT{
        .left = rect.left,
        .top = rect.top,
        .right = split_x - @divTrunc(gap, 2),
        .bottom = rect.bottom,
    };
    const right = w32.RECT{
        .left = split_x + @divTrunc(gap + 1, 2),
        .top = rect.top,
        .right = rect.right,
        .bottom = rect.bottom,
    };

    if (self.surfaces[0]) |s| {
        s.setVisible(true);
        if (s.hwnd) |h| {
            const w = @max(left.right - left.left, 1);
            const ht = @max(left.bottom - left.top, 1);
            _ = w32.MoveWindow(h, left.left, left.top, @intCast(w), @intCast(ht), 1);
            _ = w32.ShowWindow(h, w32.SW_SHOW);
        }
    }
    if (self.surfaces[1]) |s| {
        s.setVisible(true);
        if (s.hwnd) |h| {
            const w = @max(right.right - right.left, 1);
            const ht = @max(right.bottom - right.top, 1);
            _ = w32.MoveWindow(h, right.left, right.top, @intCast(w), @intCast(ht), 1);
            _ = w32.ShowWindow(h, w32.SW_SHOW);
        }
    }

    // Paint splitter line.
    if (self.hwnd) |hwnd| {
        if (w32.GetDC(hwnd)) |dc| {
            defer _ = w32.ReleaseDC(hwnd, dc);
            const line_w: i32 = @max(@as(i32, @intFromFloat(@round(1.0 * self.scale))), 1);
            const pen = w32.CreatePen(0, line_w, 0x00808080) orelse return;
            defer _ = w32.DeleteObject(pen);
            const old = w32.SelectObject(dc, pen);
            defer _ = w32.SelectObject(dc, old);
            _ = w32.MoveToEx(dc, split_x, rect.top, null);
            _ = w32.LineTo(dc, split_x, rect.bottom);
        }
    }
}

fn hitTestSplitter(self: *Window, x: i32, y: i32) bool {
    if (self.surface_count < 2) return false;
    const rect = self.surfaceRect();
    const total_w = rect.right - rect.left;
    const split_x = rect.left + @as(i32, @intFromFloat(self.split_ratio * @as(f32, @floatFromInt(total_w))));
    const hit: i32 = @max(@as(i32, @intFromFloat(@round(3.0 * self.scale))), 3);
    return x >= split_x - hit and x <= split_x + hit and y >= rect.top and y <= rect.bottom;
}

fn startSplitterDrag(self: *Window) void {
    self.dragging_split = true;
    if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
}

fn updateSplitterDrag(self: *Window, x: i32) void {
    if (!self.dragging_split) return;
    const rect = self.surfaceRect();
    const total: f32 = @floatFromInt(@max(rect.right - rect.left, 1));
    const pos: f32 = @floatFromInt(x - rect.left);
    self.split_ratio = std.math.clamp(pos / total, 0.1, 0.9);
    self.layoutSurfaces();
}

fn endSplitterDrag(self: *Window) void {
    if (!self.dragging_split) return;
    self.dragging_split = false;
    _ = w32.ReleaseCapture();
}

pub fn setTitle(self: *Window, title: [:0]const u8) void {
    const hwnd = self.hwnd orelse return;
    var wbuf: [512]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, title) catch return;
    if (wlen >= wbuf.len) return;
    wbuf[wlen] = 0;
    _ = w32.SetWindowTextW(hwnd, @ptrCast(&wbuf));
}

pub fn close(self: *Window) void {
    self.closing = true;
    self.destroyAllSurfaces();
    if (self.hwnd) |hwnd| {
        _ = w32.DestroyWindow(hwnd);
        // WM_DESTROY → onDestroy removes from app list + frees.
    }
}

fn setSurfacesVisible(self: *Window, visible: bool) void {
    for (self.surfaces[0..self.surface_count]) |s| {
        if (s) |surface| surface.setVisible(visible);
    }
}

fn onDestroy(self: *Window) void {
    const app = self.app;
    for (app.windows.items, 0..) |w, i| {
        if (w == self) {
            _ = app.windows.orderedRemove(i);
            break;
        }
    }
    self.hwnd = null;
    app.core_app.alloc.destroy(self);

    if (app.windows.items.len == 0) {
        app.startQuitTimer();
    }
}

/// Handle host keybinds (Ctrl+1 / Ctrl+2 / Ctrl+Shift+D). Returns true if consumed.
pub fn handleHostKeybind(self: *Window, vk: u16) bool {
    const mods = key.modsFromWin32();
    const builtin = key.matchBuiltin(mods, vk) orelse return false;
    switch (builtin) {
        .focus_pane_1 => self.focusPane(0),
        .focus_pane_2 => self.focusPane(1),
        .new_split_right => self.splitSideBySide() catch |err| {
            log.warn("splitSideBySide failed: {}", .{err});
        },
    }
    return true;
}

pub fn windowWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const window: *Window = if (userdata != 0)
        @ptrFromInt(@as(usize, @bitCast(userdata)))
    else
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    if (window.closing) switch (msg) {
        w32.WM_LBUTTONDOWN,
        w32.WM_LBUTTONUP,
        w32.WM_MOUSEMOVE,
        w32.WM_KEYDOWN,
        w32.WM_KEYUP,
        w32.WM_CHAR,
        => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
        else => {},
    };

    switch (msg) {
        w32.WM_SIZE => {
            if (wparam == w32.SIZE_MINIMIZED) {
                window.setSurfacesVisible(false);
                return 0;
            }
            if (wparam == w32.SIZE_RESTORED or wparam == w32.SIZE_MAXIMIZED) {
                window.setSurfacesVisible(true);
            }
            window.layoutSurfaces();
            return 0;
        },

        w32.WM_DPICHANGED => {
            const dpi = w32.GetDpiForWindow(hwnd);
            if (dpi != 0) window.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
            for (window.surfaces[0..window.surface_count]) |s| {
                if (s) |surface| surface.handleDpiChange();
            }
            window.layoutSurfaces();
            return 0;
        },

        w32.WM_LBUTTONDOWN => {
            const x: i32 = @intCast(@as(i16, @truncate(@as(isize, lparam & 0xFFFF))));
            const y: i32 = @intCast(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF))));
            if (window.hitTestSplitter(x, y)) {
                window.startSplitterDrag();
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_LBUTTONUP => {
            window.endSplitterDrag();
            return 0;
        },

        w32.WM_MOUSEMOVE => {
            if (window.dragging_split) {
                const x: i32 = @intCast(@as(i16, @truncate(@as(isize, lparam & 0xFFFF))));
                window.updateSplitterDrag(x);
                return 0;
            }
            // Splitter hover cursor.
            const x: i32 = @intCast(@as(i16, @truncate(@as(isize, lparam & 0xFFFF))));
            const y: i32 = @intCast(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF))));
            if (window.hitTestSplitter(x, y)) {
                if (w32.LoadCursorW(null, w32.IDC_SIZEWE)) |c| _ = w32.SetCursor(c);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_SETCURSOR => {
            // Let DefWindowProc handle non-client; for client we may set sizewe above.
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_CLOSE => {
            window.close();
            return 0;
        },

        w32.WM_DESTROY => {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            window.onDestroy();
            return 0;
        },

        w32.WM_ERASEBKGND => {
            if (window.app.bg_brush) |brush| {
                const hdc: w32.HDC = @ptrFromInt(wparam);
                var rect: w32.RECT = undefined;
                if (w32.GetClientRect(hwnd, &rect) != 0) {
                    _ = w32.FillRect(hdc, &rect, brush);
                }
            }
            return 1;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
