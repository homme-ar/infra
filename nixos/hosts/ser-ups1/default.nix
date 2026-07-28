# Host: ser-ups1 (Raspberry Pi 3) — apcupsd server for the APC Smart-UPS
# (SRT2200XLI over USB). Home Assistant connects to the NIS on tcp/3551.
{ lib, ... }:

{
  imports = [ ../../modules/apcupsd ];

  # DHCP is used; the address is pinned with a reservation on the router so
  # Home Assistant always finds the apcupsd NIS at the same IP.

  # The first-boot partition expansion stalls the boot on this host (the
  # post-grow re-read of the SD partition table fails while the root fs is
  # mounted and userspace never reaches dhcpcd). The 3.7G image is more than
  # enough for this appliance; grow it manually if ever needed.
  sdImage.expandOnBoot = false;

  # Drop the vc4-kms-v3d overlay (inherited from nixos-hardware defaults):
  # when the vc4 DRM driver probes on the Pi 3 the HDMI output dies (see
  # raspberrypi/linux#7139). This host is headless anyway; the firmware
  # framebuffer console is enough for local debugging.
  hardware.raspberry-pi.configtxt.settings.all.dtoverlay = lib.mkForce [ ];
}
