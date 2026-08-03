# Host: ser-serial1 (Raspberry Pi 4) — UART jump box for the rack. Serial
# devices are reachable interactively over SSH (picocom/tio) and remotely
# over TCP via ser2net (ports 7001-7004, see modules/uart).
{ ... }:

{
  imports = [
    ../../modules/rpi4
    ../../modules/uart
  ];

  # DHCP is used; the address is pinned with a reservation on the router so
  # the jump box is always reachable at the same IP.
}
