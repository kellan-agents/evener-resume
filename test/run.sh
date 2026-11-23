#!/usr/bin/env bash
# evener-resume test suite.
#
# Stub-based: every case runs in a fresh temp state dir with a stubbed
# `evener` (emits the fixture for `doctor sessions`, records argv for
# `serve`) and a stubbed `curl`. No live session is ever spawned and no real
# sprite state is touched.
#
#   bash test/run.sh
#
# The whole suite nices itself (shared-machine courtesy).
set -u

if [ -z "${EVENER_RESUME_TEST_NICED:-}" ]; then
  exec nice -n 19 env EVENER_RESUME_TEST_NICED=1 bash "$0" "$@"
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASS=0
FAIL=0
FAILED=""
TLIST=""

cleanup() {
  local d
  for d in $TLIST; do rm -rf "$d"; done
}
trap cleanup EXIT

# Fresh temp world: state dir, stub bin dir, stub log. Sets T, STATE, STUB.
# Exports the EVENER_* env resume.sh reads.
setup() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/evener-resume-test.XXXXXX")
  TLIST="$TLIST $T"
  STATE="$T/state"
  STUB="$T/stub.log"
  mkdir -p "$STATE" "$T/run" "$T/keepawake" "$T/bin" "$T/home" "$T/home/projects"

  # stub evener: fixture for `doctor sessions`, argv log for `serve`.
  cat >"$T/bin/evener" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  doctor)
    [ "${2:-}" = sessions ] && cat "${EVENER_RESUME_TEST_FIXTURE:?}"
    ;;
  *)
    printf 'evener args=%s\n' "$*" >>"${EVENER_RESUME_TEST_LOG:?}"
    ;;
esac
exit 0
EOF
  # stub curl: records "<METHOD> <task>" for task PUT/DELETE calls.
  cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
method= url=
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf 'curl %s %s\n' "${method:-GET}" "${url##*/}" >>"${EVENER_RESUME_TEST_LOG:?}"
exit 0
EOF
  chmod +x "$T/bin/evener" "$T/bin/curl"

  export EVENER_RESUME_STATE="$STATE"
  export EVENER_RESUME_RUN_DIR="$T/run"
  export EVENER_RESUME_PROJECTS="$T/projects"
  export EVENER_RESUME_KEEPAWAKE_STATE="$T/keepawake"
  export EVENER_RESUME_BUCKET="test-bucket-0001"
  export EVENER_SPRITE_CONFIG="$T/absent-config"
  export EVENER_RESUME_TEST_LOG="$STUB"
  export PATH="$T/bin:$PATH"
  # Throwaway HOME keeps the tools' `PATH="$HOME/.local/bin:$PATH"` prepend
  # from shadowing the stubs with real binaries.
  export HOME="$T/home"
  unset EVENER_RESUME_MODEL DEFAULT_MODEL RESUME_BUCKET EVENER_RESUME_WORKDIR \
        WORKDIR NICE EVENER_RESUME_NICE EVENER_BIN PROVIDER_ENV \
        EVENER_RESUME_PROVIDER_ENV LEGACY_CUTOFF 2>/dev/null || true
}

# Materialize the run's doctor fixture: fresh timestamps so every session
# counts as recent, optionally pre-filtered by $1 (a jq filter on .sessions).
fresh_fixture() {
  jq --arg now "$(date -u +%FT%TZ)" \
     --arg s0 "$(date -u -d '10 minutes ago' +%FT%TZ)" \
     "${1:-.} | .sessions |= map(.last_activity = \$now | .started_at = \$s0)" \
     "$ROOT/test/fixtures/doctor-sessions.json" >"$T/fixture.json"
  export EVENER_RESUME_TEST_FIXTURE="$T/fixture.json"
}

serves() {
  if [ -f "$STUB" ]; then
    grep -c 'evener args=serve' "$STUB" || true
  else
    echo 0
  fi
}

run_case() {
  local name=$1 out
  out=$(mktemp "${TMPDIR:-/tmp}/evener-resume-case.XXXXXX")
  setup
  if "$name" >"$out" 2>&1; then
    PASS=$((PASS + 1))
    echo "PASS: $name"
  else
    FAIL=$((FAIL + 1))
    FAILED="$FAILED $name"
    echo "FAIL: $name"
    sed 's/^/    /' "$out"
  fi
  rm -f "$out"
}

LOGF() { echo "$STATE/resume.log"; }

# --- cases ------------------------------------------------------------------

fuse_trips_after_three_boots() {
  local now
  now=$(date +%s)
  printf '{"recent_boots":[%s,%s,%s]}\n' \
    "$((now - 100))" "$((now - 200))" "$((now - 300))" >"$STATE/fuse.json"
  fresh_fixture
  bash "$ROOT/resume/resume.sh" --force || { echo "run failed"; return 1; }
  grep -q "FUSE TRIPPED" "$(LOGF)" \
    || { echo "no FUSE TRIPPED line:"; cat "$(LOGF)"; return 1; }
  [ "$(serves)" = "0" ] || { echo "resumed despite tripped fuse"; return 1; }
}

