# definition-gui.ps1 - the control window for a run: pick one, edit it, launch it, keep editing it.
#
#   powershell -NoProfile -Sta -ExecutionPolicy Bypass -File .\definition-gui.ps1 -Signal <signal file>
#
# WinForms, because it ships with Windows and needs no dependency the loop does not already have.
# There is nothing to install and nothing to keep in sync with package.json.
#
# The definition stays ONE string on disk: it is handed to the verifier whole. The two boxes are an
# editing view of it, split on the section headings and written back with those same headings, so
# nothing downstream has to know this window exists.
#
# THIS FILE IS PURE ASCII ON PURPOSE. Windows PowerShell 5.1 reads a BOM-less script as ANSI, so a
# literal block character here would arrive mangled on a machine with a different code page. The logo
# is drawn with '#' and the blocks are substituted in at runtime instead.
#
# TWO THINGS THIS WINDOW OWNS
#
# 1. Which run to work on. Every existing run under projectfiles/ is listed with where it stopped, so
#    a run that died mid-cycle is resumed by picking it, not by setting an environment variable. Each
#    entry's tooltip is that run's ORIGINAL definition, from definition.original.md, which the loop
#    writes once at first launch. After a few mid-run corrections that snapshot is the only remaining
#    record of what the run set out to do.
#
# 2. The definition, for as long as the run lasts. The window does NOT close at launch: it stays open
#    and Save rewrites the live run's definition.md. The loop re-reads that file at the start of every
#    cycle, so a correction lands on the next cycle. Closing this window does not stop the run.
#
# Exit codes, which start_syzyf.bat only reads when -Signal is absent:
#   0  launch this run
#   1  quit, nothing launched
#   2  no GUI available here, fall back to a text editor
#
# With -Signal set, the approved run id is written to that file instead, because a window that stays
# open cannot report its answer as an exit code.

[CmdletBinding()]
param(
  # A specific definition to open. Optional: normally the window discovers runs itself. Kept because
  # -SelfTest and -Normalize operate on one file, and the text-editor fallback path names one too.
  [string]$Path = '',
  # Preselect this run, e.g. when DOD_RUN_ID was already set by the caller.
  [string]$RunId = '',
  # Where run folders live. Defaults to projectfiles/ next to this script.
  [string]$Root = '',
  # The template a new run is seeded from.
  [string]$Template = '',
  # Where to write the approved run id. When set, the window stays open after launching.
  [string]$Signal = '',
  # Used to allocate a new run folder: `bun dod-loop.ts --prepare`. One source of truth for the id
  # sequence and the seeding rules, rather than a second copy of them in PowerShell.
  [string]$Bun = 'bun',
  # The opencode server the TUI is serving: used to list this run's sessions and to tell the TUI which
  # one to display. Inherited from the launcher's OPENCODE_BASE_URL when not given.
  [string]$BaseUrl = '',
  # Open straight into live mode for -RunId, skipping the approval gate. For reattaching to a run that
  # is already going, when the window it was launched from is gone.
  [switch]$Live,
  # Where to put this window on first show, as "x,y,width,height". The launcher passes the left-hand
  # column from layout.ps1 so the TUI can have the rest of the screen. Dragging afterwards sticks;
  # nothing re-applies it.
  [string]$Bounds = '',
  # Print the model catalogue as the picker would build it, then exit. For checking the merge of
  # "what is available" and "what the cache knows about it" without opening a window.
  [switch]$ListModels,
  # Print how a definition splits, and what runs exist, then exit without opening a window.
  [switch]$SelfTest,
  # Rewrite one definition with the canonical headings and exit. Same save path the window uses.
  [switch]$Normalize
)

$ErrorActionPreference = 'Stop'
# Invoke-WebRequest draws a progress bar per call. Off, because the session list polls every two seconds
# and in Windows PowerShell that bar costs more than the request does.
$ProgressPreference = 'SilentlyContinue'

if (-not $Root) { $Root = Join-Path $PSScriptRoot 'projectfiles' }
if (-not $Template) { $Template = Join-Path $PSScriptRoot '.opencode\dod.md' }
if (-not $BaseUrl) { $BaseUrl = $env:OPENCODE_BASE_URL }
if (-not $BaseUrl) { $BaseUrl = 'http://localhost:4096' }

# Canonical headings. Written on every save, so a definition normalises itself the first time it is
# opened here regardless of how it was worded before.
$TaskHeading = '# 1. Task to perform'
$DodHeading = '# 2. Definition of Done'

# Loose on read, strict on write: an older definition that opens with a bare "# Definition of Done",
# or with "## 2) Definition of Done", still lands in the right box.
$TaskPattern = '(?im)^[ \t]{0,3}#{1,6}[ \t]*1[.)]?[ \t]+Task to perform\b[^\r\n]*\r?\n?'
$DodPattern = '(?im)^[ \t]{0,3}#{1,6}[ \t]*(?:2[.)]?[ \t]+)?Definition of Done\b[^\r\n]*\r?\n?'

function Read-Sections([string]$file) {
  $text = ''
  if ($file -and (Test-Path -LiteralPath $file)) { $text = [System.IO.File]::ReadAllText($file) }
  return Split-Sections $text
}

function Split-Sections([string]$text) {
  if ($null -eq $text) { $text = '' }
  $task = [regex]::Match($text, $TaskPattern)
  $dod = [regex]::Match($text, $DodPattern)

  if ($task.Success) {
    $taskStart = $task.Index + $task.Length
    if ($dod.Success -and $dod.Index -ge $taskStart) {
      return @{
        Task = $text.Substring($taskStart, $dod.Index - $taskStart).Trim()
        Dod  = $text.Substring($dod.Index + $dod.Length).Trim()
      }
    }
    return @{ Task = $text.Substring($taskStart).Trim(); Dod = '' }
  }

  if ($dod.Success) {
    # Anything above the heading is a title, not content worth preserving in a box.
    return @{ Task = ''; Dod = $text.Substring($dod.Index + $dod.Length).Trim() }
  }

  # No headings at all: treat the whole file as the Definition of Done rather than guessing a split.
  return @{ Task = ''; Dod = $text.Trim() }
}

function Write-Sections([string]$file, [string]$task, [string]$dod) {
  $body = $TaskHeading + "`r`n`r`n" + $task.Trim() + "`r`n`r`n" + $DodHeading + "`r`n`r`n" + $dod.Trim() + "`r`n"
  # Written to a sibling file and moved into place, because the loop may read this file at any moment
  # while the run is going. A truncate-then-write would give a cycle an empty definition to work from.
  # No BOM: the file is read back as UTF-8 text by Bun and pasted into a prompt, and a BOM there is
  # just three stray characters at the top of the rules.
  $encoding = New-Object System.Text.UTF8Encoding($false)
  $temp = $file + '.saving'
  [System.IO.File]::WriteAllText($temp, $body, $encoding)
  Move-Item -LiteralPath $temp -Destination $file -Force
}

# ------------------------------------------------------------------------------------------ run list
# An entry is one row in the picker. Index 0 is always the new-run row, so there is no separate button
# for it and no mode to switch into.

# Is a loop running for this run right now?
#
# The heartbeat records the loop's process id and dod-loop.ts refreshes it every few seconds while a turn
# is in flight. Asking Windows whether that process still exists is the exact answer, and it survives the
# two cases a timestamp cannot: a run parked in the fifteen minute quota cooldown writes nothing and is
# still alive, while a killed run leaves a file behind and is not.
function Get-RunHeartbeat([string]$dir) {
  $file = Join-Path $dir 'heartbeat.json'
  if (-not (Test-Path -LiteralPath $file)) { return $null }
  try {
    $beat = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json)
    if (-not $beat.pid) { return $null }
    if (-not (Get-Process -Id ([int]$beat.pid) -ErrorAction SilentlyContinue)) { return $null }
    return $beat
  } catch {
    return $null
  }
}

