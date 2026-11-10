{
  # Linode's "GRUB 2" kernel option reads grub.cfg straight off an
  # unpartitioned disk. The by-id paths follow the config profile's slots,
  # since the kernel's sda/sdb order can change between boots.
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi-disk-0";
    content = {
      type = "filesystem";
      format = "ext4";
      mountpoint = "/";
    };
  };

  # Linode creates the swap disk alongside the image disk.
  swapDevices = [ { device = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi-disk-1"; } ];
}
