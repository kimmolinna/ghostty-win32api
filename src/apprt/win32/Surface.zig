//! Win32 terminal surface (WS_CHILD HWND). Forwards input to core; DX12 binds to hwnd.
//! No WGL / OpenGL — platform.windows.hwnd drives DirectX12.zig.
const Surface = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");
const termio = @import("../../termio.zig");
const CoreSurface = @import("../../Surface.zig");
const internal_os = @import("../../os/main.zig");

const App = @import("App.zig");
const Window = @import("Window.zig");
const key = @import("key.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// Shape expected by DirectX12.zig: `opts.rt_surface.platform.windows`.
pub const PlatformWindows = struct {
    hwnd: ?std.os.windows.HANDLE = null,
    swap_chain_panel: ?*anyopaque = null,
    shared_texture: struct {
        enabled: bool = false,
        width: u32 = 0,
        height: u32 = 0,
    } = .{},
};

hwnd: ?w32.HWND = null,
width: u32 = 800,
height: u32 = 600,
scale: f32 = 1.0,
app: *App,
parent_window: *Window = undefined,
core_surface: CoreSurface = undefined,
core_surface_ready: bool = false,
core_surface_initialized: bool = false,

/// Consumed by the DX12 renderer (see DirectX12.init).
platform: struct { windows: PlatformWindows } = .{ .windows = .{} },

high_surrogate: u16 = 0,
mouse_button_mask: u3 = 0,
ime_composing: bool = false,
key_event_produced_text: bool = false,
in_live_resize: bool = false,
frame_event: ?w32.HANDLE = null,
current_cursor: ?w32.HCURSOR = null,
mouse_visible: bool = true,
last_reported_visible: ?bool = null,
title: ?[:0]const u8 = null,

pub fn init(
    self: *Surface,
    app: *App,
    parent: *Window,
    context: apprt.surface.NewSurfaceContext,
) !void {
    self.* = .{
        .app = app,
        .parent_window = parent,
    };

    self.frame_event = w32.CreateEventW(null, 1, 0, null);

    const parent_hwnd = parent.hwnd orelse return error.Win32Error;
    const sr = parent.surfaceRect();
    const hwnd = w32.CreateWindowExW(
        0,
        App.TERMINAL_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD,
        sr.left,
        sr.top,
        @intCast(@max(sr.right - sr.left, 1)),
        @intCast(@max(sr.bottom - sr.top, 1)),
        parent_hwnd,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;
    self.hwnd = hwnd;
    errdefer {
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }

    // DX12 platform — must be set before core_surface.init (renderer reads it).
    self.platform = .{
        .windows = .{
            .hwnd = @ptrCast(hwnd),
            .swap_chain_panel = null,
            .shared_texture = .{ .enabled = false, .width = 0, .height = 0 },
        },
    };

    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    self.updateDpiScale();
    self.updateClientSize();

    log.debug("Win32 surface created: {}x{} scale={d:.2}", .{
        self.width,
        self.height,
        self.scale,
    });

    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.UpdateWindow(hwnd);

    const alloc = app.core_app.alloc;

    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);

    var config = try apprt.surface.newConfig(app.core_app, &app.config, context);
    defer config.deinit();

    try self.core_surface.init(
        alloc,
        &config,
        app.core_app,
        app,
        self,
    );

    self.core_surface_ready = true;
    self.core_surface_initialized = true;
}

pub fn deinit(self: *Surface) void {
    log.debug("surface deinit: start addr={x}", .{@intFromPtr(self)});

    if (self.core_surface_initialized) {
        self.core_surface.deinit();
        self.app.core_app.deleteSurface(self);
        self.core_surface_initialized = false;
        self.core_surface_ready = false;
    }

    if (self.frame_event) |event| {
        _ = w32.CloseHandle(event);
        self.frame_event = null;
    }

    self.deinitGui();
}

fn deinitGui(self: *Surface) void {
    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }
    self.core_surface_ready = false;
    self.platform.windows.hwnd = null;
}

fn updateDpiScale(self: *Surface) void {
    if (self.hwnd) |hwnd| {
        const dpi = w32.GetDpiForWindow(hwnd);
        if (dpi != 0) {
            self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
        }
    }
}

