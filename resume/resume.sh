#!/usr/bin/env bash
# evener-resume — boot-time auto-resume of recently-active evener sessions.
#
# A hard stop kills every session daemon mid-turn; the hub then shows each
# thread as failed/restart-required until a human clicks it. This service
# (restarted on boot) watches for fresh boots and headlessly resumes the
# sessions that were live shortly before the crash, so work continues without
# anyone clicking. Resumed daemons continue interrupted turns server-side.
#
# Crash-loop safety — the crash may have been CAUSED by what we resume:
#   * fresh-boot guard: a pass runs only when machine uptime <= UPTIME_GUARD
#     and the boot epoch has not been served yet (a service restart must not
#     re-resume the same boot)
#   * fuse: 3+ distinct boots within 2h suspend auto-resume loudly for
#     manual investigation instead of feeding a crash loop (checked inside
#     every pass, including --force/--dry-run)
#   * recency: only sessions with transcript activity within RECENCY
#   * finished sessions (last turn ended end_turn=true) are never resumed:
#     they have nothing to continue, and their resume-time SessionStart
#     marker would hold the machine for an idle session
#   * stagger + cap: one resume every STAGGER seconds, at most MAX_RESUME
#   * lock check: never spawn a second daemon for a session already served
#   * fresh daemons read the current AGENTS.md, so a resumed turn re-runs an
#     interrupted build under the machine's yield convention
#   * self-hold: takes task TASK for the pass, so a platform-initiated boot
#     with no inbound activity cannot fall back asleep mid-pass
#
# Machine-specific values come from the optional shared config file
# (~/.config/evener-sprite/config, overridable via EVENER_SPRITE_CONFIG);
# per-tool EVENER_* env vars override the config file, and neutral built-in
# defaults sit under both. See config.example. RESUME_BUCKET has no default:
# unset means the auto-resume pass disables itself loudly.
#
# Modes: (none) resident loop | --force (one pass now, for testing) |
#        --dry-run (list what a pass would resume now)
set -u

CONFIG_FILE="${EVENER_SPRITE_CONFIG:-$HOME/.config/evener-sprite/config}"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

