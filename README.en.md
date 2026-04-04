# Mergen

ASN/IP based policy routing daemon for OpenWrt. Automatically resolves ASN prefix lists and creates `ip rule`/`ip route` entries to steer traffic through designated network interfaces.

Mergen uses nftables sets for O(1) packet matching with automatic ipset fallback on legacy systems.

## Features

- **ASN-based routing** -- Route traffic by Autonomous System Number (e.g., route all Cloudflare traffic via WAN2)
- **IP/CIDR routing** -- Direct prefix-based policy routing rules
- **DNS-based routing** -- Route by domain name via dnsmasq nftset/ipset integration
- **Country-based routing** -- Route by country code using RIR delegated stats
- **Multi-provider resolution** -- 6 data providers with automatic fallback and health tracking
- **IPv6 dual-stack** -- Full IPv4 and IPv6 support with separate set management
- **Safe mode** -- Atomic apply with automatic rollback on connectivity loss
- **LuCI web interface** -- 7-page web UI for rule management, monitoring, and configuration
- **mwan3 integration** -- Dual mode operation alongside mwan3 load balancer
- **Import/export** -- JSON-based rule backup and restore
- **Watchdog** -- Continuous health monitoring with interface failover

## Requirements

| Requirement      | Minimum                                   |
|------------------|-------------------------------------------|
| OpenWrt version  | 23.05 or later                            |
| Firewall backend | nftables (default) or iptables with ipset |
| Disk space       | ~500 KB                                   |
| RAM              | 32 MB or more                             |

## Installation

### From IPK packages

Download the latest release and install on your router:

```sh
scp mergen_*.ipk luci-app-mergen_*.ipk root@<router>:/tmp/
ssh root@<router>
opkg install /tmp/mergen_*.ipk
opkg install /tmp/luci-app-mergen_*.ipk    # optional: web interface
```

### From source (OpenWrt buildroot)

```sh
cd /path/to/openwrt
git clone https://github.com/KilimcininKorOglu/luci-app-mergen.git package/mergen
make menuconfig    # Select Network > Routing and Redirection > mergen
make package/mergen/compile
```

## Quick Start

```sh
# Enable the service
uci set mergen.global.enabled='1'
uci commit mergen
/etc/init.d/mergen enable
/etc/init.d/mergen start

# Add a rule: route Cloudflare (AS13335) via wan2
mergen add --name cloudflare --asn 13335 --via wan2

# Apply all rules
mergen apply

# Check status
mergen status
```

## CLI Commands

```
mergen add          Add a new routing rule
mergen remove       Remove a rule by name
mergen list         List all configured rules
mergen show         Show detailed rule information
mergen enable       Enable a disabled rule
mergen disable      Disable a rule without removing
mergen apply        Resolve prefixes and apply routing
mergen flush        Remove all active routes
mergen rollback     Restore previous routing state
mergen confirm      Confirm changes after safe mode apply
mergen status       Show daemon and routing status
mergen diag         Run diagnostics
mergen log          View daemon logs
mergen validate     Validate configuration
mergen tag          Add/remove tags on rules
mergen update       Refresh prefix cache
mergen import       Import rules from JSON
mergen export       Export rules to JSON
mergen resolve      Resolve ASN/IP without applying
mergen version      Show version information
mergen help         Show help text
```

See [docs/cli-reference.md](docs/cli-reference.md) for full command documentation with flags and examples.

## Configuration

All configuration is managed through UCI at `/etc/config/mergen`:

```
config mergen 'global'
    option enabled '1'
    option log_level 'info'
    option default_table '100'
    option ipv6_enabled '1'
    option watchdog_enabled '1'
    option mode 'standalone'

config rule
    option name 'cloudflare'
    option asn '13335'
    option via 'wan2'
    option enabled '1'

config provider 'ripe'
    option enabled '1'
    option priority '10'
```

See [docs/configuration.md](docs/configuration.md) for the complete configuration reference.

## Data Providers

| Provider   | Source                     | Type      | Default  |
|------------|----------------------------|-----------|----------|
| RIPE Stat  | stat.ripe.net              | API       | Enabled  |
| bgp.tools  | bgp.tools                  | API       | Enabled  |
| bgpview.io | bgpview.io                 | API       | Disabled |
| MaxMind    | GeoLite2 ASN database      | Offline   | Disabled |
| RouteViews | MRT dump archives          | Offline   | Disabled |
| IRR/RADB   | whois.radb.net             | Whois     | Disabled |

Providers are queried in priority order with automatic fallback on failure.

## LuCI Web Interface

The optional `luci-app-mergen` package provides a web interface under **Services > Mergen** with the following pages:

- **Overview** -- Dashboard with daemon status, active rules, and traffic statistics
- **Rules** -- CRUD management with drag-drop sorting, bulk operations, and JSON export
- **ASN Browser** -- Search and compare ASN prefix lists, quick-add rules
- **Providers** -- Provider health status, test connectivity, cache management
- **Interfaces** -- Network interface status with ping diagnostics
- **Logs** -- Real-time log viewer with level and text filtering
- **Advanced** -- Engine settings, IPv6, performance tuning, security, maintenance

See [docs/luci-guide.md](docs/luci-guide.md) for the full web interface guide.

## Building IPK Packages

Build standalone IPK packages without the OpenWrt SDK:

```sh
./build.sh
```

Output:
```
dist/mergen_0.1.0-N_all.ipk
dist/luci-app-mergen_0.1.0-N_all.ipk
```

The build number `N` is derived from the git commit count.

## Documentation

| Document                                           | Description                          |
|----------------------------------------------------|--------------------------------------|
| [docs/install.md](docs/install.md)                 | Installation and upgrade guide       |
| [docs/configuration.md](docs/configuration.md)     | UCI configuration reference          |
| [docs/cli-reference.md](docs/cli-reference.md)     | CLI command reference                |
| [docs/luci-guide.md](docs/luci-guide.md)           | LuCI web interface guide             |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Diagnostics and troubleshooting      |

## Project Structure

```
mergen/                          Daemon package
  files/usr/bin/mergen           CLI tool
  files/usr/sbin/mergen-watchdog Watchdog daemon
  files/usr/lib/mergen/          Shell library modules
  files/etc/config/mergen        UCI configuration
  files/etc/init.d/mergen        procd service script
  files/etc/mergen/providers/    Data provider scripts
  tests/                         Test suites (shunit2)

luci-app-mergen/                 Web UI package
  luasrc/controller/             LuCI controller and RPC
  luasrc/model/cbi/              CBI form models
  luasrc/view/mergen/            HTM view templates
  htdocs/luci-static/mergen/     CSS and JavaScript
  po/                            Translations (en, tr)
```

## License

[MIT](LICENSE)
