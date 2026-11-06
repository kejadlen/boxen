{
  # The OS takes the whole eMMC. The NVMe drives are the data array's members,
  # so they must never appear here.
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/mmcblk0";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          end = "-3G";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
        swap = {
          size = "100%";
          content.type = "swap";
        };
      };
    };
  };
}
