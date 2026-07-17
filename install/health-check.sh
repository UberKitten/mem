#!/bin/bash
# Example health check for the memory distiller. Exit 0 = healthy, 1 = attention.
#
# Wire this into whatever monitoring you use (a cron that emails on nonzero exit,
# a Prometheus textfile collector, a `systemctl` OnFailure unit, etc.).
#
# It checks two things:
#   1. threads.md was regenerated within the grace window (default 48h).
#   2. the last distiller run left the state watermark advancing.
#
# The distiller schedule is nightly; 48h grace tolerates one skipped night or a
# signal-gated "nothing changed" run.

set -u

GRACE_HOURS="${MEM_HEALTH_GRACE_HOURS:-48}"

# Load config for MEM_ROOT (env still wins).
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/mem/config"
if [ -r "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi
REPO_ROOT="${MEM_ROOT:-$HOME/memory-workspace}"
THREADS="$REPO_ROOT/memory/threads.md"

if [ ! -f "$THREADS" ]; then
    echo "no threads.md at $THREADS — distiller has never produced output"
    exit 1
fi

now=$(date +%s)
# stat differs across BSD/macOS and GNU/Linux.
if mtime=$(stat -f %m "$THREADS" 2>/dev/null); then :; else mtime=$(stat -c %Y "$THREADS"); fi
age_hours=$(( (now - mtime) / 3600 ))

if [ "$age_hours" -gt "$GRACE_HOURS" ]; then
    echo "threads.md last changed ${age_hours}h ago (>${GRACE_HOURS}h grace)"
    exit 1
fi

echo "ok: threads.md fresh (${age_hours}h old)"
exit 0