fn updateClientSize(self: *Surface) void {
    if (self.hwnd) |hwnd| {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &rect) != 0) {
            self.width = @intCast(rect.right - rect.left);
            self.height = @intCast(rect.bottom - rect.top);
        }
    }
}

// -----------------------------------------------------------------------
// Methods called by core Surface.zig (rt_surface.*)
// -----------------------------------------------------------------------

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    return .{ .x = self.scale, .y = self.scale };
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    return .{ .width = self.width, .height = self.height };
}

pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    if (self.hwnd) |hwnd| {
        var point: w32.POINT = undefined;
        if (w32.GetCursorPos_(&point) != 0) {
            _ = w32.ScreenToClient(hwnd, &point);
            return .{
                .x = @floatFromInt(point.x),
                .y = @floatFromInt(point.y),
            };
        }
    }
    return error.GetCursorPosFailed;
}

pub fn setVisible(self: *Surface, visible: bool) void {
    if (!self.core_surface_ready) return;
    if (self.last_reported_visible == visible) return;
    self.last_reported_visible = visible;
    self.core_surface.occlusionCallback(visible) catch |err| {
        self.last_reported_visible = null;
        log.warn("occlusionCallback failed err={}", .{err});
    };
}

pub fn close(self: *Surface, process_active: bool) void {
    log.debug("Surface.close called process_active={}", .{process_active});
    if (process_active) {
        const result = w32.MessageBoxW(
            self.parent_window.hwnd,
            std.unicode.utf8ToUtf16LeStringLiteral(
                "A process is still running in this terminal.\nClose anyway?",
            ),
            std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
            w32.MB_OKCANCEL | w32.MB_ICONWARNING | w32.MB_DEFBUTTON2,
        );
        if (result != w32.IDOK) return;
    }
    if (self.hwnd) |hwnd| {
        _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
    }
}

pub fn supportsClipboard(
    self: *const Surface,
    clipboard_type: apprt.Clipboard,
) bool {
    _ = self;
    return switch (clipboard_type) {
        .standard => true,
        .selection, .primary => false,
    };
}

fn confirmClipboard(
    self: *Surface,
    comptime message: [:0]const u8,
    comptime title: [:0]const u8,
) bool {
    const result = w32.MessageBoxW(
        self.parent_window.hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral(message),
        std.unicode.utf8ToUtf16LeStringLiteral(title),
        w32.MB_OKCANCEL | w32.MB_ICONWARNING | w32.MB_DEFBUTTON2,
    );
    return result == w32.IDOK;
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !bool {
    if (clipboard_type != .standard) return false;

    const alloc = self.app.core_app.alloc;

    const utf8z: [:0]const u8 = blk: {
        if (w32.OpenClipboard(self.hwnd) == 0) {
            log.warn("OpenClipboard failed", .{});
            return false;
        }
        defer _ = w32.CloseClipboard();

        const hglobal = w32.GetClipboardData(w32.CF_UNICODETEXT) orelse return false;
        const ptr16 = w32.GlobalLock(hglobal) orelse {
            log.warn("GlobalLock failed", .{});
            return false;
        };
        defer _ = w32.GlobalUnlock(hglobal);

        const wptr: [*]const u16 = @ptrCast(@alignCast(ptr16));
        var wlen: usize = 0;
        while (wptr[wlen] != 0) wlen += 1;

        const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, wptr[0..wlen]) catch |err| {
            log.warn("utf16LeToUtf8Alloc failed: {}", .{err});
            return false;
        };
        defer alloc.free(utf8);
        break :blk try alloc.dupeZ(u8, utf8);
    };
    defer alloc.free(utf8z);

    const core_app = self.app.core_app;
    const surface_id = self.core_surface.id;

    self.core_surface.completeClipboardRequest(state, utf8z, false) catch |err| {
        const approved = switch (err) {
            error.UnsafePaste => self.confirmClipboard(
                "The text being pasted contains characters that could run " ++
                    "commands unexpectedly (for example, newlines).\n\nPaste anyway?",
                "Ghostty — Potentially Unsafe Paste",
            ),
            error.UnauthorizedPaste => self.confirmClipboard(
                "An application is requesting access to read the clipboard.\n\nAllow this?",
                "Ghostty — Authorize Clipboard Access",
            ),
            else => {
                log.err("completeClipboardRequest error: {}", .{err});
                return true;
            },
        };
        if (approved) {
            const cs = core_app.findSurfaceByID(surface_id) orelse return true;
            cs.completeClipboardRequest(state, utf8z, true) catch |e| {
                log.err("completeClipboardRequest (confirmed) error: {}", .{e});
            };
        }
    };

    return true;
}

