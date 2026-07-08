# Agent / developer reference

This file is for anyone (human or agent) making code changes. End-user install
and usage live in `README.md`; everything architectural lives here.

## Session start

**Read `~/.claude/.ccg/changelog.md` before doing any work in this repo.**
The `SessionStart` hook (`.claude/hooks/fetch-changelog.sh`) fetches the Claude Code
changelog and caches it there (12 h TTL). Use the `Read` tool to load it into
context. Missing a changelog entry has caused real debugging time (e.g.
`terminalSequence` was in the 2.1.141 notes but unknown until we hit the
problem). This hook lives in `.claude/settings.json` (project-scoped,
untracked) — absent from both the root `settings.json` and
`~/.claude/settings.json` so it fires only for sessions in this repo.

## Post-change checklist

After every change, verify the following in order:

1. **Validator** — run `./tests/validate.sh`. It must pass. If the change
   introduces new behavior, extend the validator to cover it before considering
   the change complete.
2. **Tab title verification** — to confirm a title change took effect in a
   live session, use one of: `tail ~/.claude/.ccg/termseq.log` (every
   `tab-title.sh` run appends a timestamped line with the exact title and
   session id), or osascript to read Ghostty's current tab titles. Do not
   rely on the user manually confirming.
3. **Tab targeting** — will notifications still focus the correct tab?
   `focus-ghostty-tab.sh` uses contains-match against AX tab titles; confirm
   the title stored in state files and passed via `terminal-notifier` still
   uniquely identifies the session.
