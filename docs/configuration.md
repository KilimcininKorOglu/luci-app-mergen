# Mergen Configuration Reference

Mergen uses the standard OpenWrt UCI (Unified Configuration Interface) system.
All configuration resides in a single file:

```
/etc/config/mergen
```

This document covers every configurable section and option.

---

## 1. Global Section

The global section controls daemon behavior, engine selection, safety mechanisms,
and resource limits. There is exactly one global section.

```uci
config mergen 'global'
    option enabled '1'
    option log_level 'info'
    option update_interval '86400'
    option default_table '100'
    option ipv6_enabled '1'
    option packet_engine 'auto'
    option mode 'standalone'
    option max_prefix_per_rule '10000'
    option max_prefix_total '50000'
    option watchdog_enabled '1'
    option watchdog_interval '60'
    option safe_mode_ping_target '8.8.8.8'
    option fallback_strategy 'sequential'
    option config_version '1'
```

### Option Reference

| Option                  | Type    | Default        | Description                                                                 |
|-------------------------|---------|----------------|-----------------------------------------------------------------------------|
| `enabled`               | boolean | `0`            | Master switch. Set to `1` to activate Mergen.                               |
| `log_level`             | enum    | `info`         | Logging verbosity. One of: `debug`, `info`, `warning`, `error`.             |
| `update_interval`       | integer | `86400`        | Seconds between automatic prefix list refreshes (86400 = 24 hours).         |
| `default_table`         | integer | `100`          | Base routing table number. Each rule gets a table starting from this value.  |
| `ipv6_enabled`          | boolean | `1`            | Enable IPv6 prefix resolution and routing. Set to `0` for IPv4-only.        |
| `packet_engine`         | enum    | `auto`         | Packet matching backend. One of: `auto`, `nftables`, `ipset`.               |
| `mode`                  | enum    | `standalone`   | Operating mode. `standalone` manages routes directly; `mwan3` integrates with mwan3. |
| `max_prefix_per_rule`   | integer | `10000`        | Maximum number of prefixes a single rule may contain.                       |
| `max_prefix_total`      | integer | `50000`        | Maximum total prefixes across all rules combined.                           |
| `watchdog_enabled`      | boolean | `1`            | Enable the watchdog daemon for hotplug events and periodic updates.         |
| `watchdog_interval`     | integer | `60`           | Watchdog polling interval in seconds.                                       |
| `safe_mode_ping_target` | IP      | `8.8.8.8`      | Target IP for connectivity verification after `mergen apply --safe`.        |
| `fallback_strategy`     | enum    | `sequential`   | How fallback interfaces are tried. Currently only `sequential` is supported.|
| `config_version`        | integer | `1`            | Schema version for configuration migration between Mergen releases.         |

### Notes on `packet_engine`

- **auto** -- Mergen detects available tools at runtime. Prefers nftables on OpenWrt 23.05+,
  falls back to ipset on older installations.
- **nftables** -- Forces nftables sets. Fails if `nft` is not installed.
- **ipset** -- Forces legacy ipset. Fails if `ipset` is not installed.

### Notes on `mode`

- **standalone** -- Mergen creates and manages its own `ip rule` and `ip route` entries
  in dedicated routing tables.
- **mwan3** -- Mergen generates rules compatible with mwan3 policies. Requires mwan3 to
  be installed and configured separately.

---

## 2. Rule Sections

Each `config rule` block defines a single routing policy. Rules are unnamed UCI sections
(anonymous) identified internally by their `name` option, which must be unique.

```uci
config rule
    option name 'cloudflare'
    option asn '13335'
    option via 'wg0'
    option priority '100'
    option enabled '1'
    option fallback 'wan'
    list tag 'vpn'
```

### Option Reference

| Option     | Type    | Required | Default | Description                                                         |
|------------|---------|----------|---------|---------------------------------------------------------------------|
| `name`     | string  | yes      | --      | Unique rule identifier. Alphanumeric characters, hyphens, and underscores only. |
| `via`      | string  | yes      | --      | Target output interface (e.g., `wg0`, `wan`, `eth1`).               |
| `priority` | integer | no       | `100`   | Routing priority. Range: 1--32000. Lower values are evaluated first.|
| `enabled`  | boolean | no       | `1`     | Set to `0` to disable the rule without removing it.                 |
| `fallback` | string  | no       | --      | Fallback interface. Traffic reroutes here if `via` goes down.       |
| `tag`      | list    | no       | --      | One or more labels for grouping and batch operations.               |

