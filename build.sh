#!/bin/bash

set -e

kernel_config_dir=$PWD/config
source_dir=$PWD/source
build_dir=$PWD/build
patches_dir=$PWD/patches
packaging_dir=$PWD/packaging

kernel_version="6.6.43"
tarball_url="https://cdn.kernel.org/pub/linux/kernel/v${kernel_version:0:1}.x/linux-${kernel_version}.tar.xz"
tarball_name="$(echo $tarball_url | cut -f 8 -d '/')"

distros=('debian' 'alpine' 'none')

function build_kernel {
	  arch=x86_64

	  # Install amdgpu firmware
	  firmware_dir=${source_dir}/stoney_firmware
	  mkdir -p ${firmware_dir}/amdgpu
	  cp -r /lib/firmware/amdgpu/stoney* ${firmware_dir}/amdgpu
	  # doesn't matter if decompression fails
    xz_count=`ls -1 ${firmware_dir}/amdgpu/stoney*.xz 2>/dev/null | wc -l`
    zst_count=`ls -1 ${firmware_dir}/amdgpu/stoney*.zst 2>/dev/null | wc -l`
	  if [ $xz_count != 0 ]; then
      xz -d ${firmware_dir}/amdgpu/stoney*.xz &> /dev/null || true
    fi
	  if [ $zst_count != 0 ]; then
      zstd -d ${firmware_dir}/amdgpu/stoney*.zst &> /dev/null || true
    fi

    kernel_source_dir=${source_dir}/linux-${kernel_version}
    output_dir=${build_dir}
    module_dir=${output_dir}/modules
    header_dir=${output_dir}/headers

    echo "Building kernel"

    curl -L $tarball_url -o ${source_dir}/${tarball_name}
    tar xf ${source_dir}/${tarball_name} -C ${source_dir}/
    cd $kernel_source_dir
    for f in ${patches_dir}/*; do
        patch -p1 < $f &> /dev/null || true;
    done

    # install config
    cp ${kernel_config_dir}/config .config
    make CROSS_COMPILE=$cross ARCH=$arch olddefconfig

    # build kernel and modules
    make CROSS_COMPILE=$cross ARCH=$arch -j$(nproc)

    # install build files to output dir
    mkdir -p $output_dir
    make modules_install install \
	    ARCH=$arch \
            INSTALL_MOD_PATH=$module_dir \
	    INSTALL_MOD_STRIP=1 \
	    INSTALL_PATH=$output_dir \
	    INSTALL_DTBS_PATH=$dtbs_dir
    cp .config $output_dir/config
    cp System.map $output_dir/System.map
    cp include/config/kernel.release $output_dir/kernel.release

    # install header files
    # stolen from arch's linux PKGBUILD
    mkdir -p $header_dir

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
    strip $header_dir/vmlinux

    # compress all resulting files
    cd $output_dir; tar -caf kernel.tar.gz *; cd -
}

function package_kernel {
    distro=$1

    # determine which container tools are available
    if command -v podman &> /dev/null; then
        container=podman
    elif command -v docker &> /dev/null; then
        container=docker
        if [ "$EUID" -e 0 ] || id -nG "$USER" | grep -qw "docker"; then
            elevate=""
        elif command -v sudo &> /dev/null; then
            elevate=sudo
        elif command -v doas &> /dev/null; then
            elevate=doas
        else
            echo "Can't elevate to root privileges and user is not in the Docker group. Skipping packaging"
            return
        fi
    else
        echo "No suitable container tool found. Skipping packaging"
        return
    fi

    case $distro in
    alpine)
	cd ../..
        package_dir=${packaging_dir}/alpine/pkg/community/linux-chrultrabook-stoney/
        mkdir -p "${package_dir}"
	cp ${build_dir}/kernel.tar.gz ${package_dir}
        cp packaging/alpine/src/community/linux-chrultrabook-stoney/APKBUILD.template ${package_dir}/APKBUILD
        sed -i "s/KERNELVER/${kernel_version}/g" ${package_dir}/APKBUILD
        mkdir ${packaging_dir}/../builds
	sudo $container run --rm \
            -v ${packaging_dir}/alpine:/stoney:z \
            -v ${packaging_dir}/../builds:/builds \
            -i alpine:latest \
            /stoney/package.sh $USER
        sudo chown -R $USER:$USER ${packaging_dir}/../..
    ;;
    debian)
	package_dir=${packaging_dir}/debian/pkg/chrultrabook/linux-chrultrabook-stoney/
	mkdir -p ${packaging_dir}/debian/bin/DEBIAN
	cp ${build_dir}/kernel.tar.gz ${packaging_dir}/debian/bin/
	cp ${package_dir}/control.main ${packaging_dir}/debian/bin/DEBIAN/control
	cp ${package_dir}/postinst ${packaging_dir}/debian/bin/DEBIAN/postinst
	cp ${package_dir}/preinst ${packaging_dir}/debian/bin/DEBIAN/preinst
	cp ${package_dir}/triggers ${packaging_dir}/debian/bin/DEBIAN/triggers
	cp ${package_dir}/postrm ${packaging_dir}/debian/bin/DEBIAN/postrm
	cp ${package_dir}/prerm ${packaging_dir}/debian/bin/DEBIAN/prerm
	CODE_PWD="$(pwd)"
	cd ${packaging_dir}/debian/bin
	tar -xvf kernel.tar.gz
	rm -f kernel.tar.gz
	mkdir -p boot usr/src lib usr/share/kernel/chrultrabook-stoney
	mv vmlinuz* boot/vmlinuz-"${kernel_version}"-chrultrabook-stoney
	mv config boot/config-"${kernel_version}"-chrultrabook-stoney
	mv System.map boot/System.map-"${kernel_version}"-chrultrabook-stoney
	mv kernel.release usr/share/kernel/chrultrabook-stoney
	mv modules/lib/modules lib/
	mv headers usr/src/linux-headers-"${kernel_version}"-chrultrabook-stoney
	rm -f System.map-* config-*
	ln -s usr/src/linux-headers-"${kernel_version}"-chrultrabook-stoney lib/modules/"${kernel_version}"-chrultrabook-stoney/build
	cd "$CODE_PWD"
	unset CODE_PWD
        chmod 0755 ${packaging_dir}/debian/bin/*
	chmod 0755 ${packaging_dir}/debian/bin/DEBIAN/*
	chmod 0644 ${packaging_dir}/debian/bin/DEBIAN/control
	chmod 0644 ${packaging_dir}/debian/bin/DEBIAN/triggers
	find ${packaging_dir}/debian/bin/* -type d | xargs -I '{}' sudo chmod 0755 "{}"
        sed -i "s/KERNELVER/${kernel_version}/g" ${packaging_dir}/debian/bin/DEBIAN/control
        sed -i "s/KERNELVER/${kernel_version}/g" ${packaging_dir}/debian/bin/DEBIAN/preinst
        sed -i "s/KERNELVER/${kernel_version}/g" ${packaging_dir}/debian/bin/DEBIAN/postinst
	sudo chown -R root:root ${packaging_dir}/debian/bin/*
	sudo dpkg-deb --build ${packaging_dir}/debian/bin
	mkdir ${packaging_dir}/../builds
	sudo mv ${packaging_dir}/debian/bin.deb ${packaging_dir}/../builds/kernel.deb
	sudo chown -R $USER:$USER ${packaging_dir}/../builds
    ;;
    esac
}

build_kernel
# if an argument is passed to the script, package for that distro. otherwise package for each distro
if [[ -n $1 ]]; then
    distro=$1
    package_kernel $distro
else
    for distro in ${distros[@]}; do
        package_kernel $distro;
    done
fi