4. **Notification text** — does any user-visible string need updating?
5. **README.md** — does the human-facing documentation still reflect the
   current install flow? (Architecture details don't belong there.)
6. **Dashboard** — open `.ccg/dashboard.html` and inspect every place that
   enumerates session states (the `STATES` constant, per-state arrays in
   `compute()`, the "Right now" cards, the "Last 24 hours · totals"
   cards, the chart datasets, the `render()` block). If the change adds
   or renames a state, every one of those must be updated; if it adds a
   new metric, decide whether the dashboard should surface it. **For
   any dashboard change, always (a) deploy the updated file to
   `~/.claude/.ccg/dashboard.html` — don't ask, this overrides item 7 —
   then (b) view it through the running server via the
   `chrome-devtools` MCP, list console messages, and take a snapshot or
   screenshot. Treat any console error, network failure, or visibly
   broken section as a blocking issue and fix it before moving on.**
   The point is to surface render bugs (missing canvases, undefined
   refs, mis-sized charts) before the user sees them, not just to
   confirm the file parses.
7. **Hook parity** — `settings.json` (project) and `~/.claude/settings.json`
   (global) must define the same core hook events (`SessionStart`,
   `Notification`, `UserPromptSubmit`, `PostToolUse`, `Stop`, `StopFailure`,
   `SessionEnd`) with identical matchers and commands. The global file may have
   additional hooks (`PreToolUse`/unfence, `SubagentStop`/agent-arena,
   `Stop`/sync-permissions) that are intentionally absent from the project
   file. **Project-specific hooks go in `.claude/settings.json`** (not in the
   root `settings.json`, which is the source for the deployed global config;
   not in `~/.claude/settings.json`). Their scripts live in `.claude/hooks/`,
   not in `hooks/`. Any change to a shared hook must be applied to **both** the
   root `settings.json` and `~/.claude/settings.json`.
8. **Local deploy** — ask the user whether the change should be copied to
   `~/.claude/hooks/` / `~/swiftbar/` / `~/.claude/.ccg/`.
9. **Commit and push** — every change ends with a commit and a push to
   *all* configured remotes (this overrides the default "only commit
   when explicitly asked" rule for this repo). Remotes to push to are
   whatever `git remote` lists; today that's `origin` and `trilogy`.
   Push to each one in sequence.
   **Always hold the commit and push until the new feature or fix is
   proven working** — not just for bug fixes but for any new behavior.
   "Proven" means the user has confirmed it behaves correctly in
   practice (or there is concrete in-situ evidence it does), NOT merely
   that the validator passes or the code looks right. The validator and
   local diagnostics are necessary but not sufficient. Deploy to
   `~/.claude/...` so the change can be exercised live, then wait. Once
   the user confirms it's working, commit and push immediately without
   asking.

## Architecture

Four layers cooperate:

1. **Tab title (ANSI)** — `tab-title.sh` writes `⏳ Claude Code | …`,
   `🔔 Claude Code | …`, `👀 Claude Code | …` (idle session with a live
   Claude-owned monitor — see "Watching state" below), `⚙️ Claude Code | …`
   (idle session with a live background Agent/Task/Workflow — see
   "Agents-running state" below), or the base title (no prefix) via
   `\033]2;<title>\007`. Primary user-visible signal. The menubar plugin
   uses the `binoculars` and `gearshape.fill` SF Symbols for the watching
   and agents-running states respectively (SF Symbols render better than
   emojis at menubar height); the tab title keeps the emoji prefixes
   because terminal ANSI titles render emojis reliably across UIs but
   can't reference SF Symbols.
2. **State files** — `tab-title.sh` also maintains one file per bell-state
   session at `~/.claude/bell-state/<session_id>`. The SwiftBar plugin
   reads this directory as its source of truth. Format:
   - Line 1: full tab title with icon prefix
   - Line 2: status string (`input` | `working` | `watching` | `idle`)
   - Line 3: the claude ancestor PID (stored for all write states).
     `sweep-bell-state.sh` uses it to prune orphaned files when the
     process has exited. The plugin also uses it for `watching` files
     to verify the monitored process is still alive on each poll.
3. **Push refresh** — on actual state transitions, `refresh-menubar.sh` fires
   `open -g swiftbar://refreshallplugins` so SwiftBar re-runs the plugin
   within a few hundred ms. The plugin's filename-encoded 30 s poll is a
   safety net, not the primary path.
4. **Event log + dashboard** — `tab-title.sh` also appends every transition
   to `~/.claude/.ccg/events.jsonl` (append-only JSONL: `{ts, session_id,
   state, title, cwd}`). The single-file dashboard at `~/.claude/.ccg/dashboard.html`
   fetches the log over HTTP every second and computes live + last-24h
   metrics. This layer is independent of bell mode — events are logged
   even when `notifs` mode suppresses bell-state writes for working/idle.

### Why state files instead of AppleScript tab enumeration

The macOS Accessibility API has a **30–60 second lag** reflecting ANSI-set tab
titles while Ghostty is backgrounded. An AppleScript-enumerating plugin made
the menubar feel 30 s+ behind reality. State files are visible to the plugin
within milliseconds, so the menubar updates in ~200 ms of a bell transition.
Diagnosed empirically via `BELL_TRACE` (see `/tmp/bell-trace.log` patterns
like `title-set` at T+0 but AppleScript `lines=0 bytes=0` at T+0, T+30s;
finally `lines=1` at T+60s).

### Why `refreshallplugins` vs `refreshplugin?name=…`

The plugin filename encodes its poll interval (`.30s.sh`), and users may
rename it (e.g. `.1m.sh`). `refreshallplugins` is resilient to that. The
externality (other SwiftBar plugins re-run) is negligible because we only
trigger on bell transitions — typically a few times a minute at most.

### Watching state

A session in `idle` state is upgraded to `watching` when the `claude`
ancestor process still has at least one live child whose command line
contains the `/tmp/claude-<hex>-cwd` marker. That marker is emitted by
Claude Code's bash-tool wrapper, so it's present on synchronous Bash
calls, `Bash(run_in_background: true)` shells, and the `Monitor` tool's
long-running background command. Synchronous calls exit in seconds, so
any match while the session has reported idle is a live Monitor or
background bash — work the user should "keep an eye on."

Detection happens entirely in `tab-title.sh`'s `idle` branch:

1. Walk up from `$PPID` (max 8 hops) looking for a process whose `comm`
   is `claude`. The hook's invocation chain is usually `claude → shell →
   tab-title.sh`, so this lands in 1–2 hops. The `CCG_CLAUDE_PID` env
   var short-circuits the walk (used by the validator to point at a PID
   it owns).
2. Run `ps -axo ppid=,command=` and awk-count immediate children of that
   PID whose command matches `/\/tmp\/claude-[0-9a-f]+-cwd/`.
3. If the count is >0, treat the effective status as `watching` for
   title, state file, and event log.

Stale watching is handled in the plugin, not the hook: when the plugin
reads a `watching` state file it `kill -0`s line 3 (the claude PID) and
re-runs the awk count, downgrading to `idle` in memory if either check
fails. This lets a session reflect a monitor that exited *after* `Stop`
fired — there's no hook for that transition, so polling on each plugin
run is the only way the dropdown can stay honest.

Sub-agent (`Task` tool) monitors are not detected — they're children of
a *sub-agent* claude PID, not the main session's. If you need to extend
this, change `_count_live_monitors` to a transitive descendant walk.
Immediate children covers Monitor and `run_in_background` for the main
session, which is the common case.

### Agents-running state

A session in `idle` state is upgraded to `agents` when it has a background
`Agent`/`Task` invocation (or a `Workflow`, which spawns subagents
internally) still running. This is distinct from `watching`: a background
agent is *real progress* delegated by the session, whereas watching is a
live monitor passively observing something else. Precedence is
`agents > watching > idle` — if a session somehow has both (e.g. a
background agent that itself launched a monitored Bash command), `agents`
wins.

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

**Stray-working guard must re-derive, not mirror.** The finishing background
agent is itself what fires `SubagentStop` → `working` for that actor (see
"Pending-input set" below for the stray-working guard this hits). Observed
live: the guard originally mirrored the logical-state file straight back
(`idle|watching|agents) effective_status="$_logical"`), which is correct for
`watching` (a monitor's exit isn't itself a hook event, so nothing else ever
re-checks it) but wrong for `agents` — the finishing agent's *own*
SubagentStop is exactly the moment its transcript goes stale, yet the guard
was reading the stale pre-computed value instead of re-checking liveness. Net
effect: the tab stuck on ⚙️ for however long it took the next unrelated hook
(a fresh prompt) to fire. The fix factors the idle→refinement logic into
`_resolve_idle_refinement` (agents > watching > idle, live-checked) and calls
it from BOTH the initial idle-upgrade path and this guard, so a stray
subagent `working` re-derives current liveness instead of trusting the file.
`watching`'s behavior is unaffected: `_resolve_idle_refinement` still finds
the same live monitor marker either way, since re-deriving is a superset of
mirroring when the underlying signal hasn't changed.

**Re-deriving still isn't enough — a finishing agent's own transcript is still
"fresh" at re-derive time.** The fix above stopped the guard from *mirroring*
a stale value, but re-checking liveness still read `agents` back in practice
(observed live: the tab stuck on ⚙️ for 6+ minutes with zero intervening
hooks). Root cause: `_count_live_agents`'s freshness check
(`mtime within CCG_AGENTS_FRESH_SEC`, default 60s) can't distinguish "still
writing" from "wrote its last byte one second ago" — a subagent's transcript
mtime is only a second or two old at the exact instant its own `SubagentStop`
fires, comfortably inside the 60s window. So the stray-working guard's
re-derive counted the very agent whose termination triggered it as still
live, and re-confirmed `agents`. The state only cleared once that transcript
aged *past* 60s on some later, unrelated hook — matching the reported
symptom exactly. The fix: `_count_live_agents` takes an optional exclude
parameter (the finishing actor's id, matched against the transcript's
`agent-<id>.jsonl` basename), threaded through `_resolve_idle_refinement`'s
optional third argument. The stray-working guard passes `$actor` (the
current hook payload's `agent_id`) so a subagent's own `SubagentStop`
provably excludes its own file from the count rather than relying on mtime
staleness that hasn't happened yet. The initial idle-upgrade call site never
passes this — it has no "this specific one just ended" signal, only "check
what's live right now" — so its behavior is unchanged. A genuinely live
sibling subagent's transcript is untouched by the exclusion (only the
`agent-<id>.jsonl` matching the specific actor is skipped), so the state
correctly stays at `agents` when other background work is still running.

### Pending-input set (parallel-subagent bell hold)

Subagents (`Agent`/`Task` tool) share the parent's `session_id` but fire their
own hook events. With multiple subagents running, one subagent raising a
permission prompt (`input`) and another finishing a tool call (`PostToolUse` →
`working`) race over the *single* per-session state file — last write wins, so
`working` clobbers the bell within seconds and it can never be answered. (This
is distinct from the `watching` case: N subagents running means the **main agent
is genuinely working** — it's blocked awaiting them — whereas a monitors-only
session is parked. The two must not collapse to the same state.)

The fix keys a **per-actor pending set** at `~/.claude/.ccg/pending/<sid>/`,
one empty file per actor with an unanswered permission request:

- The actor key is the hook payload's **`agent_id`** (verified empirically:
  subagent `PostToolUse`/`PermissionRequest` payloads carry `agent_id` +
  `agent_type`; the main agent's carry neither). The main agent maps to the
  `__main__` sentinel — hex `agent_id`s can never collide with it.
  `transcript_path` is **not** usable as the key: it points at the *parent*
  transcript for subagent events too.
- **`input`** → add this actor's file to the set.
- **`working`** → remove *this actor's* file (match-by-id, not "clear any one"
  — a busy sibling must not clear a different actor's bell), then if the set is
  still non-empty, downgrade the effective status back to `input` so the bell
  holds.
- **`idle` / `end`** → clear the whole set (the turn genuinely ended; the main
  `Stop` can't fire while a subagent is still pending).
- Each actor only ever touches its **own** file, so concurrent subagent
  processes never race on shared state — no lock needed.

The reaper for the no-`PostToolUse` paths: a **denied** permission never runs a
tool, so no `PostToolUse` ever fires for that actor. `SubagentStop` is therefore
wired (in both `settings.json` files) to `tab-title.sh working`, which removes
the actor via the same match-by-id path. Without it a denied subagent's bell
would stick forever. (`agent_id` arrives two ways: as **arg 3** on the
`input` path — `notify.sh` forwards it — and via **stdin `.agent_id`** on the
`working`/`SubagentStop` path that reads the raw hook JSON.)

The flip side of wiring `SubagentStop → working`: a stray `working` can arrive
after the session has already settled. Two observed variants:

- **Stray-late-SubagentStop**: a subagent's terminal event lands a second or two
  after the main agent's `Stop` settled to `idle`, with no pending bell to clear
  (observed: `idle` at T, subagent `working` at T+2s, frozen ⏳ for 28 min).
- **Stray-main-after-end**: a `Stop`/`StopFailure` hook fires after `SessionEnd`
  already removed the logical-state file. The actor is `__main__`, so the old
  subagent-only guard missed it (observed: `end` at T, `__main__` `working` at
  T+0.66s, no-PID bell-state file, frozen ⏳ until the 60-min stale cap).

The `working` branch guards against both:

- **Subagent stray (A)**: when a subagent (`actor=<hex>`) arrives with empty
  pending set and logical state already settled (`idle`/`watching`), mirror it
  back to that settled state. Mid-turn subagent working (logical=`working`) and
  the main agent's own working both pass through.
- **Main-after-end stray (B)**: when `__main__` arrives with empty pending set
  and the logical-state file is **absent** (deleted by the prior `end` handler),
  suppress to `idle`. The distinguisher is the absent file: in real sessions
  `SessionStart` always fires `idle` (which creates the file) before any
  `working`, so absent means post-end. The main agent's legitimate start-of-turn
  `working` always arrives while the file exists (containing `idle`), so it
  still passes through.

This is why the logical-state file (`~/.claude/.ccg/sessions/<sid>`) is read in
the pending-set block, not just for event-log dedup.

Crash cleanup: a session that dies without firing `idle`/`end` leaks its pending
dir. `sweep-bell-state.sh` hard-expires any pending dir untouched for 12h
(mirrors the state-file cap; tidy-up only, no menubar refresh). Sandbox via
`CCG_PENDING_DIR`.

#### Pre-bell state restore

Answering a bell used to unconditionally drop the tab into `working` once the
pending set emptied — correct for the common case (main agent was mid-turn)
but wrong whenever the bell interrupted a *non-working* idle-family state.
The concrete trigger: a backgrounded subagent (`agents` state — see
"Agents-running state" below) raises its own permission prompt. The main
session was never "working" in the ⏳ sense; it was idling on a still-running
background agent. Once that prompt is answered, forcing `working` painted a
wrong tab state until some unrelated later hook happened to correct it.

The fix snapshots the logical state in force at the **first** bell of a batch
into a flat file, `~/.claude/.ccg/pending/<sid>.prebell` (a sibling of the
`<sid>/` pending-set directory, not inside it — so it survives independently
of which actor files come and go). Rules:

- **`input`, pending set was empty** (first bell in the batch): read the
  current logical-state file and snapshot it to `<sid>.prebell`, unless it's
  already there. A *second*, concurrent bell (a sibling subagent's own prompt)
  must NOT overwrite this — the first bell's snapshot is the one true
  pre-interruption state for the whole batch, and by the time the second bell
  fires the logical state is already `input` (not useful to snapshot).
- **`working`, pending set now empty AND a snapshot exists**: consume the
  snapshot (read + delete) and, if it was `watching` or `agents`, re-derive
  that refinement **live** via `_resolve_idle_refinement` rather than
  mirroring the stale value back — same "re-derive not mirror" rationale as
  the stray-working guard, since the snapshotted background agent/monitor may
  have finished during the wait. If the snapshot was plain `idle` (no live
  refinement) or `working`, fall through to the default `working` — a bell
  that interrupted genuinely idle or working state legitimately means new
  work is starting once it's answered.
- Deliberately **not** excluding the resolving actor's own transcript in this
  path (unlike the stray-working guard's exclude parameter): a subagent whose
  permission request was just *granted* usually keeps running, so its
  transcript is genuinely fresh, and excluding it would wrongly downgrade
  `agents` on every granted-permission tool call. The narrow miss — a
  *denied* permission causing that subagent to stop immediately with no other
  live agents — self-corrects via the sweep's idle-refinement pass within
  ~30s (see "Agents-running state" below), the same backstop that already
  exists for the fully-quiet-session gap.
- **`idle` / `end`**: also remove any leftover `<sid>.prebell`, mirroring how
  the pending-set directory itself is cleared.

`sweep-bell-state.sh`'s pending-dir hard-age pass globs `-type d`, which
doesn't match this flat file, so it separately globs `-type f -name
'*.prebell'` to reap one left behind by a crashed session.

### Deferred completion notification (agents-gated Stop notification)

The `Stop` hook's "Task completed" `notify.sh` call fires whenever the main
agent's turn ends — including when a backgrounded Agent/Task/Workflow
subagent is still running (the tab-title `agents` state). That's misleading:
the main turn paused, but the fleet isn't actually done, and notifying at
that moment trains the user to check in on false-positive "done" pings.

`notify.sh` accepts an optional 5th argument, `gate`. When called with
`gate=agents` (the Stop hook's call site: `notify.sh '✅' 'Task completed' ''
'' agents`), it checks the same liveness signal `tab-title.sh`'s
`_count_live_agents` uses — a fresh (`CCG_AGENTS_FRESH_SEC`, default 60s)
subagent transcript under `~/.claude/projects/*/<session_id>/subagents/
*.jsonl` — and exits silently before sending anything if one is found. Other
call sites (`PermissionRequest`, `StopFailure`) don't pass `gate`, so they're
never suppressed.

Suppressing outright would create a silent gap: nothing else was watching for
the background agent to actually finish. The counterpart lives in
`sweep-bell-state.sh`'s existing logical-state idle-refinement pass (see
"Agents-running state" above) — the same pass that already rewrites a
session's logical state from `agents` to `idle` once the subagent transcript
goes stale now also calls `notify.sh '✅' 'Background task completed'` on
that specific `agents → idle` edge (not `watching → idle`, not `idle → idle`
no-ops). This pass already runs every ~30s via the SwiftBar plugin regardless
of bell mode, so it's the natural place to catch "background work just
finished" without adding a new poller. `cwd` for the notification's subtitle
is looked up from the most recent non-empty `cwd` field logged for that
session in `events.jsonl`, since the logical-state file itself carries no cwd.

### Refresh gating

`tab-title.sh` compares the desired state file against the on-disk state
file and only fires `refresh-menubar.sh` when something actually changed.
This is important because `PostToolUse` fires after every tool call and sets
status=working; without gating, every tool use would trigger a plugin refresh.
The gate:

- `input`: fire only if file didn't exist or content differs.
- `idle` / `working`: fire only if the file existed and was removed.
- `query`: never fires; read-only path.

### Event log dedup

`events.jsonl` must record real transitions only — `PostToolUse` fires after
every tool call, so a naive append would flood the log. `tab-title.sh`
keeps a per-session "logical state" file at `~/.claude/.ccg/sessions/<sid>`
and only appends to `events.jsonl` when the new state differs from that file.
The file is two lines: **line 1 the state name, line 2 the ancestor claude
PID** (the same PID stored on line 3 of bell-state files). Line 2 lets
`sweep-bell-state.sh` reconcile dead sessions back into the event log — see
"Stale-state cleanup" below. All readers (`head -n1` dedup here, the
stray-subagent guard) take only line 1, so the added PID line is transparent
to them. On `end`, the per-session file is removed so a future `SessionStart`
for the same `session_id` would re-emit `idle`. A pure `end` with no prior
state is dropped to avoid zombie entries from stray hook invocations.

This layer is intentionally independent of bell mode: in `notifs` mode the
bell-state file isn't written for `idle`/`working`, but the event log still
gets every transition. Sandbox via `CCG_EVENT_LOG` and
`CCG_SESSION_STATE_DIR` env vars (the validator does this).

### Stale-state cleanup

A session can end without firing `end` — process killed, Ghostty tab
closed mid-prompt, macOS reboot while the SessionEnd hook is mid-flight.
Its state file would otherwise linger as a phantom dropdown entry.
`sweep-bell-state.sh` handles this with a hard-age pass: any state
file older than 12 h is deleted unconditionally. The graceful path is the
SessionEnd hook calling `tab-title.sh end`, which removes the file the
moment a session exits cleanly; the sweep only matters for crashes and
similar irregular exits.

Faster than the 12 h cap, a **PID-liveness pass** prunes a state file the
moment its owning claude PID (line 3) fails `kill -0`. A file with **no PID**
can't be `kill -0`'d — under the current hooks this is either a pre-PID legacy
file or a rare `_find_claude_pid` failure (the claude ancestor had already
exited when the hook fired, e.g. a fleet session torn down mid-write). Since
every live session writes a PID, a no-PID file untouched past
`NO_PID_STALE_MIN` (default 30 min, override `CCG_NO_PID_STALE_MIN`) is stale
and gets reaped — so a stuck "working" tile clears from the menubar in 30 min,
not 12 h. A *fresh* no-PID file is kept (a live session may rewrite it with a
PID on its next transition). The logical-state reconciliation pass uses the
same `NO_PID_STALE_MIN` for its no-PID fallback, so the menubar and dashboard
drop these phantoms in lockstep.

An earlier version of the sweep also ran an "AX-verified" pass that
queried Ghostty's tab tree via AppleScript and pruned any state file
whose title was missing. We removed it because the AppleScript query
races with Ghostty's own tab-bar redraws and intermittently returns
partial tab lists (empirically, ~14% of queries omit a tab; ~1% omit
multiple). That made the pass spuriously delete state files for live
idle sessions, so the menubar would silently lose entries over time.
The 12 h cap is the trade-off: phantoms can linger up to 12 h, but
real sessions are never wrongly evicted.

The sweep is dispatched in the background by the plugin after it emits
output, so it never blocks menubar rendering. When it prunes anything, it
nudges SwiftBar so the dropdown reflects reality on the next run.

#### Logical-state reconciliation (dashboard ↔ menubar convergence)

The menubar and the dashboard once disagreed badly on "right now" (e.g.
menubar showing ~5 live sessions, dashboard ~39). The cause is an
**asymmetry in liveness signals**:

- The **menubar** reads bell-state *files*, which the sweep above actively
  *deletes* the moment the owning claude PID dies (`kill -0` on line 3). Dead
  sessions vanish within one sweep cycle.
- The **dashboard** reads `events.jsonl`, an **append-only log with no
  reaper**. It only learns a session ended when an `end` line is appended,
  and that only happens if the `SessionEnd` hook fires `tab-title.sh end`. A
  crash/kill/closed-tab/reboot skips that hook, so the session's last logged
  state lingers as `working`/`idle` for the full 12 h dashboard window. The
  dashboard is browser JS fetching one file over HTTP — it **cannot** probe a
  PID or list a directory, and a timestamp alone can't distinguish a
  live-but-quiet session (event-log dedup means 40 min of work logs one
  `working` line) from a dead one. So liveness must be reconciled *into the
  log*, server-side.

Raising the dashboard's right-now window (a past "fix") only traded the
opposite bug (live-quiet sessions dropping off) for this one. The real fix is
a sweep pass that emits a **synthetic `end`** for any logged-but-dead session,
using the same PID-death signal the bell-state pass uses — so both layers
converge by construction. For each `~/.claude/.ccg/sessions/<sid>` file whose
line-1 state ≠ `end`:

- **line-2 PID alive** → keep. **PID dead** → append `end` + remove the file.
- **no PID (legacy 1-line file)** → can't prove death, so fall back to the
  12 h hard-age cap.

The synthetic `end`'s `ts` is **`min(now, mtime + 30 min)`**, not `now`. The
logical-state file's mtime equals the last logged transition (dedup only
rewrites it on real changes), and `mtime + 30 min` matches the dashboard's
existing trailing-span cap (`TRAILING_CAP_SEC` in `spanFor`) — so historical
totals and the timeline chart are unchanged; only the right-now phantom
disappears. Emitting at `now` would retroactively inflate the dead session's
working-time. This pass runs even in `notifs` mode (where no bell-state file
exists for working/idle), which is why it keys off the logical-state file, not
the bell-state file. Sandbox via `CCG_SESSION_STATE_DIR` and `CCG_EVENT_LOG`.

#### `end` is terminal until resume — dashboard straggler guard

Even with the reconciliation above, the dashboard's "working" card kept
drifting above the menubar. Cause: `events.jsonl` is append-only, and a
`working`/`input`/`watching` event sometimes lands **after** a session's
`end` — a `SubagentStop`/`PostToolUse` straggler firing during teardown, or
the sweep's own synthetic `end` whose **integer-second** ts lost a same-second
tie to a *fractional* straggler (e.g. synthetic `end` at `670.000` vs a stray
`working` at `670.110`). The dashboard's old "latest event by ts" rule then
read the straggler as the live state and counted a dead session as `working`
(and painted a 30-min phantom open span in the timeline).

The fix lives in `dashboard.html`'s `stripStragglers()` (sliced by
`// <stripStragglers>` markers for the validator): walk each session's events
in ts order, mark `ended` on `end`, **clear it on `idle`**, and drop any
non-`idle` event seen while ended. `end` is therefore terminal — but a fresh
`idle` (a `SessionStart`) reopens the session, so `claude --continue` /
`--resume`, which **reuse the session id**, keep working. This one rule also
absorbs the synthetic-`end` tie collision, so the sweep's exact ts no longer
has to win the race. It's applied in all **three** per-session loops
(`compute` + both daily-trend functions) so a straggler can neither inflate a
right-now card nor paint a phantom span; the validator asserts all three call
sites exist. A blanket "exclude any session that ever emitted `end`" would be
simpler but **wrong** — it would drop resumed sessions, which are legitimately
live.

### Plugin display swap: ` | ` → ` — `

State file titles contain ` | ` (from `Claude Code | <dir>`). SwiftBar uses
` | ` as its parameter separator, so the plugin swaps to ` — ` in the
visible display text. `param1=` retains the original 🔔-prefixed title for
`focus-ghostty-tab.sh`'s contains-match.

### Dashboard north-star metric: "Fleet stalled on you"

The dashboard's headline lever is **fleet-stall share**, not a per-bell
latency. The reasoning behind every choice in its definition (arrived at
empirically against real `events.jsonl` data — re-deriving it from scratch
is expensive, so it's recorded here):

- **Why not median/p90 per bell.** Any central tendency over "the bells that
  survive" suffers two biases the user actively hits: *survivorship* (automating
  trivial bells removes the easy members, so the median of what's left rises
  even at constant behavior) and *queueing inflation* (more parallel agents →
  each bell's latency includes time spent serving other bells, Little's Law).
  Both make the number a moving goalpost that punishes good behavior. Median and
  p90 are kept only as **diagnostics** (bottom row), never as the goal.

- **The metric.** Per 5-min bin: a bin is *stalled* when ≥1 session is awaiting
  input AND zero sessions are working. Share = stalled bins ÷ **bell-pending
  bins** (bins with ≥1 session awaiting input). Reads as "of the time I was on
  the hook, how much did I waste with no agent making progress." It is
  *composition-invariant* (trimming easy bells doesn't move it) and
  *concurrency-correct* (wall-clock bins, not summed-per-session, so more agents
  don't inflate it) — the two properties median/p90 lack.

- **Watching counts as idle.** A `watching` session is parked; only a background
  monitor is alive, which isn't *your* forward progress. So `watching` is
  excluded from both the stalled numerator and the engaged denominator — a bell
  pending while only a monitor ticks still counts as a stall. (Chosen
  deliberately over treating watching as activity.)

- **Agents-running counts as engaged, the opposite of watching.** A session in
  the `agents` state has a background Agent/Task/Workflow actually delegating
  work, not just observing — real progress toward the fleet's goal. So a bell
  pending while a background agent runs elsewhere is NOT a stall: `agents` is
  added alongside `working` in the stalled-bin check (`w === 0 && ag === 0`).
  This is the deliberate mirror image of the watching decision above — the two
  states look superficially similar (both are refinements of `idle`) but have
  opposite treatment because one is passive observation and the other is
  active delegated work.

- **Denominator = bell-pending bins, not "any engaged time."** The
  bell-pending denominator gives a readable dynamic range (~20–60% on real days)
  vs. the flat ~4–5% you get dividing by all-engaged time, which under-reads as
  a lever. Verified: same stalls read 5% (engaged denom) vs 27% (bell-pending
  denom) on the same day.

- **The gate is on bell-pending bins** (`STALL_MIN_SAMPLE = 12` = 1 h on the
  hook), NOT on bell count, session count, or work time. This is the metric's
  own denominator, so gating on it is the textbook precision gate (standard
  error of a proportion is governed by *its* `n`). The empirical clincher:
  bell-count/session/work-time gates are *anti-correlated* with reliability on
  real data — e.g. 05-13 (67 bells, 387 work-min, but only 9 bell-pending bins →
  noisy 67%) vs 05-24 (25 bells, 87 work-min, but 220 bell-pending bins → the
  genuine worst day at 100%). Any activity-based gate hides 05-24 (low bells)
  while showing 05-13 (high bells) — exactly backwards. Only the
  bell-pending-bin gate ranks them correctly. Below the floor the 24h card shows
  `—` and chart days render blank (tooltip: "Too few bells to score").

- **Bin size = 5 min.** The stall % is bin-invariant from 1–10 min on real data
  (26/28/27/25%), so the choice isn't an artifact. 5 min is the sweet spot
  because its gate floor lands at a meaningful 1 h (12 bins) — at 1 min the floor
  would be a useless 12 min, at 15 min the dominant-state rule erases fast bells
  entirely (a 4-min bell never dominates a 15-min bin → on-the-hook collapses to
  0). Finer bins (2 min) capture sub-5-min bells more faithfully but cost chart
  smoothness; only switch if rewarding sub-5-min responsiveness becomes a goal.

- **Verdict banner.** The dashboard names the single highest-leverage action,
  not just a number. `verdictFor(stall, conc, workingSecs)` is a pure function
  (sliced out by `// <verdictFor>` markers for the validator) with precedence:
  gated → stall-critical (≥50%) → stall-high (≥25%) → fanout (stall healthy but
  concurrent share <30%) → good. **Stall dominates concurrency** because a
  stalled fleet is wasted wall-clock you caused, whereas low concurrency is only
  opportunity cost.

- **Companion metric: concurrent share** (push *up*) is the mirror of fleet-stall
  (pull *down*) — share of working-time bins with ≥2 sessions in parallel.

## Scripts

`hooks/` contains scripts that are **installed globally** (`~/.claude/hooks/`).
`.claude/hooks/` contains scripts that are **project-local** (used only when
Claude runs in this repo, referenced from `.claude/settings.json`).

| Script | Purpose | Triggered by |
|--------|---------|--------------|
| `hooks/tab-title.sh` | Sets the terminal tab title via `terminalSequence` JSON output (Claude Code 2.1.141+) with a direct `/dev/tty` write as fallback; writes/removes `~/.claude/bell-state/<session_id>`; upgrades idle to `watching`/`agents` when a live monitor or background Agent/Task/Workflow is detected; appends real state transitions to `~/.claude/.ccg/events.jsonl`; fires `refresh-menubar.sh` on actual state change | `SessionStart`, `UserPromptSubmit`, `PostToolUse`, `Stop`, `notify.sh` (for `input`) |
| `hooks/notify.sh` | Sends `terminal-notifier`; skips if user is already on that tab; routes to `tab-title.sh` for title updates; optional `gate=agents` 5th arg suppresses the notification while a background Agent/Task/Workflow subagent is still live for the session | `Notification`, `Stop` |
| `hooks/focus-ghostty-tab.sh` | AppleScript to focus a Ghostty tab by title-contains match; works across windows and single-tab windows | Notification `-execute`, SwiftBar dropdown |
| `hooks/refresh-menubar.sh` | `open -g swiftbar://refreshallplugins`; silent no-op if SwiftBar isn't installed | `tab-title.sh` on state change; `sweep-bell-state.sh` after pruning |
| `hooks/sweep-bell-state.sh` | Prunes bell-state files (dead PID, or >12 h); reconciles dead-but-unended sessions into `events.jsonl` via synthetic `end` events so the dashboard matches the menubar; fires a deferred "Background task completed" notification via `notify.sh` on the `agents → idle` logical-state edge | Background job dispatched by the SwiftBar plugin after each run |
| `.claude/hooks/fetch-changelog.sh` | Fetches `https://code.claude.com/docs/en/changelog`, strips HTML via `textutil`, caches to `~/.claude/.ccg/changelog.md` (12 h TTL) | `SessionStart` (project-only, via `.claude/settings.json`) |
| `hooks/dashboard-server.sh` | Manages the metrics-dashboard HTTP server (`start`/`stop`/`status`/`toggle`); writes `~/.claude/.ccg/server.pid` and opens browser on start | SwiftBar dropdown entry click |
| `swiftbar/ghostty-bells.30s.sh` | Reads state dir, emits dropdown (sessions + dashboard entry), dispatches sweep in background | SwiftBar 30 s poll + push-refresh URL |
| `.ccg/dashboard.html` | Single-file metrics dashboard; fetches `events.jsonl` over HTTP every second | Served via `python3 -m http.server` from `~/.claude/.ccg/` |
| `.ccg/config.json` | Mode config (`{"mode":"notifs|off|always-on"}`); shipped with `always-on` | Read by `tab-title.sh` and the SwiftBar plugin |
| `tests/validate.sh` | End-to-end validator; see below | Manual / CI |

## Environment variables

- **`BELL_TRACE=1`** — enables timestamped tracing in every script on the
  chain. Zero overhead when unset (each `__trace` function early-returns on
  the first line). Enable for a whole session by adding `"BELL_TRACE": "1"`
  under `env` in `~/.claude/settings.json`; for a one-off invocation, prefix
  the command: `BELL_TRACE=1 ~/.claude/hooks/tab-title.sh idle <session_id>`.
- **`BELL_TRACE_LOG`** — override the trace log path (default
  `/tmp/bell-trace.log`). The validator uses this to sandbox.
- **`BELL_STATE_DIR`** — override the state directory (default
  `~/.claude/bell-state`). The validator uses this to sandbox; production
  hooks don't set it.
- **`BELL_CONFIG`** — override the config-file path (default
  `~/.claude/.ccg/config.json`). The validator uses this to sandbox.
- **`CCG_EVENT_LOG`** — override the dashboard event log path (default
  `~/.claude/.ccg/events.jsonl`). The validator uses this to sandbox.
- **`CCG_SESSION_STATE_DIR`** — override the per-session logical-state
  directory used for event-log dedup (default `~/.claude/.ccg/sessions`).
  The validator uses this to sandbox.
- **`CCG_PENDING_DIR`** — override the pending-input set directory (default
  `~/.claude/.ccg/pending`). One subdir per session, one file per actor with
  an unanswered permission request; see "Pending-input set" above. The
  validator and `sweep-bell-state.sh` both honor it.
- **`CCG_NO_PID_STALE_MIN`** — staleness cap in minutes (default `30`) for
  state files that carry no claude PID, used by `sweep-bell-state.sh` for both
  the bell-state PID-liveness pass and the logical-state reconciliation no-PID
  fallback. A no-PID file untouched longer than this is reaped (menubar) /
  synthetically ended (dashboard). See "Stale-state cleanup".
- **`CCG_CLAUDE_PID`** — short-circuit the watching-detection walk in
  `tab-title.sh`. When set, `_find_claude_pid` returns this value
  immediately instead of walking up from `$PPID` looking for a `claude`
  ancestor. The validator sets it to `999999` (a dead PID) globally so
  no test accidentally walks up to the real claude process the validator
  is running under, and overrides it per-test in the watching section.
  Not used in production hook invocations.
- **`CCG_NOTIF_EXPIRY_HOURS`** — how many hours before a `ccg-*` macOS
  notification is auto-removed by `sweep-bell-state.sh` (default `12`). Set to
  `0` to disable expiry entirely.
- **`CCG_DIR`** — override the dashboard-server's working directory
  (default `~/.claude/.ccg`). Determines where the PID file and server
  log live, and the directory `python3 -m http.server` serves.
- **`CCG_DASHBOARD_PORT`** — override the dashboard server port (default
  `8765`).
- **`GHOSTTY_HOOKS_DIR`** — override the hooks directory path used by the
  SwiftBar plugin (default `~/.claude/hooks`).
- **`CCG_PROJECTS_DIR`** — override the Claude Code projects directory
  searched for subagent transcripts (default `~/.claude/projects`), used by
  `_count_live_agents` in both `tab-title.sh` and the SwiftBar plugin to
  detect background Agent/Task/Workflow liveness. The validator uses this to
  sandbox; production hooks don't set it.
- **`CCG_AGENTS_FRESH_SEC`** — freshness window in seconds (default `60`) for
  a background-agent transcript's mtime before `_count_live_agents` no longer
  counts it as live. See "Agents-running state".

## Validator

`tests/validate.sh` covers: prerequisites, state-file lifecycle,
title-write to parent's TTY (regression guard against the no-controlling-
terminal hook environment introduced in Claude Code 2.1.139), refresh
gating (fire vs skip), event-log dedup + JSON shape, `refresh-menubar.sh`
gate paths, plugin output (SF Symbol + count, param1 preservation,
` | ` → ` — ` swap, empty-dir hiding), dashboard-entry toggle (open/stop
based on PID file, stale-PID handling, position after sessions),
`dashboard-server.sh status` modes, stale-file sweep (hard-age prune
at 12 h, fresh files protected, PID-liveness prune for orphaned sessions,
fresh no-PID files kept but stale ones reaped past `NO_PID_STALE_MIN`,
refresh-after-prune), logical-state
reconciliation (a dead-PID session gets a synthetic `end` appended to
`events.jsonl` and its logical-state file removed; a live-PID session is
untouched; the synthetic `end` ts is the trailing-span cap `mtime + 30min`,
not `now`; stale no-PID files reaped past `NO_PID_STALE_MIN`; `tab-title.sh`
writes a 2-line state+pid logical-state file and dedup still keys off line 1),
watching state
(3-line state-file shape with claude PID on line 3 for all write states,
event log records `watching`, notifs mode suppresses the state file,
plugin downgrades stale watching files to idle, `Watching` section
ordered between `Working` and `Idle`), agents-running state (⚙️ prefix on
the state file, event log records `agents`, notifs mode suppresses the
state file, precedence over `watching` when both a fresh subagent
transcript and a live monitor marker are present, plugin downgrades a
stale-transcript agents file to idle, `Agents running` section ordered
between `Working` and `Watching`, the finishing agent's own
`SubagentStop` re-derives live state instead of sticking on the stale
logical-state value, and that re-derive excludes the finishing agent's OWN
transcript — which is still mtime-fresh at that exact instant — from the
liveness count, while a genuinely live sibling transcript still keeps the
state at `agents`), `BELL_TRACE` toggle (off = 0
bytes, on = populated), dashboard verdict logic (slices `verdictFor` from
`dashboard.html` by its `// <verdictFor>` markers and runs it under Node
across every branch + precedence boundary; asserts `renderVerdict` has a
`case` for each kind), dashboard straggler handling (slices
`stripStragglers` by its `// <stripStragglers>` markers and runs it under
Node: `end` is terminal so a post-`end` straggler or a tie-colliding synthetic
`end` reads as ended, while a fresh `idle` reopens a resumed session; asserts
all three per-session loops route through it), stray-working guard
(a stray `working` — subagent arriving after `idle`, or `__main__` arriving
after `end` deleted the logical-state file — must not resurrect `working`;
the main agent's start-of-turn `working` and a real mid-turn subagent `working`
both still pass through), pre-bell state restore (a bell that interrupts
`agents`/`watching` restores that refinement — re-derived live — instead of
defaulting to `working`; a second concurrent bell does not clobber the first
bell's snapshot; a bell interrupting plain `idle` or genuine mid-turn
`working` still defaults to/stays `working`; the snapshot file is consumed
on restore and cleared on `idle`/`end`), the notify.sh agents-gate (a live
subagent transcript suppresses the `gate=agents` notification entirely; a
stale or absent transcript lets it through; call sites that omit `gate`
are never suppressed even with a live transcript present), the deferred
completion notification (`sweep-bell-state.sh`'s logical-state
idle-refinement pass fires a `Background task completed` notification
specifically on the `agents → idle` edge, and does not fire one on
`watching → idle` or any other transition), and end-to-end
`input`→state→plugin latency.

It sandboxes via `BELL_STATE_DIR` pointing at a temp dir, so it never touches
real session state.

```sh
./tests/validate.sh            # failures + summary
./tests/validate.sh --verbose  # show every passing check
```

Exit code = number of failures. **Every code change must keep this passing,
and any new observable behavior must get a corresponding check.** If you
can't express the new behavior as a validator check, push back on the
change or lean on `BELL_TRACE` to make it observable first.

## Picking SF Symbols

When choosing an SF Symbol for the menubar (the SwiftBar plugin, status
icons, dashboard entries — anything rendered with `sfimage=…` or `:name:`
syntax), DEFAULT to rendering a temporary preview plugin so the user can
see all candidates rendered live in their menubar before deciding. Do not
ask the user to pick from a written list of names — SF Symbols don't read
the same way in prose as they do at menubar size, and the visual will
change the answer.

The temp-plugin pattern:

1. Drop a one-shot plugin into the **actual plugin directory** — the same
   directory the real plugin (`ghostty-bells.30s.sh`) already lives in
   (`~/swiftbar` on this machine; confirm with
   `defaults read com.ameba.SwiftBar PluginDirectory` if unsure — see the
   gotcha below, this is NOT `~/Library/Application Support/SwiftBar/`).
   Name it so it sorts AFTER the real plugin (e.g. `zzz-symbol-demo.5s.sh`)
   so the menubar stays mostly normal.
2. The plugin's title line should put every candidate side-by-side using
   the `:name:` shorthand, e.g.
   `echo "(picking) :eye: :binoculars: :waveform.path.ecg: :eye.circle: | font=.AppleSystemUIFontBold"`.
3. The dropdown should list each candidate with `sfimage=<name>` and a
   short description of when it'd fit, so the user can see each one
   rendered at dropdown size too.
4. Refresh SwiftBar (`open -g swiftbar://refreshallplugins`) and ask the
   user to look at the menubar.
5. AFTER the user picks, remove the demo plugin file (and any transient
   state files you wrote to make a real state visible) and refresh again.

Always offer at least 3–4 candidates including one that's a clear
thematic fit and one that's deliberately different in style (filled vs
outline, abstract vs literal), so the comparison is informative rather
than confirming a single guess.

## Gotchas

- **`/bin/bash` is 3.2.** The deployed scripts run under the kernel's
  interpretation of the `#!/bin/bash` shebang, which is the system bash.
  Avoid features from bash 4+. In particular, apostrophes inside quoted
  heredocs (`<<'EOF'`) confuse bash 3.2 — use `of AppleScript` instead of
  `AppleScript's`.
- **`pgrep -x Ghostty` is unreliable.** Ghostty's comm appears as `ghostty`
  (lowercase) but `pgrep -x` doesn't consistently match it on macOS. Use
  `osascript -e 'tell application "System Events" to return (exists process
  "Ghostty")'` instead.
- **SwiftBar's first-launch picker cannot be skipped.** The `defaults` key
  it actually reads is `PluginDirectory` (with security-scoped bookmark),
  not `PluginDirectoryPath`. Plain `defaults write` doesn't preseed it.
- **The SwiftBar plugin dir is `~/swiftbar`, not
  `~/Library/Application Support/SwiftBar/`.** The latter is SwiftBar's own
  app-support folder (it exists, is writable, and looks plausible) but
  SwiftBar never scans it for plugins — a script dropped there silently
  never appears. Always verify with
  `defaults read com.ameba.SwiftBar PluginDirectory` before writing a demo
  or real plugin file, rather than assuming the path.
- **Hooks can't `open -g` directly during rapid bursts.** All our hook-side
  `open` calls are synchronous (not backgrounded) so we get an exit code
  in trace; SwiftBar's URL-scheme dispatch is fast enough that this adds
  ~50 ms, not meaningful.
- **Menubar click still uses AX.** `focus-ghostty-tab.sh` relies on
  AppleScript, which has the AX lag. In practice the user clicks seconds
  after the bell appears, by which time Ghostty has been fronted enough for
  AX to update. If a click ever fails to find the tab, that's the reason.
