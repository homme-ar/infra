# apcupsd monitoring daemon for the APC Smart-UPS (SRT2200XLI) connected over
# USB. Exposes the NIS (Network Information Server) on :3551 for the Home
# Assistant apcupsd integration, plus a Prometheus exporter on :9162.
{ pkgs, ... }:

{
  # Rebuild apcupsd with the MODBUS-over-USB driver (nixpkgs builds it with
  # plain USB HID only, which on this UPS exposes a very limited set of
  # readings). The Modbus driver reports the full set (LINEV, LOADPCT,
  # OUTPUTV, frequencies, ...). Requires Modbus to be enabled on the UPS
  # front panel (Advanced menu -> Configuration -> Modbus).
  nixpkgs.overlays = [
    (_final: prev: {
      apcupsd = prev.apcupsd.overrideAttrs (old: {
        buildInputs = old.buildInputs ++ [
          prev.libmodbus
          # apcupsd's modbus-usb driver uses the legacy libusb-0.1 API.
          prev.libusb-compat-0_1
        ];
        configureFlags = old.configureFlags ++ [ "--enable-modbus-usb" ];
        # configure fills @LIBUSBH@ in include/libusb.h with the libusb *out*
        # path, but usb.h lives in the dev output (same workaround the package
        # already applies for Darwin).
        prePatch = old.prePatch + ''
          substituteInPlace include/libusb.h.in \
            --replace-fail "@LIBUSBH@" "${prev.libusb-compat-0_1.dev}/include/usb.h"
        '';
      });
    })
  ];

  services.apcupsd = {
    enable = true;
    configText = ''
      UPSCABLE usb
      UPSTYPE modbus
      # Empty DEVICE = autodetect the USB-attached UPS.
      DEVICE
      # Listen on all interfaces so Home Assistant can reach the NIS.
      NISIP 0.0.0.0
      NISPORT 3551
      # Report-only host: disable every shutdown trigger (-1/0) so the Pi
      # keeps reporting UPS status until the battery is fully exhausted.
      # Home Assistant is responsible for any shutdown automation.
      BATTERYLEVEL -1
      MINUTES -1
      TIMEOUT 0
    '';
  };

  # UPS metrics on :9162 (scrapes the local NIS at :3551 by default), scraped
  # by the cluster Prometheus.
  services.prometheus.exporters.apcupsd = {
    enable = true;
    openFirewall = false;
  };

  # The NIS (:3551) and the exporter (:9162) are only reachable from the
  # Kubernetes nodes (10.0.20.0/24 — in-cluster HA egress is masqueraded to
  # the node IP) and the office network (10.0.70.0/24).
  networking.firewall.extraCommands = ''
    for cidr in 10.0.20.0/24 10.0.70.0/24; do
      iptables -A nixos-fw -p tcp -s "$cidr" --dport 3551 -j nixos-fw-accept
      iptables -A nixos-fw -p tcp -s "$cidr" --dport 9162 -j nixos-fw-accept
    done
  '';
}
