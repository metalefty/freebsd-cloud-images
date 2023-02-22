#!/usr/bin/env bash
version="${1:-13.0}"
debug=$4
install_media="${install_media:-http}"
requisite_pkgs="curl"

pkg info --quiet ${requisite_pkgs}
if [ $? != 0 ]; then
    echo "Requisite packages are missing, install following packages:" >&2
    echo "${requisite_pkgs}" | sed -e 's|^|\t|' -e 's| |\n\t|g' >&2
    exit 1
fi

set -eux
root_fs="${root_fs:-zfs}"  # ufs or zfs

function build {
    VERSION=$1
    BASE_URL="http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/${VERSION}-RELEASE"
    if ! curl --fail --silent -L $BASE_URL; then
        BASE_URL="http://ftp-archive.freebsd.org/pub/FreeBSD-Archive/old-releases/amd64/${VERSION}-RELEASE"
    fi


    if [ ${root_fs} = "zfs" ]; then
        gptboot=/boot/gptzfsboot
    else
        gptboot=/boot/gptboot
    fi

    dd if=/dev/zero of=final.raw bs=1048576 count=3000
    md_dev=$(mdconfig -a -t vnode -f final.raw)
    gpart create -s gpt ${md_dev}
    gpart add -t freebsd-boot -s 1024 ${md_dev}
    gpart bootcode -b /boot/pmbr -p ${gptboot} -i 1 ${md_dev}
    gpart add -t efi -s 40M ${md_dev}
    gpart add -s 1G -l swapfs -t freebsd-swap ${md_dev}
    gpart add -t freebsd-${root_fs} -l rootfs ${md_dev}
    newfs_msdos -F 32 -c 1 /dev/${md_dev}p2
    mount -t msdosfs /dev/${md_dev}p2 /mnt
    mkdir -p /mnt/EFI/BOOT
    cp /boot/loader.efi /mnt/EFI/BOOT/BOOTX64.efi
    umount /mnt


    if [ ${root_fs} = "zfs" ]; then
        zpool create -o altroot=/mnt zroot ${md_dev}p4
        zfs set compress=on  zroot
        zfs create -o mountpoint=none                                  zroot/ROOT
        zfs create -o mountpoint=/ -o canmount=noauto                  zroot/ROOT/default
        mount -t zfs zroot/ROOT/default /mnt
        zpool set bootfs=zroot/ROOT/default zroot
    else
        newfs -U -L FreeBSD /dev/${md_dev}p4
        mount /dev/${md_dev}p4 /mnt
    fi


    curl -L ${BASE_URL}/base.txz | tar vxf - -C /mnt
    curl -L ${BASE_URL}/kernel.txz | tar vxf - -C /mnt
    echo "
export ASSUME_ALWAYS_YES=YES
cd /tmp
pkg install -y ca_root_nss
pkg install -y net/cloud-init
pkg install -y firstboot-freebsd-update firstboot-pkgs
pkg install -y dual-dhclient
cp /usr/local/etc/cloud/cloud.cfg.d/05_logging.cfg.sample /usr/local/etc/cloud/cloud.cfg.d/05_logging.cfg
touch /etc/rc.conf
" > /mnt/tmp/cloudify.sh

    if [ -z "${debug}" ]; then # Lock root account
        echo "pw mod user root -w no" >> /mnt/tmp/cloudify.sh
    else
        echo 'echo "!234AaAa56" | pw usermod -n root -h 0' >> /mnt/tmp/cloudify.sh
    fi

    chmod +x /mnt/tmp/cloudify.sh

    cp /etc/resolv.conf /mnt/etc/resolv.conf
    mount -t devfs devfs /mnt/dev
    chroot /mnt /tmp/cloudify.sh
    umount /mnt/dev
    rm /mnt/tmp/cloudify.sh
    echo '' > /mnt/etc/resolv.conf
    if [ ${root_fs} = "ufs" ]; then
        echo '/dev/gpt/rootfs   /       ufs     rw      1       1' >>  /mnt/etc/fstab
    fi
    echo '/dev/gpt/swapfs  none    swap    sw      0       0' >> /mnt/etc/fstab

    echo 'boot_multicons="YES"' >> /mnt/boot/loader.conf
    echo 'boot_serial="YES"' >> /mnt/boot/loader.conf
    echo 'comconsole_speed="115200"' >> /mnt/boot/loader.conf
    echo 'autoboot_delay="1"' >> /mnt/boot/loader.conf
    echo 'console="comconsole,efi"' >> /mnt/boot/loader.conf
    echo '-P' >> /mnt/boot.config
    rm -rf /mnt/tmp/*

    if [ -n "${debug}" ]; then
        echo 'rc_debug="YES"' >> /mnt/etc/rc.conf
    fi

    echo 'cloudinit_enable="YES"' >> /mnt/etc/rc.conf
    echo 'ipv6_activate_all_interfaces="YES"' >> /mnt/etc/rc.conf
    echo 'dhclient_program="/usr/local/sbin/dual-dhclient"' >> /mnt/etc/rc.conf
    echo 'sshd_enable="YES"' >> /mnt/etc/rc.conf
    echo 'sendmail_enable="NONE"' >> /mnt/etc/rc.conf

    echo 'qemu_guest_agent_enable="YES"' >> /mnt/etc/rc.conf
    echo 'qemu_guest_agent_flags="-d -v -l /var/log/qemu-ga.log"' >> /mnt/etc/rc.conf

    touch /mnt/firstboot
    echo 'firstboot_freebsd_update_enable="YES"' >> /mnt/etc/rc.conf
    echo 'firstboot_pkgs_enable="YES"' >> /mnt/etc/rc.conf
    echo 'firstboot_pkgs_list=""' >> /mnt/etc/rc.conf

    if [ ${root_fs} = "ufs" ]; then
        echo 'growfs_enable="YES"' >> /mnt/etc/rc.conf
    fi

    echo "/etc/rc.conf"
    echo "***"
    cat /mnt/etc/rc.conf
    echo "***"

    if [ ${root_fs} = "zfs" ]; then
        echo 'zfs_load="YES"' >> /mnt/boot/loader.conf
        echo 'vfs.root.mountfrom="zfs:zroot/ROOT/default"' >> /mnt/boot/loader.conf
        echo 'zfs_enable="YES"' >> /mnt/etc/rc.conf

        # make sure the directory exists before creating cloud.cfg
        mkdir -p /mnt/etc/cloud
        echo 'growpart:
   mode: auto
   devices:
      - /dev/vtbd0p4
      - /
' >> /mnt/etc/cloud/cloud.cfg
    fi

    if [ ${root_fs} = "zfs" ]; then
        ls /mnt
        ls /mnt/sbin
        ls /mnt/sbin/init
        zfs umount /mnt
        zfs umount /mnt/zroot
        zpool export zroot
    else
        umount /dev/${md_dev}p4
    fi
    mdconfig -du ${md_dev}
}

build $version
