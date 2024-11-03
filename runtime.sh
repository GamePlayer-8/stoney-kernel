#!/bin/bash

set -ex

SCRIPT_PATH="$(dirname "$(realpath "$0")")"
SYS_RULE="${SYS_RULE:-$1}"
BUILD_RUNTIME="${BUILD_RUNTIME:-$2}"
BUILD_RUNTIME="${BUILD_RUNTIME:-/tmp}"

kernel_config_dir="${BUILD_RUNTIME}/config"
source_dir="${BUILD_RUNTIME}/kernel/source"
build_dir="${BUILD_RUNTIME}/build"
patches_dir="${BUILD_RUNTIME}/patches"

kernel_version="6.6.43"
tarball_url="https://cdn.kernel.org/pub/linux/kernel/v${kernel_version:0:1}.x/linux-${kernel_version}.tar.xz"
tarball_name="$(echo $tarball_url | cut -f 8 -d '/')"
arch="x86_64"
firmware_dir="${source_dir}/stoney_firmware"

distros=('debian' 'alpine' 'vanilla')

function build_kernel {
    # Install amdgpu firmware
    mkdir -p "${firmware_dir}/amdgpu"
    cp -r /lib/firmware/amdgpu/stoney* "${firmware_dir}/amdgpu"
    cp -r "$SCRIPT_PATH/patches" "${patches_dir}"
    cp -r "$SCRIPT_PATH/config" "${kernel_config_dir}"
    # doesn't matter if decompression fails
    xz_count=`ls -1 "${firmware_dir}"/amdgpu/stoney*.xz 2>/dev/null | wc -l`
    zst_count=`ls -1 "${firmware_dir}"/amdgpu/stoney*.zst 2>/dev/null | wc -l`
	if [ $xz_count != 0 ]; then
        xz -d "${firmware_dir}"/amdgpu/stoney*.xz &> /dev/null || true
    fi
	if [ $zst_count != 0 ]; then
        zstd -d "${firmware_dir}"/amdgpu/stoney*.zst &> /dev/null || true
    fi

    kernel_source_dir="${source_dir}/linux-${kernel_version}"
    output_dir="${build_dir}"
    module_dir="${output_dir}/modules"
    header_dir="${output_dir}/headers"

    echo "Building kernel"

    curl -L "$tarball_url" -o "${source_dir}/${tarball_name}"
    tar xf "${source_dir}/${tarball_name}" -C "${source_dir}/"
    cd "$kernel_source_dir"
    for f in "${patches_dir}"/*; do
        patch -p1 < "$f" &> /dev/null || true;
    done

    # install config
    cp "${kernel_config_dir}/config" .config
    make CROSS_COMPILE="$cross" ARCH="$arch" olddefconfig

    # build kernel and modules
    make CROSS_COMPILE="$cross" ARCH="$arch" -j"$(nproc --all)"

    # install build files to output dir
    mkdir -p "$output_dir"
    make modules_install install \
	    ARCH="$arch" \
            INSTALL_MOD_PATH="$module_dir" \
	    INSTALL_MOD_STRIP=1 \
	    INSTALL_PATH="$output_dir" \
	    INSTALL_DTBS_PATH="$dtbs_dir"
    cp .config "$output_dir/config"
    cp System.map "$output_dir/System.map"
    cp include/config/kernel.release "$output_dir/kernel.release"

    # install header files
    # stolen from arch's linux PKGBUILD
    mkdir -p "$header_dir"

    # build files
    install -Dt "$header_dir" -m644 .config Makefile Module.symvers System.map \
        vmlinux
    install -Dt "$header_dir/kernel" -m644 kernel/Makefile
    install -Dt "$header_dir/arch/x86" -m644 arch/x86/Makefile
    cp -t "$header_dir" -a scripts

    # header files
    cp -t "$header_dir" -a include
    cp -t "$header_dir/arch/x86" -a arch/x86/include
    install -Dt "$header_dir/arch/x86/kernel" -m644 arch/x86/kernel/asm-offsets.s
    install -Dt "$header_dir/drivers/md" -m644 drivers/md/*.h
    install -Dt "$header_dir/net/mac80211" -m644 net/mac80211/*.h
    install -Dt "$header_dir/drivers/media/i2c" -m644 drivers/media/i2c/msp3400-driver.h
    install -Dt "$header_dir/drivers/media/usb/dvb-usb" -m644 drivers/media/usb/dvb-usb/*.h
    install -Dt "$header_dir/drivers/media/dvb-frontends" -m644 drivers/media/dvb-frontends/*.h
    install -Dt "$header_dir/drivers/media/tuners" -m644 drivers/media/tuners/*.h
    install -Dt "$header_dir/drivers/iio/common/hid-sensors" -m644 drivers/iio/common/hid-sensors/*.h

    # kconfig files
    find . -name 'Kconfig*' -exec install -Dm644 {} "$header_dir/{}" \;

    # remove documentation
    rm -r "$header_dir/Documentation"

    # remove broken symlinks
    find -L "$header_dir" -type l -delete

    # remove loose objects
    find "$header_dir" -type f -name '*.o' -delete

    # strip build tools
    while read -rd '' file; do
        case "$(file -Sib "$file")" in
            application/x-sharedlib\;*)      # Libraries (.so)
                strip "$file" ;;
            application/x-archive\;*)        # Libraries (.a)
                strip "$file" ;;
            application/x-executable\;*)     # Binaries
                strip "$file" ;;
            application/x-pie-executable\;*) # Relocatable binaries
                strip "$file" ;;
        esac
    done < <(find "$header_dir" -type f -perm -u+x ! -name vmlinux -print0)
    strip "$header_dir/vmlinux"

    # compress all resulting files
    cd "$output_dir"; tar -caf kernel.tar.gz *; cd -
    if [ -z "$DEBIAN_SYS" ]; then
        rm -f /dist/kernel-alpine.tar.gz
        mv "$output_dir/kernel.tar.gz" /dist/kernel-alpine.tar.gz
        return 0
    fi
    rm -f /dist/kernel.tar.gz
    mv "$output_dir/kernel.tar.gz" /dist/
}

function package_kernel {
    distro=$1

    case $distro in
        alpine)
                rm -rf /dist/alpine
                rm -rf "${build_dir}"
                mkdir -p "${build_dir}"
                cp -r "$SCRIPT_PATH/packaging/alpine" "${build_dir}/"
                package_dir="${build_dir}/alpine/pkg/community/linux-chrultrabook-stoney"
                mkdir -p "${package_dir}"
                cp /dist/kernel-alpine.tar.gz "${package_dir}/kernel.tar.gz"
                cp "${build_dir}/alpine/src/community/linux-chrultrabook-stoney/APKBUILD.template" "${package_dir}/APKBUILD"
                sed -i "s/KERNELVER/${kernel_version}/g" "${package_dir}/APKBUILD"
                output_dir="${build_dir}"
                BUILDUSER="abuilder"
                adduser "$BUILDUSER" -D || true
                usermod -aG abuild "$BUILDUSER" || true
                mkdir -p "/home/$BUILDUSER/.abuild"
                chown -R "$BUILDUSER:$BUILDUSER" "/home/$BUILDUSER"
                if [ -d "/dist/alpine-keys" ]; then
                    cp -r "/dist/alpine-keys" "/home/$BUILDUSER/.abuild"
                else
                    su "$BUILDUSER" -c "abuild-keygen -an"
                fi
                chown -R "$BUILDUSER:$BUILDUSER" "/home/$BUILDUSER/.abuild"
                chown -R "$BUILDUSER:$BUILDUSER" "${build_dir}"
                akeys="$(find "/home/$BUILDUSER/.abuild/" -type f -name '*.rsa.pub' | tr '\n' ' ')"
                for export_key in $akeys; do
                    cp -v "$export_key" /etc/apk/keys/
                done
                mkdir -p /root/.abuild/
                for export_key in $akeys; do
                    cp -v "$export_key" /root/.abuild/
                done
                chown -R 0:0 /root
                # Checksum
                su "$BUILDUSER" -c "cd ${package_dir}
                abuild checksum"
                # Build
                apk add $(grep "depends\=" "${package_dir}/APKBUILD" | cut -f 2 -d '"' | tr '\n' ' ') \
                        $(grep "makedepends\=" "${package_dir}/APKBUILD" | cut -f  2 -d '"' | tr '\n' ' ')
                su "$BUILDUSER" -c "cd ${package_dir}
                abuild -rKFc"
                mkdir -p /dist/alpine/keys
                cp -rv "/home/$BUILDUSER/packages/community/x86_64" /dist/alpine/pkg
                for export_key in $akeys; do
                    cp -v "$export_key" /dist/alpine/keys/
                done
                chown -R 0:0 /dist
                ;;
        debian)
                rm -rf /dist/debian
                rm -rf "${build_dir}"
                mkdir -p "${build_dir}"
                cp -r "$SCRIPT_PATH/packaging/debian" "${build_dir}/"
                package_dir="${build_dir}/debian/pkg/chrultrabook/linux-chrultrabook-stoney"
                mkdir -p "${build_dir}/debian/bin/DEBIAN"
                cp /dist/kernel.tar.gz "${build_dir}/debian/bin/kernel.tar.gz"
                cp "${package_dir}/control.main" "${build_dir}/debian/bin/DEBIAN/control"
                cp "${package_dir}/postinst" "${build_dir}/debian/bin/DEBIAN/postinst"
                cp "${package_dir}/preinst" "${build_dir}/debian/bin/DEBIAN/preinst"
                cp "${package_dir}/triggers" "${build_dir}/debian/bin/DEBIAN/triggers"
                cp "${package_dir}/postrm" "${build_dir}/debian/bin/DEBIAN/postrm"
                cp "${package_dir}/prerm" "${build_dir}/debian/bin/DEBIAN/prerm"
                cd ${build_dir}/debian/bin
                tar -xvf kernel.tar.gz
                rm -f kernel.tar.gz
                mkdir -p boot usr/src lib usr/share/kernel/chrultrabook-stoney
                mv vmlinuz* boot/vmlinuz-"${kernel_version}"-chrultrabook-stoney
                mv config boot/config-"${kernel_version}"-chrultrabook-stoney
                mv System.map boot/System.map-"${kernel_version}"-chrultrabook-stoney
                mv kernel.release usr/share/kernel/chrultrabook-stoney
                mv modules/lib/modules lib/
                mv headers usr/src/linux-headers-"${kernel_version}"-chrultrabook-stoney
                rm -rf System.map-* config-* lib/modules/"${kernel_version}"-chrultrabook-stoney/build
                cd -
                chmod 0755 "${build_dir}"/debian/bin/*
                chmod 0755 "${build_dir}"/debian/bin/DEBIAN/*
                chmod 0644 "${build_dir}"/debian/bin/DEBIAN/control
                chmod 0644 "${build_dir}"/debian/bin/DEBIAN/triggers
                find "${build_dir}"/debian/bin/* -type d | xargs -I '{}' chmod 0755 "{}"
                find "${build_dir}"/debian/bin/DEBIAN -type f | xargs -I '{}' sed -i "s/KERNELVER/${kernel_version}/g" "{}"
                chown -R 0:0 "${build_dir}"/debian/bin/*
                dpkg-deb --build "${build_dir}"/debian/bin
                mkdir /dist/debian
                mv "${build_dir}/debian/bin.deb" /dist/debian/kernel-debian.deb
                chown -R 0:0 /dist
                ;;
        *)

                ;;
    esac
}

case $SYS_RULE in
        vanilla)
                build_kernel
                ;;
        alpine|debian)
                package_kernel "$SYS_RULE"
                ;;
        *)
                build_kernel
                for distro in ${distros[@]}; do
                    package_kernel $distro;
                done
                ;;
esac