pub fn setClipboard(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    if (clipboard_type != .standard) return;

    const app = self.app;

    if (confirm) {
        if (!self.confirmClipboard(
            "An application is requesting to write to the system clipboard.\n\nAllow this?",
            "Ghostty — Authorize Clipboard Access",
        )) return;
    }

    const text = blk: {
        for (contents) |c| {
            if (std.mem.eql(u8, c.mime, "text/plain")) break :blk c.data;
        }
        return;
    };

    const alloc = app.core_app.alloc;
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(alloc, text);
    defer alloc.free(utf16);

    const byte_size = (utf16.len + 1) * @sizeOf(u16);
    const hglobal = w32.GlobalAlloc(w32.GMEM_MOVEABLE, byte_size) orelse {
        log.warn("GlobalAlloc failed for clipboard write", .{});
        return;
    };

    const dst_bytes = w32.GlobalLock(hglobal) orelse {
        log.warn("GlobalLock failed for clipboard write", .{});
        _ = w32.GlobalFree(hglobal);
        return;
    };

    const dst16: [*]u16 = @ptrCast(@alignCast(dst_bytes));
    @memcpy(dst16[0..utf16.len], utf16);
    dst16[utf16.len] = 0;
    _ = w32.GlobalUnlock(hglobal);

    if (w32.OpenClipboard(null) == 0) {
        log.warn("OpenClipboard failed for clipboard write", .{});
        _ = w32.GlobalFree(hglobal);
        return;
    }
    defer _ = w32.CloseClipboard();

    _ = w32.EmptyClipboard();
    if (w32.SetClipboardData(w32.CF_UNICODETEXT, hglobal) == null) {
        log.warn("SetClipboardData failed", .{});
        _ = w32.GlobalFree(hglobal);
    }
}

pub fn defaultTermioEnv(self: *const Surface) !std.process.EnvMap {
    const alloc = self.app.core_app.alloc;
    var env = try internal_os.getEnvMap(alloc);
    errdefer env.deinit();
    return env;
}

pub fn setTitle(self: *Surface, title: [:0]const u8) void {
    const alloc = self.app.core_app.alloc;
    if (self.title) |old| alloc.free(old);
    self.title = alloc.dupeZ(u8, title) catch null;
    self.parent_window.setTitle(title);
}

pub fn getTitle(self: *Surface) ?[:0]const u8 {
    return self.title;
}

pub fn setMouseShape(self: *Surface, shape: terminal.MouseShape) void {
    const cursor = switch (shape) {
        .text => w32.LoadCursorW(null, w32.IDC_IBEAM),
        .pointer => w32.LoadCursorW(null, w32.IDC_HAND),
        .crosshair => w32.LoadCursorW(null, w32.IDC_CROSS),
        .e_resize, .w_resize, .ew_resize => w32.LoadCursorW(null, w32.IDC_SIZEWE),
        .n_resize, .s_resize, .ns_resize => w32.LoadCursorW(null, w32.IDC_SIZENS),
        .nwse_resize, .nw_resize, .se_resize => w32.LoadCursorW(null, w32.IDC_SIZENWSE),
        .nesw_resize, .ne_resize, .sw_resize => w32.LoadCursorW(null, w32.IDC_SIZENESW),
        .not_allowed => w32.LoadCursorW(null, w32.IDC_NO),
        .progress => w32.LoadCursorW(null, w32.IDC_APPSTARTING),
        .wait => w32.LoadCursorW(null, w32.IDC_WAIT),
        else => w32.LoadCursorW(null, w32.IDC_ARROW),
    };
    self.current_cursor = cursor;
    if (cursor) |c| _ = w32.SetCursor(c);
}

pub fn handleSetCursor(self: *Surface) bool {
    if (!self.mouse_visible) {
        _ = w32.SetCursor(null);
        return true;
    }
    if (self.current_cursor) |c| {
        _ = w32.SetCursor(c);
        return true;
    }
    return false;
}

