# Host: ser-dns1 — AdGuard Home DNS server.
{ ... }:

{
  imports = [ ../../modules/adguard ];

  # Recommended: static address — this is the DNS server handed out by DHCP
  # (the onboard Ethernet interface on Raspberry Pi 4 is `end0`).
  # networking.interfaces.end0.ipv4.addresses = [
  #   { address = "192.168.1.11"; prefixLength = 24; }
  # ];
  # networking.defaultGateway = "192.168.1.1";
  # # The host itself can resolve through AdGuard Home once it is running.
  # networking.nameservers = [ "127.0.0.1" ];
}
