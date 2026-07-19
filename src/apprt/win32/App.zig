//! Win32 application runtime. Message loop, window classes, surface lifecycle.
//! DX12 rendering binds to Surface child HWNDs (no WGL / OpenGL).
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");

const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// DX12 draws on the renderer thread.
pub const must_draw_from_app_thread = false;

const WM_APP_WAKEUP: u32 = w32.WM_APP + 1;
const QUIT_TIMER_ID: usize = 1;

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");
pub const TERMINAL_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyTerminal");
pub const MSG_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyMsg");

core_app: *CoreApp,
config: Config,
msg_hwnd: ?w32.HWND = null,
hinstance: w32.HINSTANCE,
class_atom: u16 = 0,
terminal_class_atom: u16 = 0,
msg_class_atom: u16 = 0,
windows: std.ArrayList(*Window) = .empty,
bg_brush: ?w32.HBRUSH = null,
quit_timer_state: enum { off, active, expired } = .off,
quit_requested: bool = false,

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;

    const hinstance = w32.GetModuleHandleW(null) orelse
        return error.Win32Error;

    const alloc = core_app.alloc;
    var config = Config.load(alloc) catch |err| err: {
        log.err("failed to load config: {}", .{err});
        var def: Config = try .default(alloc);
        errdefer def.deinit();
        try def.addDiagnosticFmt(
            "error loading user configuration: {}",
            .{err},
        );
        break :err def;
    };
    errdefer config.deinit();

    const bg = config.background;
    const bg_brush = w32.CreateSolidBrush(w32.RGB(bg.r, bg.g, bg.b));

    self.* = .{
        .core_app = core_app,
        .config = config,
        .hinstance = hinstance,
        .bg_brush = bg_brush,
    };

    // Application icon; fall back to IDI_APPLICATION if IDI_GHOSTTY missing.
    const app_icon = w32.LoadIconW(hinstance, w32.IDI_GHOSTTY) orelse
        w32.LoadIconW(null, w32.IDI_APPLICATION);

    // Top-level container: GDI paint, NO CS_OWNDC (DX12 does not need it).
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = w32.CS_DBLCLKS,
        .lpfnWndProc = &Window.windowWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = app_icon,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = bg_brush,
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = app_icon,
    };
    self.class_atom = w32.RegisterClassExW(&wc);
    if (self.class_atom == 0) return error.Win32Error;
    errdefer if (self.class_atom != 0) {
        _ = w32.UnregisterClassW(WINDOW_CLASS_NAME, self.hinstance);
    };

    // Terminal surface child: also NO CS_OWNDC (no WGL).
    const tc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &surfaceWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = app_icon,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = TERMINAL_CLASS_NAME,
        .hIconSm = app_icon,
    };
    self.terminal_class_atom = w32.RegisterClassExW(&tc);
    if (self.terminal_class_atom == 0) return error.Win32Error;
    errdefer if (self.terminal_class_atom != 0) {
        _ = w32.UnregisterClassW(TERMINAL_CLASS_NAME, self.hinstance);
    };

    const mc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &msgWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = MSG_CLASS_NAME,
        .hIconSm = null,
    };
    self.msg_class_atom = w32.RegisterClassExW(&mc);
    if (self.msg_class_atom == 0) return error.Win32Error;
    errdefer if (self.msg_class_atom != 0) {
        _ = w32.UnregisterClassW(MSG_CLASS_NAME, self.hinstance);
    };

    self.msg_hwnd = w32.CreateWindowExW(
        0,
        MSG_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("GhosttyMsg"),
        0,
        0,
        0,
        0,
        0,
        w32.HWND_MESSAGE,
        null,
        hinstance,
        null,
    );
    if (self.msg_hwnd == null) return error.Win32Error;
    _ = w32.SetWindowLongPtrW(self.msg_hwnd.?, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
}

