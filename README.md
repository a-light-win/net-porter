# net-porter

`net-porter` is a [netavark](https://github.com/containers/netavark) plugin
to provide macvlan network to rootless podman container.

It consists with two major part:

- `net-porter plugin`: the `netavark` plugin that called by `netavark`
  inside the rootless environment.
- `net-porter server`: the server that responsible to creates
  the macvlan network.

The `net-porter server` is running in the rootful environment,
and listens on a unix socket. When the container starts,
netavark will call the `net-porter plugin`. The plugin then
will connect to the `net-porter server` via the unix socket,
and pass the required information to the `net-porter server`.

The `net-porter server` will authenticate the request
by the `uid` of the caller. And then creates the macvlan network
if the user has the permission.

`net-porter server` creates the macvlan via the cni plugins.

## Installation

The `net-porter` can only running on the linux system.

User can install the `net-porter` by the pre-built package,
We provide deb, rpm, and archlinux packages.

### Install with deb package

```bash
apt install -f /path/to/net-porter.deb
```

### Install with archlinux package

```bash
pacman -U /path/to/net-porter.pkg.tar.zst
```

### Build from source

If you want to build and package `net-porter` from source,
you may need following program installed:

- [git](https://git-scm.com/)
- [just](https://github.com/casey/just)
- [podman](https://github.com/containers/podman)

After install the above program, running following command to build the package:

```bash
just pack-all
```

And you will find the packages in the `zig-out/` directory.

## Configuration

The server will read the configuration from the `/etc/net-porter/config.json`.
and here is a config example:

```json
{
  "domain_socket": {
    "path": "/run/net-porter.sock",
    "user": "root",
    "group": "net-porter"
  },
  "resources": [
    {
      "name": "macvlan-dhcp",
      "allow_user": ["podman"]
      "allow_groups": ["root"]
    }
  ],
  "log": {
    "dump_env": {
      "enabled": true
    }
  }
}
```

We also need a cni configuration file for the macvlan network,
put the cni configuration file in the `/etc/net-porter/cni.d` directory,
and ensure the file name is the same as the `name` field in the `resources` field
with `.json` suffix. And here is a cni configuration example:

```json
{
  "cniVersion": "1.0.0",
  "name": "macvlan-dhcp",
  "plugins": [
    {
      "type": "macvlan",
      "master": "infra",
      "linkInContainer": false,
      "ipam": {
        "type": "dhcp",
        "request": [
          {
            "skipDefault": true,
            "option": "subnet-mask"
          }
        ],
        "provide": [
          {
            "option": "host-name",
            "fromArg": "K8S_POD_NAME"
          }
        ]
      }
    }
  ]
}
```

Ensure the `master` filed set to the interface on the host.
And if you want default routes as well, set the `skipDefault` to `false`.
More information about the cni configuration, please refer to the
official [cni documentation](https://www.cni.dev/plugins/current/main/macvlan/).

## Integrate with `podman`

Create a container network with `net-porter` driver, and use it with `podman`.

```bash
podman network create -d net-porter -o net_porter_resource=macvlan-dhcp -o net_porter_socket=/run/net-porter.sock net-porter
```

- `-d net-porter`: use the `net-porter` driver.
- `-o net_porter_resource=macvlan-dhcp`: specify the resource name, should be
  the same with server configuration.
- `-o net_porter_socket=/run/net-porter.sock`: specify the unix socket path
  of `net-porter server` listens on.
- `net-porter`: the network name.
