#!/bin/sh
# Mergen ASN Resolver
# Provider plugin orchestration, prefix resolution, and caching
# Implemented in T004 (Plugin Architecture), T005 (RIPE), T006 (Cache)

MERGEN_PROVIDERS_DIR="/etc/mergen/providers"
MERGEN_CACHE_DIR=""

# Initialize resolver — called once at startup or before resolve operations
mergen_resolver_init() {
	mergen_uci_get "global" "cache_dir" "/tmp/mergen/cache"
	MERGEN_CACHE_DIR="$MERGEN_UCI_RESULT"
	[ -d "$MERGEN_CACHE_DIR" ] || mkdir -p "$MERGEN_CACHE_DIR"
}
