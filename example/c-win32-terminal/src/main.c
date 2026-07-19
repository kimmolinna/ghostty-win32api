// example/c-win32-terminal/src/main.c
//
// Issue #82 spike host: pure Win32 HWND + DX12 via libghostty, no XAML/.NET.
//
// Deliverables:
//   1. Multi-surface — two side-by-side child HWNDs (ugly split, no tab chrome)
//   2. Clipboard — Win32 OpenClipboard / CF_UNICODETEXT
//   3. Text input — dead keys, IME composition, UTF-16 surrogates
//   4. Resize — timer ticks during WM_ENTERSIZEMOVE (DX12 swap chain)
//   5. Dark mode — DwmSetWindowAttribute immersive dark title bar

#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#include <windows.h>
#include <windowsx.h>
#include <dwmapi.h>
#include <imm.h>
#include <ghostty.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

// Portable strdup (MSVC provides _strdup; MinGW/zig-gnu provide strdup).
static char* xstrdup(const char* s) {
    if (!s) s = "";
    size_t n = strlen(s) + 1;
    char* out = (char*)malloc(n);
    if (out) memcpy(out, s, n);
    return out;
}

static void spike_log(const char* fmt, ...) {
    FILE* f = fopen("spike82.log", "a");
    va_list ap;
    if (f) {
        SYSTEMTIME st;
        GetLocalTime(&st);
        fprintf(f, "%02u:%02u:%02u.%03u ",
                st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
        va_start(ap, fmt);
        vfprintf(f, fmt, ap);
        va_end(ap);
        fputc('\n', f);
        fclose(f);
    }
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "imm32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

#define WM_GHOSTTY_WAKEUP (WM_APP + 1)
#define WM_GHOSTTY_CLIPBOARD (WM_APP + 2)
#define WM_GHOSTTY_RESIZE_TIMER 1
#define RESIZE_TIMER_MS 8
#define SPLIT_GAP_PX 4
#define SURFACE_COUNT 2

// --- Surface slot (one child HWND + one ghostty surface) ---

typedef struct {
    HWND hwnd;
    ghostty_surface_t surface;
    WCHAR high_surrogate;
    bool ime_composing;
} SurfaceSlot;

static HWND g_hwnd = NULL;
static HWND g_split_bar = NULL;
static ghostty_app_t g_app = NULL;
static SurfaceSlot g_slots[SURFACE_COUNT];
static int g_focused = 0;
static double g_split_ratio = 0.5; // left pane share of client width
static bool g_dragging_split = false;
static LARGE_INTEGER g_qpc_freq;
static LARGE_INTEGER g_start_qpc;
static bool g_first_frame_logged = false;

// Clipboard marshaling (libghostty may call from a background thread).
typedef enum {
    CLIP_OP_READ = 1,
    CLIP_OP_WRITE = 2,
    CLIP_OP_CONFIRM = 3,
} ClipOp;

typedef struct {
    ClipOp op;
    ghostty_surface_t surface;
    void* state;
    ghostty_clipboard_e loc;
    char* text; // owned UTF-8; free after handling
    bool confirm;
} ClipMsg;

// --- Helpers ---

static SurfaceSlot* slot_from_hwnd(HWND hwnd) {
    for (int i = 0; i < SURFACE_COUNT; i++) {
        if (g_slots[i].hwnd == hwnd) return &g_slots[i];
    }
    return NULL;
}

static SurfaceSlot* focused_slot(void) {
    if (g_focused < 0 || g_focused >= SURFACE_COUNT) return NULL;
    return &g_slots[g_focused];
}

static void set_focused(int index) {
    if (index < 0 || index >= SURFACE_COUNT) return;
    if (g_focused == index) return;
    SurfaceSlot* prev = focused_slot();
    if (prev && prev->surface) ghostty_surface_set_focus(prev->surface, false);
    g_focused = index;
    SurfaceSlot* next = focused_slot();
    if (next && next->hwnd) SetFocus(next->hwnd);
    if (next && next->surface) ghostty_surface_set_focus(next->surface, true);
}

static void apply_dark_mode(HWND hwnd) {
    BOOL dark = TRUE;
    DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));
}

