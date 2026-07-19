# Issue #82 decision: Windows apprt path

Date: 2026-07-19 (updated: WinUI removed)
Parent: wintty #82
Spike host: example/c-win32-terminal (embedded C API + Win32 HWND + DX12)

## Choice

**Path 2 — native `src/apprt/win32/`** (long-term), built like Linux GTK:

- `zig build -Dapp-runtime=win32` → `ghostty.exe`
- Structure mirrored from upstream `src/apprt/gtk/`
- Win32 details adapted from InsipidPoint; renderer stays Wintty DX12 (HWND)

## WinUI

The C# WinUI 3 tree (`windows/`) has been **removed**. See [WINUI-REMOVED.md](WINUI-REMOVED.md).

Keep `example/c-win32-terminal` as regression / embedder smoke (`zig build` / `zig cc`).