pub fn core(self: *Surface) *CoreSurface {
    return &self.core_surface;
}

pub fn rtApp(self: *Surface) *App {
    return self.app;
}

pub fn signalFrameDrawn(self: *Surface) void {
    if (self.frame_event) |event| {
        _ = w32.SetEvent(event);
    }
}

// -----------------------------------------------------------------------
// Message handlers (from App.surfaceWndProc)
// -----------------------------------------------------------------------

pub fn handleResize(self: *Surface, width: u32, height: u32) void {
    if (width == 0 or height == 0) return;
    self.width = width;
    self.height = height;

    if (!self.core_surface_ready) return;

    self.core_surface.sizeCallback(.{ .width = width, .height = height }) catch |err| {
        log.err("sizeCallback error: {}", .{err});
        return;
    };

    if (self.in_live_resize) {
        if (self.frame_event) |event| {
            _ = w32.ResetEvent(event);
        }
        self.core_surface.renderer_thread.wakeup.notify() catch {};
        if (self.frame_event) |event| {
            _ = w32.WaitForSingleObject(event, 16);
        }
    } else {
        self.core_surface.renderer_thread.wakeup.notify() catch {};
    }
}

pub fn handleDpiChange(self: *Surface) void {
    self.updateDpiScale();
    if (!self.core_surface_ready) return;
    self.core_surface.contentScaleCallback(.{ .x = self.scale, .y = self.scale }) catch |err| {
        log.err("contentScaleCallback error: {}", .{err});
    };
}

pub fn handleKeyEvent(self: *Surface, wparam: usize, lparam: isize, action: input.Action) void {
    if (!self.core_surface_ready) return;
    const vk: u16 = @intCast(wparam & 0xFFFF);

    if (vk == w32.VK_PROCESSKEY) return;
    if (vk == w32.VK_PACKET) return;

    // Host MVWT keybinds (Ctrl+1 / Ctrl+2 / Ctrl+Shift+D).
    if (action == .press or action == .repeat) {
        if (self.parent_window.handleHostKeybind(vk)) return;
    }

    const extended = (lparam & (1 << 24)) != 0;
    const mapped = key.mapVirtualKey(vk, extended);
    const mods = key.getModifiers();

    if (self.isWin32InputMode()) {
        if (!mapped.modifier()) {
            const actual_action_w32 = if (action == .press and (lparam & (1 << 30)) != 0)
                input.Action.repeat
            else
                action;
            const unshifted_cp: u21 = if (mapped.codepoint()) |cp| cp else 0;
            const effect = self.core_surface.keyCallback(.{
                .action = actual_action_w32,
                .key = mapped,
                .mods = mods,
                .consumed_mods = .{},
                .utf8 = "",
                .unshifted_codepoint = unshifted_cp,
            }) catch |err| {
                log.err("key callback error: {}", .{err});
                return;
            };
            if (effect == .consumed or effect == .closed) return;
        }
        self.sendWin32InputEvent(vk, lparam, action);
        return;
    }

    const actual_action = if (action == .press and (lparam & (1 << 30)) != 0)
        input.Action.repeat
    else
        action;

    const unshifted_codepoint: u21 = if (mapped.codepoint()) |cp| cp else 0;

    var utf8_buf: [16]u8 = undefined;
    var utf8_text: []const u8 = "";
    var consumed_mods: input.Mods = .{};
    var event_mods = mods;

    self.key_event_produced_text = false;

    if ((actual_action == .press or actual_action == .repeat) and !key.isModifierVk(vk)) {
        var keyboard_state: [256]u8 = undefined;
        if (w32.GetKeyboardState(&keyboard_state) != 0) {
            const scancode: u32 = @intCast((lparam >> 16) & 0xFF);
            var utf16_buf: [4]u16 = undefined;
            const result = w32.ToUnicode(
                @intCast(vk),
                scancode,
                &keyboard_state,
                &utf16_buf,
                utf16_buf.len,
                0,
            );
            if (result > 0) {
                const utf16_slice = utf16_buf[0..@intCast(result)];
                if (utf16_slice[0] >= 0x20) {
                    const len = std.unicode.utf16LeToUtf8(&utf8_buf, utf16_slice) catch 0;
                    if (len > 0) {
                        utf8_text = utf8_buf[0..len];
                        if (mods.shift) consumed_mods.shift = true;
                        self.key_event_produced_text = true;
                        if (mods.ctrl and mods.alt and
                            (keyboard_state[w32.VK_RMENU] & 0x80) != 0)
                        {
                            event_mods.ctrl = false;
                            event_mods.alt = false;
                            consumed_mods.ctrl = true;
                            consumed_mods.alt = true;
                        }
                    }
                }
            }
        }
    }

    _ = self.core_surface.keyCallback(.{
        .action = actual_action,
        .key = mapped,
        .mods = event_mods,
        .consumed_mods = consumed_mods,
        .utf8 = utf8_text,
        .unshifted_codepoint = unshifted_codepoint,
    }) catch |err| {
        log.err("key callback error: {}", .{err});
    };
}

