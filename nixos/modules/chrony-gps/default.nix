# GPS-disciplined NTP stratum 1 server.
#
# Hardware: GPS HAT with NMEA output on the GPIO UART (GPIO14/GPIO15) and a
# PPS pulse wired to a GPIO pin (GPIO18 on the Uputronics GPS HAT, GPIO4 on
# the Adafruit Ultimate GPS HAT — adjust `ppsGpioPin` accordingly).
{ lib, pkgs, ... }:

let
  # GPIO pin carrying the PPS (pulse-per-second) signal.
  ppsGpioPin = 18;
in
{
  # --- Boot hardening against GPS UART chatter ---
  # The GPS module (GT-U7) streams NMEA sentences into the Pi's RX pin from
  # power-on. U-Boot reads that stream as console keypresses and drops to its
  # interactive prompt instead of auto-booting. `CONFIG_BOOTDELAY=-2` makes
  # U-Boot boot immediately without checking for keypresses (the SD image has
  # no env storage, so `saveenv` cannot persist `bootdelay`).
  hardware.raspberry-pi.firmware.uboot.package = pkgs.ubootRaspberryPiAarch64.override (old: {
    extraConfig = (old.extraConfig or "") + ''
      CONFIG_BOOTDELAY=-2
    '';
  });

  # The same NMEA chatter would also land keys on the extlinux generation
  # menu; boot the default generation instantly instead of showing it.
  boot.loader.timeout = 0;

  # --- UART / PPS wiring (config.txt, applied by the GPU firmware) ---
  # enable_uart is already on by default (U-Boot needs it). `disable-bt`
  # disables the Bluetooth modem and maps the PL011 UART (/dev/ttyAMA0) to
  # GPIO14/15 with a stable baud rate. `pps-gpio` creates /dev/pps0 from the
  # PPS pin. The vc4-kms-v3d overlay is repeated explicitly because this list
  # replaces the nixos-hardware default.
  hardware.raspberry-pi.configtxt.settings.all.dtoverlay = [
    "vc4-kms-v3d"
    "disable-bt"
    "pps-gpio,gpiopin=${toString ppsGpioPin}"
  ];

  # Make sure the PPS kernel module is loaded even if the device-tree
  # modalias auto-load does not trigger.
  boot.kernelModules = [ "pps-gpio" ];

  # The SD image enables a serial console on ttyAMA0, which would corrupt the
  # NMEA stream from the GPS. Keep the console on the local display only.
  boot.kernelParams = lib.mkForce [ "console=tty0" ];

  # Allow chrony (running as the unprivileged `chrony` user) to read the PPS device.
  services.udev.extraRules = ''
    SUBSYSTEM=="pps", GROUP="chrony", MODE="0660"
  '';

  # --- GPS receiver (NMEA stream) ---
  services.gpsd = {
    enable = true;
    devices = [ "/dev/ttyAMA0" ];
    # Poll the receiver even without clients: chrony reads the SHM segment.
    nowait = true;
    # Do not try to reconfigure the receiver (safe default).
    readonly = true;
  };

  # --- Time service ---
  services.chrony = {
    enable = true;
    # Upstream fallback used while the GPS has no fix.
    servers = [
      "time.cloudflare.com"
      "pool.ntp.org"
    ];
    extraConfig = ''
      # NMEA time from gpsd (SHM segment 0): coarse, used to number the seconds.
      refclock SHM 0 poll 3 refid GPS precision 1e-1 offset 0.0 delay 0.2

      # Kernel PPS from the GPS HAT: the precise stratum-1 source, locked to
      # the NMEA reference above and preferred over network sources.
      refclock PPS /dev/pps0 poll 3 refid PPS lock GPS prefer

      # Serve NTP to the local networks.
      allow 10.0.0.0/8
      allow 172.16.0.0/12
      allow 192.168.0.0/16

      # Keep serving local time if every source is lost.
      local stratum 10
    '';
  };

  # NTP service port.
  networking.firewall.allowedUDPPorts = [ 123 ];

  # Diagnostic tools: ppstest, cgps, gpsmon, chronyc.
  environment.systemPackages = with pkgs; [
    pps-tools
    gpsd
  ];
}
