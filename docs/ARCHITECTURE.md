# Architecture deep-dive

This document holds the rationale behind the state-machine decisions in
`tab-title.sh`, `sweep-bell-state.sh`, `notify.sh`, and `dashboard.html`.
Read the relevant section before touching state-transition logic in those
files. For the four-layer architecture overview, the Scripts table,
environment variables, and the validator summary, see the root
[`CLAUDE.md`](../CLAUDE.md).

## Contents

- [Watching state](#watching-state)
- [Agents-running state](#agents-running-state)
- [Pending-input set (parallel-subagent bell hold)](#pending-input-set-parallel-subagent-bell-hold)
  - [Pre-bell state restore](#pre-bell-state-restore)
  - [AskUserQuestion bell (❓ tab-title icon)](#askuserquestion-bell--tab-title-icon)
- [Deferred completion notification (agents-gated Stop notification)](#deferred-completion-notification-agents-gated-stop-notification)
- [Refresh gating](#refresh-gating)
- [Event log dedup](#event-log-dedup)
- [Stale-state cleanup](#stale-state-cleanup)
  - [Logical-state reconciliation (dashboard ↔ menubar convergence)](#logical-state-reconciliation-dashboard--menubar-convergence)
  - [`end` is terminal until resume — dashboard straggler guard](#end-is-terminal-until-resume--dashboard-straggler-guard)
- [Plugin display swap: ` | ` → ` — `](#plugin-display-swap----)
- [Dashboard north-star metric: "Fleet stalled on you"](#dashboard-north-star-metric-fleet-stalled-on-you)

## Watching state

**Decision:** A session in `idle` state is upgraded to `watching` when the
`claude` ancestor process still has at least one live child whose command
line contains the `/tmp/claude-<hex>-cwd` marker. That marker is emitted by
Claude Code's bash-tool wrapper, so it's present on synchronous Bash calls,
`Bash(run_in_background: true)` shells, and the `Monitor` tool's
long-running background command. Synchronous calls exit in seconds, so any
match while the session has reported idle is a live Monitor or background
bash — work the user should "keep an eye on."

Detection happens entirely in `tab-title.sh`'s `idle` branch:

1. Walk up from `$PPID` (max 8 hops) looking for a process whose `comm` is
   `claude`. The hook's invocation chain is usually `claude → shell →
   tab-title.sh`, so this lands in 1–2 hops. The `CCG_CLAUDE_PID` env var
   short-circuits the walk (used by the validator to point at a PID it
   owns).
2. Run `ps -axo ppid=,command=` and awk-count immediate children of that
   PID whose command matches `/\/tmp\/claude-[0-9a-f]+-cwd/`.
3. If the count is >0, treat the effective status as `watching` for title,
   state file, and event log.

**Why:** Stale watching is handled in the plugin, not the hook: when the
plugin reads a `watching` state file it `kill -0`s line 3 (the claude PID)
and re-runs the awk count, downgrading to `idle` in memory if either check
fails. This lets a session reflect a monitor that exited *after* `Stop`
fired — there's no hook for that transition, so polling on each plugin run
is the only way the dropdown can stay honest.

**Limitation:** Sub-agent (`Task` tool) monitors are not detected — they're
children of a *sub-agent* claude PID, not the main session's. If you need
to extend this, change `_count_live_monitors` to a transitive descendant
walk. Immediate children covers Monitor and `run_in_background` for the
main session, which is the common case.

## Agents-running state

**Decision:** A session in `idle` state is upgraded to `agents` when it has
a background `Agent`/`Task` invocation (or a `Workflow`, which spawns
subagents internally) still running. Precedence is `agents > watching >
idle` — if a session somehow has both (e.g. a background agent that itself
launched a monitored Bash command), `agents` wins.

**Why:** This is distinct from `watching`: a background agent is *real
progress* delegated by the session, whereas watching is a live monitor
passively observing something else.

Detection cannot use the process-tree approach `watching` uses. Confirmed
empirically: a background Agent/Task/Workflow invocation runs **in-process**
inside the main `claude` binary — it spawns no child OS process, so there is
no PID to `ps`-walk to. The only externally-visible liveness signal is on
disk: Claude Code writes a per-subagent transcript at
`~/.claude/projects/<project>/<session_id>/subagents/agent-<hex>.jsonl`
(paired with an `agent-<hex>.meta.json` written once at spawn). The
`.jsonl`'s mtime advances continuously while the subagent is working and
freezes the moment it finishes — "fresh mtime" plays the same liveness role
here that `kill -0` plays for `watching`.

Detection happens in `tab-title.sh`'s `idle` branch, in `_count_live_agents`:
glob `$CCG_PROJECTS_DIR/*/<session_id>/subagents/*.jsonl` (the project-dir
segment is wildcarded — `session_id` alone is unique across projects) and
count entries whose mtime is within `CCG_AGENTS_FRESH_SEC` (default 60s) of
now. `agents` is checked before `watching` in the `idle` upgrade branch, so
it takes precedence per the ordering above.

Stale agents is handled in the plugin, not the hook, mirroring `watching`:
when the plugin reads an `agents` state file it re-runs `_count_live_agents`
(keyed off the state file's own basename, which is the session_id) and
downgrades to `idle` in memory if the transcript has gone stale — same
rationale as watching's `kill -0` recheck, just filesystem- instead of
PID-based since there's no subagent PID to check.

The `agents` state is a refinement of `idle` like `watching`: it's excluded
from `notifs` mode's state file (only logged to `events.jsonl`), and it's
**engaged, not stalled**, in the dashboard's fleet-stall metric — the
opposite of `watching`'s exclusion, since a background agent is genuinely
advancing the work while a monitor is merely observing.

**Rejected alternative (mirror the logical-state file in the stray-working
guard):** The finishing background agent is itself what fires
`SubagentStop` → `working` for that actor (see [Pending-input
set](#pending-input-set-parallel-subagent-bell-hold) for the stray-working
guard this hits). The guard originally mirrored the logical-state file
straight back (`idle|watching|agents) effective_status="$_logical"`), which
is correct for `watching` (a monitor's exit isn't itself a hook event, so
nothing else ever re-checks it) but wrong for `agents` — the finishing
agent's *own* SubagentStop is exactly the moment its transcript goes stale,
yet the guard was reading the stale pre-computed value instead of
re-checking liveness. Observed live: the tab stuck on ☕️ for however long
it took the next unrelated hook (a fresh prompt) to fire.

**Fix:** factor the idle→refinement logic into `_resolve_idle_refinement`
(agents > watching > idle, live-checked) and call it from BOTH the initial
idle-upgrade path and the stray-working guard, so a stray subagent `working`
re-derives current liveness instead of trusting the file. `watching`'s
behavior is unaffected: `_resolve_idle_refinement` still finds the same
live monitor marker either way, since re-deriving is a superset of
mirroring when the underlying signal hasn't changed.

**Rejected alternative (re-derive without excluding the finishing actor):**
Re-checking liveness still read `agents` back in practice (observed live:
the tab stuck on ☕️ for 6+ minutes with zero intervening hooks). Root
cause: `_count_live_agents`'s freshness check (`mtime within
CCG_AGENTS_FRESH_SEC`, default 60s) can't distinguish "still writing" from
"wrote its last byte one second ago" — a subagent's transcript mtime is
only a second or two old at the exact instant its own `SubagentStop` fires,
comfortably inside the 60s window. So the stray-working guard's re-derive
counted the very agent whose termination triggered it as still live, and
re-confirmed `agents`. The state only cleared once that transcript aged
*past* 60s on some later, unrelated hook — matching the reported symptom
exactly.

**Fix:** `_count_live_agents` takes an optional exclude parameter (the
finishing actor's id, matched against the transcript's `agent-<id>.jsonl`
basename), threaded through `_resolve_idle_refinement`'s optional third
argument. The stray-working guard passes `$actor` (the current hook
payload's `agent_id`) so a subagent's own `SubagentStop` provably excludes
its own file from the count rather than relying on mtime staleness that
hasn't happened yet. The initial idle-upgrade call site never passes this
— it has no "this specific one just ended" signal, only "check what's live
right now" — so its behavior is unchanged. A genuinely live sibling
subagent's transcript is untouched by the exclusion (only the
`agent-<id>.jsonl` matching the specific actor is skipped), so the state
correctly stays at `agents` when other background work is still running.

## Pending-input set (parallel-subagent bell hold)

**Problem:** Subagents (`Agent`/`Task` tool) share the parent's
`session_id` but fire their own hook events. With multiple subagents
running, one subagent raising a permission prompt (`input`) and another
finishing a tool call (`PostToolUse` → `working`) race over the *single*
per-session state file — last write wins, so `working` clobbers the bell
within seconds and it can never be answered. (This is distinct from the
`watching` case: N subagents running means the **main agent is genuinely
working** — it's blocked awaiting them — whereas a monitors-only session is
parked. The two must not collapse to the same state.)

**Decision:** key a **per-actor pending set** at
`~/.claude/.ccg/pending/<sid>/`, one empty file per actor with an
unanswered permission request:

- The actor key is the hook payload's **`agent_id`** (verified empirically:
  subagent `PostToolUse`/`PermissionRequest` payloads carry `agent_id` +
  `agent_type`; the main agent's carry neither). The main agent maps to the
  `__main__` sentinel — hex `agent_id`s can never collide with it.
  `transcript_path` is **not** usable as the key: it points at the *parent*
  transcript for subagent events too.
- **`input`** → add this actor's file to the set.
- **`working`** → remove *this actor's* file (match-by-id, not "clear any
  one" — a busy sibling must not clear a different actor's bell), then if
  the set is still non-empty, downgrade the effective status back to
  `input` so the bell holds.
- **`idle` / `end`** → clear the whole set (the turn genuinely ended; the
  main `Stop` can't fire while a subagent is still pending).
- Each actor only ever touches its **own** file, so concurrent subagent
  processes never race on shared state — no lock needed.

**Reaper for the no-`PostToolUse` paths:** a **denied** permission never
runs a tool, so no `PostToolUse` ever fires for that actor. `SubagentStop`
is therefore wired (in both `settings.json` files) to `tab-title.sh
working`, which removes the actor via the same match-by-id path. Without it
a denied subagent's bell would stick forever. (`agent_id` arrives two ways:
as **arg 3** on the `input` path — `notify.sh` forwards it — and via
**stdin `.agent_id`** on the `working`/`SubagentStop` path that reads the
raw hook JSON.)

**Rejected alternative (accept the occasional stray `working`):** Wiring
`SubagentStop → working` has a flip side: a stray `working` can arrive
after the session has already settled. Two observed variants:

- **Stray-late-SubagentStop**: a subagent's terminal event lands a second
  or two after the main agent's `Stop` settled to `idle`, with no pending
  bell to clear (observed: `idle` at T, subagent `working` at T+2s, frozen
  ⏳ for 28 min).
- **Stray-main-after-end**: a `Stop`/`StopFailure` hook fires after
  `SessionEnd` already removed the logical-state file. The actor is
  `__main__`, so the old subagent-only guard missed it (observed: `end` at
  T, `__main__` `working` at T+0.66s, no-PID bell-state file, frozen ⏳
  until the 60-min stale cap).

**Fix:** the `working` branch guards against both:

- **Subagent stray (A)**: when a subagent (`actor=<hex>`) arrives with
  empty pending set and logical state already settled (`idle`/`watching`),
  mirror it back to that settled state. Mid-turn subagent working
  (logical=`working`) and the main agent's own working both pass through.
- **Main-after-end stray (B)**: when `__main__` arrives with empty pending
  set and the logical-state file is **absent** (deleted by the prior `end`
  handler), suppress to `idle`. The distinguisher is the absent file: in
  real sessions `SessionStart` always fires `idle` (which creates the file)
  before any `working`, so absent means post-end. The main agent's
  legitimate start-of-turn `working` always arrives while the file exists
  (containing `idle`), so it still passes through.

This is why the logical-state file (`~/.claude/.ccg/sessions/<sid>`) is
read in the pending-set block, not just for event-log dedup.

**Crash cleanup:** a session that dies without firing `idle`/`end` leaks
its pending dir. `sweep-bell-state.sh` hard-expires any pending dir
untouched for 12h (mirrors the state-file cap; tidy-up only, no menubar
refresh). Sandbox via `CCG_PENDING_DIR`.

### Pre-bell state restore

**Problem:** Answering a bell used to unconditionally drop the tab into
`working` once the pending set emptied — correct for the common case (main
agent was mid-turn) but wrong whenever the bell interrupted a *non-working*
idle-family state. The concrete trigger: a backgrounded subagent ([agents
state](#agents-running-state)) raises its own permission prompt. The main
session was never "working" in the ⏳ sense; it was idling on a
still-running background agent. Once that prompt is answered, forcing
`working` painted a wrong tab state until some unrelated later hook
happened to correct it.

**Decision:** snapshot the logical state in force at the **first** bell of
a batch into a flat file, `~/.claude/.ccg/pending/<sid>.prebell` (a sibling
of the `<sid>/` pending-set directory, not inside it — so it survives
independently of which actor files come and go). Rules:

- **`input`, pending set was empty** (first bell in the batch): read the
  current logical-state file and snapshot it to `<sid>.prebell`, unless
  it's already there. A *second*, concurrent bell (a sibling subagent's own
  prompt) must NOT overwrite this — the first bell's snapshot is the one
  true pre-interruption state for the whole batch, and by the time the
  second bell fires the logical state is already `input` (not useful to
  snapshot).
- **`working`, pending set now empty AND a snapshot exists**: consume the
  snapshot (read + delete) and, if it was `watching` or `agents`, re-derive
  that refinement **live** via `_resolve_idle_refinement` rather than
  mirroring the stale value back — same "re-derive not mirror" rationale as
  the stray-working guard, since the snapshotted background agent/monitor
  may have finished during the wait. If the snapshot was plain `idle` (no
  live refinement) or `working`, fall through to the default `working` — a
  bell that interrupted genuinely idle or working state legitimately means
  new work is starting once it's answered.
- **`idle` / `end`**: also remove any leftover `<sid>.prebell`, mirroring
  how the pending-set directory itself is cleared.

**Rejected alternative (exclude the resolving actor's own transcript
here too):** deliberately **not** done, unlike the stray-working guard's
exclude parameter — a subagent whose permission request was just *granted*
usually keeps running, so its transcript is genuinely fresh, and excluding
it would wrongly downgrade `agents` on every granted-permission tool call.
The narrow miss — a *denied* permission causing that subagent to stop
immediately with no other live agents — self-corrects via the sweep's
idle-refinement pass within ~30s (see [Agents-running
state](#agents-running-state)), the same backstop that already exists for
the fully-quiet-session gap.

`sweep-bell-state.sh`'s pending-dir hard-age pass globs `-type d`, which
doesn't match this flat file, so it separately globs `-type f -name
'*.prebell'` to reap one left behind by a crashed session.

### AskUserQuestion bell (❓ tab-title icon)

**Problem:** A plain permission prompt (Bash, Edit, Write, …) needs a single
allow/deny decision. An `AskUserQuestion` tool call fires the *same*
`PermissionRequest` hook event, but it's actually asking the user to pick
from a set of choices — a bell that looks identical to "approve this write"
undersells what's actually being asked.

**Decision:** `notify.sh` inspects the `PermissionRequest` payload's
`tool_name`. When it's exactly `"AskUserQuestion"`, it forwards `kind=query`
as `tab-title.sh`'s 4th argument (`tab-title.sh <status> <session_id>
<agent_id> <kind>`). `tab-title.sh` stores that `kind` as the *content* of
the actor's marker file in the existing per-actor pending-input set (rather
than just an empty sentinel file) and swaps the tab-title icon to ❓ instead
of 🔔 whenever *any* actor currently in the pending set has `kind=query` —
checking the whole set, not just the current actor, so a sibling's ordinary
permission prompt can't mask an AskUserQuestion bell raised by a different
actor in the same session (mirrors the multi-actor reasoning in the
[pending-input set](#pending-input-set-parallel-subagent-bell-hold) above).

**Scope — tab title only:** the bell-state file (what the SwiftBar menubar
reads) and the event log both keep writing the plain `input` state
unconditionally; `kind` is invisible to both. The menubar's 🔔 count and the
dashboard's `input` metric are deliberately unaffected — this is a
cosmetic distinguisher for glancing at the tab bar, not a new logical
state, so it doesn't need a fifth entry in the state machine.

**Menubar-click corollary:** because the bell-state file's icon never
changes, `ghostty-bells.30s.sh` strips the leading `🔔 ` before using the
title as `focus-ghostty-tab.sh`'s AX contains-match key (both the
notifs-mode dropdown loop and the always-on `input` case) — matching
`notify.sh`'s `match_key`, which was already icon-agnostic. Without the
strip, a menubar click on a session whose live tab title had been swapped
to ❓ would never match, because the AX title reads `❓ …` while the stale
`param1` string still read `🔔 …`. See [Plugin display swap](#plugin-display-swap---).

## Deferred completion notification (agents-gated Stop notification)

**Problem:** The `Stop` hook's "Task completed" `notify.sh` call fires
whenever the main agent's turn ends — including when a backgrounded
Agent/Task/Workflow subagent is still running (the tab-title `agents`
state). That's misleading: the main turn paused, but the fleet isn't
actually done, and notifying at that moment trains the user to check in on
false-positive "done" pings.

**Decision:** `notify.sh` accepts an optional 5th argument, `gate`. When
called with `gate=agents` (the Stop hook's call site: `notify.sh '✅' 'Task
completed' '' '' agents`), it checks the same liveness signal
`tab-title.sh`'s `_count_live_agents` uses — a fresh (`CCG_AGENTS_FRESH_SEC`,
default 60s) subagent transcript under
`~/.claude/projects/*/<session_id>/subagents/*.jsonl` — and exits silently
before sending anything if one is found. Other call sites
(`PermissionRequest`, `StopFailure`) don't pass `gate`, so they're never
suppressed.

**Why not suppress outright:** that would create a silent gap: nothing else
was watching for the background agent to actually finish. The counterpart
lives in `sweep-bell-state.sh`'s existing logical-state idle-refinement
pass (see [Agents-running state](#agents-running-state)) — the same pass
that already rewrites a session's logical state from `agents` to `idle`
once the subagent transcript goes stale now also calls `notify.sh '✅'
'Background task completed'` on that specific `agents → idle` edge (not
`watching → idle`, not `idle → idle` no-ops). This pass already runs every
~30s via the SwiftBar plugin regardless of bell mode, so it's the natural
place to catch "background work just finished" without adding a new
poller. `cwd` for the notification's subtitle is looked up from the most
recent non-empty `cwd` field logged for that session in `events.jsonl`,
since the logical-state file itself carries no cwd.

## Refresh gating

**Decision:** `tab-title.sh` compares the desired state file against the
on-disk state file and only fires `refresh-menubar.sh` when something
actually changed.

**Why:** `PostToolUse` fires after every tool call and sets status=working;
without gating, every tool use would trigger a plugin refresh. The gate:

- `input`: fire only if file didn't exist or content differs.
- `idle` / `working`: fire only if the file existed and was removed.
- `query`: never fires; read-only path.

## Event log dedup

**Problem:** `events.jsonl` must record real transitions only —
`PostToolUse` fires after every tool call, so a naive append would flood
the log.

**Decision:** `tab-title.sh` keeps a per-session "logical state" file at
`~/.claude/.ccg/sessions/<sid>` and only appends to `events.jsonl` when the
new state differs from that file. The file is two lines: **line 1 the
state name, line 2 the ancestor claude PID** (the same PID stored on line 3
of bell-state files). Line 2 lets `sweep-bell-state.sh` reconcile dead
sessions back into the event log — see [Stale-state
cleanup](#stale-state-cleanup). All readers (`head -n1` dedup here, the
stray-subagent guard) take only line 1, so the added PID line is
transparent to them. On `end`, the per-session file is removed so a future
`SessionStart` for the same `session_id` would re-emit `idle`. A pure
`end` with no prior state is dropped to avoid zombie entries from stray
hook invocations.

This layer is intentionally independent of bell mode: in `notifs` mode the
bell-state file isn't written for `idle`/`working`, but the event log still
gets every transition. Sandbox via `CCG_EVENT_LOG` and
`CCG_SESSION_STATE_DIR` env vars (the validator does this).

## Stale-state cleanup

**Problem:** A session can end without firing `end` — process killed,
Ghostty tab closed mid-prompt, macOS reboot while the SessionEnd hook is
mid-flight. Its state file would otherwise linger as a phantom dropdown
entry.

**Decision:** `sweep-bell-state.sh` handles this with a hard-age pass: any
state file older than 12 h is deleted unconditionally. The graceful path is
the SessionEnd hook calling `tab-title.sh end`, which removes the file the
moment a session exits cleanly; the sweep only matters for crashes and
similar irregular exits.

Faster than the 12 h cap, a **PID-liveness pass** prunes a state file the
moment its owning claude PID (line 3) fails `kill -0`. A file with **no
PID** can't be `kill -0`'d — under the current hooks this is either a
pre-PID legacy file or a rare `_find_claude_pid` failure (the claude
ancestor had already exited when the hook fired, e.g. a fleet session torn
down mid-write). Since every live session writes a PID, a no-PID file
untouched past `NO_PID_STALE_MIN` (default 30 min, override
`CCG_NO_PID_STALE_MIN`) is stale and gets reaped — so a stuck "working"
tile clears from the menubar in 30 min, not 12 h. A *fresh* no-PID file is
kept (a live session may rewrite it with a PID on its next transition). The
logical-state reconciliation pass uses the same `NO_PID_STALE_MIN` for its
no-PID fallback, so the menubar and dashboard drop these phantoms in
lockstep.

**Rejected alternative (AX-verified pruning):** an earlier version of the
sweep also ran an "AX-verified" pass that queried Ghostty's tab tree via
AppleScript and pruned any state file whose title was missing. We removed
it because the AppleScript query races with Ghostty's own tab-bar redraws
and intermittently returns partial tab lists (empirically, ~14% of queries
omit a tab; ~1% omit multiple). That made the pass spuriously delete state
files for live idle sessions, so the menubar would silently lose entries
over time. The 12 h cap is the trade-off: phantoms can linger up to 12 h,
but real sessions are never wrongly evicted.

The sweep is dispatched in the background by the plugin after it emits
output, so it never blocks menubar rendering. When it prunes anything, it
nudges SwiftBar so the dropdown reflects reality on the next run.

### Logical-state reconciliation (dashboard ↔ menubar convergence)

**Problem:** The menubar and the dashboard once disagreed badly on "right
now" (e.g. menubar showing ~5 live sessions, dashboard ~39). The cause is
an **asymmetry in liveness signals**:

- The **menubar** reads bell-state *files*, which the sweep above actively
  *deletes* the moment the owning claude PID dies (`kill -0` on line 3).
  Dead sessions vanish within one sweep cycle.
- The **dashboard** reads `events.jsonl`, an **append-only log with no
  reaper**. It only learns a session ended when an `end` line is appended,
  and that only happens if the `SessionEnd` hook fires `tab-title.sh end`.
  A crash/kill/closed-tab/reboot skips that hook, so the session's last
  logged state lingers as `working`/`idle` for the full 12 h dashboard
  window. The dashboard is browser JS fetching one file over HTTP — it
  **cannot** probe a PID or list a directory, and a timestamp alone can't
  distinguish a live-but-quiet session (event-log dedup means 40 min of
  work logs one `working` line) from a dead one. So liveness must be
  reconciled *into the log*, server-side.

**Rejected alternative:** raising the dashboard's right-now window (a past
"fix") only traded the opposite bug (live-quiet sessions dropping off) for
this one.

**Decision:** a sweep pass emits a **synthetic `end`** for any
logged-but-dead session, using the same PID-death signal the bell-state
pass uses — so both layers converge by construction. For each
`~/.claude/.ccg/sessions/<sid>` file whose line-1 state ≠ `end`:

- **line-2 PID alive** → keep. **PID dead** → append `end` + remove the
  file.
- **no PID (legacy 1-line file)** → can't prove death, so fall back to the
  12 h hard-age cap.

The synthetic `end`'s `ts` is **`min(now, mtime + 30 min)`**, not `now`.
The logical-state file's mtime equals the last logged transition (dedup
only rewrites it on real changes), and `mtime + 30 min` matches the
dashboard's existing trailing-span cap (`TRAILING_CAP_SEC` in `spanFor`) —
so historical totals and the timeline chart are unchanged; only the
right-now phantom disappears. Emitting at `now` would retroactively
inflate the dead session's working-time. This pass runs even in `notifs`
mode (where no bell-state file exists for working/idle), which is why it
keys off the logical-state file, not the bell-state file. Sandbox via
`CCG_SESSION_STATE_DIR` and `CCG_EVENT_LOG`.

### `end` is terminal until resume — dashboard straggler guard

**Problem:** Even with the reconciliation above, the dashboard's "working"
card kept drifting above the menubar. Cause: `events.jsonl` is
append-only, and a `working`/`input`/`watching` event sometimes lands
**after** a session's `end` — a `SubagentStop`/`PostToolUse` straggler
firing during teardown, or the sweep's own synthetic `end` whose
**integer-second** ts lost a same-second tie to a *fractional* straggler
(e.g. synthetic `end` at `670.000` vs a stray `working` at `670.110`). The
dashboard's old "latest event by ts" rule then read the straggler as the
live state and counted a dead session as `working` (and painted a 30-min
phantom open span in the timeline).

**Decision:** the fix lives in `dashboard.html`'s `stripStragglers()`
(sliced by `// <stripStragglers>` markers for the validator): walk each
session's events in ts order, mark `ended` on `end`, **clear it on
`idle`**, and drop any non-`idle` event seen while ended. `end` is
therefore terminal — but a fresh `idle` (a `SessionStart`) reopens the
session, so `claude --continue` / `--resume`, which **reuse the session
id**, keep working. This one rule also absorbs the synthetic-`end` tie
collision, so the sweep's exact ts no longer has to win the race. It's
applied in all **three** per-session loops (`compute` + both daily-trend
functions) so a straggler can neither inflate a right-now card nor paint a
phantom span; the validator asserts all three call sites exist.

**Rejected alternative:** a blanket "exclude any session that ever emitted
`end`" would be simpler but **wrong** — it would drop resumed sessions,
which are legitimately live.

## Plugin display swap: ` | ` → ` — `

**Decision:** State file titles contain ` | ` (from `Claude Code |
<dir>`). SwiftBar uses ` | ` as its parameter separator, so the plugin
swaps to ` — ` in the visible display text. `param1=` strips the leading
`🔔 ` and passes the rest of the title as the icon-agnostic match key for
`focus-ghostty-tab.sh`'s contains-match — see the [AskUserQuestion
corollary](#askuserquestion-bell--tab-title-icon) for why the icon can't
be included.

## Dashboard north-star metric: "Fleet stalled on you"

**Decision:** the dashboard's headline lever is **fleet-stall share**, not
a per-bell latency. Per 5-min bin: a bin is *stalled* when ≥1 session is
awaiting input AND zero sessions are working. Share = stalled bins ÷
**bell-pending bins** (bins with ≥1 session awaiting input). Reads as "of
the time I was on the hook, how much did I waste with no agent making
progress."

The reasoning behind every choice in its definition (arrived at
empirically against real `events.jsonl` data — re-deriving it from scratch
is expensive, so it's recorded here):

**Rejected alternative (median/p90 per bell):** any central tendency over
"the bells that survive" suffers two biases the user actively hits:
*survivorship* (automating trivial bells removes the easy members, so the
median of what's left rises even at constant behavior) and *queueing
inflation* (more parallel agents → each bell's latency includes time spent
serving other bells, Little's Law). Both make the number a moving goalpost
that punishes good behavior. Median and p90 are kept only as
**diagnostics** (bottom row), never as the goal.

**Why bell-pending bins as denominator, not "any engaged time":** the
bell-pending denominator gives a readable dynamic range (~20–60% on real
days) vs. the flat ~4–5% you get dividing by all-engaged time, which
under-reads as a lever. Verified: same stalls read 5% (engaged denom) vs
27% (bell-pending denom) on the same day.

The metric is *composition-invariant* (trimming easy bells doesn't move
it) and *concurrency-correct* (wall-clock bins, not summed-per-session, so
more agents don't inflate it) — the two properties median/p90 lack.

**Watching counts as idle:** A `watching` session is parked; only a
background monitor is alive, which isn't *your* forward progress. So
`watching` is excluded from both the stalled numerator and the engaged
denominator — a bell pending while only a monitor ticks still counts as a
stall. (Chosen deliberately over treating watching as activity.)

**Agents-running counts as engaged, the opposite of watching:** A session
in the `agents` state has a background Agent/Task/Workflow actually
delegating work, not just observing — real progress toward the fleet's
goal. So a bell pending while a background agent runs elsewhere is NOT a
stall: `agents` is added alongside `working` in the stalled-bin check
(`w === 0 && ag === 0`). This is the deliberate mirror image of the
watching decision above — the two states look superficially similar (both
are refinements of `idle`) but have opposite treatment because one is
passive observation and the other is active delegated work.

**Why the gate is on bell-pending bins, not bell count/session
count/work time:** `STALL_MIN_SAMPLE = 12` (= 1 h on the hook) gates on the
metric's own denominator — the textbook precision gate, since standard
error of a proportion is governed by *its* `n`. The empirical clincher:
bell-count/session/work-time gates are *anti-correlated* with reliability
on real data — e.g. 05-13 (67 bells, 387 work-min, but only 9 bell-pending
bins → noisy 67%) vs 05-24 (25 bells, 87 work-min, but 220 bell-pending
bins → the genuine worst day at 100%). Any activity-based gate hides 05-24
(low bells) while showing 05-13 (high bells) — exactly backwards. Only the
bell-pending-bin gate ranks them correctly. Below the floor the 24h card
shows `—` and chart days render blank (tooltip: "Too few bells to score").

**Why 5-min bins:** the stall % is bin-invariant from 1–10 min on real data
(26/28/27/25%), so the choice isn't an artifact. 5 min is the sweet spot
because its gate floor lands at a meaningful 1 h (12 bins) — at 1 min the
floor would be a useless 12 min, at 15 min the dominant-state rule erases
fast bells entirely (a 4-min bell never dominates a 15-min bin →
on-the-hook collapses to 0). Finer bins (2 min) capture sub-5-min bells
more faithfully but cost chart smoothness; only switch if rewarding
sub-5-min responsiveness becomes a goal.

**Verdict banner:** the dashboard names the single highest-leverage action,
not just a number. `verdictFor(stall, conc, workingSecs)` is a pure
function (sliced out by `// <verdictFor>` markers for the validator) with
precedence: gated → stall-critical (≥50%) → stall-high (≥25%) → fanout
(stall healthy but concurrent share <30%) → good. **Stall dominates
concurrency** because a stalled fleet is wasted wall-clock you caused,
whereas low concurrency is only opportunity cost.

**Companion metric:** concurrent share (push *up*) is the mirror of
fleet-stall (pull *down*) — share of working-time bins with ≥2 sessions in
parallel.