function Get-RunSummary([string]$dir) {
  $log = Join-Path $dir 'run.log'
  if (-not (Test-Path -LiteralPath $log)) { return 'prepared, never launched' }

  $lines = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)
  if ($lines.Count -eq 0) { return 'launched, no output yet' }

  $cycle = ''
  $outcome = ''
  foreach ($line in $lines) {
    $m = [regex]::Match($line, '^cycle (\d+):')
    if ($m.Success) { $cycle = 'cycle ' + $m.Groups[1].Value }
    if ($line -match 'DoD met') { $outcome = 'DoD MET' }
    elseif ($line -match 'pass (\d+)/(\d+)') { $outcome = 'passed ' + $Matches[1] + '/' + $Matches[2] }
    elseif ($line -match 'not done') { $outcome = 'not done' }
    elseif ($line -match 'budget .* reached') { $outcome = 'budget reached' }
  }

  $age = ''
  try {
    $span = (Get-Date) - (Get-Item -LiteralPath $log).LastWriteTime
    if ($span.TotalMinutes -lt 60) { $age = [string][int]$span.TotalMinutes + 'm ago' }
    elseif ($span.TotalHours -lt 48) { $age = [string][int]$span.TotalHours + 'h ago' }
    else { $age = [string][int]$span.TotalDays + 'd ago' }
  } catch {}

  $parts = @($cycle, $outcome, $age) | Where-Object { $_ }
  if ($parts.Count -eq 0) { return 'launched, no cycle recorded' }
  return ($parts -join '  ')
}

function Get-Entries {
  $entries = @()
  $entries += @{
    Kind    = 'new'
    Id      = ''
    Dir     = ''
    DefFile = $Template
    OrigFile = ''
    Label   = '     New run   (seeded from .opencode\dod.md)'
  }

  if (Test-Path -LiteralPath $Root) {
    $dirs = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^\d{5}$' } | Sort-Object Name -Descending)
    foreach ($dir in $dirs) {
      $def = Join-Path $dir.FullName 'definition.md'
      if (-not (Test-Path -LiteralPath $def)) { continue }
      $beat = Get-RunHeartbeat $dir.FullName
      $mark = ''
      $summary = Get-RunSummary $dir.FullName
      if ($beat) {
        $mark = 'LIVE'
        # The log summary lags a running loop by a whole turn, so the heartbeat's own view is better.
        $where = 'working'
        if ($beat.cycle -ge 0) { $where = 'cycle ' + $beat.cycle }
        if ($beat.phase) { $where = $where + ' ' + [string]$beat.phase }
        $summary = $where
      }
      $entries += @{
        Kind    = 'run'
        Id      = $dir.Name
        Dir     = $dir.FullName
        DefFile = $def
        OrigFile = Join-Path $dir.FullName 'definition.original.md'
        Live    = [bool]$beat
        Label   = ('{0,-5}{1}   {2}' -f $mark, $dir.Name, $summary)
      }
    }
  }
  return $entries
}

$script:entries = @(Get-Entries)

# The tooltip text for one entry: what that run originally set out to do, trimmed to something a
# tooltip can actually render. The full text is one button away.
$script:tipCache = @{}
function Get-TipText([int]$index) {
  # Live, the rows are sessions rather than runs. The id is what status.ps1 and the TUI both speak.
  if ($script:liveId) {
    if ($index -lt 0 -or $index -ge $script:sessionRows.Count) { return '' }
    $row = $script:sessionRows[$index]
    return 'session ' + $row.Id + "`r`n" + 'Click to show it in the TUI.'
  }
  if ($index -lt 0 -or $index -ge $script:entries.Count) { return '' }
  if ($script:tipCache.ContainsKey($index)) { return $script:tipCache[$index] }

  $entry = $script:entries[$index]
  $text = ''
  if ($entry.Kind -eq 'new') {
    $head = 'The template this new run will be seeded from:'
    $text = Get-FileText $Template
  } elseif ($entry.OrigFile -and (Test-Path -LiteralPath $entry.OrigFile)) {
    $head = 'Run ' + $entry.Id + ' originally set out to do this:'
    $text = Get-FileText $entry.OrigFile
  } else {
    $head = 'Run ' + $entry.Id + ' has no original recorded (it predates the snapshot), showing the current definition:'
    $text = Get-FileText $entry.DefFile
  }

  $body = ($text -replace "`r`n", "`n").Trim()
  if ($body.Length -gt 900) { $body = $body.Substring(0, 900).TrimEnd() + " ..." }
  $tip = $head + "`r`n`r`n" + ($body -replace "`n", "`r`n")
  $script:tipCache[$index] = $tip
  return $tip
}

function Get-FileText([string]$file) {
  if (-not $file) { return '' }
  if (-not (Test-Path -LiteralPath $file)) { return '(file not found: ' + $file + ')' }
  try { return [System.IO.File]::ReadAllText($file) } catch { return '(could not read ' + $file + ')' }
}

# -------------------------------------------------------------------------------------- sessions
# Once a run is live the picker switches to listing that run's sessions, because clicking one is the
# whole point: `POST /tui/select-session` navigates the already-open TUI to it, which is what ctrl+p
# was for. The loop titles every session "<run id> work <cycle>" or "<run id> verify <cycle>", so the
# run filter and the readable short name both come straight out of the title.

function Get-SessionAge([object]$session) {
  $stamp = 0
  try { if ($session.time.updated) { $stamp = [double]$session.time.updated } } catch {}
  if (-not $stamp) { try { if ($session.time.created) { $stamp = [double]$session.time.created } } catch {} }
  if (-not $stamp) { return @{ Sort = 0; Text = '' } }
  $seconds = [int](([datetimeoffset]::UtcNow.ToUnixTimeMilliseconds() - $stamp) / 1000)
  if ($seconds -lt 0) { $seconds = 0 }
  if ($seconds -lt 90) { $text = [string]$seconds + 's ago' }
  elseif ($seconds -lt 5400) { $text = [string][int]($seconds / 60) + 'm ago' }
  else { $text = [string][int]($seconds / 3600) + 'h ago' }
  return @{ Sort = $stamp; Text = $text }
}

# Flatten a JSON response into a real list of items.
#
# Not paranoia: `@(Invoke-RestMethod ...)` on a JSON array can yield a single object that IS the whole
# array, in which case a foreach over it runs exactly once with the entire collection bound to the loop
# variable. That produced one list row containing every session title glued together.
function ConvertTo-ItemList($value) {
  $list = New-Object System.Collections.ArrayList
  if ($null -eq $value) { return @() }
  if ($value -is [string] -or $value -isnot [System.Collections.IEnumerable]) {
    [void]$list.Add($value)
    return $list.ToArray()
  }
  foreach ($item in $value) {
    # One more level, for the case where the single yielded object is itself the array.
    if ($null -ne $item -and $item -isnot [string] -and $item -is [System.Collections.IEnumerable]) {
      foreach ($inner in $item) { [void]$list.Add($inner) }
    } else {
      [void]$list.Add($item)
    }
  }
  return $list.ToArray()
}

# $null means the server could not be reached, which is different from "no sessions yet": the window
# opens before the TUI does, so the first few refreshes after launch are expected to fail.
function Get-SessionRows([string]$runId, [bool]$everyRun) {
  try {
    # Invoke-WebRequest plus an explicit parse, rather than Invoke-RestMethod, so the shape of what
    # comes back is ours to control.
    $response = Invoke-WebRequest -Uri ($BaseUrl + '/session') -Method Get -TimeoutSec 4 -UseBasicParsing
    $sessions = ConvertTo-ItemList ($response.Content | ConvertFrom-Json)
  } catch {
    return $null
  }

  # One call for every session's state rather than one call each. A session with an entry here is doing
  # something; the type says what, including a quota retry the loop is sitting on.
  $status = $null
  try {
    $statusResponse = Invoke-WebRequest -Uri ($BaseUrl + '/session/status') -Method Get -TimeoutSec 4 -UseBasicParsing
    $status = $statusResponse.Content | ConvertFrom-Json
  } catch {}

  $rows = @()
  foreach ($session in $sessions) {
    # A session is one object with one id and one title. Anything else means the response was not the
    # shape expected, and casting it to a string would silently build a nonsense row.
    if ($null -eq $session) { continue }
    if ($session.id -isnot [string] -or $session.title -isnot [string]) { continue }
    $title = $session.title
    # Every run titles its sessions "<run id> work N", so one filter shows one run and the wider one
    # shows every run at once - which is the point when several are going and you want to jump between.
    if ($everyRun) {
      if ($title -notmatch '^\d{5} ') { continue }
      $short = $title
    } else {
      if (-not $title.StartsWith($runId + ' ')) { continue }
      $short = $title.Substring($runId.Length).Trim()
    }
    $age = Get-SessionAge $session

    $state = 'idle'
    if ($status) {
      $entry = $null
      try { $entry = $status.($session.id) } catch {}
      if ($entry) {
        $type = [string]$entry.type
        if ($type -eq 'retry') {
          $due = ''
          try { $due = ' ' + [string][int]((([double]$entry.next) - [datetimeoffset]::UtcNow.ToUnixTimeMilliseconds()) / 60000) + 'm' } catch {}
          $state = 'RETRY' + $due
        } elseif ($type) {
          $state = $type.ToUpper()
        } else {
          $state = 'RUNNING'
        }
      }
    }

    $rows += @{
      Id    = [string]$session.id
      Short = $short
      Label = ('{0,-18} {1,-12} {2}' -f $short, $state, $age.Text)
      Sort  = $age.Sort
    }
  }

  # Newest first, so the cycle running right now is the top row and never needs scrolling to. Capped
  # because a long run accumulates two sessions per cycle and the old ones are only history.
  $rows = @($rows | Sort-Object -Property @{ Expression = { $_.Sort }; Descending = $true })
  if ($rows.Count -gt 40) { $rows = @($rows[0..39]) }
  return $rows
}

