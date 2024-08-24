set unstable := true
set dotenv-filename := "pkg-env"

builder := (just_executable() +
            " -f " + "zig-out/builder/Justfile"
           )

[no-cd, script('bash')]
build arch='x86_64': fetch-builder
  echo "Build net-porter for {{ arch }} ..."
  {{ builder }} zig build "{{ arch }}-linux-musl"

[no-cd, script('bash')]
pack arch='x86_64': fetch-builder
  export PKG_ARCH="{{ arch }}"
  {{ builder }} pack

pack-all: (pack-from-scratch 'x86_64') (pack-from-scratch 'aarch64')

[no-cd, script('bash')]
clean: clean-pack clean-build

[no-cd]
clean-all: \
  clean-builder \
  clean-bootstrap-builder \
  clean

[private, no-cd, script('bash')]
pack-from-scratch arch: (build arch) (pack arch)

[private, no-cd]
clean-pack:
  rm -f zig-out/*.deb
  rm -f zig-out/*.rpm
  rm -f zig-out/*.tar.xz
  rm -f zig-out/*.tar.zst

[private, no-cd]
clean-build:
  rm -rf .zig-cache/*

[private, no-cd, script('bash')]
fetch-bootstrap-builder:
  mkdir -p zig-out
  if [ ! -e zig-out/bootstrap.just ]; then
    echo "Downloading bootstrap script of builder ..."
    curl -L -o zig-out/bootstrap.just https://raw.githubusercontent.com/a-light-win/builder/main/bootstrap/Justfile
  fi

[private, no-cd]
clean-bootstrap-builder:
  rm -f zig-out/bootstrap.just

[private, no-cd]
fetch-builder: fetch-bootstrap-builder
  {{ just_executable() }} -f zig-out/bootstrap.just bootstrap 'zig-out'

[private, no-cd]
clean-builder:
  rm -rf zig-out/builder
