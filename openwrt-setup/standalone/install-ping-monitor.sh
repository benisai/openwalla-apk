#!/bin/sh

# Compatibility wrapper for routers or setup commands using the former name.

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
exec "$SCRIPT_DIR/install-network-monitor.sh" "$@"
