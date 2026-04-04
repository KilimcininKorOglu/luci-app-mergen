# Mergen Troubleshooting Guide

[Türkçe](troubleshooting.md)

This document covers common issues encountered when running Mergen on OpenWrt,
along with diagnostic commands and resolution steps.

---

## Table of Contents

1. [Rules Not Working](#1-rules-not-working)
2. [High Memory Usage](#2-high-memory-usage)
3. [Failover Issues](#3-failover-issues)
4. [Provider Errors](#4-provider-errors)
5. [mwan3 Conflicts](#5-mwan3-conflicts)
6. [Safe Mode and Rollback](#6-safe-mode-and-rollback)
7. [LuCI Not Showing](#7-luci-not-showing)
8. [Log Analysis](#8-log-analysis)

---

## 1. Rules Not Working

If traffic is not being routed through the expected interface after running
`mergen apply`, work through the following checks in order.

### 1.1 Verify Mergen Status

Confirm that the Mergen daemon is running and that rules are in the `active`
state:

```sh
mergen status
```

Expected output includes `Daemon: active` and your rules listed as `active`
rather than `pending` or `failed`. If the daemon is not running, start it:

```sh
/etc/init.d/mergen start
```

If the daemon fails to start, check the init script output:

```sh
/etc/init.d/mergen start; echo "Exit code: $?"
```

### 1.2 Verify the Target Interface

The interface specified in the `--via` option must be up and have a valid
gateway. Check its link state:

```sh
ip link show <interface>
```

The output must show `state UP`. If the interface is down, bring it up through
the standard OpenWrt mechanism:

```sh
ifup <interface>
```

Confirm that the interface has an assigned IP address and default gateway:

```sh
ifstatus <interface>
```

### 1.3 Check the Routing Table

Mergen creates dedicated routing tables for policy-based routing. The default
starting table number is 100 (configurable via the `default_table` UCI option).
Inspect the contents of the relevant table:

```sh
ip route show table 100
```

If the table is empty or missing expected routes, re-apply the rules:

```sh
mergen apply
```

To see all ip rules that Mergen has installed:

```sh
ip rule show | grep mergen
```

For IPv6 routing tables:

```sh
ip -6 route show table 100
ip -6 rule show | grep mergen
```

### 1.4 Inspect nftables / ipset Sets

Mergen uses nftables sets (or ipset on legacy systems) for efficient prefix
matching. Verify that sets are populated:

**nftables (default):**

```sh
nft list table inet mergen
```

This should display sets named after your rules (e.g., `mergen_cloudflare`) with
the expected number of elements. To inspect a specific set:

```sh
nft list set inet mergen mergen_cloudflare
```

**ipset (legacy systems):**

```sh
ipset list | grep mergen
ipset list mergen_cloudflare
```

If the sets exist but are empty, the ASN resolver may have failed. Check
provider status:

```sh
mergen diag
```

### 1.5 Verify DNS Resolution for Domain Rules

If you have domain-based rules, Mergen relies on dnsmasq integration
(ipset/nftset). Confirm that dnsmasq is configured correctly:

```sh
cat /tmp/dnsmasq.d/mergen.conf
```

Verify that dnsmasq is running with the Mergen configuration loaded:

```sh
pgrep dnsmasq
```

Test DNS resolution for a domain in your rule set:

```sh
nslookup example.com 127.0.0.1
```

If dnsmasq is not picking up the Mergen configuration, restart it:

```sh
/etc/init.d/dnsmasq restart
```

---

## 2. High Memory Usage

Mergen stores prefix lists in nftables sets (or ipsets) in kernel memory.
Country-based rules and large ASNs can generate tens of thousands of prefixes.

### 2.1 Check Current Prefix Counts

```sh
mergen status
```

The output reports total prefix counts for both IPv4 and IPv6. Review per-rule
prefix counts:

```sh
mergen list
```

Rules with very high prefix counts (e.g., country-based rules for large
countries) are the most common cause of memory pressure.

### 2.2 Reduce Prefix Limits

Mergen enforces two limits to prevent resource exhaustion:

| UCI Option             | Description                         | Default |
|------------------------|-------------------------------------|---------|
| `prefix_limit`         | Maximum prefixes per individual rule | 10000   |
| `total_prefix_limit`   | Maximum prefixes across all rules   | 50000   |

To lower these limits:

```sh
uci set mergen.global.prefix_limit='5000'
uci set mergen.global.total_prefix_limit='25000'
uci commit mergen
mergen apply
```

### 2.3 Minimize Country-Based Rules

A single `--country` rule can resolve into thousands of ASNs, each with hundreds
of prefixes. Strategies to reduce memory consumption:

- Replace broad country rules with targeted ASN rules for the specific services
  you need.
- Reduce the number of active country rules.
- Consider disabling IPv6 if dual-stack routing is not required:

```sh
uci set mergen.global.ipv6_enabled='0'
uci commit mergen
mergen apply
```

### 2.4 Monitor System Memory

```sh
free -m
cat /proc/meminfo | grep -E 'MemTotal|MemFree|MemAvailable'
```

If available memory drops below 10 MB on a 32 MB device, reduce your rule set
or increase prefix limits only if the hardware can support it.

---

## 3. Failover Issues

Mergen supports automatic failover: when the primary interface goes down,
traffic is rerouted through a configured fallback interface.

### 3.1 Verify Fallback Configuration

Ensure that the rule has a fallback interface defined:

```sh
mergen show <rule_name>
```

The output should include a `fallback` field. If missing, add it:

```sh
mergen add --asn 13335 --via wg0 --fallback wan --name cloudflare
```

### 3.2 Confirm the Fallback Interface Is Up

```sh
ip link show <fallback_interface>
ifstatus <fallback_interface>
```

The fallback interface must be up and have a valid gateway before failover can
succeed.

### 3.3 Check the Watchdog

The watchdog daemon handles interface health monitoring and triggers failover.
Verify it is running:

```sh
ps | grep mergen-watchdog
```

If it is not running, check that the watchdog is enabled in the configuration:

```sh
uci get mergen.global.watchdog_enabled
```

Start the watchdog if needed:

```sh
/etc/init.d/mergen start
```

### 3.4 Inspect the Failover State Directory

Mergen tracks failover state in `/tmp/mergen/failover/`. Each interface has a
state file:

```sh
ls -la /tmp/mergen/failover/
cat /tmp/mergen/failover/<interface>
```

If the state file is stale or corrupted, clearing it and restarting the watchdog
may resolve the issue:

```sh
rm -rf /tmp/mergen/failover/
/etc/init.d/mergen restart
```

### 3.5 Test Interface Reachability

Simulate a failover scenario by verifying that the watchdog's ping target is
reachable through each interface:

```sh
ping -I <primary_interface> -c 3 8.8.8.8
ping -I <fallback_interface> -c 3 8.8.8.8
```

---

## 4. Provider Errors

Mergen uses pluggable ASN data providers (RIPE RIS, bgp.tools, bgpview.io,
MaxMind, RouteViews, IRR/RADB). If prefix resolution fails, follow these steps.

### 4.1 Validate Providers

Run the built-in provider validation:

```sh
mergen validate --check-providers
```

This tests connectivity and response format for each enabled provider.

### 4.2 Check Internet Connectivity

Providers require outbound HTTPS access. Verify basic connectivity:

```sh
ping -c 3 8.8.8.8
wget -q -O /dev/null https://stat.ripe.net/ && echo "RIPE reachable" || echo "RIPE unreachable"
```

If DNS resolution is failing:

```sh
nslookup stat.ripe.net
nslookup bgp.tools
```

### 4.3 Run Provider Diagnostics

```sh
mergen diag
```

This displays the health status, response time, and success rate for each
configured provider. Look for providers reporting timeouts or HTTP errors.

### 4.4 Test a Specific ASN Resolution

```sh
mergen resolve 13335
```

If the primary provider fails, Mergen automatically falls back to the next
provider in priority order. The output indicates which provider was used. If all
providers fail, check:

- Firewall rules that may be blocking outbound HTTPS (port 443).
- Proxy settings if the router is behind a proxy.
- Provider-specific rate limits (RIPE and bgpview.io enforce limits).

### 4.5 Adjust Provider Priority

If a provider is consistently slow or unreliable, lower its priority or disable
it:

```sh
uci set mergen.ripe.priority='99'
uci set mergen.bgptools.priority='10'
uci commit mergen
```

### 4.6 Clear the Provider Cache

Stale cache entries can cause unexpected behavior:

```sh
rm -rf /tmp/mergen/cache/*
mergen update
```

---

## 5. mwan3 Conflicts

Mergen can operate in standalone mode or integrate with mwan3 for multi-WAN
load balancing. Conflicts arise when both tools manage overlapping routing
tables or ip rules.

### 5.1 Diagnose mwan3 Conflicts

Run the mwan3-specific diagnostic:

```sh
mergen diag --mwan3
```

This checks for overlapping routing table numbers, conflicting ip rules, and
policy collisions between Mergen and mwan3.

### 5.2 Adjust the Default Routing Table

If Mergen and mwan3 use the same routing table numbers, change the Mergen
default:

```sh
# Check current Mergen table
uci get mergen.global.default_table

# Check mwan3 tables
ip rule show | grep mwan

# Set Mergen to a non-overlapping range
uci set mergen.global.default_table='200'
uci commit mergen
mergen flush
mergen apply
```

### 5.3 Switch to mwan3 Mode

If you want Mergen to inject its rules into mwan3 policies instead of managing
routes independently, consider switching to mwan3 integration mode. This avoids
table conflicts entirely by delegating route management to mwan3:

```sh
uci set mergen.global.mode='mwan3'
uci commit mergen
mergen apply
```

### 5.4 Inspect Overlapping Rules

List all ip rules from both tools to identify conflicts:

```sh
ip rule show
```

Look for duplicate table references or rules at the same priority level. Mergen
rules are identifiable by their comment tag.

---

## 6. Safe Mode and Rollback

Mergen includes a safe mode mechanism that prevents lockout after applying
incorrect rules. When `mergen apply --safe` is used, the system waits for
explicit confirmation before making changes permanent.

### 6.1 Confirming Changes

After `mergen apply --safe`, you have a limited window (default: 60 seconds) to
confirm:

```sh
mergen confirm
```

If you do not run `mergen confirm` within the timeout period, the watchdog
automatically reverts all changes to the previous state.

### 6.2 Manual Rollback

If rules were applied without safe mode but are causing problems, manually
revert to the previous state:

```sh
mergen rollback
```

This restores the routing tables, nftables sets, and ip rules to the state
before the last `mergen apply`.

### 6.3 Watchdog Auto-Rollback

The watchdog monitors connectivity after an apply operation. If the configured
ping target becomes unreachable, it triggers an automatic rollback. Check the
ping target configuration:

```sh
uci get mergen.global.safe_mode_ping_target
```

The default target is `8.8.8.8`. Change it if your network does not have
unrestricted access to this address:

```sh
uci set mergen.global.safe_mode_ping_target='1.1.1.1'
uci commit mergen
```

### 6.4 Adjusting the Confirmation Timeout

To change the watchdog timeout (in seconds):

```sh
uci set mergen.global.watchdog_interval='120'
uci commit mergen
```

### 6.5 Emergency Recovery

If SSH access is lost after applying rules, reboot the router. Mergen does not
persist uncommitted (unconfirmed) changes across reboots, so the previous
working state is restored automatically.

If the router is unreachable via SSH:

1. Wait for the watchdog timeout to expire (default: 60 seconds).
2. If auto-rollback does not restore access, perform a physical reboot.
3. After reboot, verify the state: `mergen status`

---

## 7. LuCI Not Showing

If the Mergen tab does not appear in the LuCI web interface after installation,
follow these steps.

### 7.1 Verify the Package Is Installed

```sh
opkg list-installed | grep luci-app-mergen
```

If the package is not listed, install it:

```sh
opkg update
opkg install luci-app-mergen
```

### 7.2 Clear Browser Cache

LuCI caches JavaScript and CSS aggressively. Clear your browser cache or
perform a hard refresh (Ctrl+Shift+R / Cmd+Shift+R).

### 7.3 Restart the Web Server

```sh
/etc/init.d/uhttpd restart
```

After restarting, reload the LuCI interface in your browser.

### 7.4 Check for LuCI Errors

If the tab appears but the page fails to load, check for Lua errors:

```sh
logread | grep -i luci
logread | grep -i mergen
```

### 7.5 Verify File Permissions

Ensure that the LuCI controller and view files have correct permissions:

```sh
ls -la /usr/lib/lua/luci/controller/mergen.lua
ls -la /usr/lib/lua/luci/model/cbi/mergen*.lua
ls -la /usr/lib/lua/luci/view/mergen/
```

All files should be readable (at minimum mode 0644).

---

## 8. Log Analysis

Mergen writes structured logs that include a severity level and component name.
Effective log analysis is the fastest path to diagnosing most issues.

### 8.1 View Recent Logs

Display the last 50 error-level log entries:

```sh
mergen log --tail 50 --level error
```

Available log levels, from most to least severe: `error`, `warning`, `info`,
`debug`.

To view all log levels:

```sh
mergen log --tail 100 --level debug
```

### 8.2 Filter by Component

Mergen logs are tagged by component (resolver, engine, route, provider, daemon).
To filter:

```sh
mergen log --tail 50 --level info | grep resolver
mergen log --tail 50 --level info | grep provider
```

### 8.3 Check the System Log

Mergen also writes to the OpenWrt system log via syslog:

```sh
logread | grep mergen
```

For real-time monitoring:

```sh
logread -f | grep mergen
```

### 8.4 Common Log Messages and Their Meaning

| Log Message                                 | Meaning                                          | Action                                      |
|---------------------------------------------|--------------------------------------------------|---------------------------------------------|
| `provider timeout`                          | ASN provider did not respond within the deadline  | Check internet connectivity; try next provider |
| `prefix limit exceeded`                     | A rule resolved to more prefixes than allowed     | Increase `prefix_limit` or reduce the rule scope |
| `interface down, failover triggered`        | Primary interface lost connectivity               | Check interface status and cables            |
| `rollback: connectivity check failed`       | Safe mode ping failed after apply                 | Review applied rules for correctness         |
| `lock acquisition failed`                   | Another Mergen process is holding the lock        | Wait and retry, or check for stale locks     |
| `nft set creation failed`                   | nftables reported an error creating a set         | Check nftables version compatibility         |

### 8.5 Generate a Diagnostic Bundle

For reporting issues, generate a full diagnostic bundle that includes logs,
configuration, and system state:

```sh
mergen diag > /tmp/mergen-diag.txt
```

This output includes:

- Mergen version and configuration
- Provider health status
- Active rules and prefix counts
- Routing table contents
- nftables/ipset set summaries
- Recent log entries
- System memory and OpenWrt version

Attach this file when reporting issues upstream.

### 8.6 Check for Stale Lock Files

If Mergen commands hang or report lock errors, a previous process may have
terminated without releasing the lock:

```sh
ls -la /var/lock/mergen.lock
```

If the lock file exists but the owning process is no longer running:

```sh
rm /var/lock/mergen.lock
```

Then retry your command.

---

## Quick Reference: Diagnostic Commands

| Purpose                        | Command                                     |
|--------------------------------|---------------------------------------------|
| Overall status                 | `mergen status`                             |
| List all rules                 | `mergen list`                               |
| Show rule detail               | `mergen show <name>`                        |
| Provider health                | `mergen diag`                               |
| Validate configuration         | `mergen validate`                           |
| Validate providers             | `mergen validate --check-providers`         |
| Check mwan3 conflicts          | `mergen diag --mwan3`                       |
| View error logs                | `mergen log --tail 50 --level error`        |
| System log                     | `logread \| grep mergen`                    |
| Routing table                  | `ip route show table 100`                   |
| IPv6 routing table             | `ip -6 route show table 100`               |
| IP rules                       | `ip rule show`                              |
| nftables sets                  | `nft list table inet mergen`                |
| Interface status               | `ip link show <iface>`                      |
| Failover state                 | `ls -la /tmp/mergen/failover/`              |
| Confirm safe mode              | `mergen confirm`                            |
| Rollback last apply            | `mergen rollback`                           |
| Flush all Mergen routes        | `mergen flush`                              |
| Clear provider cache           | `rm -rf /tmp/mergen/cache/*`                |
| Restart Mergen                 | `/etc/init.d/mergen restart`                |
| Restart LuCI web server        | `/etc/init.d/uhttpd restart`                |
