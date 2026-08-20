```
███████╗██╗   ██╗███████╗██╗   ██╗███████╗
██╔════╝╚██╗ ██╔╝╚══███╔╝╚██╗ ██╔╝██╔════╝
███████╗ ╚████╔╝   ███╔╝  ╚████╔╝ █████╗
╚════██║  ╚██╔╝   ███╔╝    ╚██╔╝  ██╔══╝
███████║   ██║   ███████╗   ██║   ██║
╚══════╝   ╚═╝   ╚══════╝   ╚═╝   ╚═╝
```

# Syzyf

**An OpenCode addon that keeps rolling the boulder until the job is actually done.**

Syzyf drives [opencode](https://opencode.ai) in a loop. You write a **Definition of Done**, and it
works towards it across as many fresh sessions as the job needs — then refuses to stop until an
independent, read-only verifier confirms three times in a row that every rule is met.

The verdict is binary. Either every rule is met, or the job is not done. No score, no percentage, no
partial credit.

![Screenshot of Syzyf in use](syzyf.jpg)

---

## Why this exists

A single agent session has a bounded context window. Any job bigger than that window ends the same
way: the agent runs out of room, writes a confident summary, and stops with the work half finished.

Syzyf assumes that will happen and builds around it:

- **Each cycle is one fresh session.** Nothing is carried in conversation memory. State travels
  through the repository on disk plus a handoff notes file.
- **The worker never grades itself.** A separate verifier session, with editing disabled, judges the
  repository from the source data and the produced artifacts. It is explicitly told that the handoff
  notes are unverified claims, not evidence.
- **One pass is not enough.** By default three consecutive passing verdicts, each from a brand-new
  verifier session, are required. Any single failure resets the streak to zero.

That last part is the whole point. The most expensive failure mode of an agent loop is not a stall,
it is a weak model deciding it is finished. A stalled loop is recoverable; a false pass is not.

---

## How a cycle works

```mermaid
flowchart TD
    A[Start cycle] --> B[New work session<br/>full tool access]
    B --> C[Work turn:<br/>read definition + handoff notes,<br/>fix the first unmet rule,<br/>append findings as you go]
    C --> D[New verifier session<br/>read-only, no memory of anything]
    D --> E[Verify turn:<br/>enumerate the source set,<br/>judge every rule from files]
    E --> F{Verdict}
    F -->|fail| G[Gaps + next directive<br/>streak reset to 0]
    G --> A
    F -->|pass| H{Streak reached?}
    H -->|no| I[Re-audit directive:<br/>try to prove the pass wrong]
    I --> A
    H -->|yes| J[Done]
```

The verifier never sees the work transcript. Its prompt carries only the Definition of Done and the
cycle number, and it must open the actual files with `read`, `glob`, `grep`, and `list` before it may
judge a rule. For any rule quantified over a set ("every packet", "all files"), it has to enumerate
that set **from the source** and report the source count against the covered count. An enumeration it
cannot finish is a gap, not a pass.

After a passing verdict that has not yet reached the streak, the next work turn is not idle — it is
told to attack the verdict: enumerate the set again, spot-check finished entries in detail, hunt for
placeholder bodies and stub sections, and fix whatever it finds.

---

## Requirements

| Thing | Why | Notes |
|---|---|---|
| Python 3.10+ | runs `install.py` | only for setup |
| [Bun](https://bun.com/install) 1.3+ | runs `dod-loop.ts` | installed by `install.py` |
| [opencode](https://opencode.ai) 1.18.18 | the TUI, which is also the server | installed by `install.py`, pinned |
| An opencode login | model access | `opencode auth login`; defaults to Zen free models |
| Windows | `start_syzyf.bat` | the loop itself is platform-neutral, see [Running without the batch file](#running-without-the-batch-file) |

---

## Install

```
python install.py
```

Double-clicking it works too. It installs Bun, installs the pinned opencode, runs `bun install`,
checks that you are authenticated, and verifies that the source folder your Definition of Done names
actually exists on this machine.

It never touches `.opencode/dod.md` or anything under `projectfiles/` — those are your content.

```
python install.py --check-only     report status, install nothing
python install.py --no-pause       do not wait for a keypress
```

If Bun or opencode were just installed, open a **new** terminal so `PATH` picks them up.

---

## Write your Definition of Done

`.opencode/dod.md` is the template every run starts from. It has two sections:

```markdown
# 1. Task to perform

Access `C:\path\to\your\source-folder`. This is <what the source is> and it has <what it holds>.
Write a <RECORD> library in `<artifact>.md` in this folder, keyed by <the key you group records by>,
defining every value in every <RECORD>. ...
Everything already known is in one text file at `C:\path\to\your\knowledge-base.txt`; read it first and
treat it as the current knowledge base.
...

# 2. Definition of Done

Work is not done if there is still any <RECORD> with unidentified information
e.g. unknown <FIELD>s purpose. ...

But all <RECORD>s need to have definition of all <FIELD>s. Skipping these is unacceptable
```

Section 1 is what to do, section 2 is how you know it is finished. The split is for your benefit while
writing and editing: **the file is stored and handed to the verifier as one string**, so nothing in the
loop has to care where the boundary falls.

Getting this file right is the one expensive decision here. The loop will chase a badly worded rule
for as many cycles as you give it, and every cycle costs a full context window.

What works:

- **Name the source with an absolute path.** The verifier judges against source data, so it needs to
  find it. `install.py` checks that the path resolves.
- **Name the artifact explicitly.** "Write `packet_library.md` in this folder" is checkable; "document
  the protocol" is not.
- **Quantify.** "Every value in every record" gives the verifier a set to enumerate. Vague rules pass
  too easily.
- **State what does not count as done.** The example spells out that any record with an unidentified
  field means the job is unfinished, and that skipping records is unacceptable.

`.opencode/dod.md` is a **template**. Each run copies it once into its own folder, so editing the
template never retroactively changes what an earlier run was judged against.

---

## Run

```
start_syzyf.bat
start_syzyf.bat "an optional directive that overrides cycle 0"
```

What happens:

1. The review window opens. Pick **New run**, or pick any existing run to resume it, then edit the
   task and the Definition of Done. **Save and launch** writes both boxes back as the one file and
   starts the run; **Quit** launches nothing. Nothing starts until you have approved what this run is
   aiming at.
2. A new run allocates its folder at that point: `projectfiles/00001/`, with the template copied in as
   `definition.md`. Quitting instead never leaves an empty folder behind.
3. The opencode TUI starts and **owns the server** on port 4096.
4. The loop runs against that server until the pass streak is reached, the cycle budget runs out, or
   something breaks.
5. **The review window stays open the whole time.** Saving in it rewrites the live run's
   `definition.md`, and the loop re-reads that file at the start of every cycle.

Both windows are placed for you on the way up: Syzyf down the left edge at full height, the TUI filling
everything to its right, and this launcher console minimised once the loop starts. See
[Window layout](#window-layout).

To watch a cycle: click it in the review window's session list, and the TUI switches to it. `ctrl+p` in
the TUI still works if you prefer it.

> **Do not close the TUI while the loop runs.** That window *is* the server.

### The review window

`definition-gui.ps1`, plain WinForms in a dark theme. It ships with Windows, so there is no dependency
to install and nothing to keep in sync with `package.json`. It does two jobs.

**It picks the run.** Every folder under `projectfiles/` is listed with where it stopped — `cycle 4
passed 1/3  25m ago`, or `prepared, never launched` — so a run that died mid-cycle is resumed by
clicking it. There is no environment variable to set and no need to know which cycle it reached, since
the handoff notes and the repository already hold the state. Hovering a run shows its **original**
definition, from `definition.original.md`, and the `Original` button opens the full text: after a few
mid-run corrections that snapshot is the only remaining record of what the run set out to do.

**It stays open for the whole run.** `Save and launch` becomes plain `Save`, and every save rewrites
the live run's `definition.md`. The loop reads that file at the start of each cycle, so a correction
lands on the next one — useful when you learn something the definition did not anticipate, or when a
rule turns out to be worded so that nothing can ever satisfy it. The cycle already in flight finishes
against the old text, because a turn in progress cannot be re-aimed.

**And once live, the run list becomes a session list.** It refreshes every two seconds from
`GET /session` and `GET /session/status`, newest cycle at the top, and **clicking a row makes the TUI
display that session**:

```
work 12     RUNNING      4s ago
verify 11   idle         2m ago
work 11     idle         6m ago
```

That is one `POST /tui/select-session` to the server the TUI is already running, so it replaces
`ctrl+p` entirely — no keystroke injection, no second TUI window, and no changes to opencode. The
window does not steal focus, on the assumption you keep both windows visible. Hovering a row shows the
session id, which is what `status.ps1` speaks.

Only sessions titled for this run are listed, so the subagent sessions a work turn spawns stay out of
the way; they are still reachable through `ctrl+p` in the TUI. Under `DOD_LOOP_NO_GUI` there is no TUI
to drive, so the list still populates but a click reports that nothing took the jump.

- Both boxes are editable from the moment it opens. `Ctrl+Enter` launches, then saves.
- Saving always writes back the canonical `# 1. Task to perform` / `# 2. Definition of Done` headings,
  so an older single-section definition normalises itself the first time you open it here.
- Saves go to a temporary file that is then moved into place, so a cycle starting mid-save cannot read
  a half-written definition. If it somehow reads an empty one anyway, the loop keeps the copy from the
  previous cycle and logs that it did.
- Before launch, closing the window with the X counts as Quit, never as approval. After launch,
  closing it is just closing a window: **the run keeps going**, and `Esc` is disabled so a stray
  keypress cannot dismiss it.
- An empty Definition of Done is refused: there would be nothing to verify against, so the run could
  never pass.
- Switching runs, or reloading, asks first if you have unsaved edits.

The script is deliberately pure ASCII. Windows PowerShell 5.1 reads a BOM-less script as ANSI, so the
logo is stored as ASCII placeholders and the block characters are substituted in at runtime.

Two switches, neither of which opens a window:

```
powershell -NoProfile -File .\definition-gui.ps1 -Path projectfiles\00001\definition.md -SelfTest
powershell -NoProfile -File .\definition-gui.ps1 -Path projectfiles\00001\definition.md -Normalize
```

`-SelfTest` prints how a definition splits, for when a file does not land in the boxes you expected.
`-Normalize` rewrites it with the canonical headings in place.

To review in a text editor instead, `set DOD_LOOP_TEXT_REVIEW=1`. That path opens `%EDITOR%` straight
away (default `notepad`; `set EDITOR=code -w` works) and asks once, on close, whether to launch. It is
also the automatic fallback on a machine where WinForms will not load.

### Window layout

A run means watching two windows at once, so the launcher arranges them rather than leaving you to drag
them into place every time:

```
+----------------+--------------------------------------+
|                |                                      |
|  Syzyf         |  opencode TUI                        |
|  definition    |  the session you clicked             |
|  + sessions    |                                      |
|                |                                      |
+----------------+--------------------------------------+
   full height          the rest of the screen
```

`layout.ps1 -Plan` computes the split once and hands the same answer to both, because they are drawn by
different processes and computing it twice is how they would end up overlapping. Syzyf gets 32% of the
working area, clamped to 560–760px: past that the text lines get too long to scan, below it the button
row wraps. The launcher console minimises itself when the loop starts, since from that point it is a
transcript and the same text is in `run.log`.

This is a **starting** arrangement only. Nothing re-applies it, so anything you drag stays dragged. To
turn it off entirely, `set DOD_LOOP_NO_LAYOUT=1`.

Placing the TUI is the awkward half. A console window cannot be positioned through a property, only by
`MoveWindow` on its handle, and asking the process you started for that handle does not work: with
Windows Terminal as the default terminal application, the window belongs to a `WindowsTerminal` process
that is no relation of the `cmd.exe` you launched, which reports no main window at all. So `layout.ps1`
snapshots the top-level windows, starts the TUI, and places the one that is new. That works for both
conhost and Windows Terminal, and it deliberately finds nothing when Windows Terminal opens the console
as a *tab* in an existing window — moving that would drag every other tab in it across the screen. When
the window cannot be found, it says so and carries on: the run matters more than the geometry.

Only the primary monitor is used, and the taskbar is excluded. Under display scaling everything stays
consistent because all the processes involved are equally DPI-unaware.

### Why the TUI owns the server

Started as `opencode --port N`, the TUI always spawns its own server in a worker, and `--port` only
tells that worker which port to bind — it never dials an external server.

(1.18.18 does ship a separate `opencode attach <url>` command, which this project has not tested. If it
forwards a remote server's events properly then the arrangement below could be inverted, and closing the
window would stop ending the run. Treat the rest of this section as describing `opencode --port N`.)

The obvious arrangement (`opencode serve` for the loop, a separate TUI to watch it) gives you two
processes with two event buses over one shared store. The TUI can read the loop's sessions, but every
event comes from the *other* server's bus, so the window renders one snapshot and then sits frozen.
It looks like the agent is stuck when it is not.

Inverting it fixes that: the TUI's own worker serves the API and forwards every event to the window,
so pointing the loop at that port makes its sessions stream live. The tradeoff is that closing the
window ends the run.

For an unattended run with no window to protect:

```
set DOD_LOOP_NO_GUI=1
start_syzyf.bat
```

---

## Where the files go

Everything a run generates lives under `projectfiles/<run id>/` and nowhere else.

```
projectfiles/
  00001/
    definition.md           the Definition of Done this run is judged against, editable while it runs
    definition.original.md  what the run was launched with, written once and never edited
    state.md                handoff notes carried between cycles
    run.log                 the full transcript
```

`definition.original.md` is written at the first launch of a run and never again, which is what makes
the review window's tooltip meaningful once the live definition has drifted from it. A run that already
had a `run.log` before this file existed does not get one invented after the fact; the window says so
rather than passing off a later edit as the original.

Run ids are five digits so the folder sorts as plain text, and they iterate: `00001`, `00002`, ...
Session titles use the id too, which is why the TUI picker shows `00001 work 0` and why the review
window can tell one run's sessions from another's.

The whole `projectfiles/` tree is gitignored. It describes whatever job you pointed the loop at, so
it is yours by default.

### The handoff file

`state.md` is the only thing that survives between cycles, and the work turn is told to append to it
continuously rather than at the end — a turn that runs out of context never reaches its own cleanup
step.

It is facts only. The work turn is explicitly forbidden from writing a verdict, a status like "work
complete", or a rule-by-rule evidence section. That rule exists because a run once ended one cycle in:
the work agent wrote "work complete, pending final verification" plus its own evidence section, and
the verifier read the claim as proof. 56 items into a job of about a thousand.

---

## Monitoring

```
powershell -ExecutionPolicy Bypass -File .\status.ps1
powershell -ExecutionPolicy Bypass -File .\status.ps1 -RunId 00003
```

Asks the server directly and reports, for both the work and verify sessions: running or idle, message
count, the last tool used, how long ago, and any pending retry with its reason and due time. A pending
retry is the difference between "thinking" and "blocked for the next two hours". Defaults to the newest
run.

```
powershell -ExecutionPolicy Bypass -File .\preflight.ps1
```

Pre-launch check: is port 4096 in use and by what, are there leftover `opencode` or `bun` processes,
what is in the folder, what runs already exist.

---

## Resuming a run

```
set DOD_RUN_ID=00003
start_syzyf.bat
```

Normally you do not need this: run `start_syzyf.bat` and pick the run in the window. Either way it
reuses that folder, its definition, and its handoff notes, and starts a fresh cycle 0 against whatever
state is on disk — so it does not matter where the previous attempt stopped, whether that was a clean
budget exit, a crash, or a window closed mid-cycle. Nothing is carried in conversation memory, so
there is no broken session to recover.

Setting `DOD_RUN_ID` preselects that run in the window, and is the run used directly when the window is
skipped.

---

## Configuration

All optional, all environment variables.

### The loop

| Variable | Default | What it does |
|---|---|---|
| `DOD_PASS_STREAK` | `3` | consecutive independent passing verdicts needed to finish |
| `DOD_CYCLE_BUDGET` | unbounded | cap the number of cycles |
| `DOD_RUN_ID` | new run | preselect this run in the review window, and the run to resume when the window is skipped |

A large job needs far more cycles than anyone would guess, since each cycle is one bounded context
window of work. That is why the budget is unbounded by default.

### Models

| Variable | Default |
|---|---|
| `DOD_WORK_MODELS` | `deepseek-v4-flash-free,big-pickle,mimo-v2.5-free` |
| `DOD_VERIFY_MODELS` | `deepseek-v4-flash-free,big-pickle,mimo-v2.5-free` |

Comma-separated chains, tried in order. A bare id is assumed to be a Zen model, so `big-pickle` and
`opencode/big-pickle` mean the same thing.

The chain is worth more than a longer backoff because Zen's free tier is not one shared budget: each
free model is a separate upstream integration with its own capacity, so one model reporting "Free
usage exceeded" says nothing about the rest.

`nemotron-3.5-lightning-free` is deliberately absent from the defaults. A verify turn has to enumerate
hundreds of source files before it may judge a rule, and a small fast model that gives up on the
enumeration and passes anyway is exactly the failure this design exists to prevent.

### Quota and watchdog

| Variable | Default | What it does |
|---|---|---|
| `DOD_QUOTA_COOLDOWN_MS` | `900000` (15m) | wait when the whole chain is rate-limited |
| `DOD_TURN_POLL_MS` | `5000` | how often to check a running turn |
| `DOD_RETRY_TOLERANCE_MS` | `60000` | a retry due sooner than this is transient and worth waiting for |
| `DOD_TURN_DEADLINE_MS` | `2700000` (45m) | backstop for a turn that wedges silently |

The server does not hand a quota refusal back to the caller. It classifies it as retryable, keeps the
request open, and schedules its own retry hours out — you see `Free usage exceeded [retrying in 1h 36m
attempt #1]` while the prompt call is still waiting, and the message record shows no error at all.

So each turn is *watched* rather than waited on: `GET /session/status` exposes the pending retry as a
typed value, and the loop abandons the model within a poll interval of a refusal appearing there, then
aborts the session so the server stops holding a turn nobody wants.

### Launcher

| Variable | Default | What it does |
|---|---|---|
| `PORT` | `4096` | port the TUI binds and the loop dials |
| `EDITOR` | `notepad` | editor for the text review fallback |
| `DOD_LOOP_NO_REVIEW` | unset | skip the review step entirely |
| `DOD_LOOP_TEXT_REVIEW` | unset | review in `%EDITOR%` instead of the window |
| `DOD_LOOP_NO_GUI` | unset | headless `opencode serve`, no TUI |
| `DOD_LOOP_NO_PAUSE` | unset | do not pause at exit |
| `DOD_LOOP_NO_LAYOUT` | unset | do not place or minimise any window |
| `OPENCODE_BASE_URL` | `http://localhost:4096` | set by the launcher from `PORT` |

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Definition of Done met |
| `1` | not done — cycle budget reached |
| `2` | the run stopped on an error |

`1` and `2` are kept apart on purpose: "not done" and "crashed" need completely different responses
from you.

---

## Repo layout

```
dod-loop.ts                       the loop: cycles, model chain, watchdog, verdict parsing
start_syzyf.bat                   launcher: allocate run, review, start TUI, run loop
definition-gui.ps1                the review window: two boxes, saved as one file
layout.ps1                        first-run window placement, and starting the TUI in its slot
install.py                        installs Bun + opencode + deps, checks login and source data
status.ps1                        where is the loop right now
preflight.ps1                     is the folder ready for a clean run
opencode.json                     opencode project config
.opencode/dod.md                  the Definition of Done template
.opencode/agent/dod-verifier.md   the read-only verifier agent
syzyf.jpg                         the screenshot in this README
projectfiles/<id>/                everything a run generates (gitignored)
```

### The verifier agent

`.opencode/agent/dod-verifier.md` is a subagent with `edit`, `bash`, `patch`, `webfetch`, `websearch`,
and `task` all set to `deny`, and only `read`, `glob`, `grep`, and `list` allowed. It cannot change the
repository it is judging.

No model is pinned in that file on purpose. The loop supplies one per request from `DOD_VERIFY_MODELS`
so it can walk the chain when a free model runs out of quota; a pin there would be a second source of
truth that silently disagrees with the loop.

---

## Running without the batch file

`dod-loop.ts` itself is platform-neutral. Only the launcher is Windows-specific.

```bash
# 1. allocate a run folder and seed its definition; prints "id|dir|definition path"
bun dod-loop.ts --prepare

# 2. review projectfiles/00001/definition.md by hand: section 1 is the task, section 2 the rules

# 3. start a server
opencode serve --port 4096

# 4. run the loop against it
DOD_RUN_ID=00001 OPENCODE_BASE_URL=http://localhost:4096 bun dod-loop.ts
```

An optional first argument overrides cycle 0's directive. `DOD_RUN_ID` is required — the loop refuses
to start without it, so no run can write outside an approved folder.

---

## Type check

```
bun run typecheck
```

---

## Known limitations

- The launcher and the review window are Windows-only. The loop itself is not; other platforms use the
  manual path above and edit `definition.md` in any editor. Mid-run editing needs no window at all —
  the loop re-reads the file every cycle whatever wrote it — so `vim projectfiles/00001/definition.md`
  during a run works exactly the same way.
- `DOD_LOOP_TEXT_REVIEW` cannot stay open during a run: it blocks the launcher until the editor closes.
  It reviews and launches, and mid-run edits are then up to you.
- Window placement covers the primary monitor only, and cannot place the TUI when Windows Terminal opens
  it as a tab in an existing window rather than a window of its own.
- WinForms paints the client area but not the scrollbars, and message boxes stay in the system theme.
  The dark title bar needs Windows 10 1809 or newer and is skipped silently on anything older.
- The TUI window is the server, so closing it ends the run. Use `DOD_LOOP_NO_GUI=1` for anything
  unattended.
- opencode is pinned to 1.18.18, because the TUI-owns-the-server arrangement depends on `--port`
  behaviour that is not part of a stable contract.
- The verify turn cannot use structured output: `deepseek-v4-flash-free` runs in thinking mode and the
  provider rejects the forced `tool_choice` that opencode's `json_schema` format needs. The loop reads
  text and digs the JSON object out of prose and code fences instead.