pub fn handleCharEvent(self: *Surface, wparam: usize) void {
    if (!self.core_surface_ready) return;
    const char_code: u16 = @intCast(wparam & 0xFFFF);

    if (char_code < 0x20 and char_code != '\t' and char_code != '\r' and char_code != '\n') return;

    const codepoint: u21 = if (char_code >= 0xD800 and char_code <= 0xDBFF) {
        self.high_surrogate = char_code;
        return;
    } else if (char_code >= 0xDC00 and char_code <= 0xDFFF) blk: {
        if (self.high_surrogate != 0) {
            const hi: u21 = self.high_surrogate;
            self.high_surrogate = 0;
            break :blk @intCast((@as(u21, hi - 0xD800) << 10) + (@as(u21, char_code) - 0xDC00) + 0x10000);
        }
        return;
    } else blk: {
        self.high_surrogate = 0;
        break :blk @intCast(char_code);
    };

    var utf8_buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return;

    if (self.isWin32InputMode()) {
        self.sendWin32CharEvent(char_code);
        return;
    }

    _ = self.core_surface.keyCallback(.{
        .action = .press,
        .key = .unidentified,
        .mods = .{},
        .consumed_mods = .{},
        .composing = false,
        .utf8 = utf8_buf[0..len],
    }) catch |err| {
        log.err("text input callback error: {}", .{err});
    };
}

pub fn handleMouseButton(
    self: *Surface,
    button: input.MouseButton,
    action: input.MouseButtonState,
    lparam: isize,
) void {
    if (!self.core_surface_ready) return;
    const x: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, lparam & 0xFFFF))));
    const y: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF))));
    const mods = key.getModifiers();

    const bit: u3 = switch (button) {
        .left => 1,
        .right => 2,
        .middle => 4,
        else => 0,
    };
    if (bit != 0) {
        const prev = self.mouse_button_mask;
        if (action == .press) {
            self.mouse_button_mask |= bit;
            if (prev == 0) {
                if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
            }
        } else {
            self.mouse_button_mask &= ~bit;
            if (prev != 0 and self.mouse_button_mask == 0) {
                _ = w32.ReleaseCapture();
            }
        }
    }

    self.core_surface.cursorPosCallback(.{ .x = x, .y = y }, mods) catch |err| {
        log.err("cursor pos callback error: {}", .{err});
    };

    _ = self.core_surface.mouseButtonCallback(action, button, mods) catch |err| {
        log.err("mouse button callback error: {}", .{err});
    };
}

pub fn handleMouseMove(self: *Surface, lparam: isize) void {
    if (!self.core_surface_ready) return;
    const x: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, lparam & 0xFFFF))));
    const y: f32 = @floatFromInt(@as(i16, @truncate(@as(isize, (lparam >> 16) & 0xFFFF))));
    const mods = key.getModifiers();
    self.core_surface.cursorPosCallback(.{ .x = x, .y = y }, mods) catch |err| {
        log.err("cursor pos callback error: {}", .{err});
    };
}

pub fn handleMouseWheel(self: *Surface, wparam: usize, axis: enum { vertical, horizontal }) void {
    if (!self.core_surface_ready) return;
    const raw_delta: i16 = @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF)));
    const delta: f64 = @as(f64, @floatFromInt(raw_delta)) / @as(f64, @floatFromInt(w32.WHEEL_DELTA));
    const scroll_mods: input.ScrollMods = .{};
    const xoff: f64 = if (axis == .horizontal) delta else 0;
    const yoff: f64 = if (axis == .vertical) delta else 0;
    self.core_surface.scrollCallback(xoff, yoff, scroll_mods) catch |err| {
        log.err("scroll callback error: {}", .{err});
    };
}

