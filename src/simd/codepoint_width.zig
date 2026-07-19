const std = @import("std");

/// Production terminal width uses `unicode.codepointWidth` (LUT).
/// This SIMD-named API is kept for benches/tests and always uses uucode.
/// The former Highway C++ bridge (`codepoint_width.cpp`) is not linked.
pub fn codepointWidth(cp: u32) i8 {
    const uucode = @import("uucode");
    if (cp > uucode.config.max_code_point) return 1;
    return uucode.get(.width, @intCast(cp));
}

test "codepointWidth basic" {
    const testing = std.testing;
    try testing.expectEqual(@as(i8, 1), codepointWidth('a'));
    try testing.expectEqual(@as(i8, 1), codepointWidth(0x100)); // Ā
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x3400)); // 㐀
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x2E3A)); // ⸺
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x1F1E6)); // 🇦
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x4E00)); // 一
    try testing.expectEqual(@as(i8, 2), codepointWidth(0xF900)); // 豈
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x20000)); // 𠀀
    try testing.expectEqual(@as(i8, 2), codepointWidth(0x30000)); // 𠀀
}