# ---------------------------------------------------------------------------------------- models
# Free models are withdrawn without notice - deepseek-v4-flash-free was a default until it vanished -
# so the chains cannot be a hardcoded list. They are chosen here and written to .opencode/models.json,
# which dod-loop.ts reads.
#
# The catalogue is merged from two sources, because neither alone is enough:
#
#   `opencode models`             every model this account can reach RIGHT NOW, and needs no server.
#   .opencode/models-cache.json   name, context and the free/paid flag, written by the loop while a
#                                 server was up. Only a server knows the cost, and this window opens
#                                 before the server exists.
#
# A model present in the CLI list but missing from the cache is still offered, marked unknown: a brand
# new free model should not be invisible just because no run has seen it yet.

$ModelsConfigFile = Join-Path $PSScriptRoot '.opencode\models.json'
$ModelsCacheFile = Join-Path $PSScriptRoot '.opencode\models-cache.json'

function Get-AvailableModelIds {
  $ids = @()
  Push-Location -LiteralPath $PSScriptRoot
  try {
    $out = & 'opencode' 'models' 2>&1
    if ($LASTEXITCODE -eq 0) {
      foreach ($line in @($out)) {
        $text = ("$line").Trim()
        if ($text -and $text -notmatch '\s' -and $text.Contains('/')) { $ids += $text }
      }
    }
  } catch {
  } finally {
    Pop-Location
  }
  return $ids
}

function Get-ModelCache {
  $map = @{}
  if (-not (Test-Path -LiteralPath $ModelsCacheFile)) { return $map }
  try {
    $parsed = (Get-Content -LiteralPath $ModelsCacheFile -Raw | ConvertFrom-Json)
    foreach ($model in @($parsed.models)) {
      if ($model.id) { $map[[string]$model.id] = $model }
    }
  } catch {}
  return $map
}

function Get-ModelCatalogue {
  $cache = Get-ModelCache
  $ids = Get-AvailableModelIds
  # No CLI answer (opencode missing, or not logged in) - fall back to whatever the cache remembers, so
  # the picker still shows something useful.
  if ($ids.Count -eq 0) { $ids = @($cache.Keys) }

  $rows = @()
  foreach ($id in $ids) {
    $info = $null
    if ($cache.ContainsKey($id)) { $info = $cache[$id] }
    $free = 'unknown'
    if ($info) { if ($info.free) { $free = 'free' } else { $free = 'PAID' } }
    $context = 0
    if ($info -and $info.context) { $context = [int]$info.context }
    $name = $id
    if ($info -and $info.name) { $name = [string]$info.name }
    $rows += @{
      Id      = $id
      Name    = $name
      Free    = $free
      Context = $context
      Label   = ('{0,-9} {1,9} ctx  {2}' -f $free, $context, $id)
    }
  }
  # Largest context first, which is the order a verify turn enumerating a big source set wants.
  return @($rows | Sort-Object -Property @{ Expression = { $_.Context }; Descending = $true })
}

function Read-ModelChains {
  $chains = @{ Work = @(); Verify = @() }
  if (-not (Test-Path -LiteralPath $ModelsConfigFile)) { return $chains }
  try {
    $parsed = (Get-Content -LiteralPath $ModelsConfigFile -Raw | ConvertFrom-Json)
    if ($parsed.work) { $chains.Work = @($parsed.work | ForEach-Object { [string]$_ }) }
    if ($parsed.verify) { $chains.Verify = @($parsed.verify | ForEach-Object { [string]$_ }) }
  } catch {}
  return $chains
}

function Write-ModelChains($work, $verify) {
  $body = [ordered]@{ work = @($work); verify = @($verify) } | ConvertTo-Json -Depth 3
  $dir = Split-Path -Parent $ModelsConfigFile
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $encoding = New-Object System.Text.UTF8Encoding($false)
  $temp = $ModelsConfigFile + '.saving'
  [System.IO.File]::WriteAllText($temp, $body, $encoding)
  Move-Item -LiteralPath $temp -Destination $ModelsConfigFile -Force
}

# ---------------------------------------------------------------------------------- non-window modes

if ($ListModels) {
  $catalogue = Get-ModelCatalogue
  $chains = Read-ModelChains
  Write-Output ('--- catalogue (' + $catalogue.Count + ' models) ---')
  foreach ($row in $catalogue) { Write-Output ('  ' + $row.Label + '   "' + $row.Name + '"') }
  Write-Output ('--- chains in ' + $ModelsConfigFile + ' ---')
  Write-Output ('  work:   ' + (@($chains.Work) -join ', '))
  Write-Output ('  verify: ' + (@($chains.Verify) -join ', '))
  exit 0
}


if ($SelfTest -or $Normalize) {
  $target = $Path
  if (-not $target -and $RunId) {
    $named = @($script:entries | Where-Object { $_.Id -eq $RunId })
    if ($named.Count -gt 0) { $target = $named[0].DefFile }
  }
  if (-not $target) {
    $pick = @($script:entries | Where-Object { $_.Kind -eq 'run' })
    if ($pick.Count -gt 0) { $target = $pick[0].DefFile } else { $target = $Template }
  }
  $parsed = Read-Sections $target
  if ($Normalize) {
    Write-Sections $target $parsed.Task $parsed.Dod
    $parsed = Read-Sections $target
    Write-Output ("rewrote " + $target)
  }
  Write-Output ('--- runs found under ' + $Root + ' ---')
  for ($i = 0; $i -lt $script:entries.Count; $i++) {
    Write-Output ('  [' + $i + '] ' + $script:entries[$i].Label)
  }

  # The live session list, exactly as the window would build it. Here because the rows are built from a
  # server response, and a response shape that only shows up at runtime is not something a window can
  # be asked to prove. One row per session, or the list is wrong.
  if ($RunId) {
    Write-Output ('--- sessions for run ' + $RunId + ' on ' + $BaseUrl + ' ---')
    $rows = Get-SessionRows $RunId
    if ($null -eq $rows) {
      Write-Output '  server not reachable (no TUI or serve running?)'
    } elseif ($rows.Count -eq 0) {
      Write-Output '  no sessions carry this run id yet'
    } else {
      Write-Output ('  ' + $rows.Count + ' row(s):')
      foreach ($row in $rows) { Write-Output ('  [' + $row.Id + '] ' + $row.Label) }
    }
  }
  Write-Output ('--- ' + $target + ' ---')
  Write-Output ('--- 1. Task to perform (' + $parsed.Task.Length + ' chars) ---')
  Write-Output $parsed.Task
  Write-Output ('--- 2. Definition of Done (' + $parsed.Dod.Length + ' chars) ---')
  Write-Output $parsed.Dod
  exit 0
}

try {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  [System.Windows.Forms.Application]::EnableVisualStyles()
} catch {
  Write-Output "no WinForms available: $($_.Exception.Message)"
  exit 2
}

# ---------------------------------------------------------------------------------------- dark theme
$Bg = [System.Drawing.Color]::FromArgb(24, 24, 27)
$Panel = [System.Drawing.Color]::FromArgb(32, 32, 36)
$Field = [System.Drawing.Color]::FromArgb(18, 18, 20)
$Border = [System.Drawing.Color]::FromArgb(62, 62, 70)
# Named $Fg, not $Text: PowerShell variable names are case-insensitive, so a script-level $Text is
# shadowed by any function parameter called $text, and the control silently gets a string instead of
# a colour.
$Fg = [System.Drawing.Color]::FromArgb(220, 221, 222)
$Muted = [System.Drawing.Color]::FromArgb(138, 140, 145)
$Accent = [System.Drawing.Color]::FromArgb(78, 201, 176)
$Heading = [System.Drawing.Color]::FromArgb(86, 156, 214)
# $LiveColor, not $Live: the -Live switch parameter owns that name, and PowerShell variable names are
# case-insensitive, so assigning a Color to $Live fails the switch's type coercion at parse time. Same
# trap as $Fg below.
$LiveColor = [System.Drawing.Color]::FromArgb(230, 180, 80)
$BtnFace = [System.Drawing.Color]::FromArgb(48, 49, 54)
$BtnGo = [System.Drawing.Color]::FromArgb(14, 99, 156)