pub fn handleImeStartComposition(self: *Surface) void {
    self.ime_composing = true;
    self.high_surrogate = 0;
    self.positionImeWindow();
}

pub fn handleImeEndComposition(self: *Surface) void {
    self.ime_composing = false;
    if (self.core_surface_ready) {
        self.core_surface.preeditCallback(null) catch {};
    }
}

pub fn handleImeComposition(self: *Surface, lparam: isize) bool {
    if (!self.core_surface_ready) return false;
    const hwnd = self.hwnd orelse return false;
    const himc = w32.ImmGetContext(hwnd) orelse return false;
    defer _ = w32.ImmReleaseContext(hwnd, himc);

    if ((lparam & w32.GCS_RESULTSTR) != 0) {
        const n = w32.ImmGetCompositionStringW(himc, w32.GCS_RESULTSTR, null, 0);
        if (n > 0) {
            const u16_len: usize = @intCast(@divTrunc(n, 2));
            var buf16: [256]u16 = undefined;
            const take = @min(u16_len, buf16.len);
            _ = w32.ImmGetCompositionStringW(himc, w32.GCS_RESULTSTR, &buf16, @intCast(take * 2));
            self.sendImeText(buf16[0..take]);
            return true;
        }
    }

    if ((lparam & w32.GCS_COMPSTR) != 0) {
        const n = w32.ImmGetCompositionStringW(himc, w32.GCS_COMPSTR, null, 0);
        if (n > 0) {
            const u16_len: usize = @intCast(@divTrunc(n, 2));
            var buf16: [256]u16 = undefined;
            const take = @min(u16_len, buf16.len);
            _ = w32.ImmGetCompositionStringW(himc, w32.GCS_COMPSTR, &buf16, @intCast(take * 2));
            var buf8: [buf16.len * 3]u8 = undefined;
            const len8 = std.unicode.utf16LeToUtf8(&buf8, buf16[0..take]) catch 0;
            self.core_surface.preeditCallback(if (len8 == 0) null else buf8[0..len8]) catch {};
        } else {
            self.core_surface.preeditCallback(null) catch {};
        }
        self.positionImeWindow();
    }
    return false;
}

fn sendImeText(self: *Surface, utf16: []const u16) void {
    if (self.isWin32InputMode()) {
        for (utf16) |code_unit| {
            self.sendWin32CharEvent(code_unit);
        }
        return;
    }

    var utf8_buf: [256]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&utf8_buf, utf16) catch |err| {
        log.warn("IME utf16→utf8 error: {}", .{err});
        return;
    };
    if (len == 0) return;

    _ = self.core_surface.keyCallback(.{
        .action = .press,
        .key = .unidentified,
        .mods = .{},
        .consumed_mods = .{},
        .composing = false,
        .utf8 = utf8_buf[0..len],
    }) catch |err| {
        log.err("IME text callback error: {}", .{err});
    };
}

fn positionImeWindow(self: *Surface) void {
    const hwnd = self.hwnd orelse return;
    const himc = w32.ImmGetContext(hwnd) orelse return;
    defer _ = w32.ImmReleaseContext(hwnd, himc);

    var pos = w32.POINT{ .x = 0, .y = 0 };
    if (self.core_surface_ready) {
        const ime_pos = self.core_surface.imePoint();
        pos.x = @intFromFloat(ime_pos.x);
        pos.y = @intFromFloat(ime_pos.y);
    }

    const cf = w32.COMPOSITIONFORM{
        .dwStyle = w32.CFS_POINT,
        .ptCurrentPos = pos,
        .rcArea = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    };
    _ = w32.ImmSetCompositionWindow(himc, &cf);
}

pub fn isWin32InputMode(self: *Surface) bool {
    _ = self;
    // Wintty core does not expose a .win32_input terminal mode yet.
    return false;
}

