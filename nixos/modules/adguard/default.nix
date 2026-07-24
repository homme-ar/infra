# AdGuard Home DNS server.
#
# NOTE — admin credentials: the setup wizard only runs when AdGuard Home
# starts without a config file, but this module always generates one, so the
# wizard never appears and `users` stays empty (panel without auth). Create
# the admin user once, directly on the host:
#
#   mkpasswd -m bcrypt -R 10 '<password>'          # on your workstation
#   ssh admin@<host>
#   sudo systemctl stop adguardhome
#   sudo vim /var/lib/AdGuardHome/AdGuardHome.yaml # replace `users: []` with:
#     users:
#       - name: admin
#         password: <bcrypt hash>
#   sudo systemctl start adguardhome
#
# `users` is not part of the declarative settings below, so it survives
# service restarts and comin deployments. The declarative `settings` are
# merged into /var/lib/AdGuardHome/AdGuardHome.yaml on every service start
# and take precedence over changes made in the web UI for the same keys;
# everything else (stats, query log, extra rewrites) remains manageable
# from the UI.
{ ... }:

{
  services.adguardhome = {
    enable = true;
    # Admin web UI on the standard HTTP port. The panel itself is protected
    # by the admin credentials (see the note at the top of this file).
    port = 80;
    # Open the web UI port (80/TCP) in the firewall. Does not cover DNS.
    openFirewall = true;
    # Keep UI-managed state persistent while enforcing the baseline below.
    mutableSettings = true;
    settings = {
      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;
        upstream_dns = [
          "https://dns.cloudflare-dns.com/dns-query"
          "https://dns.google/dns-query"
        ];
        bootstrap_dns = [
          "1.1.1.1"
          "9.9.9.9"
        ];
        # 4 MB cache, at least 10 minutes TTL.
        cache_size = 4194304;
        cache_ttl_min = 600;
      };
      filtering = {
        protection_enabled = true;
        filtering_enabled = true;
        filters = [
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt";
            name = "AdGuard DNS filter";
            id = 1;
          }
          {
            enabled = true;
            url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt";
            name = "AdAway Default Blocklist";
            id = 2;
          }
        ];
      };
    };
  };

  # DNS resolver ports (openFirewall only covers the web UI). The host sits
  # behind NAT on the local network, so no source filtering is applied.
  networking.firewall = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [ 53 ];
  };

  # Point your router's DHCP at this host for DNS, or run the AdGuard Home
  # integrated DHCP server instead (requires services.adguardhome.allowDHCP = true).
}
