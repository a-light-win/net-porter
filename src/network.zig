const std = @import("std");
// Convert form https://github.com/containers/netavark/blob/main/src/network/types.rs

pub const Driver = enum {
    @"net-porter",
    bridge,
    macvlan,
    ipvlan,
};

pub const NetPoerterDriver = enum {
    macvlan,
};

pub const Mode = enum {
    // For macvlan
    bridge,
    private,
    vepa,
    passthru,
    // For ipvlan
    l2,
    l3,
    l3s,
};

pub const ErrorMessage = struct {
    const max_message_size = 4096;

    @"error": ?[]const u8 = null,

    pub fn init(err: []const u8) ErrorMessage {
        return ErrorMessage{ .@"error" = err };
    }

    pub fn isOk(self: ErrorMessage) bool {
        return self.@"error" == null;
    }

    pub fn message(self: ErrorMessage) []const u8 {
        return self.@"error" orelse "";
    }
};

pub fn formatErrorMessage(comptime err_format: []const u8, args: anytype) ErrorMessage {
    var buf: [ErrorMessage.max_message_size]u8 = undefined;
    const err = std.fmt.bufPrint(&buf, err_format, args) catch |e| switch (e) {
        error.NoSpaceLeft => "Can't generate error message: Error message too long",
        else => unreachable,
    };
    return ErrorMessage.init(err);
}

test "ErrorMessage" {
    const err = formatErrorMessage("error {s} {d}", .{ "message", 3 });
    try std.testing.expect(!err.isOk());
    try std.testing.expectEqualSlices(u8, "error message 3", err.message());

    const allocator = std.heap.page_allocator;
    const long_msg = try allocator.alloc(u8, ErrorMessage.max_message_size + 1);
    defer allocator.free(long_msg);
    @memset(long_msg, 'x');

    const err_too_long = formatErrorMessage("{s}", .{long_msg});
    try std.testing.expect(!err_too_long.isOk());
    try std.testing.expectEqualSlices(u8, "Can't generate error message: Error message too long", err_too_long.message());
}

pub const DriverOptions = struct {
    // options for net-porter
    net_porter_driver: ?NetPoerterDriver = null,

    // options for macvlan and ipvlan
    parent: ?[]const u8 = null,
    mode: ?Mode = null,

    // global options
    mtu: ?u16 = null,
    metric: ?u32 = null,
    no_default_route: bool = false,

    fn validate(self: DriverOptions) ErrorMessage {
        if (self.net_porter_driver == null) {
            return ErrorMessage.init("net_porter_driver is required");
        }
        if (self.net_porter_driver == .macvlan) {
            if (self.parent != null) {
                return ErrorMessage.init("parent is required for macvlan");
            }
            if (self.mode) |mode| {
                switch (mode) {
                    .l3, .l3s, .l2 => return ErrorMessage.init("specified mode is not supported by macvlan"),
                    else => {},
                }
            }
        }
        return ErrorMessage{};
    }

    // Set default values for the driver options
    fn withDefaults(self: *DriverOptions) void {
        if (self.net_porter_driver == .macvlan) {
            if (self.mode == null) {
                self.mode = .bridge;
            }
        }
    }
};

pub const IpamDriver = enum {
    default,
    @"host-local",
    dhcp,
    none,
};

pub const IpamOptions = struct {
    // IPAM driver
    driver: ?IpamDriver = .default,
};

// For create network
pub const Network = struct {
    /// Name of the Network.
    name: ?[]const u8 = null,
    /// Driver for this Network, e.g. bridge, macvlan...
    driver: ?Driver = null,
    /// ID of the Network.
    id: ?[]const u8 = null,
    /// Options is a set of key-value options that have been applied to
    /// the Network.
    options: ?DriverOptions = null,
    /// IPAM options is a set of key-value options that have been applied to
    /// the Network.
    ipam_options: ?IpamOptions = null,
    /// Set up dns for this network
    dns_enabled: bool = false,
    /// Internal is whether the Network should not have external routes
    /// to public or other Networks.
    internal: bool = false,
    /// This network contains at least one ipv6 subnet.
    ipv6_enabled: bool = true,
    /// NetworkInterface is the network interface name on the host.
    network_interface: ?[]const u8 = null,
    /// Subnets to use for this network.
    subnets: ?[]Subnet = null,
    /// Static routes to use for this network.
    routes: ?[]Route = null,
    /// Network DNS servers for aardvark-dns.
    network_dns_servers: ?[][]const u8 = null,

    pub fn deinit(self: *Network, allocator: std.mem.Allocator) void {
        if (self.subnets) |subnets| allocator.free(subnets);
        if (self.routes) |routes| allocator.free(routes);
        if (self.network_dns_servers) |servers| allocator.free(servers);
    }

    pub fn validate(self: Network) ErrorMessage {
        if (self.name == null) {
            return ErrorMessage.init("name is required");
        }
        if (self.id == null) {
            return ErrorMessage.init("id is required");
        }
        if (self.options == null) {
            return ErrorMessage.init("options is required");
        }
        if (self.driver == null) {
            return ErrorMessage.init("driver is required");
        }
        if (self.driver != .@"net-porter") {
            return ErrorMessage.init("only net-porter driver is supported");
        }

        if (self.options) |options| {
            const validated = options.validate();
            if (!validated.isOk()) {
                return validated;
            }
        }
        return ErrorMessage{};
    }

    pub fn withDefaults(self: *Network) void {
        if (self.options) |*options| {
            options.withDefaults();
        }
    }
};

