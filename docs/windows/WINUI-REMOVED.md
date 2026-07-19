# WinUI 3 shell — removed

The C# WinUI 3 app under `windows/` (Ghostty / Ghostty.Core / tests / bench) has been **deleted**.

**Primary Windows host:** Zig `src/apprt/win32/` + DX12 HWND.

```text
zig build -Dapp-runtime=win32
just build-win32   # or: just run-win32
```

Feature inventory that used to live in the WinUI shell is tracked as backlog for the Zig host — see [NATIVE-APPRT-NEXT.md](NATIVE-APPRT-NEXT.md) and upstream issues (#81, #93/#94, #214).

`dist/windows/` (IconGen, `ghostty.rc`) is unrelated and remains for the Zig exe.