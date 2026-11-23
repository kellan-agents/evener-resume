# evener-resume

Boot-time auto-resume for evener sessions on a sprite. A hard stop (sprites
pause as stop/start under load) kills every session daemon mid-turn; the hub
then shows each thread failed until a human clicks it. This service resumes
the recently-active ones headlessly at boot — resumed daemons continue
interrupted turns server-side, so a crash becomes a few minutes of lost time
instead of a pile of "Needs you" rows.

## Crash-loop safety

The crash may have been *caused by* the work being resumed, so:

- fresh-boot guard: acts only when machine uptime < 10 min (a service
  crash-restart must not re-resume)
- fuse: 3+ boots within 2h suspends auto-resume loudly for manual
  investigation — checked inside every pass, `--force` included
- recency: only sessions with transcript activity in the last 45 min
- finished sessions (last turn ended `end_turn=true`) are never resumed
- stagger + cap: one resume every 45 s, at most 4 per pass
- lock check: never spawns a second daemon for a live session
- fresh daemons read the current AGENTS.md, so a resumed turn re-runs an
  interrupted build under the machine's yield convention
- self-hold: takes a task for the pass, so a platform-initiated boot with no
  inbound activity cannot fall back asleep mid-pass

## Configuration

Machine-specific values live in one optional shared config file,
`~/.config/evener-sprite/config` (override its location with
`EVENER_SPRITE_CONFIG`), never committed. Precedence: per-tool env var >
config file > neutral built-in default. `config.example` documents every key.

| Key / per-tool env var | Meaning | Default |
|---|---|---|
| `RESUME_BUCKET` / `EVENER_RESUME_BUCKET` | state bucket to resume from (serve needs the session's original working dir; the bucket names it) | unset → pass disables itself loudly |
| `DEFAULT_MODEL` / `EVENER_RESUME_MODEL` | default model, `provider/model` form; its provider prefix is prepended to sessions that carry a bare model name | empty → bare-model sessions are skipped with a log line, never guessed |
| `PROVIDER_ENV` / `EVENER_RESUME_PROVIDER_ENV` | provider env file sourced before each pass | unset → warn in the log |
| `WORKDIR` / `EVENER_RESUME_WORKDIR` | working dir passed to the resumed serve daemon | `$HOME/projects` |
| `EVENER_BIN` / `EVENER_RESUME_BIN` | evener binary | `evener` from PATH |
| `NICE` / `EVENER_RESUME_NICE` | nice level for resumed daemons | `10` |
| `EVENER_RESUME_STATE` | state dir (log, fuse file) | `~/.local/state/evener-resume` |
| `EVENER_RESUME_RUN_DIR` | evener run dir (daemon liveness, GC) | `~/.local/state/evener/run` |

Sessions in other buckets are never resumed automatically; they are logged
for manual resume.

## Install

Run `resume/resume.sh` as a service (restarted on boot). It only reads
evener state and spawns `evener serve`; no root needed. `yield/yield.sh` is
an optional companion service that renices every live session daemon to
`+NICE` so session work always yields to the hub.

## Test

```bash
resume.sh --dry-run   # list what a boot pass would resume right now
resume.sh --force     # run the pass now, ignoring the boot guard
bash test/run.sh      # stub-based test suite (temp state, no live sessions)
tail -f ~/.local/state/evener-resume/resume.log
```

## Limits

- Resumes only root sessions in the configured bucket with recent
  transcript activity.
- A resumed session continues server-side from its last interrupted turn;
  anything not committed to disk before the crash is lost.
- The fuse suspends auto-resume after 3 boots in 2h — deliberate: a crash
  loop must not be fed. Resume manually after investigating.