PATH="$HOME/.local/bin:$PATH"
STATE_DIR="${EVENER_RESUME_STATE:-$HOME/.local/state/evener-resume}"
RUN_DIR="${EVENER_RESUME_RUN_DIR:-$HOME/.local/state/evener/run}"
PROJECTS_DIR="${EVENER_RESUME_PROJECTS:-$HOME/.local/state/evener/projects}"
LOG="$STATE_DIR/resume.log"
FUSE_FILE="$STATE_DIR/fuse.json"
SOCKET="${EVENER_RESUME_SOCKET:-/.sprite/api.sock}"
TASK="${EVENER_RESUME_TASK:-evener-resume}"
# Only sessions in this project bucket are resumed: the serve command needs
# the session's original working directory, and the bucket names it. Sessions
# from other buckets are logged for manual resume.
RESUME_BUCKET="${EVENER_RESUME_BUCKET:-${RESUME_BUCKET:-}}"
UPTIME_GUARD="${EVENER_RESUME_UPTIME_GUARD:-600}"
RECENCY="${EVENER_RESUME_RECENCY:-2700}"    # 45 min
MAX_RESUME="${EVENER_RESUME_MAX:-4}"
STAGGER="${EVENER_RESUME_STAGGER:-45}"
SETTLE="${EVENER_RESUME_SETTLE:-30}"         # let the hub finish its boot scan
MODEL_DEFAULT="${EVENER_RESUME_MODEL:-${DEFAULT_MODEL:-}}"
PROVIDER_DEFAULT=""
case "$MODEL_DEFAULT" in
  */*) PROVIDER_DEFAULT="${MODEL_DEFAULT%%/*}" ;;
esac
NICE="${EVENER_RESUME_NICE:-${NICE:-10}}"
EVENER_BIN="${EVENER_RESUME_BIN:-${EVENER_BIN:-evener}}"
PROVIDER_ENV="${EVENER_RESUME_PROVIDER_ENV:-${PROVIDER_ENV:-}}"
WORKDIR="${EVENER_RESUME_WORKDIR:-${WORKDIR:-$HOME/projects}}"
KEEPAWAKE_STATE="${EVENER_RESUME_KEEPAWAKE_STATE:-$HOME/.local/state/evener-keepawake}"
MODE="${1:-}"

mkdir -p "$STATE_DIR"
touch "$LOG"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }

task_put() {
  curl -s --max-time 10 --unix-socket "$SOCKET" -H 'Content-Type: application/json' \
    -X PUT "http://sprite/v1/tasks/$TASK" -d '{"expire":"5m"}' >/dev/null
}
task_del() {
  curl -s --max-time 10 --unix-socket "$SOCKET" -X DELETE "http://sprite/v1/tasks/$TASK" >/dev/null
}

boot_epoch() { echo $(( $(date +%s) - $(cut -d. -f1 /proc/uptime) )); }

# Fuse: records this boot once (idempotent — service restarts within the
# same boot must not double-count it) and returns 1 when tripped.
fuse_ok() {
  local now b b_epoch n=0 keep=() seen=0
  now=$(date +%s)
  b_epoch=$(boot_epoch)
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    (( now - b < 7200 )) || continue
    keep+=("$b")
    if [ "$b" = "$b_epoch" ]; then seen=1; else n=$((n + 1)); fi
  done < <(jq -r '.recent_boots[]?' "$FUSE_FILE" 2>/dev/null)
  if (( seen == 0 )); then
    keep+=("$b_epoch")
    n=$((n + 1))
  fi
  printf '{"recent_boots":[%s]}\n' "$(IFS=,; echo "${keep[*]}")" >"$FUSE_FILE"
  if (( n >= 3 )); then
    log "FUSE TRIPPED: $n boots in the last 2h — auto-resume suspended; investigate the crash cause manually"
    return 1
  fi
  return 0
}

# One resume pass. Assumes the boot guard already passed (resident loop);
# the fuse and the bucket check guard every pass, whatever invoked it.
resume_pass() {
  if [ -z "$RESUME_BUCKET" ]; then
    log "RESUME_BUCKET not configured; auto-resume pass disabled"
    return 0
  fi
  if ! fuse_ok; then
    return 0
  fi
  # shellcheck source=/dev/null
  if [ -n "$PROVIDER_ENV" ]; then
    . "$PROVIDER_ENV" 2>/dev/null || log "warn: could not source $PROVIDER_ENV"
  else
    log "warn: provider env not configured"
  fi

  local now sid last model row resumed=0
  now=$(date +%s)
  # Candidates: root sessions in the main bucket with recent activity whose
  # last turn did not end cleanly (end_turn=true means nothing to continue),
  # most recent first.
  mapfile -t cands < <(evener doctor sessions --json --since 6h 2>>"$LOG" | jq -r \
    --arg bucket "$RESUME_BUCKET" --argjson now "$now" --argjson rec "$RECENCY" '
    .sessions[]
    | select(.is_subagent | not)
    | select(.bucket == $bucket)
    | select(.outcome != "end_turn=true")
    | select(((.last_activity | sub("\\.[0-9]+";"")) | fromdateiso8601) >= ($now - $rec))
    | [(.session_id), (.last_activity[0:19]), (.models[-1] // "")] | @tsv' \
    | sort -r -k2,2)

  # Sessions in other recent buckets: log for manual resume, do not spawn.
  evener doctor sessions --json --since 6h 2>>"$LOG" | jq -r \
    --arg bucket "$RESUME_BUCKET" --argjson now "$now" --argjson rec "$RECENCY" '
    .sessions[]
    | select(.is_subagent | not)
    | select(.bucket != $bucket)
    | select(((.last_activity | sub("\\.[0-9]+";"")) | fromdateiso8601) >= ($now - $rec))
    | .session_id' 2>/dev/null | while read -r sid; do
    log "note: recent session $sid is in another bucket; left for manual resume"
  done

  for row in "${cands[@]}"; do
    IFS=$'\t' read -r sid last model <<<"$row"
    [ -n "$sid" ] || continue
    if daemon_live "$sid"; then
      log "skip $sid ($last): daemon already live"
      continue
    fi
    # serve demands provider/model; session records may carry bare names.
    # The provider prefix comes from DEFAULT_MODEL (the part before its first
    # "/"); a bare model with no derivable provider is skipped, never guessed.
    if [ -z "$model" ]; then
      if [ -n "$MODEL_DEFAULT" ]; then
        model="$MODEL_DEFAULT"
      else
        log "skip $sid: no model recorded and no DEFAULT_MODEL configured"
        continue
      fi
    elif [[ "$model" != */* ]]; then
      if [ -n "$PROVIDER_DEFAULT" ]; then
        model="$PROVIDER_DEFAULT/$model"
      else
        log "skip $sid: bare model with no provider configured"
        continue
      fi
    fi
    if [ "$MODE" = "--dry-run" ]; then
      log "dry-run: would resume $sid (last $last, model $model)"
      continue
    fi
    if (( resumed >= MAX_RESUME )); then
      log "cap reached: $sid (last $last) left for manual resume"
      continue
    fi
    task_put
    setsid nice -n "$NICE" "$EVENER_BIN" serve --addr 127.0.0.1:0 \
      --resume "$sid" \
      --dir "$WORKDIR" \
      --state-dir "$PROJECTS_DIR/$RESUME_BUCKET" \
      --run-dir "$RUN_DIR" \
      --plugin-root "$HOME/.config/evener/plugins" \
      --agents-doc "$HOME/.config/evener/AGENTS.md" \
      --model "$model" \
      --api-log off \
      --daemon-idle-timeout 1h0m0s \
      </dev/null >>"$STATE_DIR/serve-$sid.log" 2>&1 &
    log "resumed $sid (last $last, model $model)"
    resumed=$((resumed + 1))
    if (( resumed < MAX_RESUME )); then
      sleep "$STAGGER"
    fi
  done

  log "pass complete: resumed=$resumed candidates=${#cands[@]}"
}

