pub const Config = @import("config/Config.zig");
pub const ManagedConfig = @import("config/ManagedConfig.zig");
pub const DomainSocket = @import("config/DomainSocket.zig");
pub const Resource = @import("config/Resource.zig");
pub const IpamConfig = Resource.IpamConfig;
pub const InterfaceConfig = Resource.InterfaceConfig;
test {
    _ = @import("config/Config.zig");
    _ = @import("config/ManagedConfig.zig");
    _ = @import("config/DomainSocket.zig");
    _ = @import("config/Resource.zig");
}
