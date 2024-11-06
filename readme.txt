# Stoney kernel

usage: /bin/sh build.sh run <build type>
possible values are: vanilla, vanilla-alpine, debian, alpine
Vanilla indicates the kernel build while debian & alpine, packaging. (firstly run vanilla, then packaging)
If no distro is specified, all will be packaged.

Docker & Docker Compose is required. Eventually use Podman & Podman Compose.
