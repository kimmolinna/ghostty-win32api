# C++ glue policy (Windows / general)

## Decision (2026-07-20)

Keep first-party `src/simd/*.cpp` as **C ABI FFI** to Highway and simdutf.
Do **not** port that glue to Zig. Vendor C++ stays linked on purpose.

Details: [src/simd/README.md](../../src/simd/README.md).

## Hygiene (done / follow-ups)

| Item | Status |
|------|--------|
| Stop linking unused `codepoint_width.cpp` in production SIMD set | Done |
| Document glue policy | Done |
| `-Dcustom-shader` / `-Dinspector` to drop glslang + dcimgui on win32 | Follow-up (deep imports: `shadertoy.zig`, `input/key.zig`, inspector) |

## Related

- [NATIVE-APPRT-NEXT.md](NATIVE-APPRT-NEXT.md) — product backlog after MVWT
- [WINUI-REMOVED.md](WINUI-REMOVED.md) — WinUI C# host removed