static BOOL WINAPI ctrl_handler(DWORD type) {
    return type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT;
}

static void wakeup_cb(void* userdata) {
    (void)userdata;
    if (g_hwnd) PostMessage(g_hwnd, WM_GHOSTTY_WAKEUP, 0, 0);
}

static void log_first_frame_if_needed(void) {
    if (g_first_frame_logged) return;
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    double ms = (double)(now.QuadPart - g_start_qpc.QuadPart) * 1000.0
        / (double)g_qpc_freq.QuadPart;
    spike_log("[spike82] startup to first tick: %.1f ms", ms);
    g_first_frame_logged = true;
}

// --- Clipboard ---

static char* utf16_to_utf8(const WCHAR* w, int wlen) {
    if (!w || wlen < 0) return NULL;
    int nbytes = WideCharToMultiByte(CP_UTF8, 0, w, wlen, NULL, 0, NULL, NULL);
    if (nbytes <= 0) return NULL;
    char* out = (char*)malloc((size_t)nbytes + 1);
    if (!out) return NULL;
    WideCharToMultiByte(CP_UTF8, 0, w, wlen, out, nbytes, NULL, NULL);
    out[nbytes] = '\0';
    return out;
}

static WCHAR* utf8_to_utf16(const char* s, int* out_len) {
    if (!s) s = "";
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    WCHAR* out = (WCHAR*)malloc((size_t)n * sizeof(WCHAR));
    if (!out) return NULL;
    MultiByteToWideChar(CP_UTF8, 0, s, -1, out, n);
    if (out_len) *out_len = n - 1; // exclude NUL
    return out;
}

static char* clipboard_read_utf8(void) {
    if (!OpenClipboard(g_hwnd)) return xstrdup("");
    HANDLE h = GetClipboardData(CF_UNICODETEXT);
    char* result = NULL;
    if (h) {
        WCHAR* w = (WCHAR*)GlobalLock(h);
        if (w) {
            result = utf16_to_utf8(w, (int)wcslen(w));
            GlobalUnlock(h);
        }
    }
    CloseClipboard();
    return result ? result : xstrdup("");
}

static void clipboard_write_utf8(const char* utf8) {
    WCHAR* w = utf8_to_utf16(utf8 ? utf8 : "", NULL);
    if (!w) return;
    size_t bytes = (wcslen(w) + 1) * sizeof(WCHAR);
    HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (!h) { free(w); return; }
    void* dest = GlobalLock(h);
    memcpy(dest, w, bytes);
    GlobalUnlock(h);
    free(w);
    if (!OpenClipboard(g_hwnd)) {
        GlobalFree(h);
        return;
    }
    EmptyClipboard();
    SetClipboardData(CF_UNICODETEXT, h);
    CloseClipboard();
}

static bool action_cb(ghostty_app_t app, ghostty_target_s target,
                       ghostty_action_s action) {
    (void)app; (void)target; (void)action;
    // Host does not handle rich apprt actions in the spike.
    return false;
}

static bool read_clipboard_cb(void* userdata, ghostty_clipboard_e loc,
                              void* state) {
    (void)userdata;
    if (loc == GHOSTTY_CLIPBOARD_SELECTION) return false;
    SurfaceSlot* slot = focused_slot();
    if (!slot || !slot->surface) return false;

    ClipMsg* msg = (ClipMsg*)calloc(1, sizeof(ClipMsg));
    if (!msg) return false;
    msg->op = CLIP_OP_READ;
    msg->surface = slot->surface;
    msg->state = state;
    msg->loc = loc;
    if (!PostMessage(g_hwnd, WM_GHOSTTY_CLIPBOARD, 0, (LPARAM)msg)) {
        free(msg);
        return false;
    }
    return true;
}

