# Host: ser-ups1 (Raspberry Pi 3) — apcupsd server for the APC Smart-UPS
# (SRT2200XLI over USB). Home Assistant connects to the NIS on tcp/3551.
{ ... }:

{
  imports = [ ../../modules/apcupsd ];

  # DHCP is used; the address is pinned with a reservation on the router so
  # Home Assistant always finds the apcupsd NIS at the same IP.
}
