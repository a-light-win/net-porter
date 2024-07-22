# net-porter

`net-porter` is a [netavark](https://github.com/containers/netavark) plugin which
creates the network interface in a rootful environment,
and then move it to the target namespace.

It consists with two major part:

- `net-porter`: the `netavark` plugin that called by `netavark` inside the rootless
  environment
- `net-porter server`: the worker that creates the network interface from the
  host and move it into the container network namespace

## requires

- `ip` command
- `nsenter` command