# The title bar is not ours to paint; it belongs to the shell. This is the one supported way to ask for
# a dark one, and it is a no-op on builds older than Windows 10 1809.
try {
  Add-Type -Namespace Syzyf -Name Dwm -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);
'@
} catch {}

function Set-DarkTitleBar($handle) {
  try {
    $on = 1
    # 20 on current builds, 19 on 1809. Trying both costs nothing; a wrong attribute is just an error
    # code nobody reads.
    if ([Syzyf.Dwm]::DwmSetWindowAttribute($handle, 20, [ref]$on, 4) -ne 0) {
      [Syzyf.Dwm]::DwmSetWindowAttribute($handle, 19, [ref]$on, 4) | Out-Null
    }
  } catch {}
}

# ---------------------------------------------------------------------------------------------- logo
# SYZYF in the ANSI Shadow style, stored as ASCII stand-ins and translated at runtime. One placeholder
# per box-drawing glyph, so the source stays inside the ASCII range this file has to keep to:
#
#   #  full block    7  top right    J  bottom right    L  bottom left
#   F  top left      |  vertical     =  horizontal
$LogoGlyphs = @{
  '#' = 0x2588
  '7' = 0x2557
  'J' = 0x255D
  'L' = 0x255A
  'F' = 0x2554
  '|' = 0x2551
  '=' = 0x2550
}
$LogoRows = @(
  '#######7##7   ##7#######7##7   ##7#######7',
  '##F====JL##7 ##FJL==###FJL##7 ##FJ##F====J',
  '#######7 L####FJ   ###FJ  L####FJ #####7',
  'L====##|  L##FJ   ###FJ    L##FJ  ##F==J',
  '#######|   ##|   #######7   ##|   ##|',
  'L======J   L=J   L======J   L=J   L=J'
)
$Logo = ($LogoRows | ForEach-Object {
    $line = New-Object System.Text.StringBuilder
    foreach ($ch in $_.ToCharArray()) {
      $key = [string]$ch
      if ($LogoGlyphs.ContainsKey($key)) { [void]$line.Append([char]$LogoGlyphs[$key]) }
      else { [void]$line.Append($ch) }
    }
    $line.ToString()
  }) -join "`r`n"

# ---------------------------------------------------------------------------------------------- form
# Quit is the default outcome, so closing the window with the X cannot be read as approval.
$script:result = 1
# The run this window is currently editing, and whether the loop has been launched against it. Once
# live, saving writes straight into the running job and the window stops being a gate.
$script:liveId = ''
$script:currentIndex = -1
$script:currentFile = ''
$script:loadedTask = ''
$script:loadedDod = ''
# The run being edited, kept separately from the list selection: once live, the list shows sessions and
# its selection has nothing to do with which definition is open.
$script:activeEntry = $null
$script:sessionRows = @()
$script:listSignature = ''

$mono = New-Object System.Drawing.Font('Consolas', 10)
$logoFont = New-Object System.Drawing.Font('Consolas', 9)
$bold = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$subFont = New-Object System.Drawing.Font('Segoe UI', 11)
$small = New-Object System.Drawing.Font('Segoe UI', 9)
$tiny = New-Object System.Drawing.Font('Segoe UI', 8)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Syzyf'
# Narrow on purpose: the logo is 42 characters wide and the prose wraps below it, so extra width only
# stretches the text boxes into unreadable long lines.
$form.Size = New-Object System.Drawing.Size(620, 900)
$form.MinimumSize = New-Object System.Drawing.Size(540, 620)
$form.StartPosition = 'CenterScreen'

# -Bounds docks this window somewhere specific, normally the full-height left column, leaving the rest of
# the screen for the TUI. Malformed input is ignored rather than fatal: a bad rectangle is not a reason
# to refuse to open the window you need in order to start a run.
if ($Bounds) {
  try {
    $rect = @($Bounds.Split(','))
    if ($rect.Count -eq 4) {
      $form.StartPosition = 'Manual'
      $form.Location = New-Object System.Drawing.Point([int]$rect[0].Trim(), [int]$rect[1].Trim())
      $form.Size = New-Object System.Drawing.Size([int]$rect[2].Trim(), [int]$rect[3].Trim())
    }
  } catch {
    $form.StartPosition = 'CenterScreen'
  }
}
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor = $Bg
$form.ForeColor = $Fg

$grid = New-Object System.Windows.Forms.TableLayoutPanel
$grid.Dock = 'Fill'
$grid.BackColor = $Bg
$grid.ColumnCount = 1
$grid.RowCount = 9
$grid.Padding = New-Object System.Windows.Forms.Padding(14, 12, 14, 12)
# header, runs label, runs list, task label, task box, dod label, dod box, hint, buttons
#
# The hint gets a row of its own rather than a cell beside the buttons. Docked to the left column the
# window is only ~614px wide, and a label sharing that row squeezed the buttons until "Save and launch"
# ran off the edge.
$rowPlan = @(
  @{ Kind = 'AutoSize'; Size = 0 },
  # Fixed, not AutoSize: this row holds a table, and leaving it to size itself is what collapsed it.
  # 32 rather than 28, because the New run button measures 30 tall and would otherwise be clipped.
  @{ Kind = 'Absolute'; Size = 32 },
  # Doubles as the live session list, where a long run has two rows per cycle, so it earns the height.
  @{ Kind = 'Absolute'; Size = 132 },
  @{ Kind = 'AutoSize'; Size = 0 },
  @{ Kind = 'Percent'; Size = 34 },
  @{ Kind = 'AutoSize'; Size = 0 },
  @{ Kind = 'Percent'; Size = 66 },
  @{ Kind = 'AutoSize'; Size = 0 },
  @{ Kind = 'AutoSize'; Size = 0 }
)
foreach ($plan in $rowPlan) {
  $style = New-Object System.Windows.Forms.RowStyle
  $style.SizeType = $plan.Kind
  if ($plan.Size -gt 0) { $style.Height = $plan.Size }
  $grid.RowStyles.Add($style) | Out-Null
}
$form.Controls.Add($grid)

# -------------------------------------------------------------------------------------------- header
$header = New-Object System.Windows.Forms.Panel
$header.BackColor = $Panel
$header.Dock = 'Fill'
$header.AutoSize = $true
$header.AutoSizeMode = 'GrowAndShrink'
$header.Padding = New-Object System.Windows.Forms.Padding(18, 14, 18, 16)
$header.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)

$headerStack = New-Object System.Windows.Forms.TableLayoutPanel
$headerStack.Dock = 'Top'
$headerStack.AutoSize = $true
$headerStack.AutoSizeMode = 'GrowAndShrink'
$headerStack.BackColor = $Panel
$headerStack.ColumnCount = 1
$headerStack.RowCount = 3
# Docked, so the single column spans the full width. That is what gives Anchor 'None' below room to
# centre in: an auto-sized column would shrink to the text and there would be nothing to centre
# within.
$fullWidth = New-Object System.Windows.Forms.ColumnStyle
$fullWidth.SizeType = 'Percent'
$fullWidth.Width = 100
$headerStack.ColumnStyles.Add($fullWidth) | Out-Null
$header.Controls.Add($headerStack)

$logoLabel = New-Object System.Windows.Forms.Label
$logoLabel.Text = $Logo
$logoLabel.Font = $logoFont
$logoLabel.ForeColor = $Accent
$logoLabel.BackColor = $Panel
$logoLabel.AutoSize = $true
$logoLabel.Anchor = 'None'
$logoLabel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
$headerStack.Controls.Add($logoLabel, 0, 0)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'an OpenCode addon'
$subtitle.Font = $subFont
$subtitle.ForeColor = $Fg
$subtitle.BackColor = $Panel
$subtitle.AutoSize = $true
$subtitle.Anchor = 'None'
$subtitle.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
$headerStack.Controls.Add($subtitle, 0, 1)

