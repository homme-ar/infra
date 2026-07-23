# AdGuard Home DNS server.
#
# First boot: complete the setup wizard at http://<host>:3000 to create the
# admin credentials. The declarative `settings` below are merged into
# /var/lib/AdGuardHome/AdGuardHome.yaml on every service start and take
# precedence over changes made in the web UI for the same keys; everything
# else (users, stats, query log, extra rewrites) remains manageable from the UI.
{ ... }:

{
  services.adguardhome = {
    enable = true;
    # Open the web UI / setup wizard port (3000/TCP). Does not cover DNS.
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

  # DNS resolver ports (openFirewall only covers the web UI).
  networking.firewall = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [ 53 ];
  };

  # Point your router's DHCP at this host for DNS, or run the AdGuard Home
  # integrated DHCP server instead (requires services.adguardhome.allowDHCP = true).
}
