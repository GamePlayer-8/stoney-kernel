# Stoney kernel

The repository provides the Stoneyridge kernel for Stoneyridge devices. Issue reporting welcome!

### Usage

`/bin/sh build.sh run <build type>`

---

Possible values are: 
 - `vanilla`
 - `vanilla-alpine`
 - `debian`
 - `alpine`

#### Description

Vanilla indicates the kernel build while debian & alpine, packaging. (firstly run vanilla, then packaging)
If no distro is specified, all will be packaged.

### Requirements

Docker & Docker Compose is required. Eventually use Podman & Podman Compose.

## License

[GPL 3.0](LICENSE.md)

## Authors

Stoneyridge & community contributors
Build provider: [Chimmie Firefly](https://chimmie.k.vu)