$blurb = New-Object System.Windows.Forms.Label
$blurb.Text = 'It keeps opening fresh sessions and working towards the Definition of Done below, and stops only once an independent read-only verifier has confirmed every rule three times in a row.'
$blurb.Font = $small
$blurb.ForeColor = $Muted
$blurb.BackColor = $Panel
$blurb.AutoSize = $true
$blurb.Anchor = 'None'
$blurb.TextAlign = 'TopCenter'
# Wraps rather than widening the window. Sized for the narrow layout, not for the screen.
$blurb.MaximumSize = New-Object System.Drawing.Size(480, 0)
$blurb.Margin = New-Object System.Windows.Forms.Padding(0)
$headerStack.Controls.Add($blurb, 0, 2)

$grid.Controls.Add($header, 0, 0)

# --------------------------------------------------------------------------------------------- boxes
function New-Label([string]$text, [int]$top) {
  $label = New-Object System.Windows.Forms.Label
  $label.Text = $text
  $label.Font = $bold
  $label.ForeColor = $Heading
  $label.BackColor = $Bg
  $label.AutoSize = $true
  $label.Margin = New-Object System.Windows.Forms.Padding(0, $top, 0, 4)
  return $label
}

# A dark TextBox with BorderStyle FixedSingle draws a border nobody can see against the background, so
# the border is a one-pixel parent panel instead.
function New-Box([string]$text) {
  $frame = New-Object System.Windows.Forms.Panel
  $frame.Dock = 'Fill'
  $frame.BackColor = $Border
  $frame.Padding = New-Object System.Windows.Forms.Padding(1)
  $frame.Margin = New-Object System.Windows.Forms.Padding(0)

  $box = New-Object System.Windows.Forms.TextBox
  $box.Multiline = $true
  $box.ScrollBars = 'Vertical'
  $box.WordWrap = $true
  $box.AcceptsTab = $true
  $box.BorderStyle = 'None'
  $box.Font = $mono
  $box.BackColor = $Field
  $box.ForeColor = $Fg
  $box.Dock = 'Fill'
  $box.Text = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
  $frame.Controls.Add($box)
  return @{ Frame = $frame; Box = $box }
}

# A table, not a Panel with docked children: an AutoSize Panel collapses to nothing around docked
# children, which hid this whole row - label and all - the first time it was tried.
$runHeader = New-Object System.Windows.Forms.TableLayoutPanel
$runHeader.Dock = 'Fill'
$runHeader.BackColor = $Bg
$runHeader.ColumnCount = 3
$runHeader.RowCount = 1
$runHeader.Height = 32
$runHeader.Margin = New-Object System.Windows.Forms.Padding(0)
foreach ($width in @(100, 0, 0)) {
  $style = New-Object System.Windows.Forms.ColumnStyle
  if ($width -gt 0) { $style.SizeType = 'Percent'; $style.Width = $width } else { $style.SizeType = 'AutoSize' }
  $runHeader.ColumnStyles.Add($style) | Out-Null
}

$runLabel = New-Label 'Run' 0
$runLabel.Dock = 'Fill'
$runLabel.AutoSize = $false
$runLabel.TextAlign = 'MiddleLeft'
$runHeader.Controls.Add($runLabel, 0, 0)

# Only meaningful once live, where it widens the session list from this run to every run that has any.
# That is what makes several runs at once usable from one window.
$allRuns = New-Object System.Windows.Forms.CheckBox
$allRuns.Text = 'all runs'
$allRuns.Font = $small
$allRuns.ForeColor = $Muted
$allRuns.BackColor = $Bg
$allRuns.AutoSize = $true
$allRuns.Anchor = 'None'
$runHeader.Controls.Add($allRuns, 1, 0)

# Starting another run means running the launcher again, so the window may as well do it. Each launcher
# allocates its own run and its own handshake file, so this is simply a second independent run.
# Styled inline rather than through Set-ButtonStyle: that helper is defined further down the file, and a
# PowerShell function does not exist until its definition has been executed.
$newRun = New-Object System.Windows.Forms.Button
$newRun.Text = 'New run'
$newRun.AutoSize = $true
$newRun.FlatStyle = 'Flat'
$newRun.BackColor = $BtnFace
$newRun.ForeColor = $Fg
$newRun.Font = $small
$newRun.FlatAppearance.BorderSize = 0
$newRun.Padding = New-Object System.Windows.Forms.Padding(6, 1, 6, 1)
$newRun.Anchor = 'None'
$newRun.Margin = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)
$runHeader.Controls.Add($newRun, 2, 0)

$grid.Controls.Add($runHeader, 0, 1)

$runFrame = New-Object System.Windows.Forms.Panel
$runFrame.Dock = 'Fill'
$runFrame.BackColor = $Border
$runFrame.Padding = New-Object System.Windows.Forms.Padding(1)
$runFrame.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)

$runList = New-Object System.Windows.Forms.ListBox
$runList.Dock = 'Fill'
$runList.BorderStyle = 'None'
$runList.BackColor = $Field
$runList.ForeColor = $Fg
$runList.Font = $mono
$runList.IntegralHeight = $false
$runFrame.Controls.Add($runList)
$grid.Controls.Add($runFrame, 0, 2)

$task = New-Box ''
$dod = New-Box ''
$taskBox = $task.Box
$dodBox = $dod.Box

$grid.Controls.Add((New-Label '1. Task to perform' 8), 0, 3)
$grid.Controls.Add($task.Frame, 0, 4)
$grid.Controls.Add((New-Label '2. Definition of Done' 12), 0, 5)
$grid.Controls.Add($dod.Frame, 0, 6)

# ------------------------------------------------------------------------------------------- buttons
$buttons = New-Object System.Windows.Forms.TableLayoutPanel
$buttons.Dock = 'Fill'
$buttons.AutoSize = $true
$buttons.BackColor = $Bg
$buttons.ColumnCount = 6
$buttons.RowCount = 1
$buttons.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
foreach ($width in @(100, 0, 0, 0, 0, 0)) {
  $style = New-Object System.Windows.Forms.ColumnStyle
  if ($width -gt 0) { $style.SizeType = 'Percent'; $style.Width = $width } else { $style.SizeType = 'AutoSize' }
  $buttons.ColumnStyles.Add($style) | Out-Null
}

$hint = New-Object System.Windows.Forms.Label
$hint.AutoSize = $true
$hint.Dock = 'Top'
$hint.Font = $tiny
$hint.ForeColor = $Muted
$hint.BackColor = $Bg
$hint.TextAlign = 'TopLeft'
$hint.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
# Wraps instead of widening the window, and leaves the button row the full width to itself.
$hint.MaximumSize = New-Object System.Drawing.Size(560, 0)
$grid.Controls.Add($hint, 0, 7)

function Set-ButtonStyle($button, $back) {
  $button.AutoSize = $true
  $button.FlatStyle = 'Flat'
  $button.BackColor = $back
  $button.ForeColor = $Fg
  $button.FlatAppearance.BorderSize = 0
  # Tight, because five buttons plus a highlighted one have to fit a 614px column without clipping.
  $button.Padding = New-Object System.Windows.Forms.Padding(8, 5, 8, 5)
  $button.Margin = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
}

$models = New-Object System.Windows.Forms.Button
$models.Text = 'Models'
Set-ButtonStyle $models $BtnFace
$buttons.Controls.Add($models, 1, 0)

$original = New-Object System.Windows.Forms.Button
$original.Text = 'Original'
Set-ButtonStyle $original $BtnFace
$buttons.Controls.Add($original, 2, 0)

$reload = New-Object System.Windows.Forms.Button
$reload.Text = 'Reload'
Set-ButtonStyle $reload $BtnFace
$buttons.Controls.Add($reload, 3, 0)

$quit = New-Object System.Windows.Forms.Button
$quit.Text = 'Quit'
Set-ButtonStyle $quit $BtnFace
$buttons.Controls.Add($quit, 4, 0)

$launch = New-Object System.Windows.Forms.Button
$launch.Text = 'Save && launch'
Set-ButtonStyle $launch $BtnGo
$launch.Font = $bold
$launch.ForeColor = [System.Drawing.Color]::White
$buttons.Controls.Add($launch, 5, 0)

$grid.Controls.Add($buttons, 0, 8)

# ---------------------------------------------------------------------------------------- behaviour

function ConvertTo-CrLf([string]$text) {
  if ($null -eq $text) { return '' }
  return (($text -replace "`r`n", "`n") -replace "`n", "`r`n")
}