### Target Options (mutually exclusive)

Exactly one of the following target options must be set per rule. For multiple values,
use `list` syntax instead of `option`.

| Option    | Type          | Description                                                       |
|-----------|---------------|-------------------------------------------------------------------|
| `asn`     | integer/list  | One or more Autonomous System Numbers (e.g., `13335`).            |
| `ip`      | CIDR/list     | One or more IP/CIDR blocks (e.g., `185.70.40.0/22`).             |
| `domain`  | string/list   | One or more domain names for DNS-based routing.                   |
| `country` | string/list   | One or more ISO 3166-1 alpha-2 country codes (e.g., `TR`, `US`). |

**Single target** uses `option`, **multiple targets** use `list`:

```uci
# Single ASN
config rule
    option name 'cloudflare'
    option asn '13335'
    option via 'wg0'

# Multiple ASNs
config rule
    option name 'google'
    list asn '15169'
    list asn '36040'
    option via 'wg0'

# Multiple IP blocks
config rule
    option name 'office-network'
    list ip '10.0.0.0/8'
    list ip '172.16.0.0/12'
    option via 'lan'
```

---

## 3. Provider Sections

Provider sections configure the ASN resolution data sources. Mergen queries enabled
providers in priority order (lowest number first) and uses the first successful result.

```uci
config provider 'ripe'
    option enabled '1'
    option priority '10'
    option api_url 'https://stat.ripe.net/data/announced-prefixes/data.json'
    option timeout '30'

config provider 'bgptools'
    option enabled '1'
    option priority '20'
    option api_url 'https://bgp.tools/table.jsonl'
    option timeout '30'

config provider 'maxmind'
    option enabled '0'
    option priority '30'
    option db_path '/usr/share/mergen/GeoLite2-ASN.mmdb'
```

### Option Reference

| Option     | Type    | Required | Default | Description                                                         |
|------------|---------|----------|---------|---------------------------------------------------------------------|
| `enabled`  | boolean | no       | `0`     | Set to `1` to activate this provider.                               |
| `priority` | integer | no       | `99`    | Resolution order. Lower values are queried first.                   |
| `api_url`  | string  | no       | --      | API endpoint URL. Required for network-based providers.             |
| `timeout`  | integer | no       | `30`    | API request timeout in seconds.                                     |
| `db_path`  | string  | no       | --      | Local database file path. Used by offline providers like MaxMind.   |

### Available Providers

| Section ID   | Source               | Notes                                          |
|--------------|----------------------|------------------------------------------------|
| `ripe`       | RIPE Stat API        | Official RIR data. Subject to rate limiting.   |
| `bgptools`   | bgp.tools            | Fast, comprehensive BGP table data.            |
| `bgpview`    | bgpview.io           | Simple REST API. Subject to rate limiting.     |
| `maxmind`    | MaxMind GeoLite2     | Offline ASN database. Requires periodic download. |
| `routeviews` | RouteViews           | Full MRT/RIB dumps. Most comprehensive but heavy. |
| `irr`        | IRR / RADB           | Whois-based queries against routing registries.|

When a provider fails (timeout, HTTP error, empty response), Mergen automatically
tries the next enabled provider according to the `fallback_strategy` setting.

---

## 4. Example Configurations

### 4.1 VPN Split Routing

Route specific services through a WireGuard tunnel while keeping default traffic
on the primary WAN interface.

```uci
config mergen 'global'
    option enabled '1'
    option log_level 'info'
    option update_interval '86400'
    option default_table '100'
    option ipv6_enabled '1'
    option packet_engine 'auto'
    option mode 'standalone'
    option watchdog_enabled '1'
    option safe_mode_ping_target '8.8.8.8'
    option fallback_strategy 'sequential'
    option config_version '1'

config provider 'ripe'
    option enabled '1'
    option priority '10'
    option api_url 'https://stat.ripe.net/data/announced-prefixes/data.json'
    option timeout '30'

config rule
    option name 'cloudflare'
    option asn '13335'
    option via 'wg0'
    option priority '100'
    option enabled '1'
    option fallback 'wan'
    list tag 'vpn'

config rule
    option name 'google'
    list asn '15169'
    list asn '36040'
    option via 'wg0'
    option priority '200'
    option enabled '1'
    option fallback 'wan'
    list tag 'vpn'

config rule
    option name 'protonmail'
    option ip '185.70.40.0/22'
    option via 'wg0'
    option priority '300'
    option enabled '1'
    list tag 'vpn'
```