static void confirm_read_clipboard_cb(void* userdata, const char* str,
                                      void* state,
                                      ghostty_clipboard_request_e req) {
    (void)userdata; (void)req;
    SurfaceSlot* slot = focused_slot();
    if (!slot || !slot->surface) return;

    ClipMsg* msg = (ClipMsg*)calloc(1, sizeof(ClipMsg));
    if (!msg) return;
    msg->op = CLIP_OP_CONFIRM;
    msg->surface = slot->surface;
    msg->state = state;
    msg->text = xstrdup(str ? str : "");
    // Spike: auto-confirm (no modal settings UI — #82 non-goal).
    msg->confirm = true;
    if (!PostMessage(g_hwnd, WM_GHOSTTY_CLIPBOARD, 0, (LPARAM)msg)) {
        free(msg->text);
        free(msg);
    }
}

static void write_clipboard_cb(void* userdata, ghostty_clipboard_e loc,
                               const ghostty_clipboard_content_s* content,
                               size_t content_count, bool confirm) {
    (void)userdata; (void)confirm;
    if (loc == GHOSTTY_CLIPBOARD_SELECTION) return;

    const char* text = "";
    for (size_t i = 0; i < content_count; i++) {
        if (content[i].mime && content[i].data &&
            (strcmp(content[i].mime, "text/plain") == 0 ||
             strcmp(content[i].mime, "text/plain;charset=utf-8") == 0)) {
            text = content[i].data;
            break;
        }
    }
    // Prefer first entry if mime unknown.
    if ((!text || !text[0]) && content_count > 0 && content[0].data)
        text = content[0].data;

    ClipMsg* msg = (ClipMsg*)calloc(1, sizeof(ClipMsg));
    if (!msg) return;
    msg->op = CLIP_OP_WRITE;
    msg->text = xstrdup(text ? text : "");
    if (!PostMessage(g_hwnd, WM_GHOSTTY_CLIPBOARD, 0, (LPARAM)msg)) {
        free(msg->text);
        free(msg);
    }
}

static void handle_clipboard_msg(ClipMsg* msg) {
    if (!msg) return;
    switch (msg->op) {
    case CLIP_OP_READ: {
        char* text = clipboard_read_utf8();
        if (msg->surface) {
            ghostty_surface_complete_clipboard_request(
                msg->surface, text ? text : "", msg->state, false);
        }
        free(text);
        break;
    }
    case CLIP_OP_WRITE:
        clipboard_write_utf8(msg->text);
        break;
    case CLIP_OP_CONFIRM:
        if (msg->surface) {
            ghostty_surface_complete_clipboard_request(
                msg->surface, msg->text ? msg->text : "", msg->state,
                msg->confirm);
        }
        break;
    }
    free(msg->text);
    free(msg);
}

static void close_surface_cb(void* userdata, bool process_alive) {
    (void)userdata; (void)process_alive;
    // Spike: closing either surface closes the window.
    if (g_hwnd) PostMessage(g_hwnd, WM_CLOSE, 0, 0);
}

// --- Input helpers ---

static uint32_t scancode_from_lparam(LPARAM lp) {
    uint32_t sc = (lp >> 16) & 0xFF;
    if (lp & (1 << 24)) sc |= 0xE000;
    return sc;
}

static ghostty_input_mods_e current_mods(void) {
    ghostty_input_mods_e mods = GHOSTTY_MODS_NONE;
    if (GetKeyState(VK_SHIFT) & 0x8000) mods |= GHOSTTY_MODS_SHIFT;
    if (GetKeyState(VK_CONTROL) & 0x8000) mods |= GHOSTTY_MODS_CTRL;
    if (GetKeyState(VK_MENU) & 0x8000) mods |= GHOSTTY_MODS_ALT;
    if (GetKeyState(VK_LWIN) & 0x8000 || GetKeyState(VK_RWIN) & 0x8000)
        mods |= GHOSTTY_MODS_SUPER;
    if (GetKeyState(VK_CAPITAL) & 0x0001) mods |= GHOSTTY_MODS_CAPS;
    if (GetKeyState(VK_NUMLOCK) & 0x0001) mods |= GHOSTTY_MODS_NUM;
    return mods;
}