function Set-Baseline {
  $script:loadedTask = $taskBox.Text
  $script:loadedDod = $dodBox.Text
}

function Test-Dirty {
  return (($taskBox.Text -ne $script:loadedTask) -or ($dodBox.Text -ne $script:loadedDod))
}

function Set-Hint([string]$message) {
  $hint.Text = $message + [Environment]::NewLine + $script:currentFile
}

function Show-Problem([string]$message, [string]$title) {
  [System.Windows.Forms.MessageBox]::Show($message, $title, 'OK', 'Warning') | Out-Null
}

$script:suppressSelect = $false

function Load-Entry([int]$index) {
  if ($index -lt 0 -or $index -ge $script:entries.Count) { return }
  $entry = $script:entries[$index]
  $parsed = Read-Sections $entry.DefFile
  $taskBox.Text = ConvertTo-CrLf $parsed.Task
  $dodBox.Text = ConvertTo-CrLf $parsed.Dod
  $script:currentIndex = $index
  $script:currentFile = $entry.DefFile
  $script:activeEntry = $entry
  Set-Baseline
  if ($entry.Kind -eq 'new') {
    Set-Hint 'A new run folder is allocated when you launch. Ctrl+Enter launches.'
  } else {
    Set-Hint ('Resuming run ' + $entry.Id + ' from wherever it stopped. Ctrl+Enter launches.')
  }
}

# Allocating through `bun dod-loop.ts --prepare` rather than in PowerShell keeps one source of truth
# for the id sequence and for how a definition is seeded. A second copy of those rules here would
# eventually disagree with the loop.
function New-RunFolder {
  $out = ''
  $code = 1
  Push-Location -LiteralPath $PSScriptRoot
  try {
    $out = & $Bun 'dod-loop.ts' '--prepare' 2>&1
    $code = $LASTEXITCODE
  } catch {
    return @{ Error = 'could not run "' + $Bun + '": ' + $_.Exception.Message }
  } finally {
    Pop-Location
  }
  $text = ($out | Out-String)
  if ($code -ne 0) { return @{ Error = 'bun dod-loop.ts --prepare failed:' + [Environment]::NewLine + $text.Trim() } }
  $line = @($out | Where-Object { "$_" -match '\|' } | Select-Object -Last 1)
  if ($line.Count -eq 0) { return @{ Error = 'could not read the new run id from:' + [Environment]::NewLine + $text.Trim() } }
  $parts = ("$($line[0])").Trim().Split('|')
  if ($parts.Count -lt 3) { return @{ Error = 'unexpected --prepare output: ' + $line[0] } }
  return @{ Id = $parts[0]; Dir = $parts[1]; DefFile = $parts[2] }
}

