# Native Win32 apprt — post-MVWT backlog

Date: 2026-07-19  
Status: MVWT (`zig build -Dapp-runtime=win32` → `ghostty.exe`) is the daily host path.  
WinUI C# under `windows/` has been **removed**. Primary host is Zig `src/apprt/win32/`.

This backlog mirrors [deblasis/wintty README — What is next](https://github.com/deblasis/wintty/blob/windows/README.md), adapted for the **Zig Win32 apprt** (`src/apprt/win32/`), not WinUI.

## Done in this phase (MVWT)

- [x] `Runtime.win32` + exhaustive `app_runtime` switches
- [x] Native apprt: App / Window / Surface (no WGL; DX12 via `platform.windows.hwnd`)
- [x] `ghostty.exe` builds and opens a ConPTY shell
- [x] Side-by-side split (2 surfaces), Ctrl+1 / Ctrl+2 / Ctrl+Shift+D, splitter drag
- [x] Clipboard, IME hooks, dark title bar (`DwmSetWindowAttribute`)
- [x] `example/c-win32-terminal` kept as HWND+DX12 regression harness

## Priority order (after MVWT)

1. **Renderer throughput** (shared DX12 core — helps exe and DLL)
2. **Multi-window** + `windows-*` config keys
3. **Tray / Explorer / default-terminal**
4. **Packaging** last

---

### Renderer throughput

Issues: [#93](https://github.com/deblasis/wintty/issues/93), [#94](https://github.com/deblasis/wintty/issues/94)

- [ ] Scroll optimization — row versioning / GPU buffer rotation (only re-upload newly exposed rows)
- [ ] Adaptive presentation — waitable swap chain, `ALLOW_TEARING` / VRR, skip-present when idle
- [ ] Glyph Protocol upload parity (DX12 + DirectWrite atlas) ([#551](https://github.com/deblasis/wintty/issues/551))
- [ ] Kitty image upload through the DX12 atlas

### Native integration gaps

Issue: [#81](https://github.com/deblasis/wintty/issues/81) — implement in Zig Win32 apprt

- [ ] System tray / background mode
- [ ] “Open Terminal Here” (registry + Win11 `IExplorerCommand`)
- [ ] Default terminal handoff (`ITerminalHandoff`)
- [ ] Automation surface (CLI / COM; macOS AppleScript counterpart)
- [ ] Multi-window (beyond single top-level HWND)

### Config surface & packaging

Issue: [#214](https://github.com/deblasis/wintty/issues/214)

- [ ] `windows-*` config keys (`macos-*` mirror: titlebar, backdrop, icon theming, …)
- [ ] Installer (MSI / MSIX / winget); auto-update later
- [ ] VT-compliance CI (esctest) ([#508](https://github.com/deblasis/wintty/issues/508))

## Build note

Windows GUI subsystem expects `WinMain`; current Zig entry is `main`. `GhosttyExe.zig` therefore uses **Console** subsystem so linking succeeds. Top-level windows still work; a later step can add a `WinMain` shim and switch back to `.Windows` for release builds.

## C++ glue

See [CPP-GLUE.md](CPP-GLUE.md) — keep SIMD FFI in C++; do not rewrite vendors.

## Renderer throughput progress

Issues: [#93](https://github.com/deblasis/wintty/issues/93), [#94](https://github.com/deblasis/wintty/issues/94)

- [x] Skip-present when idle — DX12 `presentLastTarget` is a no-op (FLIP retains last frame; matches Metal)
- [ ] Waitable swap chain + `SetMaximumFrameLatency`
- [ ] `ALLOW_TEARING` / VRR + adaptive sync interval
- [ ] Scroll optimization — viewport pin change without full rebuild (#94)
- [ ] Glyph Protocol → DX12 atlas (#551)

## Sources

See [SOURCES.md](SOURCES.md) — upstream Ghostty first; forks as reference only.