static void send_utf16_text(SurfaceSlot* slot, const WCHAR* wc_buf, int count) {
    if (!slot || !slot->surface || count <= 0) return;
    char utf8[256];
    int len = WideCharToMultiByte(CP_UTF8, 0, wc_buf, count,
                                  utf8, sizeof(utf8) - 1, NULL, NULL);
    if (len <= 0) return;
    utf8[len] = '\0';
    ghostty_surface_text(slot->surface, utf8, (uintptr_t)len);
}

static void layout_children(void) {
    if (!g_hwnd) return;
    RECT rc;
    GetClientRect(g_hwnd, &rc);
    int width = rc.right - rc.left;
    int height = rc.bottom - rc.top;
    if (width < 2 * SPLIT_GAP_PX + 40) width = 2 * SPLIT_GAP_PX + 40;

    int left_w = (int)(width * g_split_ratio);
    if (left_w < 40) left_w = 40;
    if (left_w > width - SPLIT_GAP_PX - 40) left_w = width - SPLIT_GAP_PX - 40;
    int right_x = left_w + SPLIT_GAP_PX;
    int right_w = width - right_x;

    if (g_slots[0].hwnd) {
        MoveWindow(g_slots[0].hwnd, 0, 0, left_w, height, TRUE);
        if (g_slots[0].surface)
            ghostty_surface_set_size(g_slots[0].surface,
                                    (uint32_t)left_w, (uint32_t)height);
    }
    if (g_split_bar) {
        MoveWindow(g_split_bar, left_w, 0, SPLIT_GAP_PX, height, TRUE);
    }
    if (g_slots[1].hwnd) {
        MoveWindow(g_slots[1].hwnd, right_x, 0, right_w, height, TRUE);
        if (g_slots[1].surface)
            ghostty_surface_set_size(g_slots[1].surface,
                                    (uint32_t)right_w, (uint32_t)height);
    }
}

static bool handle_ime_composition(SurfaceSlot* slot, LPARAM lp) {
    if (!slot || !slot->surface) return false;
    DWORD flags = (DWORD)(lp & 0xFFFFFFFF);
    HIMC himc = ImmGetContext(slot->hwnd);
    if (!himc) return false;

    bool handled = false;
    if (flags & GCS_RESULTSTR) {
        LONG nbytes = ImmGetCompositionStringW(himc, GCS_RESULTSTR, NULL, 0);
        if (nbytes > 0 && (nbytes & 1) == 0) {
            int u16_len = (int)(nbytes / 2);
            WCHAR* buf = (WCHAR*)malloc((size_t)u16_len * sizeof(WCHAR));
            if (buf) {
                LONG got = ImmGetCompositionStringW(
                    himc, GCS_RESULTSTR, buf, (DWORD)nbytes);
                if (got > 0 && (got & 1) == 0) {
                    send_utf16_text(slot, buf, (int)(got / 2));
                    handled = true;
                }
                free(buf);
            }
        }
    }

    ImmReleaseContext(slot->hwnd, himc);
    return handled;
}

// --- Child surface WndProc ---

