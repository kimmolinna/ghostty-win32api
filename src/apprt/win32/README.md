# src/apprt/win32 — native Windows apprt (MVWT)

Path 2: **native Win32 + DX12** (no OpenGL/WGL). Former C# WinUI shell (windows/) removed — see docs/windows/WINUI-REMOVED.md.

## Layout

| File | Role |
|------|------|
| `App.zig` | Window classes (no `CS_OWNDC`), message-only wakeup HWND, `run`/`tick`/`wakeup`, `performAction` |
| `Window.zig` | Top-level HWND, dark mode, 1–2 side-by-side surfaces, splitter drag |
| `Surface.zig` | `WS_CHILD` HWND, `platform.windows.hwnd` for DX12, input/IME/clipboard → core |
| `key.zig` | VK → `input.Key`, Ctrl+1/Ctrl+2/Ctrl+Shift+D host binds |
| `win32.zig` | Bindings (from InsipidPoint) |
| `SplitTree.zig` / `TabBar.zig` | Stubs for later chrome |

## Multi-surface

- Start with one surface; **Ctrl+Shift+D** or `new_split` adds a second at ratio 0.5.
- **Ctrl+1** / **Ctrl+2** focus panes; drag the center splitter to resize.

## Build

```text
zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast
→ zig-out/bin/ghostty.exe
```

Requires `MSVC_DIR` / vcvars (same as DLL builds). Exe uses Console subsystem today (Zig `main` vs WinMain); see [NATIVE-APPRT-NEXT.md](../../../docs/windows/NATIVE-APPRT-NEXT.md).

## Post-MVWT backlog

Same issues as upstream README **What is next**, but implement on this Zig host: [NATIVE-APPRT-NEXT.md](../../../docs/windows/NATIVE-APPRT-NEXT.md) (#93/#94 renderer, #81 native gaps, #214 config/packaging).
