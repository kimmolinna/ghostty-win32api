# src/simd — FFI glue policy

Zig owns application logic. **Highway** and **simdutf** are intentional C++ vendor deps.
`src/simd/*.cpp` is a thin **C ABI bridge**, not tech debt to rewrite in Zig.

```text
Zig (base64.zig / vt.zig / index_of.zig)
  → extern ghostty_simd_*
  → *.cpp (C ABI)
  → Highway / simdutf
```

## Rules

| Do | Don't |
|----|--------|
| Keep a thin C ABI in `.cpp` | Don't "port the glue" to Zig while vendors remain |
| Put new pure logic in Zig | Don't grow `.cpp` with non-vendor logic |
| Treat `.cpp` as FFI, not ownership | Don't confuse "remove C++" with "change wrapper language" |
| Use `-Dsimd=false` scalar fallbacks when needed | Don't rewrite Highway/simdutf in Zig without a hard requirement |

Touch the glue again only if Highway and/or simdutf are dropped entirely — then the bridge goes away, it does not become Zig.

## Files

| File | Role |
|------|------|
| `base64.cpp` | simdutf base64 → `ghostty_simd_base64_*` |
| `vt.cpp` | Highway scan + simdutf UTF-8 → `ghostty_simd_decode_utf8_until_control_seq` |
| `index_of.cpp` / `index_of.h` | Highway byte scan |
| `codepoint_width.cpp` | **Not linked in production** — prod width uses Zig LUT (`unicode/`); Zig wrapper uses uucode |
| `*.zig` | Thin wrappers + scalar paths when `-Dsimd=false` |

See also [docs/windows/CPP-GLUE.md](../../docs/windows/CPP-GLUE.md).