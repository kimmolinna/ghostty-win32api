//! Win32 virtual-key → Ghostty input.Key mapping and host keybinds.
const std = @import("std");
const input = @import("../../input.zig");
const w32 = @import("win32.zig");

pub const Mods = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    _pad: u4 = 0,
};

/// Host-side MVWT keybinds (before / in addition to config bindings).
pub const Builtin = enum {
    focus_pane_1, // Ctrl+1
    focus_pane_2, // Ctrl+2
    new_split_right, // Ctrl+Shift+D
};

pub fn matchBuiltin(mods: Mods, vk: u32) ?Builtin {
    if (mods.ctrl and !mods.shift and !mods.alt and !mods.super) {
        if (vk == '1' or vk == w32.VK_NUMPAD1) return .focus_pane_1;
        if (vk == '2' or vk == w32.VK_NUMPAD2) return .focus_pane_2;
    }
    if (mods.ctrl and mods.shift and !mods.alt and vk == 'D') return .new_split_right;
    return null;
}

pub fn modsFromWin32() Mods {
    return .{
        .shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0,
        .ctrl = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0,
        .alt = w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0,
        .super = w32.GetKeyState(@as(i32, w32.VK_LWIN)) < 0 or
            w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0,
    };
}

/// Ghostty input.Mods from Win32 key state.
pub fn getModifiers() input.Mods {
    var mods: input.Mods = .{};

    if (w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0) {
        mods.shift = true;
        if (w32.GetKeyState(@as(i32, w32.VK_RSHIFT)) < 0) {
            mods.sides.shift = .right;
        }
    }
    if (w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0) {
        mods.ctrl = true;
        if (w32.GetKeyState(@as(i32, w32.VK_RCONTROL)) < 0) {
            mods.sides.ctrl = .right;
        }
    }
    if (w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0) {
        mods.alt = true;
        if (w32.GetKeyState(@as(i32, w32.VK_RMENU)) < 0) {
            mods.sides.alt = .right;
        }
    }
    if (w32.GetKeyState(@as(i32, w32.VK_LWIN)) < 0 or
        w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0)
    {
        mods.super = true;
        if (w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0) {
            mods.sides.super = .right;
        }
    }
    if (w32.GetKeyState(@as(i32, w32.VK_CAPITAL)) & 1 != 0) {
        mods.caps_lock = true;
    }
    if (w32.GetKeyState(@as(i32, w32.VK_NUMLOCK)) & 1 != 0) {
        mods.num_lock = true;
    }
    return mods;
}

pub fn isModifierVk(vk: u16) bool {
    return switch (vk) {
        w32.VK_SHIFT,
        w32.VK_LSHIFT,
        w32.VK_RSHIFT,
        w32.VK_CONTROL,
        w32.VK_LCONTROL,
        w32.VK_RCONTROL,
        w32.VK_MENU,
        w32.VK_LMENU,
        w32.VK_RMENU,
        w32.VK_LWIN,
        w32.VK_RWIN,
        w32.VK_CAPITAL,
        w32.VK_NUMLOCK,
        w32.VK_SCROLL,
        => true,
        else => false,
    };
}

