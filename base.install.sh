#!/bin/bash

# My Little Arch Linux Installer
#
# Copyright (c) 2012 Anders Nor Berle <anders@berle.cc>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

FS="ext4"
FS_OPTIONS="rw,relatime,noatime,data=ordered"
FS_SSD_OPTIONS="discard"
HOSTNAME="arch"
BOOT_PART="/dev/disk/by-partlabel/boot"
LVM_PART="/dev/disk/by-partlabel/archdisk"
HOOKS=""

while test $# -gt 0; do
  OPTION=$1
  shift

  case "$OPTION" in
    --btrfs)
      FS="btrfs"
      FS_OPTIONS="defaults,noatime"
      FS_SSD_OPTIONS="discard,ssd"
      ;;
    --luks)
      USE_LUKS=1
      ;;
    --hostname=*)
      HOSTNAME=`echo "$OPTION" | sed 's/--hostname=//'`
      ;;
    --nfs=*)
      NFS_CACHE=`echo "$OPTION" | sed 's/--nfs=//'`
      ;;
    --ssd)
      USE_SSD=1
      ;;
    -*)
      echo "Unrecognized option $OPTION"
      exit
      ;;
    *)
      DEVICE=$OPTION
      ;;
  esac
done

if [ "x$DEVICE" = "x" ]; then
  echo "Usage: $0 <options> <device>"
  cat<<"EOF"

My Little Arch Linux Installer
  Written by Anders Nor Berle <anders@berle.cc>

  --btrfs                  Use BTRFS as root filesystem (Default ext4)
  --hostname=<hostname>    Set the target hostname (Default "arch")
  --luks                   Enable LUKS encryption (Default off)
  --nfs=<remote>           Mount an NFS directory as pacman package cache
  --ssd                    Optimize for SSD devices

EOF
  exit
fi

if [ "x$USE_SSD" != "x" ]; then
  FS_OPTIONS="$FS_OPTIONS,$FS_SSD_OPTIONS"
fi

# -- Unmount any previous attempt

#umount /mnt/var/cache/pacman/pkg
#umount /mnt/boot
#umount /mnt/home
#umount /mnt
#vgremove -f arch
#cryptsetup luksClose $LVM_PART

# -- Partitioning

sgdisk \
  -o \
  -n 1:0:+32M -t 1:ef02 -c 1:bios \
  -n 2:0:+512M -c 2:boot \
  -N=3 -c 3:archdisk \
  -p $DEVICE

sleep 2 # Needed to make partitions visible

# -- LUKS

if [ "x$USE_LUKS" != "x" ]; then
  HOOKS="$HOOKS encrypt"
  LUKS_PART=$LVM_PART
  LVM_PART="/dev/mapper/crypt"

  cryptsetup \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    --iter-time 5000 \
    --verify-passphrase \
    luksFormat $LUKS_PART

  cryptsetup \
    luksOpen $LUKS_PART crypt
fi

# -- LVM

HOOKS="$HOOKS lvm2"
ROOT_PART="/dev/mapper/arch-root"
HOME_PART="/dev/mapper/arch-home"

pvcreate $LVM_PART
vgcreate arch $LVM_PART
lvcreate --name root --extents 20%FREE arch
lvcreate --name home --extents 100%FREE arch

# -- Filesystems

mkfs.ext2 $BOOT_PART
mkfs.$FS $ROOT_PART
mkfs.$FS $HOME_PART

# -- Mount

mount $ROOT_PART /mnt
mkdir /mnt/home
mount $HOME_PART /mnt/home
mkdir /mnt/boot
mount $BOOT_PART /mnt/boot

if [ "x$NFS_CACHE" != "x" ]; then
  mkdir -p /mnt/var/cache/pacman/pkg
  mount -o nolock $NFS_CACHE /mnt/var/cache/pacman/pkg
fi

# -- Initialize base system

pacstrap /mnt base base-devel btrfs-progs syslinux networkmanager sudo gptfdisk ntp

# -- /etc

echo $ROOT_PART / $FS $FS_OPTIONS 0 1 >> /mnt/etc/fstab
echo $HOME_PART /home $FS $FS_OPTIONS 0 2 >> /mnt/etc/fstab
echo $BOOT_PART /boot ext2 rw,relatime,noatime 0 2 >> /mnt/etc/fstab

perl -pi -e 's/(issue_discards) = 0/$1 = 1/' /etc/lvm/lvm.conf

echo en_US.UTF-8 UTF-8 > /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo LANG=en_US.UTF-8 > /mnt/etc/locale.conf

# -- Time setup

read -p "Enter timezone (ex Europe/Oslo): " -r
arch-chroot /mnt timedatectl set-timezone $REPLY
arch-chroot /mnt systemctl enable ntpd
arch-chroot /mnt systemctl start ntpd
arch-chroot /mnt timedatectl set-ntp 1
ln -s /usr/share/zoneinfo/Europe/Oslo /mnt/etc/localtime
hwclock --systohc --utc

# -- Hostname

echo $HOSTNAME > /mnt/etc/hostname

# -- Network

arch-chroot /mnt systemctl enable NetworkManager.service

# -- Initramfs

perl -pi -e 's/^(HOOKS)/#$1/' /mnt/etc/mkinitcpio.conf
echo HOOKS=\"base udev autodetect modconf keyboard block$HOOKS filesystems fsck\" >> /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -p linux

# -- User setup

read -p "Enter username: " -r
arch-chroot /mnt useradd -m -g users -G wheel -s /bin/bash $REPLY
arch-chroot /mnt passwd $REPLY
arch-chroot /mnt passwd -l root
echo "%wheel ALL=(ALL) ALL" > /mnt/etc/sudoers.d/wheel

# -- Syslinux

cp -r /mnt/usr/lib/syslinux/bios/*.c32 /mnt/boot/syslinux

sed -i 's,\/dev\/sda3,'"$ROOT_PART"',g' /mnt/boot/syslinux/syslinux.cfg
if [ "x$USE_LUKS" != "x" ]; then
    sed -i 's,^[    ].*APPEND.*,    APPEND root='"$ROOT_PART"' cryptdevice='"$LUKS_PART"':crypt rw,g' /mnt/boot/syslinux/syslinux.cfg
fi

sgdisk $DEVICE --attributes=1:set:2 # GPT
arch-chroot /mnt syslinux-install_update -a -i -m

