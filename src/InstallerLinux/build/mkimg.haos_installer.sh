#!/bin/sh

profile_haos_installer() {
    profile_base

    title="HAOS AIO Installer USB"
    desc="Bootable HAOS AIO installer environment"
    profile_abbrev="haos"
    image_name="haos-installer"
    image_ext="iso"
    output_format="iso"
    arch="x86_64"
    hostname="haos-installer"

    kernel_flavors="lts"
    kernel_addons=""
    modloop_sign="no"
    kernel_cmdline="modules=loop,squashfs,sd-mod,usb-storage,uas,ahci,nvme,virtio_blk,virtio_pci,virtio_net,e1000,e1000e,igb,igc,ixgbe,i40e,ice,r8169,atlantic,alx,tg3,bnx2,bnx2x,qede,mlx4_en,mlx5_core,be2net,enic,sky2,skge,forcedeth,via-rhine,via-velocity,tulip,pcnet32,8139too,8139cp,sis900,natsemi,vmxnet3,r8152,asix,ax88179_178a,cdc_ether,smsc95xx,dm9601,mcs7830 console=tty1"

    boot_addons=""
    fs_label="HAOS-INSTLR"

    apks="$apks
        dialog
        newt
        ca-certificates
        curl
        dhcpcd
        iproute2
        linux-firmware
        jq
        xz
        util-linux
        util-linux-misc
        parted
        e2fsprogs
        dosfstools
        gptfdisk
        pv
        efibootmgr
        efivar
        pciutils
        usbutils
        openrc
        eudev
        kbd
        terminus-font
        bash
        coreutils
        findmnt
        nvme-cli
    "

    apkovl="haos-installer.apkovl.sh"
}
