# Win32 host parity backlog

Implement under `src/apprt/win32/` against **upstream GTK behavior**, using forks only as checklists ([SOURCES.md](SOURCES.md)).

## Order

1. Tabs (chrome + tab actions) — zcg TabBar / GTK tab
2. Real SplitTree (recursive H/V) — replace MVWT 2-pane-only
3. Search panel
4. Command palette
5. Quick terminal (quake)
6. Multi-window + single-instance IPC
7. Scrollbar / DND / tray (FEATURE-GAP / Liam list)

DX12 HWND surfaces stay the render path throughout.