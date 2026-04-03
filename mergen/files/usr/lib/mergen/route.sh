#!/bin/sh
# Mergen Route Manager
# Policy routing (ip rule/route), nftables/ipset set management, snapshots
# Implemented in T008 (Policy Routing), T014 (Rollback), T017 (nftables)

# Source core.sh if not already loaded (allows test override)
if ! type mergen_log >/dev/null 2>&1; then
	. /usr/lib/mergen/core.sh
fi