static LRESULT CALLBACK surface_wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    SurfaceSlot* slot = slot_from_hwnd(hwnd);

    switch (msg) {
    case WM_SETFOCUS:
        for (int i = 0; i < SURFACE_COUNT; i++) {
            if (g_slots[i].hwnd == hwnd) {
                g_focused = i;
                break;
            }
        }
        if (slot && slot->surface) ghostty_surface_set_focus(slot->surface, true);
        return 0;

    case WM_KILLFOCUS:
        if (slot && slot->surface) ghostty_surface_set_focus(slot->surface, false);
        return 0;

    case WM_LBUTTONDOWN:
        SetFocus(hwnd);
        if (slot && slot->surface) {
            SetCapture(hwnd);
            ghostty_surface_mouse_button(slot->surface,
                GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, current_mods());
        }
        return 0;

    case WM_LBUTTONUP:
        if (slot && slot->surface) {
            ReleaseCapture();
            ghostty_surface_mouse_button(slot->surface,
                GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, current_mods());
        }
        return 0;

    case WM_RBUTTONDOWN:
        SetFocus(hwnd);
        if (slot && slot->surface)
            ghostty_surface_mouse_button(slot->surface,
                GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, current_mods());
        return 0;

    case WM_RBUTTONUP:
        if (slot && slot->surface)
            ghostty_surface_mouse_button(slot->surface,
                GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, current_mods());
        return 0;

    case WM_MBUTTONDOWN:
        if (slot && slot->surface)
            ghostty_surface_mouse_button(slot->surface,
                GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, current_mods());
        return 0;

    case WM_MBUTTONUP:
        if (slot && slot->surface)
            ghostty_surface_mouse_button(slot->surface,
                GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, current_mods());
        return 0;

    case WM_MOUSEMOVE:
        if (slot && slot->surface) {
            double x = (double)GET_X_LPARAM(lp);
            double y = (double)GET_Y_LPARAM(lp);
            ghostty_surface_mouse_pos(slot->surface, x, y, current_mods());
        }
        return 0;

    case WM_MOUSEWHEEL:
        if (slot && slot->surface) {
            double delta = (double)GET_WHEEL_DELTA_WPARAM(wp) / WHEEL_DELTA;
            ghostty_surface_mouse_scroll(slot->surface, 0, delta, 0);
        }
        return 0;

    case WM_MOUSEHWHEEL:
        if (slot && slot->surface) {
            double delta = (double)GET_WHEEL_DELTA_WPARAM(wp) / WHEEL_DELTA;
            ghostty_surface_mouse_scroll(slot->surface, delta, 0, 0);
        }
        return 0;

    case WM_KEYDOWN:
    case WM_SYSKEYDOWN: {
        if (!slot || !slot->surface) break;
        // Ctrl+1 / Ctrl+2 focus panes (ugly placeholder navigation).
        if ((GetKeyState(VK_CONTROL) & 0x8000) && wp == '1') {
            set_focused(0);
            return 0;
        }
        if ((GetKeyState(VK_CONTROL) & 0x8000) && wp == '2') {
            set_focused(1);
            return 0;
        }
        // IME is consuming keys.
        if (wp == VK_PROCESSKEY) return 0;

        ghostty_input_key_s key = {
            .action = (lp & (1 << 30)) ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS,
            .mods = current_mods(),
            .consumed_mods = GHOSTTY_MODS_NONE,
            .keycode = scancode_from_lparam(lp),
            .text = NULL,
            .unshifted_codepoint = 0,
            .composing = slot->ime_composing,
        };
        ghostty_surface_key(slot->surface, key);
        return 0;
    }

    case WM_KEYUP:
    case WM_SYSKEYUP: {
        if (!slot || !slot->surface) break;
        if (wp == VK_PROCESSKEY) return 0;
        ghostty_input_key_s key = {
            .action = GHOSTTY_ACTION_RELEASE,
            .mods = current_mods(),
            .consumed_mods = GHOSTTY_MODS_NONE,
            .keycode = scancode_from_lparam(lp),
            .text = NULL,
            .unshifted_codepoint = 0,
            .composing = false,
        };
        ghostty_surface_key(slot->surface, key);
        return 0;
    }

    case WM_DEADCHAR:
    case WM_SYSDEADCHAR:
        // Dead keys: TranslateMessage already consumed the base; wait for
        // the composed WM_CHAR. Do not inject the dead mark itself.
        return 0;

    case WM_UNICHAR: {
        if (wp == UNICODE_NOCHAR) return TRUE;
        if (!slot || !slot->surface) break;
        uint32_t cp = (uint32_t)wp;
        wchar_t wc_buf[3] = {0};
        int count;
        if (cp >= 0x10000 && cp < 0x110000) {
            cp -= 0x10000;
            wc_buf[0] = (wchar_t)(0xD800 | (cp >> 10));
            wc_buf[1] = (wchar_t)(0xDC00 | (cp & 0x3FF));
            count = 2;
        } else {
            wc_buf[0] = (wchar_t)cp;
            count = 1;
        }
        send_utf16_text(slot, wc_buf, count);
        return 0;
    }

    case WM_CHAR:
    case WM_SYSCHAR: {
        if (!slot || !slot->surface) break;
        // During IME composition, result arrives via WM_IME_COMPOSITION.
        if (slot->ime_composing) return 0;

        WCHAR wc = (WCHAR)wp;
        if (IS_HIGH_SURROGATE(wc)) {
            slot->high_surrogate = wc;
            return 0;
        }

        wchar_t wc_buf[3] = {0};
        int count;
        if (IS_LOW_SURROGATE(wc)) {
            if (slot->high_surrogate) {
                wc_buf[0] = slot->high_surrogate;
                wc_buf[1] = wc;
                slot->high_surrogate = 0;
                count = 2;
            } else {
                return 0;
            }
        } else {
            slot->high_surrogate = 0;
            // Skip control chars already handled as key events (except tab/CR).
            if (wc < 0x20 && wc != L'\t' && wc != L'\r') return 0;
            wc_buf[0] = wc;
            count = 1;
        }
        send_utf16_text(slot, wc_buf, count);
        return 0;
    }

    case WM_IME_STARTCOMPOSITION:
        if (slot) {
            slot->ime_composing = true;
            slot->high_surrogate = 0;
        }
        return 0;

    case WM_IME_ENDCOMPOSITION:
        if (slot) slot->ime_composing = false;
        return 0;

    case WM_IME_COMPOSITION:
        if (slot && handle_ime_composition(slot, lp)) return 0;
        break;

    case WM_IME_SETCONTEXT:
        // Suppress the default floating composition window; we commit via
        // GCS_RESULTSTR. ISC_SHOWUICOMPOSITIONWINDOW = 0x80000000.
        lp &= ~(LPARAM)0x80000000;
        return DefWindowProc(hwnd, msg, wp, lp);

    case WM_SIZE:
        if (slot && slot->surface) {
            ghostty_surface_set_size(slot->surface, LOWORD(lp), HIWORD(lp));
        }
        return 0;

    case WM_ERASEBKGND:
        return 1;

    default:
        break;
    }

    return DefWindowProc(hwnd, msg, wp, lp);
}

