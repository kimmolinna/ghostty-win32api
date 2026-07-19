//! Native Win32 application runtime (Path 2: win32 + DX12).
//! Windowing/input/clipboard via Win32; rendering via core DirectX12 (HWND).

pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const Window = @import("win32/Window.zig");
pub const SplitTree = @import("win32/SplitTree.zig");
pub const TabBar = @import("win32/TabBar.zig");
pub const key = @import("win32/key.zig");

const internal_os = @import("../os/main.zig");
pub const resourcesDir = internal_os.resourcesDir;

test {
    _ = App;
    _ = Surface;
    _ = Window;
    _ = SplitTree;
    _ = TabBar;
    _ = key;
}
