# UART jump-box support: USB-to-serial adapters get stable, physical-port
# based names (/dev/uart/usb1..usb4) and ser2net exposes each one over TCP
# (7001..7004) for remote access without SSH. Interactive tools (picocom,
# tio) are available over SSH as well.
{ pkgs, ... }:

{
  # --- Stable device naming ---
  # Symlinks keyed on the USB *topology* (physical port), not on the adapter
  # identity: cheap CH340 clones have no unique serial number, and the
  # port -> TCP-port mapping must survive swapping adapters. On the Pi 4 all
  # four USB-A ports hang off the internal USB 2.0 hub (1-1.x); full/high
  # speed serial adapters always enumerate there regardless of the physical
  # port.
  services.udev.extraRules = ''
    SUBSYSTEM=="tty", KERNELS=="1-1.1", SYMLINK+="uart/usb1"
    SUBSYSTEM=="tty", KERNELS=="1-1.2", SYMLINK+="uart/usb2"
    SUBSYSTEM=="tty", KERNELS=="1-1.3", SYMLINK+="uart/usb3"
    SUBSYSTEM=="tty", KERNELS=="1-1.4", SYMLINK+="uart/usb4"
  '';

  # --- Interactive serial tools (over SSH) ---
  environment.systemPackages = with pkgs; [
    picocom
    tio
  ];

  # The admin user opens the ttyUSB devices directly (no sudo).
  users.users.admin.extraGroups = [ "dialout" ];

  # --- ser2net (serial over TCP) ---
  # nixpkgs has no services.ser2net module (checked at the pinned rev,
  # ser2net 4.6.7), so the unit is defined here. RFC2217 (telnet) lets the
  # client negotiate the baud rate at connect time, so no per-port baud is
  # baked in; kickolduser drops a stale session when a new client connects.
  environment.etc."ser2net.yaml".text = ''
    connection: &uart-usb1
      accepter: telnet(rfc2217),tcp,7001
      connector: serialdev,/dev/uart/usb1,local
      options:
        kickolduser: true

    connection: &uart-usb2
      accepter: telnet(rfc2217),tcp,7002
      connector: serialdev,/dev/uart/usb2,local
      options:
        kickolduser: true

    connection: &uart-usb3
      accepter: telnet(rfc2217),tcp,7003
      connector: serialdev,/dev/uart/usb3,local
      options:
        kickolduser: true

    connection: &uart-usb4
      accepter: telnet(rfc2217),tcp,7004
      connector: serialdev,/dev/uart/usb4,local
      options:
        kickolduser: true
  '';

  systemd.services.ser2net = {
    description = "Serial port to network proxy (ser2net)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      # -n: stay in the foreground (ser2net self-daemonizes otherwise).
      ExecStart = "${pkgs.ser2net}/bin/ser2net -n -c /etc/ser2net.yaml";
      Restart = "on-failure";
    };
  };

  # Serial-over-TCP ports are only reachable from the Kubernetes nodes
  # (10.0.20.0/24) and the office network (10.0.70.0/24), same policy as the
  # metrics exporters in modules/common.
  networking.firewall.extraCommands = ''
    for cidr in 10.0.20.0/24 10.0.70.0/24; do
      iptables -A nixos-fw -p tcp -s "$cidr" --dport 7001:7004 -j nixos-fw-accept
    done
  '';
}