pub fn run(self: *App) !void {
    const alloc = self.core_app.alloc;
    const window = try alloc.create(Window);
    errdefer alloc.destroy(window);
    try window.init(self);
    try self.windows.append(alloc, window);
    _ = try window.addSurface(.window);

    var msg: w32.MSG = undefined;
    while (true) {
        const result = w32.GetMessageW(&msg, null, 0, 0);
        if (result == 0) {
            if (!self.quit_requested) continue;
            break;
        }
        if (result < 0) return error.Win32Error;
        if (self.quit_requested) break;

        // Skip TranslateMessage for terminal surfaces so ToUnicode owns
        // dead-key state (except VK_PROCESSKEY for IME).
        const skip_translate = switch (msg.message) {
            w32.WM_KEYDOWN, w32.WM_KEYUP, w32.WM_SYSKEYDOWN, w32.WM_SYSKEYUP => blk: {
                if (msg.wParam == w32.VK_PROCESSKEY) break :blk false;
                const h = msg.hwnd orelse break :blk false;
                const atom: u16 = @truncate(w32.GetClassLongW(h, w32.GCW_ATOM));
                break :blk atom != 0 and atom == self.terminal_class_atom;
            },
            else => false,
        };
        if (!skip_translate) _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
}

pub fn terminate(self: *App) void {
    self.stopQuitTimer();

    if (self.msg_hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
        self.msg_hwnd = null;
    }

    const alloc = self.core_app.alloc;
    for (self.windows.items) |window| {
        window.deinit();
        alloc.destroy(window);
    }
    self.windows.deinit(alloc);

    if (self.bg_brush) |brush| {
        _ = w32.DeleteObject(@ptrCast(brush));
        self.bg_brush = null;
    }

    if (self.msg_class_atom != 0) {
        _ = w32.UnregisterClassW(MSG_CLASS_NAME, self.hinstance);
        self.msg_class_atom = 0;
    }
    if (self.terminal_class_atom != 0) {
        _ = w32.UnregisterClassW(TERMINAL_CLASS_NAME, self.hinstance);
        self.terminal_class_atom = 0;
    }
    if (self.class_atom != 0) {
        _ = w32.UnregisterClassW(WINDOW_CLASS_NAME, self.hinstance);
        self.class_atom = 0;
    }

    self.config.deinit();
}

pub fn wakeup(self: *App) void {
    if (self.msg_hwnd) |hwnd| {
        _ = w32.PostMessageW(hwnd, WM_APP_WAKEUP, 0, 0);
    }
}

pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) !bool {
    return false;
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => {
            self.quit_requested = true;
            w32.PostQuitMessage(0);
            return true;
        },

        .new_window => {
            const alloc = self.core_app.alloc;
            const window = alloc.create(Window) catch |err| {
                log.err("failed to allocate new window err={}", .{err});
                return true;
            };
            window.init(self) catch |err| {
                log.err("failed to init new window err={}", .{err});
                alloc.destroy(window);
                return true;
            };
            self.windows.append(alloc, window) catch |err| {
                log.err("failed to track new window err={}", .{err});
                window.deinit();
                alloc.destroy(window);
                return true;
            };
            _ = window.addSurface(.window) catch |err| {
                log.err("failed to add surface to new window err={}", .{err});
                return true;
            };
            return true;
        },

        .set_title => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setTitle(value.title);
                },
            }
            return true;
        },

        .ring_bell => {
            _ = w32.MessageBeep(0xFFFFFFFF);
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.parent_window.hwnd) |win_hwnd| {
                        if (w32.GetForegroundWindow() != win_hwnd) {
                            var fwi: w32.FLASHWINFO = .{
                                .cbSize = @sizeOf(w32.FLASHWINFO),
                                .hwnd = win_hwnd,
                                .dwFlags = w32.FLASHW_ALL | w32.FLASHW_TIMERNOFG,
                                .uCount = 2,
                                .dwTimeout = 0,
                            };
                            _ = w32.FlashWindowEx(&fwi);
                        }
                    }
                },
            }
            return true;
        },

        .quit_timer => {
            switch (value) {
                .start => self.startQuitTimer(),
                .stop => self.stopQuitTimer(),
            }
            return true;
        },

        .config_change => {
            if (value.config.clone(self.core_app.alloc)) |new_config| {
                self.config.deinit();
                self.config = new_config;

                if (self.bg_brush) |old_brush| {
                    _ = w32.DeleteObject(@ptrCast(old_brush));
                }
                const bg = new_config.background;
                self.bg_brush = w32.CreateSolidBrush(w32.RGB(bg.r, bg.g, bg.b));

                for (self.windows.items) |w| w.onConfigChange();
            } else |err| {
                log.err("error updating app config err={}", .{err});
            }
            return true;
        },

        .close_window => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const win = core_surface.rt_surface.parent_window;
                    win.close();
                },
            }
            return true;
        },

        .close_tab => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    // MVWT: ignore mode; always close this surface.
                    switch (value) {
                        else => {},
                    }
                    core_surface.rt_surface.close(false);
                },
            }
            return true;
        },

        .mouse_shape => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setMouseShape(value);
                },
            }
            return true;
        },

        .new_split => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const win = core_surface.rt_surface.parent_window;
                    // MVWT: any direction becomes a horizontal side-by-side split.
                    switch (value) {
                        else => {},
                    }
                    win.splitSideBySide() catch |err| {
                        log.err("failed to create split: {}", .{err});
                    };
                },
            }
            return true;
        },

        else => return false,
    }
}

pub fn startQuitTimer(self: *App) void {
    self.stopQuitTimer();
    if (!self.config.@"quit-after-last-window-closed") return;

    if (self.config.@"quit-after-last-window-closed-delay") |v| {
        const ms = v.asMilliseconds();
        if (self.msg_hwnd) |hwnd| {
            _ = w32.SetTimer(hwnd, QUIT_TIMER_ID, ms, null);
            self.quit_timer_state = .active;
        }
    } else {
        self.quit_timer_state = .expired;
        self.quit_requested = true;
        w32.PostQuitMessage(0);
    }
}

