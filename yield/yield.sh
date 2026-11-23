#!/usr/bin/env bash
# evener-yield — keep session daemons yield-class on a slow-AI machine.
#
# This sprite runs a slow-AI provider: latency is acceptable, stability is
# not. The hub must always outrank session work, and builds (nice +19 per
# AGENTS.md) must yield to everything. The hub spawns its daemons with no
# nice knob we can set, so this loop periodically renices every live session
# daemon (from the run dir) to +NICE — covering hub-spawned, gate-spawned,
# and resumed daemons alike. renice is idempotent; only the first change of
# each daemon is logged.
set -u

PATH="$HOME/.local/bin:$PATH"
STATE_DIR="${EVENER_YIELD_STATE:-$HOME/.local/state/evener-yield}"
LOG="$STATE_DIR/yield.log"
RUN_DIR="${EVENER_YIELD_RUN_DIR:-$HOME/.local/state/evener/run}"
NICE="${EVENER_YIELD_NICE:-10}"
INTERVAL="${EVENER_YIELD_INTERVAL:-120}"

mkdir -p "$STATE_DIR"
touch "$LOG"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }

log "yield loop starting (renice session daemons to +$NICE every ${INTERVAL}s)"

while true; do
  for j in "$RUN_DIR"/*.json; do
    [ -f "$j" ] || continue
    pid=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$j" | head -1)
    [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] || continue
    out=$(renice -n "$NICE" -p "$pid" 2>/dev/null) || continue
    # renice reports "old priority 0, new priority 10" only on a real change.
    if printf '%s' "$out" | grep -q "old priority 0"; then
      log "reniced daemon pid $pid to +$NICE"
    fi
  done
  sleep "$INTERVAL"
done
