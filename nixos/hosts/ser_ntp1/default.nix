# Host: ser_ntp1 — GPS-disciplined NTP stratum 1 server.
{ ... }:

{
  imports = [ ../../modules/chrony-gps ];

  # Recommended: static address for a time server (the onboard Ethernet
  # interface on Raspberry Pi 4 is `end0`).
  # networking.interfaces.end0.ipv4.addresses = [
  #   { address = "192.168.1.10"; prefixLength = 24; }
  # ];
  # networking.defaultGateway = "192.168.1.1";
  # networking.nameservers = [ "192.168.1.1" ];
}
