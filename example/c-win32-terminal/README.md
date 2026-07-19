# Example: Win32 Terminal — Issue #82 Spike

Pure Win32 HWND host for `libghostty` with **DX12** rendering. No WinUI, no .NET, no XAML.

Implements [wintty#82](https://github.com/deblasis/wintty/issues/82) spike deliverables:

| # | Deliverable | Host behavior |
|---|-------------|-----------------|
| 1 | Multi-surface | Two child HWNDs side-by-side with a dragable splitter (Ctrl+1 / Ctrl+2 to focus) |
| 2 | Clipboard | `OpenClipboard` / `CF_UNICODETEXT`; paste confirm auto-accepted (no settings UI) |
| 3 | Text input | Dead keys, IME (`WM_IME_*` + `ImmGetCompositionStringW`), UTF-16 surrogates, `WM_UNICHAR` |
| 4 | Resize | Timer ticks during `WM_ENTERSIZEMOVE` so DX12 swap chain keeps updating |
| 5 | Dark mode | `DwmSetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE)` |

Startup timing is logged to stderr as `[spike82] startup to first tick: … ms` (success target < 200 ms).

## Prerequisites

- Windows 10/11
- Zig **0.15.2+** (used both for `ghostty.dll` and as the **C compiler** via `zig cc`)
- Visual Studio Build Tools (MSVC) for glslang when building the DLL

## Build DLL

From the repo root (VS tools on PATH, or `MSVC_DIR` set):

```powershell
zig build -Dapp-runtime=none
```

## Build & run the host (Zig as C compiler)

Preferred — Zig build system compiles `main.c` via its C backend:

```powershell
cd example/c-win32-terminal
zig build
zig build run
```

Or the PowerShell helper (`zig cc` + `zig dlltool`):

```powershell
.\build.ps1
.\out\c_win32_terminal.exe
```

One-liner:

```powershell
zig cc -target x86_64-windows-msvc -D_CRT_SECURE_NO_WARNINGS src/main.c `
  -I ../../include ../../zig-out/lib/ghostty.lib `
  -luser32 -lgdi32 -ldwmapi -limm32 -o ./out/c_win32_terminal.exe
```

## Non-goals (per #82)

Tab bar chrome, settings UI, accessibility, installer, InsipidPoint feature parity.