dry_run_selects_unfinished_recent() {
  fresh_fixture '.sessions |= map(select(.session_id != "test-sid-2004"))'
  bash "$ROOT/resume/resume.sh" --dry-run || { echo "run failed"; return 1; }
  local log
  log=$(LOGF)
  grep -q "would resume test-sid-2002" "$log" \
    || { echo "unfinished recent session not selected:"; cat "$log"; return 1; }
  if grep -q "would resume test-sid-2001" "$log"; then
    echo "finished session selected"
    return 1
  fi
  if grep -q "test-sid-2005" "$log"; then
    echo "subagent leaked into selection or notes"
    return 1
  fi
  grep -q "test-sid-2003 is in another bucket; left for manual resume" "$log" \
    || { echo "other-bucket note missing:"; cat "$log"; return 1; }
  [ "$(serves)" = "0" ] || { echo "dry-run spawned serve"; return 1; }
}

bare_model_without_provider_skips() {
  # 1: bare session model, no DEFAULT_MODEL anywhere → skip with a loud line.
  fresh_fixture '.sessions |= map(select(.session_id == "test-sid-2004"))'
  bash "$ROOT/resume/resume.sh" --dry-run || { echo "run 1 failed"; return 1; }
  local log
  log=$(LOGF)
  grep -q "skip test-sid-2004: bare model with no provider configured" "$log" \
    || { echo "bare-model skip line missing:"; cat "$log"; return 1; }
  grep -q "would resume" "$log" \
    && { echo "bare-model session was not skipped"; return 1; }
  # 2: DEFAULT_MODEL provides the provider prefix → prefixed in the line.
  setup
  fresh_fixture '.sessions |= map(select(.session_id == "test-sid-2004"))'
  export DEFAULT_MODEL="provider-a/model-y"
  bash "$ROOT/resume/resume.sh" --dry-run || { echo "run 2 failed"; return 1; }
  log=$(LOGF)
  grep -q "would resume test-sid-2004" "$log" \
    || { echo "no would-resume line with DEFAULT_MODEL set:"; cat "$log"; return 1; }
  grep -q "model provider-a/model-bare" "$log" \
    || { echo "bare model not prefixed from DEFAULT_MODEL:"; cat "$log"; return 1; }
}

bucket_unset_disables_loudly() {
  unset EVENER_RESUME_BUCKET RESUME_BUCKET
  fresh_fixture
  bash "$ROOT/resume/resume.sh" --dry-run || { echo "run failed"; return 1; }
  local log
  log=$(LOGF)
  grep -q "RESUME_BUCKET not configured; auto-resume pass disabled" "$log" \
    || { echo "no loud disabled line:"; cat "$log"; return 1; }
  if grep -q "would resume" "$log"; then
    echo "resumed something with the bucket unset"
    return 1
  fi
  return 0
}

gc_removes_dead_keeps_live() {
  printf '{"pid":4000000,"session_id":"test-sid-9001"}\n' >"$T/run/dead.json"
  printf '{"pid":%s,"session_id":"test-sid-9002"}\n' "$$" >"$T/run/live.json"
  : >"$T/run/4000000.lock"
  # Only the finished session as a candidate: no serve spawn in this case.
  fresh_fixture '.sessions |= map(select(.session_id == "test-sid-2001"))'
  bash "$ROOT/resume/resume.sh" --force || { echo "run failed"; return 1; }
  [ ! -e "$T/run/dead.json" ] || { echo "dead-pid info json not removed"; return 1; }
  [ ! -e "$T/run/4000000.lock" ] || { echo "dead-pid lock not removed"; return 1; }
  [ -e "$T/run/live.json" ] || { echo "live-pid info json removed"; return 1; }
  [ "$(serves)" = "0" ] || { echo "unexpected serve spawn"; return 1; }
}

no_hardcoded_machine_refs() {
  # Needles are concatenated so this file itself carries no machine-identity
  # strings (they are checked for, never spelled out).
  local home_path machine provider bucket_id
  home_path="home/""sprite"
  machine="gray""goo"
  provider="luna""route"
  bucket_id="zPXzFnh""KEg"
  if grep -n -e "$home_path" -e "$machine" -e "$provider" -e "$bucket_id" \
      "$ROOT/resume/resume.sh" "$ROOT/yield/yield.sh"; then
    echo "machine-specific strings found in resume.sh or yield.sh"
    return 1
  fi
}

# --- run --------------------------------------------------------------------

cd "$ROOT"
for c in fuse_trips_after_three_boots dry_run_selects_unfinished_recent \
         bare_model_without_provider_skips bucket_unset_disables_loudly \
         gc_removes_dead_keeps_live no_hardcoded_machine_refs; do
  run_case "$c"
done

echo "evener-resume tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || { echo "failed:$FAILED"; exit 1; }
