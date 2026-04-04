# Mergen Installation Guide

[Türkçe](install.md)

Mergen is an ASN/IP based policy routing tool for OpenWrt. It enables you to
route traffic through different WAN interfaces based on destination ASN or IP
ranges.

---

## Requirements

| Requirement      | Minimum                                   |
|------------------|-------------------------------------------|
| OpenWrt version  | 23.05 or later                            |
| Firewall backend | nftables (default) or iptables with ipset |
| Disk space       | ~500 KB                                   |
| RAM              | 32 MB or more                             |

Mergen supports both the nftables backend (default on OpenWrt 22.03+) and the
legacy iptables/ipset backend. The appropriate backend is detected automatically
at runtime.

---

## Installation via opkg

This is the recommended method for most users.

```sh
opkg update
opkg install mergen luci-app-mergen
```

The `luci-app-mergen` package is optional and provides a web interface through
LuCI. If you plan to manage Mergen exclusively via the command line, you can
omit it.

---

## Manual Installation from Source

For development builds or architectures not yet covered by the package feed,
you can compile Mergen within the OpenWrt build system.

1. Clone the repository into your OpenWrt source tree:

   ```sh
   cd /path/to/openwrt
   git clone https://github.com/KilimcininKorOglu/luci-app-mergen.git package/mergen
   ```

2. Update the feed index and select the package:

   ```sh
   make menuconfig   # Navigate to Network -> Routing and Redirection -> mergen
   ```

3. Compile the package:

   ```sh
   make package/mergen/compile V=s
   ```

4. The resulting `.ipk` file will be located under `bin/packages/`. Transfer it
   to your router and install manually:

   ```sh
   opkg install /tmp/mergen_*.ipk
   ```

---

## Post-Install Verification

After installation, confirm that Mergen is operational:

```sh
mergen version
```

Expected output includes the installed version number and build information.

```sh
mergen status
```

This displays the current routing policy state, active rules, and the firewall
backend in use. A healthy installation reports `status: running` with no errors.

---

## Dependencies

Mergen pulls in the following dependencies automatically when installed via
opkg:

| Dependency | Purpose                                                   |
|------------|-----------------------------------------------------------|
| dnsmasq    | Required for DNS-based routing (ipset/nftset integration) |
| nftables   | Default firewall backend for set-based routing rules      |
| ipset      | Alternative backend when using iptables (legacy systems)  |

If your OpenWrt installation uses the default nftables backend, no additional
configuration is needed. For iptables-based setups, ensure that `kmod-ipt-ipset`
and `ipset` are installed.

> **Note:** Mergen requires dnsmasq rather than dnsmasq-full in most cases.
> However, if you need advanced DNS features (DNSSEC, conntrack marking), install
> `dnsmasq-full` instead.

---

## Upgrading

To upgrade an existing installation:

```sh
opkg update
opkg upgrade mergen
```

Configuration migration is automatic. Your existing routing policies, ASN lists,
and interface assignments are preserved across upgrades. No manual intervention
is required.

After upgrading, verify the new version:

```sh
mergen version
mergen status
```

---

## Uninstallation

To remove Mergen and its LuCI interface:

```sh
opkg remove luci-app-mergen
opkg remove mergen
```

This removes the binaries and default configuration. Custom configuration files
under `/etc/mergen/` are preserved by opkg's conffile mechanism. To perform a
complete removal including configuration:

```sh
opkg remove mergen luci-app-mergen
rm -rf /etc/mergen/
```

After removal, restart the firewall to clean up any remaining routing rules:

```sh
/etc/init.d/firewall restart
```
