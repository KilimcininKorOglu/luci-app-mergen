# Mergen LuCI Web Interface Guide

This guide covers the LuCI web interface for **Mergen**, an ASN/IP-based policy routing tool for OpenWrt. All pages are accessible under **Services > Mergen** in the LuCI administration panel.

---

## Table of Contents

1. [Overview Page](#1-overview-page)
2. [Rules Page](#2-rules-page)
3. [ASN Browser Page](#3-asn-browser-page)
4. [Providers Page](#4-providers-page)
5. [Interfaces Page](#5-interfaces-page)
6. [Logs Page](#6-logs-page)
7. [Advanced Settings Page](#7-advanced-settings-page)

---

## 1. Overview Page

**Navigation:** Services > Mergen > Overview

The Overview page provides a real-time dashboard of your Mergen installation. It is the default landing page when you open the Mergen interface.

### Status Cards

Five status cards are displayed across the top of the page:

| Card             | Description                                                                 |
|:-----------------|:----------------------------------------------------------------------------|
| Daemon Status    | Shows whether the Mergen daemon is **Running**, **Stopped**, or in **Error** state, indicated by a color-coded badge (green, gray, or red). |
| Total Rules      | The total number of configured rules, with a breakdown of active and disabled counts beneath. |
| Total Prefixes   | The number of IPv4 prefixes currently loaded, with an IPv4/IPv6 split shown below. |
| Last Sync        | Timestamp of the most recent prefix data synchronization, with a relative time indicator (e.g., "2 hours ago"). |
| Next Sync        | The projected time of the next automatic prefix update, calculated from the configured update interval. |

### Active Rules Table

Below the status cards, a table lists every configured rule with the following columns:

| Column    | Description                                                                             |
|:----------|:----------------------------------------------------------------------------------------|
| Rule Name | Clickable name that navigates to the Rules page for editing.                            |
| Rule Type | The rule category displayed in uppercase: ASN, IP, DOMAIN, or COUNTRY.                 |
| Target    | The ASN numbers, IP/CIDR blocks, domains, or country codes targeted by the rule. Long values are truncated to 40 characters. |
| Interface | The outbound interface for matched traffic. If a fallback interface is configured, it appears in parentheses beside the primary. |
| Priority  | The numeric priority value (lower numbers are processed first).                         |
| Traffic   | Live traffic counters showing packet count and byte volume (e.g., "1284 pkt / 3.2 MB"). Refreshes automatically every 15 seconds. |
| Status    | Color-coded badge: **active** (green), **disabled** (gray), or **failover** (red) when the primary interface is down and traffic has switched to the fallback. |

### Quick Action Buttons

Three buttons appear between the status cards and the rules table:

- **Apply All** -- Applies all current rules to the routing table immediately. Use this after making configuration changes on any page.
- **Update Prefixes** -- Triggers an on-demand prefix data refresh from all configured providers, then applies the updated routes.
- **Restart Daemon** -- Stops and restarts the Mergen init script. A confirmation prompt appears before execution.

### Daemon Status Details

A collapsible section labeled "Daemon Status (details)" contains the raw output of the `mergen status` command. Click the summary header to expand or collapse it.

### Recent Operations Log

The bottom of the page shows the 10 most recent log entries with timestamps. A "View all logs" link navigates to the full Logs page.

### Auto-Refresh

The Overview page automatically refreshes daemon status every 30 seconds and traffic statistics every 15 seconds without requiring a page reload.

---

## 2. Rules Page

**Navigation:** Services > Mergen > Rules

The Rules page is where you create, edit, reorder, and remove routing rules. It uses a UCI-bound table form, meaning changes are saved to the OpenWrt configuration system when you click **Save & Apply**.

### Summary Cards

Two cards at the top display:

- **Total Rules** -- Number of rule sections in the configuration.
- **Active Rules** -- Number of rules with the enabled flag set.

### Adding a New Rule

1. Scroll to the bottom of the rules table and click the **Add** button.
2. Fill in the fields described below.
3. Click **Save & Apply** to persist the rule.

### Rule Fields

| Field              | Description                                                                                                        |
|:-------------------|:-------------------------------------------------------------------------------------------------------------------|
| Enabled            | Toggle checkbox. Disabled rules remain in the configuration but are not applied to the routing table.              |
| Rule Name          | A unique identifier for the rule. Only letters, digits, dashes, and underscores are allowed. Maximum 32 characters. |
| Rule Type          | Select the target type. **ASN** routes traffic destined for IP prefixes announced by the specified autonomous systems. **IP/CIDR** routes traffic to explicitly listed IP ranges. |
| ASN                | Visible when Rule Type is ASN. Enter one or more ASN numbers separated by commas or spaces (e.g., `13335, 32934`). |
| IP/CIDR            | Visible when Rule Type is IP/CIDR. Enter one or more CIDR blocks separated by commas or spaces (e.g., `10.0.0.0/8, 172.16.0.0/12`). Both IPv4 and IPv6 CIDR notation are accepted. |
| Interface          | The outbound network interface through which matched traffic will be routed. The dropdown lists both physical devices and logical UCI interfaces. |
| Priority           | Numeric priority value (1--32000). Lower values are processed first. Default is 100.                               |
| Fallback Interface | Optional. If the primary interface goes down, traffic fails over to this interface automatically. Select "-- None --" to disable fallback. |
| Tags               | Optional comma-separated labels for organizational purposes (e.g., `vpn, office, streaming`).                      |

### Editing a Rule

All fields in the table are directly editable. Modify any value and click **Save & Apply** at the bottom of the page.

When you change the Rule Type dropdown, the row briefly highlights in yellow to signal that the conditional fields (ASN vs. IP/CIDR) have changed.

### Removing a Rule

Click the **Delete** button on the right side of any rule row. A confirmation dialog appears before the rule is removed.

### Drag-and-Drop Sorting

Rules can be reordered by dragging rows within the table. Grab any row and drag it above or below another row. When you drop, priorities are automatically recalculated in increments of 10 starting from 100 and saved to the backend immediately.

Visual indicators (top or bottom border highlights) show the drop position while dragging.

### Cloning a Rule

Each rule row has a **Clone** button in the actions column. Click it and enter a name for the copy. The new rule inherits all settings from the source rule (type, ASN/IP targets, interface, priority, tags) with the enabled flag preserved. The cloned rule appears after a page reload.

### Bulk Operations

To operate on multiple rules at once:

1. Use the checkboxes in the leftmost column to select rules. The "select all" checkbox in the header toggles all rows.
2. When one or more rules are selected, a bulk toolbar appears showing the count of selected rules and the following buttons:

| Button          | Action                                                      |
|:----------------|:------------------------------------------------------------|
| Enable          | Sets the enabled flag on all selected rules.                |
| Disable         | Clears the enabled flag on all selected rules.              |
| Delete          | Removes all selected rules after a confirmation prompt.     |
| Export Selected | Downloads a JSON file containing only the selected rules.   |

### JSON Export

Two export options are available:

- **Export JSON** button (top toolbar) -- Downloads all rules as a `mergen-rules.json` file.
- **Export Selected** button (bulk toolbar) -- Downloads only the checked rules.

The exported JSON format is:

```json
{
  "rules": [
    {
      "name": "example-rule",
      "type": "asn",
      "asn": "13335",
      "via": "wan",
      "priority": 100,
      "enabled": true
    }
  ]
}
```

### Apply All

The **Apply All** button at the top of the Rules page triggers an immediate application of all rules to the routing table, equivalent to running `mergen apply` from the command line.

---

## 3. ASN Browser Page

**Navigation:** Services > Mergen > ASN Browser

The ASN Browser lets you look up autonomous system information, inspect announced prefixes, compare multiple ASNs side by side, and create routing rules directly from the browser results.

### Searching for an ASN

1. Enter an ASN number in the search field (e.g., `13335` or `AS13335`). The "AS" prefix is stripped automatically.
2. Click **Search** or press Enter.
3. For numeric ASN inputs of three or more digits, the search fires automatically after 300 milliseconds of inactivity.

While the query is processing, a "Resolving..." indicator appears. If the ASN cannot be found or the provider fails, an error message is displayed below the search bar.

### ASN Detail Panel

After a successful search, four information cards appear:

| Card          | Content                                            |
|:--------------|:---------------------------------------------------|
| ASN           | The ASN number prefixed with "AS" (e.g., AS13335). |
| Provider      | The data provider that resolved the query.         |
| IPv4 Prefixes | Count of IPv4 prefixes announced by this ASN.      |
| IPv6 Prefixes | Count of IPv6 prefixes announced by this ASN.      |

### Prefix Table

Below the cards, a paginated table lists all announced prefixes with three columns: index number, prefix (in CIDR notation), and type (IPv4 or IPv6).

**Filtering:** Use the radio buttons above the table to show All, IPv4 only, or IPv6 only prefixes.

**Pagination:** The table shows 50 prefixes per page. Use the Prev/Next buttons and the page indicator to navigate. The range indicator (e.g., "1-50 / 328") shows your current position.

### Quick-Add Rule

To create a routing rule for the currently viewed ASN without leaving the browser:

1. Enter a rule name in the "Rule Name" field. A default name is suggested as `asn-<number>` (e.g., `asn-13335`).
2. Select the target interface from the dropdown.
3. Click **Add Rule**.

The rule is created immediately in the UCI configuration as an ASN-type rule with priority 100 and enabled status. A success message confirms the creation.

### Comparing ASNs

You can compare up to four ASNs side by side:

1. Search for the first ASN and click the **Compare** button to add it to the comparison set.
2. Search for another ASN and click **Compare** again.
3. Repeat for up to four ASNs total.

The comparison panel appears below the search results and displays a card for each ASN showing its provider, IPv4 count, and IPv6 count. Each card has a remove button (X) to exclude it from the comparison.

When two or more ASNs are in the comparison, Mergen automatically calculates **common prefixes** -- IP ranges announced by all compared ASNs. These are listed in a separate section below the comparison cards. If no common prefixes exist, the panel states so explicitly.

Click **Clear Comparison** to reset the comparison set.

---

## 4. Providers Page

**Navigation:** Services > Mergen > Providers

The Providers page configures the data sources that Mergen uses to resolve ASN numbers into IP prefix lists. It also manages fallback strategy and cache settings.

### Provider Table

The provider table is a UCI-bound form where each row represents a configured data provider. Available columns:

| Column       | Description                                                                                  |
|:-------------|:---------------------------------------------------------------------------------------------|
| Enabled      | Toggle checkbox to enable or disable this provider.                                          |
| Priority     | Numeric priority (lower values are tried first). Default is 10.                              |
| API URL      | The HTTPS endpoint for this provider's API. Must begin with `https://`. Leave blank for providers that use other protocols (e.g., whois). |
| Timeout      | Maximum seconds to wait for a response (1--120). Default is 30.                              |
| Rate Limit   | Maximum requests per minute. Set to 0 for unlimited.                                         |
| Whois Server | For IRR/RADB-type providers, the whois server hostname (e.g., `whois.radb.net`).             |
| DB Path      | For local database providers like MaxMind, the filesystem path to the database file.         |
| Test         | Per-provider test button (see below).                                                        |

Use the **Add** button at the bottom to create a new provider, and the **Delete** button on any row to remove one.

Providers are sortable; you can reorder them to control the fallback sequence.

Click **Save & Apply** to persist changes.

### General Provider Settings

Below the provider table, the "General Provider Settings" section contains two options:

| Setting           | Description                                                                                           |
|:------------------|:------------------------------------------------------------------------------------------------------|
| Fallback Strategy | Controls how providers are consulted when the primary fails. **Sequential**: try each provider in priority order. **Parallel**: query all providers simultaneously and use the first response. **Cache Only**: serve only from local cache, never contact providers. |
| Cache TTL         | Time-to-live for cached prefix data in seconds. Default is 86400 (24 hours). After this period, data is re-fetched from providers on the next update cycle. |

### Provider Maintenance

The bottom section of the page offers maintenance operations:

- **Test All Providers** -- Runs a validation check against all configured providers by resolving a known ASN (AS13335/Cloudflare) through each one. Results appear in a log panel below the buttons.
- **Clear All Cache** -- Deletes all cached prefix data. A confirmation dialog appears first. After clearing, prefixes will be re-fetched from providers on the next update.

### Per-Provider Test

Each row in the provider table has an individual **Test** button. Clicking it tests that specific provider by attempting an ASN resolution. The button temporarily changes to show the result:

- **OK** (green) -- The provider responded successfully and returned prefix data.
- **FAIL** (red) -- The provider did not return valid data.

The button reverts to its default state after 5 seconds.

---

## 5. Interfaces Page

**Navigation:** Services > Mergen > Interfaces

The Interfaces page shows all network interfaces available on the system along with their relevance to Mergen routing.

### Interface Status Table

| Column       | Description                                                                                |
|:-------------|:-------------------------------------------------------------------------------------------|
| Name         | Interface name. Physical devices show their system name (e.g., `eth0`, `wlan0`). Logical UCI interfaces appear with a "(logical)" suffix. |
| Status       | Color-coded badge: **up** (green), **down** (red), or **unknown** (gray) for logical interfaces whose physical state cannot be determined. |
| IP Address   | The primary IP address assigned to the interface, or a dash if none.                       |
| Mergen Rules | Count of enabled Mergen rules that route traffic through this interface.                   |
| Actions      | A **Ping** button to open the connectivity test panel for this interface.                  |

### Connectivity Test (Ping)

Clicking the **Ping** button on any interface row opens a test panel:

1. **Target** -- Enter an IP address or hostname to ping. Defaults to `8.8.8.8`.
2. **Count** -- Select 3, 5, or 10 ping packets from the dropdown.
3. Click the **Ping** button to execute the test.

The test sends ICMP packets through the selected interface (using the `-I` flag) and displays:

- The raw ping output in a log panel.
- Summary cards showing: **Transmitted** packets, **Received** packets, **Loss** percentage, and **Average Latency** in milliseconds.

This is useful for verifying that a WAN interface has connectivity before assigning rules to it.

---

## 6. Logs Page

**Navigation:** Services > Mergen > Logs

The Logs page provides a live, filterable view of Mergen system log entries sourced from the OpenWrt syslog.

### Filter Bar

The top of the page contains filter controls:

| Control      | Options / Description                                                              |
|:-------------|:-----------------------------------------------------------------------------------|
| Level        | Dropdown to filter by minimum severity: All Levels, Error, Warning, Info, Debug. Selecting a level shows that level and all more severe levels (e.g., selecting "Warning" shows Warning and Error entries). |
| Filter Text  | Free-text search field. Filters log entries by matching the text against the message body (case-insensitive). The filter applies with a 300-millisecond debounce after you stop typing. |
| Lines        | Number of log entries to display: 25, 50, 100, or 200.                             |
| Auto-refresh | Checkbox (enabled by default). When active, the log view refreshes every 5 seconds. |

### Log Display

Each log entry is displayed as a single line containing:

- **Timestamp** -- Date and time from syslog.
- **Level Badge** -- Color-coded: Error (red), Warning (yellow/amber), Info (green), Debug (gray).
- **Message** -- The log message text.

The log container auto-scrolls to the latest entry after each refresh.

### Action Buttons

| Button             | Description                                                                              |
|:-------------------|:-----------------------------------------------------------------------------------------|
| Refresh            | Manually triggers a log refresh with the current filter settings.                        |
| Download Log       | Fetches up to 500 log entries and downloads them as a `.log` text file named `mergen-logs-YYYY-MM-DD.log`. Each line contains the timestamp, level in brackets, and the message. |
| Diagnostics Bundle | Generates a comprehensive diagnostics package and downloads it as a `.txt` file. The bundle includes: Mergen status, rule list, validation output, `ip rule show`, `ip route show table 100`, `nft list sets`, and the 50 most recent Mergen log entries. |

The diagnostics bundle is particularly useful when reporting issues or seeking support.

---

## 7. Advanced Settings Page

**Navigation:** Services > Mergen > Advanced

The Advanced page provides access to all global Mergen settings organized into tabbed sections, along with maintenance operations at the bottom.

### Master Enable

At the top of the settings form, the **Enabled** checkbox controls the global on/off state of the Mergen system.

### Routing Tab

| Setting                 | Description                                                                         | Default |
|:------------------------|:------------------------------------------------------------------------------------|:--------|
| Routing Table Number    | The Linux routing table number used by Mergen (1--252).                             | 100     |
| ip rule Priority Start  | The starting priority number for `ip rule` entries created by Mergen (1--32000).    | 100     |
| Operating Mode          | **Standalone** (recommended): Mergen manages its own routing tables independently. **mwan3 Integration**: Mergen cooperates with the mwan3 multi-WAN manager. | Standalone |

### Packet Engine Tab

| Setting                | Description                                                                              | Default  |
|:-----------------------|:-----------------------------------------------------------------------------------------|:---------|
| Packet Matching Engine | **nftables** (recommended): Uses nftables sets for prefix matching. **ipset** (legacy): Uses the older ipset framework. Choose based on your OpenWrt version and installed packages. | nftables |

### IPv6 Tab

| Setting         | Description                                                                             | Default |
|:----------------|:----------------------------------------------------------------------------------------|:--------|
| Enable IPv6     | Toggle IPv6 prefix resolution and routing. When disabled, only IPv4 prefixes are processed. | Off     |
| IPv6 Table Mode | Visible only when IPv6 is enabled. **Shared table with IPv4**: IPv6 routes go into the same routing table as IPv4. **Separate IPv6 table**: IPv6 routes use a dedicated table number. | Shared  |

### Performance Tab

| Setting                       | Description                                                                    | Default |
|:------------------------------|:-------------------------------------------------------------------------------|:--------|
| Max Prefix Limit (per rule)   | Maximum number of prefixes allowed per individual rule. Prevents a single ASN with excessive announcements from consuming resources. | 10000   |
| Total Prefix Limit (all rules)| Maximum total prefixes across all rules combined.                              | 50000   |
| Update Interval (seconds)     | How often prefix data is automatically refreshed from providers.               | 86400   |
| API Timeout (seconds)         | Maximum time to wait for a provider API response (1--120).                     | 30      |
| Parallel Query Limit          | Number of concurrent provider queries during prefix resolution (1--10).        | 2       |

### Security Tab

| Setting                           | Description                                                                      | Default |
|:----------------------------------|:---------------------------------------------------------------------------------|:--------|
| Rollback Watchdog Timeout         | Seconds to wait after applying new routes before confirming them. If connectivity to the ping target is lost during this window, routes are automatically rolled back (10--600). | 60      |
| Safe Mode Ping Target             | IP address or hostname pinged by the watchdog to verify connectivity after route changes. | 8.8.8.8 |

### Logging Tab

| Setting   | Description                                                | Default |
|:----------|:-----------------------------------------------------------|:--------|
| Log Level | Minimum log severity written to syslog: Debug, Info, Warning, or Error. | Info    |

### Maintenance Section

Below the tabbed settings, the maintenance section provides the following operations:

#### Flush All Routes

Removes all Mergen-created routes and nftables/ipset sets from the system. A confirmation dialog warns that all routes will be removed. This does not delete rules from the configuration; routes can be recreated by clicking **Apply All** on the Overview or Rules page.

#### Backup Config

Downloads the current `/etc/config/mergen` UCI configuration file through the LuCI backup mechanism. Save this file to restore your configuration later.

#### Validate Config

Runs `mergen validate --check-providers` to verify the integrity of the current configuration and test connectivity to all providers. Results appear in a log panel below the buttons.

#### Factory Reset

Resets all Mergen settings to their defaults. This operation:

- Deletes all configured rules.
- Deletes all configured providers.
- Resets every global setting to its default value.
- Flushes all active routes.

Two consecutive confirmation dialogs must be accepted before the reset proceeds. The page reloads automatically after completion.

#### Restore Configuration

To restore a previously backed up configuration:

1. Click the file input and select a `.conf` or `.txt` file containing a Mergen UCI configuration.
2. The **Restore Config** button becomes active once a file is selected.
3. Click **Restore Config** and confirm the replacement.

The uploaded content is validated to ensure it contains a `config global` section. Upon success, the current configuration file is overwritten and the page reloads.

#### Version Information

Three version values are displayed at the bottom of the page:

| Item           | Description                                                     |
|:---------------|:----------------------------------------------------------------|
| Mergen CLI     | The version of the `mergen` command-line binary.                |
| LuCI App       | The installed version of the `luci-app-mergen` package.         |
| Config Version | The internal configuration schema version number.               |