fn sendWin32InputEvent(self: *Surface, vk: u16, lparam: isize, action: input.Action) void {
    const scancode: u16 = @intCast((lparam >> 16) & 0xFF);
    const extended = (lparam & (1 << 24)) != 0;
    const repeat_count: u16 = @intCast(lparam & 0xFFFF);
    const key_down: u1 = if (action == .press or action == .repeat) 1 else 0;

    var unicode_char: u16 = 0;
    if (key_down == 1 and !key.isModifierVk(vk)) {
        var keyboard_state: [256]u8 = undefined;
        if (w32.GetKeyboardState(&keyboard_state) != 0) {
            var utf16_buf: [4]u16 = undefined;
            const result = w32.ToUnicode(
                @intCast(vk),
                @intCast(scancode),
                &keyboard_state,
                &utf16_buf,
                utf16_buf.len,
                0,
            );
            if (result > 0) {
                unicode_char = utf16_buf[0];
            }
        }
    }

    var ctrl_state: u32 = 0;
    if (w32.GetKeyState(@as(i32, w32.VK_RSHIFT)) < 0 or
        w32.GetKeyState(@as(i32, w32.VK_LSHIFT)) < 0 or
        w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0)
        ctrl_state |= 0x0010;
    if (w32.GetKeyState(@as(i32, w32.VK_LCONTROL)) < 0)
        ctrl_state |= 0x0008;
    if (w32.GetKeyState(@as(i32, w32.VK_RCONTROL)) < 0)
        ctrl_state |= 0x0004;
    if (w32.GetKeyState(@as(i32, w32.VK_LMENU)) < 0)
        ctrl_state |= 0x0002;
    if (w32.GetKeyState(@as(i32, w32.VK_RMENU)) < 0)
        ctrl_state |= 0x0001;
    if (w32.GetKeyState(@as(i32, w32.VK_CAPITAL)) & 1 != 0)
        ctrl_state |= 0x0080;
    if (w32.GetKeyState(@as(i32, w32.VK_NUMLOCK)) & 1 != 0)
        ctrl_state |= 0x0020;
    if (w32.GetKeyState(@as(i32, w32.VK_SCROLL)) & 1 != 0)
        ctrl_state |= 0x0040;
    if (extended)
        ctrl_state |= 0x0100;

    self.writeWin32InputSequence(vk, scancode, unicode_char, key_down, ctrl_state, repeat_count);
}

pub fn sendWin32CharEvent(self: *Surface, char_code: u16) void {
    self.writeWin32InputSequence(0, 0, char_code, 1, 0, 1);
    self.writeWin32InputSequence(0, 0, char_code, 0, 0, 1);
}

fn writeWin32InputSequence(
    self: *Surface,
    vk: u16,
    sc: u16,
    uc: u16,
    kd: u1,
    cs: u32,
    rc: u16,
) void {
    var buf: [64]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{};{};{};{};{};{}_", .{
        vk, sc, uc, kd, cs, rc,
    }) catch return;

    const msg = termio.Message.writeReq(
        self.app.core_app.alloc,
        seq,
    ) catch return;
    self.core_surface.io.queueMessage(msg, .unlocked);
}

pub fn handleFocus(self: *Surface, focused: bool) void {
    if (!self.core_surface_ready) return;
    if (!focused) {
        self.high_surrogate = 0;
        if (self.ime_composing) {
            self.ime_composing = false;
            if (self.hwnd) |hwnd| {
                if (w32.ImmGetContext(hwnd)) |himc| {
                    defer _ = w32.ImmReleaseContext(hwnd, himc);
                    _ = w32.ImmNotifyIME(himc, w32.NI_COMPOSITIONSTR, w32.CPS_CANCEL, 0);
                }
            }
            self.core_surface.preeditCallback(null) catch {};
        }
        var ks: [256]u8 = undefined;
        if (w32.GetKeyboardState(&ks) != 0) {
            var buf: [4]u16 = undefined;
            _ = w32.ToUnicode(@intCast(w32.VK_SPACE), 0x39, &ks, &buf, buf.len, 0);
            _ = w32.ToUnicode(@intCast(w32.VK_SPACE), 0x39, &ks, &buf, buf.len, 0);
        }
    }
    self.core_surface.focusCallback(focused) catch |err| {
        log.err("focus callback error: {}", .{err});
    };
}
