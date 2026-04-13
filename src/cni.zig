pub const Cni = @import("cni/Cni.zig");
pub const CniManager = @import("cni/CniManager.zig");
pub const DhcpManager = @import("cni/DhcpManager.zig");

test {
    _ = @import("cni/Cni.zig");
    _ = @import("cni/CniManager.zig");
    _ = @import("cni/DhcpManager.zig");
}