function Write-Signal([string]$id) {
  if (-not $Signal) { return }
  $dir = Split-Path -Parent $Signal
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  [System.IO.File]::WriteAllText($Signal, $id + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
}

# After this the window is no longer a gate, it is the run's control panel: the launch button becomes a
# plain save, and the run picker becomes a live session list you can click to steer the TUI.
function Enter-LiveMode([string]$id, [string]$file) {
  $script:liveId = $id
  $script:currentFile = $file
  # The run list is about to be replaced by sessions, so remember what is being edited before it goes.
  $dir = Split-Path -Parent $file
  $script:activeEntry = @{
    Kind     = 'run'
    Id       = $id
    Dir      = $dir
    DefFile  = $file
    OrigFile = Join-Path $dir 'definition.original.md'
  }
  $form.Text = 'Syzyf - run ' + $id + ' (live)'
  $runLabel.ForeColor = $LiveColor
  $launch.Text = 'Save'
  $quit.Text = 'Close window'
  # Esc must not throw away a window the operator is using to steer a running job.
  $form.CancelButton = $null
  Set-Baseline
  Set-Hint 'Saved edits apply from the next cycle. Closing this window does not stop the run.'

  $script:listSignature = ''
  $runList.Items.Clear()
  # The launcher starts this window before the TUI, so the first refreshes are expected to fail until
  # the server is up. The timer keeps trying and the label says which state it is in.
  Update-Sessions
  $sessionTimer.Start()
}

function Update-Sessions {
  if (-not $script:liveId) { return }
  $everyRun = $allRuns.Checked
  $rows = Get-SessionRows $script:liveId $everyRun
  $scope = 'run ' + $script:liveId
  if ($everyRun) { $scope = 'every run' }

  if ($null -eq $rows) {
    $runLabel.Text = 'Sessions, ' + $scope + ' - waiting for the server on ' + $BaseUrl
    return
  }
  if ($rows.Count -eq 0) {
    $runLabel.Text = 'Sessions, ' + $scope + ' - none yet, the first cycle is starting'
    return
  }
  # Short, because this row now shares its width with the all-runs tick and the New run button.
  $runLabel.Text = 'Sessions, ' + $scope

  # Rebuilding the list on every tick would fight the mouse and reset the scroll position, so it is
  # only rebuilt when something actually changed.
  $signature = (($rows | ForEach-Object { $_.Label }) -join '|')
  $script:sessionRows = $rows
  if ($signature -eq $script:listSignature) { return }
  $script:listSignature = $signature
  $script:tipCache = @{}

  $selected = $runList.SelectedIndex
  $script:suppressSelect = $true
  $runList.BeginUpdate()
  $runList.Items.Clear()
  foreach ($row in $rows) { $runList.Items.Add($row.Label) | Out-Null }
  if ($selected -ge 0 -and $selected -lt $runList.Items.Count) { $runList.SelectedIndex = $selected }
  $runList.EndUpdate()
  $script:suppressSelect = $false
}

# The whole reason this list exists. One documented POST and the TUI navigates itself; no keystroke
# injection, and no second TUI window to manage.
function Select-TuiSession($row) {
  $body = @{ sessionID = $row.Id } | ConvertTo-Json -Compress
  try {
    Invoke-RestMethod -Uri ($BaseUrl + '/tui/select-session') -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 6 | Out-Null
    Set-Hint ('TUI switched to ' + $row.Short + '  (' + $row.Id + ')')
  } catch {
    # Most likely nothing is attached to that server, which is the normal case under DOD_LOOP_NO_GUI.
    Set-Hint ('The TUI did not take the jump - is one running on ' + $BaseUrl + '? ' + $_.Exception.Message)
  }
}

function Invoke-Save {
  if (-not $dodBox.Text.Trim()) {
    Show-Problem 'The Definition of Done is empty, so there is nothing to verify against and the run can never pass.' 'Nothing to work towards'
    $dodBox.Focus() | Out-Null
    return
  }

  # Live: the run already exists and the loop is reading this file every cycle.
  if ($script:liveId) {
    try {
      Write-Sections $script:currentFile $taskBox.Text $dodBox.Text
    } catch {
      Show-Problem ("Could not save:" + [Environment]::NewLine + $_.Exception.Message) 'Save failed'
      return
    }
    Set-Baseline
    Set-Hint ('Saved ' + (Get-Date -Format 'HH:mm:ss') + '. It applies from the next cycle; the one in flight finishes on the old text.')
    return
  }

  # Not live yet: this is the approval gate. A new run gets its folder now, so quitting instead never
  # leaves an empty one behind.
  $entry = $script:entries[$script:currentIndex]
  $targetId = $entry.Id
  $targetFile = $entry.DefFile
  if ($entry.Kind -eq 'new') {
    $made = New-RunFolder
    if ($made.Error) {
      Show-Problem $made.Error 'Could not allocate a run'
      return
    }
    $targetId = $made.Id
    $targetFile = $made.DefFile
  }

  try {
    Write-Sections $targetFile $taskBox.Text $dodBox.Text
  } catch {
    Show-Problem ("Could not save:" + [Environment]::NewLine + $_.Exception.Message) 'Save failed'
    return
  }

  Write-Signal $targetId
  $script:result = 0
  # Without a signal file the caller is waiting on the exit code, so there is nothing to stay open for.
  if ($Signal) { Enter-LiveMode $targetId $targetFile } else { $form.Close() }
}

# One checkable, reorderable chain. Ticked items form the chain, and the order of the rows IS the order
# the loop tries them in, which is why Up and Down matter as much as the ticks.
function New-ChainPanel([string]$title, $catalogue, $chosenIds) {
  $panel = New-Object System.Windows.Forms.Panel
  $panel.Dock = 'Fill'
  $panel.BackColor = $Bg
  $panel.Padding = New-Object System.Windows.Forms.Padding(0)

  $label = New-Object System.Windows.Forms.Label
  $label.Text = $title
  $label.Font = $bold
  $label.ForeColor = $Heading
  $label.BackColor = $Bg
  $label.Dock = 'Top'
  $label.Height = 22
  $panel.Controls.Add($label)

  $bar = New-Object System.Windows.Forms.Panel
  $bar.Dock = 'Bottom'
  $bar.Height = 34
  $bar.BackColor = $Bg

  $list = New-Object System.Windows.Forms.CheckedListBox
  $list.Dock = 'Fill'
  $list.BorderStyle = 'FixedSingle'
  $list.BackColor = $Field
  $list.ForeColor = $Fg
  $list.Font = $mono
  $list.CheckOnClick = $true
  $list.IntegralHeight = $false

  # Chosen models first, in the order they were saved, then everything else. So the chain reads top-down
  # and the unused models sit below it.
  $rows = New-Object System.Collections.ArrayList
  foreach ($id in @($chosenIds)) {
    $match = @($catalogue | Where-Object { $_.Id -eq $id })
    if ($match.Count -gt 0) { [void]$rows.Add($match[0]) }
  }
  foreach ($row in $catalogue) {
    if (-not (@($rows | Where-Object { $_.Id -eq $row.Id }).Count)) { [void]$rows.Add($row) }
  }
  foreach ($row in $rows) {
    $checked = (@($chosenIds) -contains $row.Id)
    [void]$list.Items.Add($row.Label, $checked)
  }
  $list.Tag = $rows

  $up = New-Object System.Windows.Forms.Button
  $up.Text = 'Up'
  Set-ButtonStyle $up $BtnFace
  $up.Margin = New-Object System.Windows.Forms.Padding(0)
  $up.Dock = 'Left'
  $down = New-Object System.Windows.Forms.Button
  $down.Text = 'Down'
  Set-ButtonStyle $down $BtnFace
  $down.Dock = 'Left'

  # GetNewClosure, so each panel's buttons keep hold of their own list rather than the last one created.
  $up.Add_Click({ Move-ChainItem $list -1 }.GetNewClosure())
  $down.Add_Click({ Move-ChainItem $list 1 }.GetNewClosure())

  $bar.Controls.Add($down)
  $bar.Controls.Add($up)
  $panel.Controls.Add($bar)
  $panel.Controls.Add($list)
  $list.BringToFront()
  return @{ Panel = $panel; List = $list }
}

function Move-ChainItem($list, [int]$delta) {
  $index = $list.SelectedIndex
  if ($index -lt 0) { return }
  $target = $index + $delta
  if ($target -lt 0 -or $target -ge $list.Items.Count) { return }
  $rows = $list.Tag
  $wasChecked = $list.GetItemChecked($index)
  $movedRow = $rows[$index]
  $movedLabel = $list.Items[$index]
  $rows.RemoveAt($index)
  $list.Items.RemoveAt($index)
  $rows.Insert($target, $movedRow)
  $list.Items.Insert($target, $movedLabel)
  $list.SetItemChecked($target, $wasChecked)
  $list.SelectedIndex = $target
}

function Get-CheckedIds($list) {
  $ids = @()
  $rows = $list.Tag
  for ($i = 0; $i -lt $list.Items.Count; $i++) {
    if ($list.GetItemChecked($i)) { $ids += $rows[$i].Id }
  }
  return $ids
}

function Show-ModelPicker {
  $catalogue = Get-ModelCatalogue
  if ($catalogue.Count -eq 0) {
    Show-Problem ("No models found. Check that opencode is on PATH and you are logged in:" + [Environment]::NewLine + "  opencode auth login") 'No models'
    return
  }
  $chains = Read-ModelChains

  $dialog = New-Object System.Windows.Forms.Form
  $dialog.Text = 'Free models - work and verify chains'
  $dialog.Size = New-Object System.Drawing.Size(880, 620)
  $dialog.StartPosition = 'CenterParent'
  $dialog.BackColor = $Bg
  $dialog.ForeColor = $Fg
  $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 9)

  $blurbLabel = New-Object System.Windows.Forms.Label
  $blurbLabel.Text = 'Tick the models each turn may use, in the order they should be tried. The loop moves to the next one when a model reports "Free usage exceeded", so more than one is worth having. A vanished model is dropped automatically at launch. Leave both empty to let the loop use every free model, largest context first.'
  $blurbLabel.Font = $small
  $blurbLabel.ForeColor = $Muted
  $blurbLabel.BackColor = $Bg
  $blurbLabel.Dock = 'Top'
  $blurbLabel.Height = 62
  $dialog.Controls.Add($blurbLabel)

  $footer = New-Object System.Windows.Forms.Panel
  $footer.Dock = 'Bottom'
  $footer.Height = 44
  $footer.BackColor = $Bg

  $split = New-Object System.Windows.Forms.TableLayoutPanel
  $split.Dock = 'Fill'
  $split.BackColor = $Bg
  $split.ColumnCount = 2
  $split.RowCount = 1
  foreach ($half in @(50, 50)) {
    $style = New-Object System.Windows.Forms.ColumnStyle
    $style.SizeType = 'Percent'
    $style.Width = $half
    $split.ColumnStyles.Add($style) | Out-Null
  }

  $workPanel = New-ChainPanel 'Work chain' $catalogue $chains.Work
  $verifyPanel = New-ChainPanel 'Verify chain' $catalogue $chains.Verify
  $split.Controls.Add($workPanel.Panel, 0, 0)
  $split.Controls.Add($verifyPanel.Panel, 1, 0)

  $refresh = New-Object System.Windows.Forms.Button
  $refresh.Text = 'Refresh from server'
  Set-ButtonStyle $refresh $BtnFace
  $refresh.Dock = 'Left'
  $refresh.Add_Click({
      # Only a server knows the cost, so this is the one action here that needs one running.
      Push-Location -LiteralPath $PSScriptRoot
      $failed = $null
      try {
        $env:OPENCODE_BASE_URL = $BaseUrl
        $out = & $Bun 'dod-loop.ts' '--models' 2>&1
        if ($LASTEXITCODE -ne 0) { $failed = ($out | Out-String) }
      } catch {
        $failed = $_.Exception.Message
      } finally {
        Pop-Location
      }
      if ($failed) {
        Show-Problem ("Could not refresh from " + $BaseUrl + ":" + [Environment]::NewLine + $failed.Trim() + [Environment]::NewLine + [Environment]::NewLine + "The list below still shows what opencode reports as available.") 'No server to ask'
        return
      }
      $dialog.Tag = 'refresh'
      $dialog.Close()
    })

  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = 'Cancel'
  Set-ButtonStyle $cancel $BtnFace
  $cancel.Dock = 'Right'

  $save = New-Object System.Windows.Forms.Button
  $save.Text = 'Save chains'
  Set-ButtonStyle $save $BtnGo
  $save.Font = $bold
  $save.ForeColor = [System.Drawing.Color]::White
  $save.Dock = 'Right'
  $save.Add_Click({
      $workIds = Get-CheckedIds $workPanel.List
      $verifyIds = Get-CheckedIds $verifyPanel.List
      try {
        Write-ModelChains $workIds $verifyIds
      } catch {
        Show-Problem ("Could not save:" + [Environment]::NewLine + $_.Exception.Message) 'Save failed'
        return
      }
      $dialog.Tag = 'saved'
      $dialog.Close()
    })

  $footer.Controls.Add($refresh)
  $footer.Controls.Add($cancel)
  $footer.Controls.Add($save)
  $dialog.Controls.Add($footer)
  $dialog.Controls.Add($split)
  $split.BringToFront()
  $dialog.CancelButton = $cancel
  $dialog.Add_Shown({ Set-DarkTitleBar $dialog.Handle })
  [void]$dialog.ShowDialog($form)
  $outcome = $dialog.Tag
  $dialog.Dispose()

  if ($outcome -eq 'saved') {
    $saved = Read-ModelChains
    $workCount = @($saved.Work).Count
    $verifyCount = @($saved.Verify).Count
    Set-Hint ('Saved model chains: work ' + $workCount + ', verify ' + $verifyCount + '. Applies to the next run launched.')
  }
  # Refresh rewrote the cache, so reopen with the fresher labels rather than making the operator click again.
  if ($outcome -eq 'refresh') { Show-ModelPicker }
}