pub fn stopQuitTimer(self: *App) void {
    switch (self.quit_timer_state) {
        .off => {},
        .expired => {
            self.quit_timer_state = .off;
            self.quit_requested = false;
        },
        .active => {
            if (self.msg_hwnd) |hwnd| {
                _ = w32.KillTimer(hwnd, QUIT_TIMER_ID);
            }
            self.quit_timer_state = .off;
        },
    }
}

fn tick(self: *App) void {
    self.core_app.tick(self) catch |err| {
        log.err("core app tick error: {}", .{err});
    };
}

fn surfaceWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const surface: *Surface = if (userdata != 0)
        @ptrFromInt(@as(usize, @bitCast(userdata)))
    else
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    if (surface.hwnd == null or surface.hwnd.? != hwnd)
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_SIZE => {
            const width: u32 = @intCast(lparam & 0xFFFF);
            const height: u32 = @intCast((lparam >> 16) & 0xFFFF);
            surface.handleResize(width, height);
            return 0;
        },

        w32.WM_CLOSE => {
            surface.parent_window.closeSurface(surface);
            return 0;
        },

        w32.WM_DESTROY => {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            surface.hwnd = null;
            surface.core_surface_ready = false;
            return 0;
        },

        w32.WM_ERASEBKGND => {
            if (surface.app.bg_brush) |brush| {
                const hdc_erase: w32.HDC = @ptrFromInt(wparam);
                var rect: w32.RECT = undefined;
                if (w32.GetClientRect(hwnd, &rect) != 0) {
                    _ = w32.FillRect(hdc_erase, &rect, brush);
                }
            }
            return 1;
        },

        w32.WM_PAINT => {
            _ = w32.ValidateRect(hwnd, null);
            if (surface.core_surface_ready) {
                surface.core_surface.renderer_thread.wakeup.notify() catch {};
            }
            return 0;
        },

        w32.WM_DPICHANGED => {
            surface.handleDpiChange();
            return 0;
        },

        w32.WM_KEYDOWN, w32.WM_SYSKEYDOWN => {
            surface.handleKeyEvent(wparam, lparam, .press);
            return 0;
        },

        w32.WM_KEYUP, w32.WM_SYSKEYUP => {
            surface.handleKeyEvent(wparam, lparam, .release);
            return 0;
        },

        w32.WM_CHAR, w32.WM_SYSCHAR => {
            if (!surface.key_event_produced_text) {
                surface.handleCharEvent(wparam);
            }
            surface.key_event_produced_text = false;
            return 0;
        },

        w32.WM_LBUTTONDOWN => {
            surface.handleMouseButton(.left, .press, lparam);
            return 0;
        },
        w32.WM_LBUTTONUP => {
            surface.handleMouseButton(.left, .release, lparam);
            return 0;
        },
        w32.WM_RBUTTONDOWN => {
            surface.handleMouseButton(.right, .press, lparam);
            return 0;
        },
        w32.WM_RBUTTONUP => {
            surface.handleMouseButton(.right, .release, lparam);
            return 0;
        },
        w32.WM_MBUTTONDOWN => {
            surface.handleMouseButton(.middle, .press, lparam);
            return 0;
        },
        w32.WM_MBUTTONUP => {
            surface.handleMouseButton(.middle, .release, lparam);
            return 0;
        },

        w32.WM_MOUSEMOVE => {
            surface.handleMouseMove(lparam);
            return 0;
        },

        w32.WM_MOUSEWHEEL => {
            surface.handleMouseWheel(wparam, .vertical);
            return 0;
        },
        w32.WM_MOUSEHWHEEL => {
            surface.handleMouseWheel(wparam, .horizontal);
            return 0;
        },

        w32.WM_SETCURSOR => {
            if (surface.handleSetCursor()) return 1;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_IME_STARTCOMPOSITION => {
            surface.handleImeStartComposition();
            return 0;
        },
        w32.WM_IME_ENDCOMPOSITION => {
            surface.handleImeEndComposition();
            return 0;
        },
        w32.WM_IME_COMPOSITION => {
            if (surface.handleImeComposition(lparam)) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_IME_SETCONTEXT => {
            // Keep default composition UI (ISC_SHOWUICOMPOSITIONWINDOW).
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_SETFOCUS => {
            surface.parent_window.setActiveSurface(surface);
            surface.handleFocus(true);
            return 0;
        },
        w32.WM_KILLFOCUS => {
            surface.handleFocus(false);
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn msgWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const app: *App = @ptrFromInt(@as(usize, @bitCast(userdata)));

    if (msg == WM_APP_WAKEUP) {
        app.tick();
        return 0;
    }

    if (msg == w32.WM_TIMER and wparam == QUIT_TIMER_ID) {
        _ = w32.KillTimer(hwnd, QUIT_TIMER_ID);
        app.quit_timer_state = .expired;
        app.quit_requested = true;
        w32.PostQuitMessage(0);
        return 0;
    }

    return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
}
