# Mergen CLI Reference

[Türkçe](cli-reference.md)

Mergen is an ASN/IP-based policy routing tool for OpenWrt. It resolves ASN prefixes automatically and manages `ip rule`, `ip route`, and `nftables`/`ipset` entries to steer traffic through designated network interfaces.

All commands require root privileges.

```
mergen <command> [options]
```

---

## Table of Contents

- [add](#add)
- [remove](#remove)
- [list](#list)
- [show](#show)
- [enable](#enable)
- [disable](#disable)
- [apply](#apply)
- [flush](#flush)
- [rollback](#rollback)
- [confirm](#confirm)
- [status](#status)
- [diag](#diag)
- [log](#log)
- [validate](#validate)
- [tag](#tag)
- [update](#update)
- [import](#import)
- [export](#export)
- [resolve](#resolve)
- [version](#version)
- [help](#help)

---

## add

Create a new policy routing rule. Each rule binds a set of destinations (ASN prefixes, IP/CIDR blocks, domains, or country-level ASNs) to a target network interface.

**Syntax**

```
mergen add --name <NAME> (--asn <ASN> | --ip <CIDR> | --domain <FQDN> | --country <CC>) --via <IFACE> [--priority <N>] [--fallback <IFACE>]
```

**Options**

| Option             | Required | Description                                                                                      |
|--------------------|----------|--------------------------------------------------------------------------------------------------|
| `--name <NAME>`    | Yes      | Unique human-readable identifier for the rule.                                                   |
| `--asn <ASN>`      | No*      | Autonomous System Number. Mergen resolves all announced prefixes for this ASN automatically.      |
| `--ip <CIDR>`      | No*      | IPv4 or IPv6 address block in CIDR notation (e.g. `185.70.40.0/22`).                             |
| `--domain <FQDN>`  | No*      | Fully qualified domain name. Resolved via dnsmasq nftset/ipset integration.                      |
| `--country <CC>`   | No*      | ISO 3166-1 alpha-2 country code (e.g. `TR`, `US`). Adds all ASNs registered in that country.     |
| `--via <IFACE>`    | Yes      | Target network interface for matching traffic (e.g. `wg0`, `wan2`, `lan`).                       |
| `--priority <N>`   | No       | Routing rule priority. Lower values are evaluated first. Default: `100`. Range: `1`--`32000`.     |
| `--fallback <IFACE>` | No    | Fallback interface used when the primary `--via` interface goes down.                            |

\* Exactly one of `--asn`, `--ip`, `--domain`, or `--country` is required.

**Examples**

```bash
# Route all Cloudflare (AS13335) traffic through a WireGuard tunnel
mergen add --name cloudflare --asn 13335 --via wg0

# Route a specific subnet through a secondary WAN
mergen add --name office-vpn --ip 10.0.0.0/8 --via wan2 --priority 50

# Route a domain through VPN with DNS-based resolution
mergen add --name protonmail --domain protonmail.com --via wg0

# Route all Turkey-registered ASNs through the default WAN
mergen add --name turkey-direct --country TR --via wan

# Route with failover: use wg0, fall back to wan if the tunnel drops
mergen add --name google --asn 15169 --via wg0 --fallback wan --priority 200
```

---

## remove

Delete an existing rule by name. This removes the rule from the UCI configuration. The rule's routes remain active until the next `mergen apply` or `mergen flush`.

**Syntax**

```
mergen remove <NAME>
```

**Arguments**

| Argument | Required | Description                     |
|----------|----------|---------------------------------|
| `<NAME>` | Yes      | Name of the rule to remove.     |

**Examples**

```bash
# Remove the rule named "cloudflare"
mergen remove cloudflare

# Remove and immediately re-apply to clear stale routes
mergen remove office-vpn && mergen apply
```

---

## list

Display all configured rules in a summary table.

**Syntax**

```
mergen list
```

**Output Columns**

| Column | Description                                                    |
|--------|----------------------------------------------------------------|
| ID     | Sequential row number.                                         |
| NAME   | Rule name.                                                     |
| TYPE   | Rule type: `ASN`, `IP`, `DOMAIN`, or `COUNTRY`.               |
| TARGET | ASN number, CIDR block, domain, or country code.               |
| VIA    | Target interface.                                              |
| PRI    | Priority value.                                                |
| STATUS | Current state: `active`, `pending`, `disabled`, or `failed`.   |

**Examples**

```bash
mergen list
```

```
ID  NAME         TYPE     TARGET              VIA   PRI  STATUS
1   cloudflare   ASN      AS13335 (847 pfx)   wg0   100  active
2   protonmail   IP       185.70.40.0/22      wg0   100  pending
3   google       ASN      AS15169 (1203 pfx)  wg0   200  active
4   turkey       COUNTRY  TR (412 ASNs)       wan   300  disabled
```

---

## show

Display detailed information about a single rule, including its resolved prefix list, interface binding, and current operational state.

**Syntax**

```
mergen show <NAME>
```

**Arguments**

| Argument | Required | Description                    |
|----------|----------|--------------------------------|
| `<NAME>` | Yes      | Name of the rule to inspect.   |

**Examples**

```bash
mergen show cloudflare
```

```
Rule:       cloudflare
Type:       ASN
ASN:        13335
Via:        wg0
Fallback:   wan
Priority:   100
Status:     active
Enabled:    yes
Tags:       cdn, vpn-routed
Table:      100
Prefixes:   847 total (612 IPv4, 235 IPv6)
Last Sync:  2026-04-03 14:30:00 UTC
Provider:   ripe

IPv4 Prefixes (first 10):
  104.16.0.0/13
  104.24.0.0/14
  172.64.0.0/13
  ...
```

---

## enable

Activate a previously disabled rule or all rules matching a tag. Enabled rules are included in the next `mergen apply`.

**Syntax**

```
mergen enable <NAME>
mergen enable --tag <TAG>
```

**Options**

| Option        | Description                                           |
|---------------|-------------------------------------------------------|
| `<NAME>`      | Name of the specific rule to enable.                  |
| `--tag <TAG>` | Enable all rules that carry the specified tag.         |

**Examples**

```bash
# Enable a single rule
mergen enable cloudflare

# Enable all rules tagged "vpn-routed"
mergen enable --tag vpn-routed
```

---

## disable

Deactivate a rule or all rules matching a tag. Disabled rules are excluded from routing but remain in the configuration.

**Syntax**

```
mergen disable <NAME>
mergen disable --tag <TAG>
```

**Options**

| Option        | Description                                           |
|---------------|-------------------------------------------------------|
| `<NAME>`      | Name of the specific rule to disable.                 |
| `--tag <TAG>` | Disable all rules that carry the specified tag.        |

**Examples**

```bash
# Disable a single rule
mergen disable google

# Disable all rules tagged "streaming"
mergen disable --tag streaming
```

---

## apply

Compile all enabled rules into system routing entries (`ip rule`, `ip route`, `nftables` sets) and apply them atomically. If any rule fails to apply, the entire operation is rolled back automatically.

**Syntax**

```
mergen apply [--force] [--safe]
```

**Options**

| Option    | Description                                                                                               |
|-----------|-----------------------------------------------------------------------------------------------------------|
| `--force` | Bypass prefix count limits and apply even if thresholds are exceeded.                                     |
| `--safe`  | Enable safe mode: after applying, Mergen tests connectivity (ping). If the test fails within 60 seconds, all changes are rolled back automatically. |

**Examples**

```bash
# Standard apply
mergen apply

# Force apply, ignoring prefix count warnings
mergen apply --force

# Safe apply with automatic rollback on connectivity loss
mergen apply --safe
```

**Safe Mode Behavior**

When `--safe` is used, Mergen performs the following sequence:

1. Takes a snapshot of the current routing state.
2. Applies all pending rules.
3. Pings the configured safe mode target (default: `8.8.8.8`).
4. If the ping succeeds, the new state is committed.
5. If the ping fails or no `mergen confirm` is received within 60 seconds, Mergen rolls back to the snapshot automatically.

---

## flush

Remove all Mergen-managed routes, `ip rule` entries, and `nftables`/`ipset` sets from the running system. Rules remain in the UCI configuration and can be re-applied with `mergen apply`.

**Syntax**

```
mergen flush [--confirm]
```

**Options**

| Option      | Description                                                       |
|-------------|-------------------------------------------------------------------|
| `--confirm` | Skip the interactive confirmation prompt. Required for scripting. |

**Examples**

```bash
# Interactive flush (prompts for confirmation)
mergen flush

# Non-interactive flush for scripts
mergen flush --confirm
```

---

## rollback

Revert to the routing state snapshot that was captured before the most recent `mergen apply`. This restores all `ip rule`, `ip route`, and `nftables` set entries to their prior state.

**Syntax**

```
mergen rollback
```

**Examples**

```bash
# Undo the last apply
mergen rollback
```

---

## confirm

Confirm the currently applied routing state after a `mergen apply --safe` operation. This prevents the automatic rollback timer from reverting the changes.

**Syntax**

```
mergen confirm
```

**Examples**

```bash
# Apply in safe mode, then confirm once you verify connectivity
mergen apply --safe
# ... verify that SSH/web access still works ...
mergen confirm
```

---

## status

Display the current operational status of the Mergen system, including daemon state, rule counts, prefix totals, and synchronization timestamps.

**Syntax**

```
mergen status [--traffic]
```

**Options**

| Option      | Description                                                   |
|-------------|---------------------------------------------------------------|
| `--traffic` | Include per-rule traffic counters (bytes/packets) if available. |

**Examples**

```bash
mergen status
```

```
Mergen v1.0.0 | OpenWrt 23.05.3
Daemon:    active (pid 1234)
Rules:     3 active, 1 pending, 0 failed
Prefixes:  2463 total (1826 IPv4, 637 IPv6)
Last sync: 2026-04-03 14:30:00 UTC
Next sync: 2026-04-04 14:30:00 UTC
```

```bash
mergen status --traffic
```

```
Mergen v1.0.0 | OpenWrt 23.05.3
Daemon:    active (pid 1234)
Rules:     3 active, 1 pending, 0 failed
Prefixes:  2463 total (1826 IPv4, 637 IPv6)
Last sync: 2026-04-03 14:30:00 UTC
Next sync: 2026-04-04 14:30:00 UTC

RULE          VIA   PACKETS    BYTES
cloudflare    wg0   145832     198.4 MB
google        wg0   87210      112.7 MB
office-vpn    wan2  3201       1.8 MB
```

---

## diag

Run diagnostic checks and output debug information about the routing setup. Useful for troubleshooting rule application failures, provider connectivity, and mwan3 integration issues.

**Syntax**

```
mergen diag [--asn <ASN>] [--mwan3]
```

**Options**

| Option        | Description                                                                   |
|---------------|-------------------------------------------------------------------------------|
| `--asn <ASN>` | Run diagnostics for a specific ASN: resolve prefixes, check route entries.    |
| `--mwan3`     | Include mwan3-specific diagnostics (policy status, interface tracking state). |

When invoked without options, `mergen diag` outputs a full system diagnostic report covering routing tables, nftables sets, interface states, provider health, and lock file status.

**Examples**

```bash
# Full system diagnostics
mergen diag

# Diagnose routing for a specific ASN
mergen diag --asn 13335

# Include mwan3 integration diagnostics
mergen diag --mwan3
```

```bash
mergen diag --asn 13335
```

```
ASN Diagnostics: AS13335
  Provider:    ripe (healthy)
  Prefixes:    847 (612 IPv4, 235 IPv6)
  Cache:       fresh (age: 2h 14m)
  Route table: 100
  ip rules:    612 entries matching table 100
  nft set:     mergen_cloudflare (612 IPv4 elements)
  Ping test:   104.16.0.1 -> wg0 (ok, 12ms)
```

---

## log

Query and display Mergen log entries from syslog with optional filtering.

**Syntax**

```
mergen log [--tail <N>] [--level <LEVEL>] [--component <COMP>]
```

**Options**

| Option              | Description                                                                           |
|---------------------|---------------------------------------------------------------------------------------|
| `--tail <N>`        | Show only the last `N` log entries. Default: all available entries.                    |
| `--level <LEVEL>`   | Filter by minimum log level: `debug`, `info`, `warning`, `error`.                     |
| `--component <COMP>` | Filter by component name: `Core`, `Engine`, `Route`, `Resolver`, `Provider`, `Daemon`, `CLI`, `NFT`, `IPSET`, `SafeMode`, `Snapshot`. |

**Examples**

```bash
# Show the last 20 log entries
mergen log --tail 20

# Show only errors
mergen log --level error

# Show resolver-related warnings and errors
mergen log --level warning --component Resolver

# Show the last 50 entries from the Route component
mergen log --tail 50 --component Route
```

---

## validate

Validate the current UCI configuration without applying any changes. Checks for syntax errors, invalid ASN/IP values, missing interfaces, rule conflicts, and prefix limit violations.

**Syntax**

```
mergen validate [--check-providers]
```

**Options**

| Option              | Description                                                                 |
|---------------------|-----------------------------------------------------------------------------|
| `--check-providers` | Also test connectivity to each enabled ASN provider (requires network access). |

**Examples**

```bash
# Validate configuration only
mergen validate

# Validate configuration and test provider connectivity
mergen validate --check-providers
```

```bash
mergen validate
```

```
[+] Config syntax: OK
[+] Rule "cloudflare": ASN 13335 valid, interface wg0 exists
[+] Rule "office-vpn": CIDR 10.0.0.0/8 valid, interface wan2 exists
[!] Rule "broken": interface "wg99" not found. Available: wan, wg0, wan2, lan
[+] No rule conflicts detected
[+] Prefix limits: within bounds (estimated 2463 / 50000)

Result: 1 error(s), 0 warning(s)
```

```bash
mergen validate --check-providers
```

```
[+] Config syntax: OK
[+] Provider "ripe": reachable (latency: 142ms)
[!] Provider "bgptools": connection timeout (30s)
[+] Provider "bgpview": reachable (latency: 87ms)
[+] Provider "maxmind": disabled (skipped)

Result: 0 error(s), 1 warning(s)
```

---

## tag

Manage tags on rules. Tags allow batch operations via `mergen enable --tag` and `mergen disable --tag`.

**Syntax**

```
mergen tag add <RULE> <TAG>
mergen tag remove <RULE> <TAG>
```

**Subcommands**

| Subcommand | Description                              |
|------------|------------------------------------------|
| `add`      | Attach a tag to the specified rule.      |
| `remove`   | Detach a tag from the specified rule.    |

**Arguments**

| Argument | Required | Description                         |
|----------|----------|-------------------------------------|
| `<RULE>` | Yes      | Name of the rule to tag or untag.   |
| `<TAG>`  | Yes      | Tag label (alphanumeric and hyphens).|

**Examples**

```bash
# Tag the "cloudflare" rule with "cdn"
mergen tag add cloudflare cdn

# Tag multiple rules for batch operations
mergen tag add cloudflare vpn-routed
mergen tag add google vpn-routed

# Remove a tag
mergen tag remove google vpn-routed
```

---

## update

Refresh the cached ASN prefix lists for all enabled rules by querying the configured providers. Optionally re-apply routes with the updated prefixes.

**Syntax**

```
mergen update [--apply]
```

**Options**

| Option    | Description                                                   |
|-----------|---------------------------------------------------------------|
| `--apply` | Automatically run `mergen apply` after the prefix update completes. |

**Examples**

```bash
# Update prefix caches only
mergen update

# Update and immediately apply the new prefixes
mergen update --apply
```

---

## import

Load rules from a JSON file into the UCI configuration. Existing rules with the same name are skipped unless `--replace` is specified.

**Syntax**

```
mergen import <file.json> [--replace]
```

**Arguments**

| Argument      | Required | Description                     |
|---------------|----------|---------------------------------|
| `<file.json>` | Yes      | Path to the JSON rules file.    |

**Options**

| Option      | Description                                                                 |
|-------------|-----------------------------------------------------------------------------|
| `--replace` | Overwrite existing rules that share the same name as imported rules.         |

**JSON File Format**

```json
{
  "rules": [
    {
      "name": "cloudflare",
      "asn": 13335,
      "via": "wg0",
      "priority": 100
    },
    {
      "name": "google-services",
      "asn": [15169, 36040],
      "via": "wg0",
      "priority": 200
    },
    {
      "name": "internal",
      "ip": ["10.0.0.0/8", "172.16.0.0/12"],
      "via": "lan",
      "priority": 50
    }
  ]
}
```

**Examples**

```bash
# Import rules from a file
mergen import /etc/mergen/rules.d/office.json

# Import and overwrite existing rules with matching names
mergen import /tmp/backup-rules.json --replace
```

---

## export

Export the current rule configuration to a file in JSON or UCI format.

**Syntax**

```
mergen export [--format <FORMAT>] [--output <FILE>]
```

**Options**

| Option              | Description                                                              |
|---------------------|--------------------------------------------------------------------------|
| `--format <FORMAT>` | Output format: `json` (default) or `uci`.                               |
| `--output <FILE>`   | Write output to a file instead of stdout. Parent directory must exist.   |

**Examples**

```bash
# Export as JSON to stdout
mergen export

# Export as JSON to a file
mergen export --format json --output /tmp/mergen-rules.json

# Export in UCI format
mergen export --format uci

# Export UCI format to a file
mergen export --format uci --output /tmp/mergen-config.uci
```

---

## resolve

Query the configured ASN providers and display the prefix list for a given ASN without creating or modifying any rules. Useful for previewing what prefixes an ASN would add before committing a rule.

**Syntax**

```
mergen resolve <ASN> [--provider <NAME>]
```

**Arguments**

| Argument | Required | Description                   |
|----------|----------|-------------------------------|
| `<ASN>`  | Yes      | Autonomous System Number.     |

**Options**

| Option              | Description                                                            |
|---------------------|------------------------------------------------------------------------|
| `--provider <NAME>` | Force resolution through a specific provider instead of the priority chain. Accepted values: `ripe`, `bgptools`, `bgpview`, `maxmind`, `routeviews`, `irr`. |

**Examples**

```bash
# Resolve using the default provider priority chain
mergen resolve 13335

# Force resolution through a specific provider
mergen resolve 13335 --provider bgptools
```

```bash
mergen resolve 13335
```

```
AS13335 (Cloudflare, Inc.)
Provider: ripe
Prefixes: 847 total (612 IPv4, 235 IPv6)

IPv4 (612):
  104.16.0.0/13
  104.24.0.0/14
  172.64.0.0/13
  ...

IPv6 (235):
  2606:4700::/32
  2803:f800::/32
  ...
```

---

## version

Display the installed Mergen version, the OpenWrt release, and the active packet matching engine.

**Syntax**

```
mergen version
```

**Examples**

```bash
mergen version
```

```
Mergen v1.0.0
OpenWrt 23.05.3 (kernel 5.15.134)
Packet engine: nftables
```

---

## help

Display general help or detailed usage information for a specific command.

**Syntax**

```
mergen help [<command>]
```

**Arguments**

| Argument    | Required | Description                                              |
|-------------|----------|----------------------------------------------------------|
| `<command>` | No       | Command name to display detailed help for. Omit for general help. |

**Examples**

```bash
# Show general help with a list of all commands
mergen help

# Show detailed help for the "add" command
mergen help add

# Show detailed help for the "apply" command
mergen help apply
```

---

## Exit Codes

All Mergen commands return standard exit codes:

| Code | Meaning                                                  |
|------|----------------------------------------------------------|
| `0`  | Success.                                                 |
| `1`  | General error (invalid arguments, missing dependencies). |
| `2`  | Configuration error (invalid UCI config, missing rule).  |
| `3`  | Provider error (all providers failed, timeout).          |
| `4`  | Route application error (kernel rejected a route).       |
| `5`  | Rollback triggered (safe mode connectivity test failed). |

---

## Environment

| Path                       | Description                              |
|----------------------------|------------------------------------------|
| `/etc/config/mergen`       | UCI configuration file.                  |
| `/etc/mergen/providers/`   | ASN provider plugin scripts.             |
| `/etc/mergen/rules.d/`     | Directory for imported JSON rule files.  |
| `/tmp/mergen/cache/`       | Cached prefix lists (ephemeral).         |
| `/tmp/mergen/status.json`  | Watchdog runtime status.                 |
| `/var/lock/mergen.lock`    | Lock file for CLI/watchdog coordination. |
| `/usr/lib/mergen/`         | Core library scripts.                    |

---

## See Also

- `mergen-watchdog` -- background daemon for hotplug events, periodic updates, and safe mode monitoring
- OpenWrt UCI documentation: <https://openwrt.org/docs/guide-user/base-system/uci>
- mwan3 multi-WAN manager: <https://openwrt.org/docs/guide-user/network/wan/multiwan/mwan3>
