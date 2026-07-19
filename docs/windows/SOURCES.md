# Sources of truth and Windows references

## Primary

| Remote / project | Role |
|------------------|------|
| [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty) | **Source of truth** for VT, config semantics, `apprt` contracts, GTK apprt as the structural model |
| This repo (`ghostty-win32api`) | Soft fork: Zig Win32 apprt + Wintty DX12 HWND host |

## Technical base (already in tree)

| Project | Role |
|---------|------|
| [deblasis/wintty](https://github.com/deblasis/wintty) (`upstream` remote) | DX12 renderer, libghostty Windows work, throughput issues #93/#94 |

## Reference only (ideas / checklists — do not wholesale merge)

| Project | Take | Skip |
|---------|------|------|
| [zcg/ghostty-win](https://github.com/zcg/ghostty-win) | Closest `apprt/win32` layout (tabs, SplitTree, SearchPanel, CommandPalette); Acrylic/Mica ideas | Direct2D renderer |
| [liamsmith86/ghostty-windows](https://github.com/liamsmith86/ghostty-windows) | GTK-parity feature list, IME / single-instance / scrollbar behavior | WGL OpenGL stack |
| [Thr45hx/ghostty-windows](https://github.com/Thr45hx/ghostty-windows) | FEATURE-GAP priorities | Binary-only packaging; D3D11 as code base |
| InsipidPoint / local `ghostty-windows-ref` | HWND / IME / clipboard patterns (already used for MVWT) | WGL |

## Rules

1. New behavior matches **upstream Ghostty** (especially GTK apprt semantics).
2. Rendering stays **DX12** (Wintty path) — do not switch to OpenGL/Direct2D to match a fork.
3. Forks are cheat sheets for Win32 host features; reimplement under `src/apprt/win32/`.
4. Vendor C++ (simdutf/Highway/…) stays linked; see [CPP-GLUE.md](CPP-GLUE.md).

## Remotes (intended)

```text
origin    → github.com/kimmolinna/ghostty-win32api
upstream  → github.com/deblasis/wintty
ghostty   → github.com/ghostty-org/ghostty   (optional sync)
```