static LRESULT CALLBACK split_wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_SETCURSOR:
        SetCursor(LoadCursor(NULL, IDC_SIZEWE));
        return TRUE;
    case WM_LBUTTONDOWN:
        g_dragging_split = true;
        SetCapture(hwnd);
        return 0;
    case WM_LBUTTONUP:
        g_dragging_split = false;
        ReleaseCapture();
        return 0;
    case WM_MOUSEMOVE:
        if (g_dragging_split && g_hwnd) {
            POINT pt = { GET_X_LPARAM(lp), GET_Y_LPARAM(lp) };
            ClientToScreen(hwnd, &pt);
            ScreenToClient(g_hwnd, &pt);
            RECT rc;
            GetClientRect(g_hwnd, &rc);
            int width = rc.right - rc.left;
            if (width > 0) {
                g_split_ratio = (double)pt.x / (double)width;
                if (g_split_ratio < 0.15) g_split_ratio = 0.15;
                if (g_split_ratio > 0.85) g_split_ratio = 0.85;
                layout_children();
                if (g_app) ghostty_app_tick(g_app);
            }
        }
        return 0;
    case WM_ERASEBKGND: {
        HDC hdc = (HDC)wp;
        RECT rc;
        GetClientRect(hwnd, &rc);
        HBRUSH br = CreateSolidBrush(RGB(60, 60, 60));
        FillRect(hdc, &rc, br);
        DeleteObject(br);
        return 1;
    }
    default:
        break;
    }
    return DefWindowProc(hwnd, msg, wp, lp);
}

