{
  # Linode's "GRUB 2" kernel option reads grub.cfg straight off an
  # unpartitioned disk.
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/sda";
    content = {
      type = "filesystem";
      format = "ext4";
      mountpoint = "/";
    };
  };

  # Linode creates the swap disk alongside the image disk.
  swapDevices = [ { device = "/dev/sdb"; } ];
}