// For setup and teardown of a network
pub const NetworkPluginExec = struct {
    /// The id for the container
    container_id: []const u8,
    /// The name for the container
    container_name: []const u8,
    /// The port mappings for this container. Optional
    port_mappings: ?[]PortMapping,
    /// The network config for this network
    network: Network,
    /// The special network options for this specific container
    network_options: PerNetworkOptions,

    pub fn deinit(self: *NetworkPluginExec, allocator: std.mem.Allocator) void {
        if (self.port_mappings) |mappings| {
            for (mappings) |*mapping| {
                mapping.deinit(allocator);
            }
            allocator.free(mappings);
        }
        self.network.deinit(allocator);
        self.network_options.deinit(allocator);
    }

    pub fn validate(self: NetworkPluginExec) ErrorMessage {
        if (self.network) {
            const validated = self.network.validate();
            if (!validated.isOk()) {
                return validated;
            }
        }
        return ErrorMessage{};
    }

    pub fn withDefaults(self: *NetworkPluginExec) void {
        if (self.network) {
            self.network.withDefaults();
        }
    }
};

pub const Subnet = struct {
    /// Gateway IP for this Network.
    gateway: ?[]const u8,
    /// LeaseRange contains the range where IP are leased. Optional.
    lease_range: ?LeaseRange,
    /// Subnet for this Network in CIDR form.
    subnet: ?[]const u8,
};

pub const Route = struct {
    /// Gateway IP for this route.
    gateway: ?[]const u8,
    /// Destination for this route in CIDR form.
    destination: ?[]const u8,
    /// Route Metric
    metric: ?u32,
};

pub const LeaseRange = struct {
    /// StartIP first IP in the subnet which should be used to assign ips.
    start_ip: ?[]const u8,
    /// EndIP last IP in the subnet which should be used to assign ips.
    end_ip: ?[]const u8,
};

pub const PerNetworkOptions = struct {
    /// Aliases contains a list of names which the dns server should resolve
    /// to this container. Should only be set when DNSEnabled is true on the Network.
    /// If aliases are set but there is no dns support for this network the
    /// network interface implementation should ignore this and NOT error.
    aliases: ?[][]const u8,
    /// InterfaceName for this container. Required.
    interface_name: []const u8,
    /// StaticIPs for this container.
    static_ips: ?[][]const u8,
    /// MAC address for the container interface.
    static_mac: ?[]const u8,

    pub fn deinit(self: *PerNetworkOptions, allocator: std.mem.Allocator) void {
        if (self.aliases) |aliases| {
            for (aliases) |alias| {
                allocator.free(alias);
            }
            allocator.free(aliases);
        }
        allocator.free(self.interface_name);
        if (self.static_ips) |ips| {
            allocator.free(ips);
        }
        if (self.static_mac) |mac| {
            allocator.free(mac);
        }
    }
};

pub const PortMapping = struct {
    /// ContainerPort is the port number that will be exposed from the
    /// container.
    container_port: u16,
    /// HostIP is the IP that we will bind to on the host.
    /// If unset, assumed to be 0.0.0.0 (all interfaces).
    host_ip: []const u8,
    /// HostPort is the port number that will be forwarded from the host into
    /// the container.
    host_port: u16,
    /// Protocol is the protocol forward.
    /// Must be either "tcp", "udp", and "sctp", or some combination of these
    /// separated by commas.
    /// If unset, assumed to be TCP.
    protocol: []const u8,
    /// Range is the number of ports that will be forwarded, starting at
    /// HostPort and ContainerPort and counting up.
    /// This is 1-indexed, so 1 is assumed to be a single port (only the
    /// Hostport:Containerport mapping will be added), 2 is two ports (both
    /// Hostport:Containerport and Hostport+1:Containerport+1), etc.
    /// If unset, assumed to be 1 (a single port).
    /// Both hostport + range and containerport + range must be less than
    /// 65536.
    range: u16,

    pub fn deinit(self: *PortMapping, allocator: std.mem.Allocator) void {
        allocator.free(self.host_ip);
        allocator.free(self.protocol);
    }
};