// --- Parent window ---

static LRESULT CALLBACK parent_wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_GHOSTTY_WAKEUP:
        if (g_app) {
            ghostty_app_tick(g_app);
            log_first_frame_if_needed();
        }
        return 0;

    case WM_GHOSTTY_CLIPBOARD:
        handle_clipboard_msg((ClipMsg*)lp);
        return 0;

    case WM_ENTERSIZEMOVE:
        SetTimer(hwnd, WM_GHOSTTY_RESIZE_TIMER, RESIZE_TIMER_MS, NULL);
        return 0;

    case WM_EXITSIZEMOVE:
        KillTimer(hwnd, WM_GHOSTTY_RESIZE_TIMER);
        layout_children();
        if (g_app) ghostty_app_tick(g_app);
        return 0;

    case WM_TIMER:
        if (wp == WM_GHOSTTY_RESIZE_TIMER && g_app) {
            ghostty_app_tick(g_app);
        }
        return 0;

    case WM_SIZE:
        layout_children();
        return 0;

    case WM_DPICHANGED: {
        UINT new_dpi = HIWORD(wp);
        double new_scale = (double)new_dpi / 96.0;
        for (int i = 0; i < SURFACE_COUNT; i++) {
            if (g_slots[i].surface)
                ghostty_surface_set_content_scale(
                    g_slots[i].surface, new_scale, new_scale);
        }
        RECT* suggested = (RECT*)lp;
        SetWindowPos(hwnd, NULL,
            suggested->left, suggested->top,
            suggested->right - suggested->left,
            suggested->bottom - suggested->top,
            SWP_NOZORDER | SWP_NOACTIVATE);
        layout_children();
        return 0;
    }

    case WM_DESTROY:
        KillTimer(hwnd, WM_GHOSTTY_RESIZE_TIMER);
        PostQuitMessage(0);
        return 0;

    default:
        break;
    }
    return DefWindowProc(hwnd, msg, wp, lp);
}

static HWND create_child_surface_hwnd(HINSTANCE hInst, int index) {
    char class_name[] = "GhosttySpikeSurface";
    static bool registered = false;
    if (!registered) {
        WNDCLASSEXA wc = {
            .cbSize = sizeof(wc),
            .style = CS_HREDRAW | CS_VREDRAW,
            .lpfnWndProc = surface_wnd_proc,
            .hInstance = hInst,
            .hCursor = LoadCursor(NULL, IDC_IBEAM),
            .hbrBackground = NULL,
            .lpszClassName = class_name,
        };
        RegisterClassExA(&wc);
        registered = true;
    }
    return CreateWindowExA(
        0, class_name, "",
        WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS,
        0, 0, 100, 100,
        g_hwnd, (HMENU)(UINT_PTR)(index + 1), hInst, NULL);
}