pub fn mapVirtualKey(vk: u16, extended: bool) input.Key {
    return switch (vk) {
        0x41 => .key_a,
        0x42 => .key_b,
        0x43 => .key_c,
        0x44 => .key_d,
        0x45 => .key_e,
        0x46 => .key_f,
        0x47 => .key_g,
        0x48 => .key_h,
        0x49 => .key_i,
        0x4A => .key_j,
        0x4B => .key_k,
        0x4C => .key_l,
        0x4D => .key_m,
        0x4E => .key_n,
        0x4F => .key_o,
        0x50 => .key_p,
        0x51 => .key_q,
        0x52 => .key_r,
        0x53 => .key_s,
        0x54 => .key_t,
        0x55 => .key_u,
        0x56 => .key_v,
        0x57 => .key_w,
        0x58 => .key_x,
        0x59 => .key_y,
        0x5A => .key_z,

        0x30 => .digit_0,
        0x31 => .digit_1,
        0x32 => .digit_2,
        0x33 => .digit_3,
        0x34 => .digit_4,
        0x35 => .digit_5,
        0x36 => .digit_6,
        0x37 => .digit_7,
        0x38 => .digit_8,
        0x39 => .digit_9,

        w32.VK_F1 => .f1,
        w32.VK_F2 => .f2,
        w32.VK_F3 => .f3,
        w32.VK_F4 => .f4,
        w32.VK_F5 => .f5,
        w32.VK_F6 => .f6,
        w32.VK_F7 => .f7,
        w32.VK_F8 => .f8,
        w32.VK_F9 => .f9,
        w32.VK_F10 => .f10,
        w32.VK_F11 => .f11,
        w32.VK_F12 => .f12,
        w32.VK_F13 => .f13,
        w32.VK_F14 => .f14,
        w32.VK_F15 => .f15,
        w32.VK_F16 => .f16,
        w32.VK_F17 => .f17,
        w32.VK_F18 => .f18,
        w32.VK_F19 => .f19,
        w32.VK_F20 => .f20,
        w32.VK_F21 => .f21,
        w32.VK_F22 => .f22,
        w32.VK_F23 => .f23,
        w32.VK_F24 => .f24,

        w32.VK_RETURN => if (extended) .numpad_enter else .enter,
        w32.VK_BACK => .backspace,
        w32.VK_TAB => .tab,
        w32.VK_ESCAPE => .escape,
        w32.VK_SPACE => .space,
        w32.VK_PRIOR => .page_up,
        w32.VK_NEXT => .page_down,
        w32.VK_END => .end,
        w32.VK_HOME => .home,
        w32.VK_LEFT => .arrow_left,
        w32.VK_UP => .arrow_up,
        w32.VK_RIGHT => .arrow_right,
        w32.VK_DOWN => .arrow_down,
        w32.VK_INSERT => .insert,
        w32.VK_DELETE => .delete,

        w32.VK_LSHIFT => .shift_left,
        w32.VK_RSHIFT => .shift_right,
        w32.VK_LCONTROL => .control_left,
        w32.VK_RCONTROL => .control_right,
        w32.VK_LMENU => .alt_left,
        w32.VK_RMENU => .alt_right,
        w32.VK_LWIN => .meta_left,
        w32.VK_RWIN => .meta_right,
        w32.VK_SHIFT => if (extended) .shift_right else .shift_left,
        w32.VK_CONTROL => if (extended) .control_right else .control_left,
        w32.VK_MENU => if (extended) .alt_right else .alt_left,

        w32.VK_CAPITAL => .caps_lock,
        w32.VK_NUMLOCK => .num_lock,
        w32.VK_SCROLL => .scroll_lock,

        w32.VK_OEM_1 => .semicolon,
        w32.VK_OEM_PLUS => .equal,
        w32.VK_OEM_COMMA => .comma,
        w32.VK_OEM_MINUS => .minus,
        w32.VK_OEM_PERIOD => .period,
        w32.VK_OEM_2 => .slash,
        w32.VK_OEM_3 => .backquote,
        w32.VK_OEM_4 => .bracket_left,
        w32.VK_OEM_5 => .backslash,
        w32.VK_OEM_6 => .bracket_right,
        w32.VK_OEM_7 => .quote,

        w32.VK_NUMPAD0 => .numpad_0,
        w32.VK_NUMPAD1 => .numpad_1,
        w32.VK_NUMPAD2 => .numpad_2,
        w32.VK_NUMPAD3 => .numpad_3,
        w32.VK_NUMPAD4 => .numpad_4,
        w32.VK_NUMPAD5 => .numpad_5,
        w32.VK_NUMPAD6 => .numpad_6,
        w32.VK_NUMPAD7 => .numpad_7,
        w32.VK_NUMPAD8 => .numpad_8,
        w32.VK_NUMPAD9 => .numpad_9,
        w32.VK_MULTIPLY => .numpad_multiply,
        w32.VK_ADD => .numpad_add,
        w32.VK_SEPARATOR => .numpad_separator,
        w32.VK_SUBTRACT => .numpad_subtract,
        w32.VK_DECIMAL => .numpad_decimal,
        w32.VK_DIVIDE => .numpad_divide,

        w32.VK_APPS => .context_menu,
        w32.VK_PAUSE => .pause,

        else => .unidentified,
    };
}