Equivalent CLI commands:

```sh
mergen add --name cloudflare --asn 13335 --via wg0 --fallback wan
mergen add --name google --asn 15169,36040 --via wg0 --fallback wan
mergen add --name protonmail --ip 185.70.40.0/22 --via wg0
mergen apply
```

### 4.2 Country-Based Routing

Keep domestic traffic on the primary WAN connection and route everything else
through a VPN.

```uci
config rule
    option name 'domestic-direct'
    option country 'TR'
    option via 'wan'
    option priority '100'
    option enabled '1'
    list tag 'geo'
```

Equivalent CLI command:

```sh
mergen add --name domestic-direct --country TR --via wan
mergen apply
```

Combined with a default VPN route (configured outside Mergen at the OS level),
this ensures that all resolved Turkish ASN prefixes bypass the tunnel.

### 4.3 DNS-Based Routing

Route traffic to specific domains through a designated interface using
dnsmasq nftset/ipset integration.

```uci
config rule
    option name 'streaming'
    list domain 'netflix.com'
    list domain 'hulu.com'
    list domain 'disneyplus.com'
    option via 'wg0'
    option priority '150'
    option enabled '1'
    list tag 'media'
```

Equivalent CLI command:

```sh
mergen add --name streaming --domain netflix.com,hulu.com,disneyplus.com --via wg0
mergen apply
```

DNS-based rules work by inserting nftset or ipset directives into the dnsmasq
configuration. Resolved IP addresses are dynamically added to the matching set
as DNS queries occur.

### 4.4 Multi-WAN with Failover

Split traffic across two WAN links with automatic failover when an interface
goes down.

```uci
config mergen 'global'
    option enabled '1'
    option mode 'standalone'
    option watchdog_enabled '1'
    option watchdog_interval '30'
    option fallback_strategy 'sequential'
    option config_version '1'

config rule
    option name 'work-traffic'
    option asn '8075'
    option via 'wan_fiber'
    option priority '100'
    option enabled '1'
    option fallback 'wan_lte'
    list tag 'work'

config rule
    option name 'cdn-traffic'
    list asn '13335'
    list asn '16509'
    option via 'wan_lte'
    option priority '200'
    option enabled '1'
    option fallback 'wan_fiber'
    list tag 'cdn'
```

When `wan_fiber` goes down, the watchdog detects the interface state change
via hotplug and reroutes `work-traffic` through `wan_lte`. When `wan_fiber`
recovers, traffic is moved back automatically.

---

## 5. File Locations

| Path                        | Description                                    |
|-----------------------------|------------------------------------------------|
| `/etc/config/mergen`        | UCI configuration file (permissions: 0600)     |
| `/tmp/mergen/cache/`        | Cached ASN prefix lists                        |
| `/tmp/mergen/status.json`   | Runtime status (watchdog state, rule counts)   |
| `/var/lock/mergen.lock`     | Process lock for concurrent access control     |
| `/etc/mergen/providers/`    | Provider plugin scripts                        |
| `/etc/mergen/rules.d/`      | Directory for JSON rule import files           |
| `/usr/lib/mergen/`          | Core library modules                           |
| `/usr/bin/mergen`           | CLI binary                                     |
| `/usr/sbin/mergen-watchdog` | Watchdog daemon                                |

---

## 6. Applying Changes

Editing `/etc/config/mergen` directly or through `uci` commands does not activate
routing rules. After any configuration change, run:

```sh
mergen apply
```

For safe application with automatic rollback on connectivity loss:

```sh
mergen apply --safe
```

Safe mode verifies connectivity by pinging `safe_mode_ping_target` after applying
rules. If the ping fails within 60 seconds, all changes are rolled back automatically.

To validate configuration without applying:

```sh
mergen validate
```