static bool create_surface_for_slot(int index, double scale) {
    SurfaceSlot* slot = &g_slots[index];
    ghostty_surface_config_s surface_cfg = ghostty_surface_config_new();
    surface_cfg.platform_tag = GHOSTTY_PLATFORM_WINDOWS;
    surface_cfg.platform.windows.hwnd = (void*)slot->hwnd;
    surface_cfg.scale_factor = scale;

    slot->surface = ghostty_surface_new(g_app, &surface_cfg);
    if (!slot->surface) {
        fprintf(stderr, "ghostty_surface_new failed for slot %d\n", index);
        return false;
    }
    return true;
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmdLine, int show) {
    (void)hPrev; (void)cmdLine;

    QueryPerformanceFrequency(&g_qpc_freq);
    QueryPerformanceCounter(&g_start_qpc);
    remove("spike82.log");
    spike_log("[spike82] WinMain start");

    if (!AttachConsole(ATTACH_PARENT_PROCESS)) AllocConsole();
    freopen("CONOUT$", "w", stdout);
    freopen("CONOUT$", "w", stderr);
    SetConsoleCtrlHandler(ctrl_handler, TRUE);

    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    WNDCLASSEXA parent_wc = {
        .cbSize = sizeof(parent_wc),
        .style = CS_HREDRAW | CS_VREDRAW,
        .lpfnWndProc = parent_wnd_proc,
        .hInstance = hInst,
        .hCursor = LoadCursor(NULL, IDC_ARROW),
        .hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH),
        .lpszClassName = "GhosttySpike82",
    };
    RegisterClassExA(&parent_wc);

    WNDCLASSEXA split_wc = {
        .cbSize = sizeof(split_wc),
        .lpfnWndProc = split_wnd_proc,
        .hInstance = hInst,
        .hCursor = LoadCursor(NULL, IDC_SIZEWE),
        .lpszClassName = "GhosttySpikeSplit",
    };
    RegisterClassExA(&split_wc);

    g_hwnd = CreateWindowExA(
        0, "GhosttySpike82", "Ghostty #82 Win32+DX12 Spike",
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT, 1200, 700,
        NULL, NULL, hInst, NULL);
    if (!g_hwnd) {
        fprintf(stderr, "CreateWindowEx failed: %lu\n", GetLastError());
        return 1;
    }
    apply_dark_mode(g_hwnd);

    memset(g_slots, 0, sizeof(g_slots));
    for (int i = 0; i < SURFACE_COUNT; i++) {
        g_slots[i].hwnd = create_child_surface_hwnd(hInst, i);
        if (!g_slots[i].hwnd) {
            fprintf(stderr, "child HWND %d failed\n", i);
            return 1;
        }
    }

    g_split_bar = CreateWindowExA(
        0, "GhosttySpikeSplit", "",
        WS_CHILD | WS_VISIBLE,
        0, 0, SPLIT_GAP_PX, 100,
        g_hwnd, NULL, hInst, NULL);

    char* argv[] = { "ghostty-spike82" };
    if (ghostty_init(1, argv) != 0) {
        spike_log("ghostty_init failed");
        return 1;
    }
    spike_log("[spike82] ghostty_init ok");

    ghostty_config_t config = ghostty_config_new();
    ghostty_config_load_default_files(config);
    ghostty_config_load_recursive_files(config);
    ghostty_config_finalize(config);

    ghostty_runtime_config_s runtime_cfg = {
        .userdata = NULL,
        .supports_selection_clipboard = false,
        .wakeup_cb = wakeup_cb,
        .action_cb = action_cb,
        .read_clipboard_cb = read_clipboard_cb,
        .confirm_read_clipboard_cb = confirm_read_clipboard_cb,
        .write_clipboard_cb = write_clipboard_cb,
        .close_surface_cb = close_surface_cb,
    };

    g_app = ghostty_app_new(&runtime_cfg, config);
    ghostty_config_free(config);
    if (!g_app) {
        spike_log("ghostty_app_new failed");
        return 1;
    }
    spike_log("[spike82] ghostty_app_new ok");

    UINT dpi = GetDpiForWindow(g_hwnd);
    double scale = (double)dpi / 96.0;

    for (int i = 0; i < SURFACE_COUNT; i++) {
        if (!create_surface_for_slot(i, scale)) {
            spike_log("surface %d failed", i);
            ghostty_app_free(g_app);
            return 1;
        }
        spike_log("[spike82] surface %d ok", i);
    }

    layout_children();
    ShowWindow(g_hwnd, show);
    UpdateWindow(g_hwnd);

    for (int i = 0; i < SURFACE_COUNT; i++) {
        ghostty_surface_set_occlusion(g_slots[i].surface, true);
    }
    set_focused(0);

    MSG msg;
    while (GetMessage(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }

    for (int i = 0; i < SURFACE_COUNT; i++) {
        if (g_slots[i].surface) ghostty_surface_free(g_slots[i].surface);
        g_slots[i].surface = NULL;
    }
    ghostty_app_free(g_app);
    return (int)msg.wParam;
}
