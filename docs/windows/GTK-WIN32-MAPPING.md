# GTK → Win32 apprt mapping (post-#82)

| GTK (`src/apprt/gtk/`) | Win32 target (`src/apprt/win32/`) | Notes |
|------------------------|-----------------------------------|-------|
| `class/application.zig` | `App.zig` | Message loop, wakeup, performAction |
| `class/window.zig` | `Window.zig` | Top-level HWND, dark mode, split layout |
| `class/surface.zig` | `Surface.zig` | Child HWND → core Surface + DX12 |
| `class/tab.zig` | `TabBar.zig` (stub) | Later chrome |
| `class/split_tree.zig` | `SplitTree.zig` (stub) / layout in `Window.zig` | MVWT: 2-pane side-by-side |
| `key.zig` / actions | `key.zig` + `apprt.action` | Host binds + core keybinds |

Spike proof (embedded): `example/c-win32-terminal` built with `zig build` / `zig cc`.
WinUI C# host removed — see [WINUI-REMOVED.md](WINUI-REMOVED.md).