daemon_live() {
  local sid=$1 j jpid jsid
  for j in "$RUN_DIR"/*.json; do
    [ -f "$j" ] || continue
    jpid=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$j" | head -1)
    jsid=$(sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p' "$j" | head -1)
    if [ "$jsid" = "$sid" ] && [ -d "/proc/$jpid" ]; then
      return 0
    fi
  done
  return 1
}

# Boot-time GC: locks and daemon info files whose pid is dead. Killed
# daemons leave them behind on every hard stop.
gc_run_dir() {
  local f pid removed=0
  for f in "$RUN_DIR"/*.lock; do
    [ -f "$f" ] || continue
    pid="${f##*/}"; pid="${pid%.lock}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    if [ ! -d "/proc/$pid" ]; then rm -f "$f"; removed=$((removed + 1)); fi
  done
  for f in "$RUN_DIR"/*.json; do
    [ -f "$f" ] || continue
    pid=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$f" | head -1)
    [ -n "$pid" ] || continue
    if [ ! -d "/proc/$pid" ]; then rm -f "$f"; removed=$((removed + 1)); fi
  done
  log "run-dir GC: removed $removed stale lock/info files"
}

# Marker GC: killed sessions never fire SessionEnd, so their keepawake
# markers would hold the machine long after a crash. Any marker whose
# session has no live daemon is stale by definition.
marker_gc() {
  local m sid removed=0
  for m in "$KEEPAWAKE_STATE"/*; do
    [ -f "$m" ] || continue
    case "${m##*/}" in *.log) continue ;; esac
    sid="${m##*/}"
    if ! daemon_live "$sid"; then rm -f "$m"; removed=$((removed + 1)); fi
  done
  (( removed > 0 )) && log "marker GC: removed $removed markers of sessions with no live daemon"
}

case "$MODE" in
  --dry-run|--force)
    resume_pass
    if [ "$MODE" = "--force" ]; then
      gc_run_dir
      marker_gc
      task_del
    fi
    ;;
  *)
    LAST_BOOT=""
    log "resident loop starting (guards: uptime<=${UPTIME_GUARD}s, recency=${RECENCY}s, cap=$MAX_RESUME, stagger=${STAGGER}s)"
    while true; do
      up=$(cut -d. -f1 /proc/uptime)
      boot=$(boot_epoch)
      if (( up <= UPTIME_GUARD )) && [ "$boot" != "$LAST_BOOT" ]; then
        LAST_BOOT="$boot"
        log "fresh boot detected (uptime ${up}s, boot epoch $boot): starting resume pass"
        # Self-hold first: a platform-initiated boot has no inbound
        # activity to keep the machine up while the hub settles.
        task_put
        sleep "$SETTLE"
        gc_run_dir
        resume_pass
        marker_gc
        task_del
      fi
      sleep 60
    done
    ;;
esac
