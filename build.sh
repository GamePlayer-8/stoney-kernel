#!/bin/sh

set -ex

SCRIPT_PATH="$(realpath "$(dirname "$0")")"
CONTAINER_TYPE="${CONTAINER_TYPE:-$2}"
CONTAINER_TYPE="${CONTAINER_TYPE:-vanilla}"
NPROC_CPUS="${NPROC_CPUS:-$3}"
NPROC_CPUS="${NPROC_CPUS:-$(nproc --all)}"
export NPROC_CPUS

VERSION="${VERSION:-$4}"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 | rev | cut -f 1 -d 'v' | rev).$(git rev-list --count HEAD)}"
export VERSION

cd "$SCRIPT_PATH"

distros='vanilla vanilla-alpine debian alpine'

case "$1" in
        "build")
                docker compose build "$2"
                ;;
        "run")
                docker compose down "$2"
                docker compose up "$2"
                ;;
        "clean")
                docker compose down --remove-orphans -v --rmi all
                ;;
        *)
                docker compose build
                for distro in $distros; do
                    docker compose up "$distro";
                done
                ;;
esac