function Show-Original {
  $entry = $script:activeEntry
  if ($null -eq $entry) { return }
  $title = 'Template: ' + $Template
  $body = ''
  if ($entry.Kind -eq 'new') {
    $body = Get-FileText $Template
  } elseif ($entry.OrigFile -and (Test-Path -LiteralPath $entry.OrigFile)) {
    $title = 'Run ' + $entry.Id + ' as originally launched'
    $body = Get-FileText $entry.OrigFile
  } else {
    $title = 'Run ' + $entry.Id + ' has no original recorded, showing its current definition'
    $body = Get-FileText $entry.DefFile
  }

  $view = New-Object System.Windows.Forms.Form
  $view.Text = $title
  $view.Size = New-Object System.Drawing.Size(700, 640)
  $view.StartPosition = 'CenterParent'
  $view.BackColor = $Bg
  $view.ForeColor = $Fg
  $box = New-Object System.Windows.Forms.TextBox
  $box.Multiline = $true
  $box.ReadOnly = $true
  $box.ScrollBars = 'Vertical'
  $box.WordWrap = $true
  $box.BorderStyle = 'None'
  $box.Font = $mono
  $box.BackColor = $Field
  $box.ForeColor = $Fg
  $box.Dock = 'Fill'
  $box.Text = ConvertTo-CrLf $body
  $view.Controls.Add($box)
  $view.Add_Shown({ Set-DarkTitleBar $view.Handle })
  $view.ShowDialog($form) | Out-Null
  $view.Dispose()
}

$sessionTimer = New-Object System.Windows.Forms.Timer
$sessionTimer.Interval = 2000
$sessionTimer.Add_Tick({ Update-Sessions })

# Rebuild at once rather than waiting for the next tick, and clear the signature so the wider list is
# actually redrawn instead of being mistaken for unchanged.
$allRuns.Add_CheckedChanged({
    if (-not $script:liveId) { return }
    $script:listSignature = ''
    Update-Sessions
  })

# A second run is a second launcher: it allocates its own id, gets its own handshake file and its own
# window, and attaches to the server this one already started.
$newRun.Add_Click({
    $launcher = Join-Path $PSScriptRoot 'start_syzyf.bat'
    if (-not (Test-Path -LiteralPath $launcher)) {
      Show-Problem ('Cannot find the launcher at ' + $launcher) 'No launcher'
      return
    }
    try {
      Start-Process -FilePath $launcher -WorkingDirectory $PSScriptRoot | Out-Null
      Set-Hint 'Started another launcher. Its own window will open for you to pick and approve that run.'
    } catch {
      Show-Problem ("Could not start another run:" + [Environment]::NewLine + $_.Exception.Message) 'Launch failed'
    }
  })

# Jumping is bound to a real mouse click, not to SelectedIndexChanged: the refresh reselects a row
# every time the list is rebuilt, and that must never fire a navigation.
$runList.Add_MouseClick({
    param($sender, $e)
    if (-not $script:liveId) { return }
    $index = $sender.IndexFromPoint($e.Location)
    if ($index -lt 0 -or $index -ge $script:sessionRows.Count) { return }
    Select-TuiSession $script:sessionRows[$index]
  })

$runList.Add_SelectedIndexChanged({
    if ($script:suppressSelect) { return }
    # Live: the list is sessions, and picking one is handled by the click above.
    if ($script:liveId) { return }
    $index = $runList.SelectedIndex
    if ($index -eq $script:currentIndex) { return }
    if (Test-Dirty) {
      $answer = [System.Windows.Forms.MessageBox]::Show(
        'Discard the unsaved edits to the definition you were looking at?',
        'Unsaved edits', 'YesNo', 'Warning')
      if ($answer -ne 'Yes') {
        $script:suppressSelect = $true
        $runList.SelectedIndex = $script:currentIndex
        $script:suppressSelect = $false
        return
      }
    }
    Load-Entry $index
  })

# Per-item tooltips, which a ListBox does not do on its own. Set only when the row under the pointer
# changes, or the tooltip flickers away on every mouse move.
$tip = New-Object System.Windows.Forms.ToolTip
$tip.InitialDelay = 350
$tip.ReshowDelay = 80
$tip.AutoPopDelay = 32000
$tip.ShowAlways = $true
$script:tipIndex = -2
$runList.Add_MouseMove({
    param($sender, $e)
    $index = $sender.IndexFromPoint($e.Location)
    if ($index -eq $script:tipIndex) { return }
    $script:tipIndex = $index
    if ($index -ge 0) { $tip.SetToolTip($sender, (Get-TipText $index)) } else { $tip.SetToolTip($sender, '') }
  })
$runList.Add_MouseLeave({ $script:tipIndex = -2 })

$launch.Add_Click({ Invoke-Save })
$original.Add_Click({ Show-Original })
$models.Add_Click({ Show-ModelPicker })

$reload.Add_Click({
    if ((Test-Dirty) -and -not $script:liveId) {
      $answer = [System.Windows.Forms.MessageBox]::Show(
        'Discard your unsaved edits and reload this definition from disk?',
        'Reload', 'YesNo', 'Warning')
      if ($answer -ne 'Yes') { return }
    } elseif (Test-Dirty) {
      $answer = [System.Windows.Forms.MessageBox]::Show(
        'Discard your unsaved edits and reload the live definition from disk?',
        'Reload', 'YesNo', 'Warning')
      if ($answer -ne 'Yes') { return }
    }
    $parsed = Read-Sections $script:currentFile
    $taskBox.Text = ConvertTo-CrLf $parsed.Task
    $dodBox.Text = ConvertTo-CrLf $parsed.Dod
    Set-Baseline
    Set-Hint ('Reloaded from disk at ' + (Get-Date -Format 'HH:mm:ss') + '.')
  })

$quit.Add_Click({
    if (-not $script:liveId) { $script:result = 1 }
    $form.Close()
  })

# Closing while live is just closing a window; the run carries on inside the TUI. Unsaved edits are
# the only thing actually at risk, so that is the only thing worth asking about.
$form.Add_FormClosing({
    param($sender, $e)
    if ($script:liveId -and (Test-Dirty)) {
      $answer = [System.Windows.Forms.MessageBox]::Show(
        'You have unsaved edits to the live definition. Close anyway? The run keeps going either way.',
        'Unsaved edits', 'YesNo', 'Warning')
      if ($answer -ne 'Yes') { $e.Cancel = $true }
    }
    # Closing before launching is an answer too, and the caller is watching the signal file for it.
    # Saying so explicitly turns its "did the window die?" poll into a one-second exit.
    if (-not $e.Cancel -and -not $script:liveId -and $script:result -ne 0) { Write-Signal 'quit' }
    if (-not $e.Cancel) { $sessionTimer.Stop() }
  })

$form.CancelButton = $quit
$form.Add_Shown({
    Set-DarkTitleBar $form.Handle
    $taskBox.Focus() | Out-Null
  })

# Ctrl+Enter launches, then saves, from either box, since plain Enter belongs to the text.
$onKey = {
  param($sender, $e)
  if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
    $e.SuppressKeyPress = $true
    $launch.PerformClick()
  }
}
$taskBox.Add_KeyDown($onKey)
$dodBox.Add_KeyDown($onKey)

# ------------------------------------------------------------------------------------- initial state
foreach ($entry in $script:entries) { $runList.Items.Add($entry.Label) | Out-Null }

# Default to a new run: resuming is a deliberate choice, and the rows below make it a one-click one.
$start = 0
if ($RunId) {
  for ($i = 0; $i -lt $script:entries.Count; $i++) {
    if ($script:entries[$i].Id -eq $RunId) { $start = $i; break }
  }
} elseif ($Path) {
  for ($i = 0; $i -lt $script:entries.Count; $i++) {
    if ($script:entries[$i].DefFile -and ($script:entries[$i].DefFile -eq $Path)) { $start = $i; break }
  }
}

$script:suppressSelect = $true
$runList.SelectedIndex = $start
$script:suppressSelect = $false
Load-Entry $start

# -Live reattaches to a run that is already going: the loop is driven by the launcher and does not care
# whether this window exists, so there is nothing to approve and nothing to hand over.
if ($Live) {
  if (-not $RunId) {
    [System.Windows.Forms.MessageBox]::Show('-Live needs -RunId, so it knows which run to attach to.', 'Nothing to attach to', 'OK', 'Warning') | Out-Null
    exit 1
  }
  Enter-LiveMode $RunId (Join-Path (Join-Path $Root $RunId) 'definition.md')
}

[void]$form.ShowDialog()
$sessionTimer.Stop()
$sessionTimer.Dispose()
$form.Dispose()
exit $script:result
