#!/bin/sh
# Mergen Rule Engine
# Rule CRUD operations, conflict detection, and rule compilation
# Implemented in T007 (Rule CRUD), T028 (Conflict Detection), T029 (Tags)

# Source core.sh if not already loaded (allows test override)
if ! type mergen_log >/dev/null 2>&1; then
	. /usr/lib/mergen/core.sh
fi
