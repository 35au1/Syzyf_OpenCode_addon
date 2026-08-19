# status.ps1 - where is the DoD loop right now?
#
#   powershell -ExecutionPolicy Bypass -File .\status.ps1
#   powershell -ExecutionPolicy Bypass -File .\status.ps1 -RunId 00003
#
# Asks the opencode server directly. The TUI renders a snapshot and does not reliably receive live
# events, so a window that looks frozen is not evidence of a stalled turn. This is.

param(
  # Defaults to the newest run folder, which is almost always the one you meant.
  [string]$RunId = ''
)

$base = $env:OPENCODE_BASE_URL
if (-not $base) { $base = 'http://localhost:4096' }

$root = Join-Path $PSScriptRoot 'projectfiles'
if (-not (Test-Path $root)) { Write-Output "no projectfiles folder: no run has started"; exit 0 }

if (-not $RunId) {
  $newest = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
    Where-Object Name -Match '^\d{5}$' | Sort-Object Name | Select-Object -Last 1
  if (-not $newest) { Write-Output "no run folders under $root"; exit 0 }
  $RunId = $newest.Name
}

$runDir = Join-Path $root $RunId
$logFile = Join-Path $runDir 'run.log'
if (-not (Test-Path $logFile)) { Write-Output "run $RunId has no run.log yet: the loop has not started"; exit 0 }

Write-Output ("run:   " + $RunId)
Write-Output ("files: " + $runDir)
Write-Output ''

$log = Get-Content $logFile
$cycleLine = ($log | Select-String -Pattern '^cycle \d+: work (\S+)\s+verifier (\S+)$' | Select-Object -Last 1)
if (-not $cycleLine) {
  Write-Output 'no cycle line in run.log yet'
  Write-Output ($log -join "`n")
  exit 0
}

$work = $cycleLine.Matches[0].Groups[1].Value
$verify = $cycleLine.Matches[0].Groups[2].Value
$now = [datetimeoffset]::UtcNow.ToUnixTimeMilliseconds()

Write-Output ('now: ' + (Get-Date -Format 'HH:mm:ss') + '    ' + $cycleLine.Line)
Write-Output ''

# The server states a pending retry outright, including a quota refusal it is sitting on. Worth
# surfacing here: it is the difference between "thinking" and "blocked for the next two hours".
try {
  $status = Invoke-RestMethod -Uri ($base + '/session/status') -Method Get -TimeoutSec 30
} catch {
  $status = $null
}

foreach ($pair in @(@('work  ', $work), @('verify', $verify))) {
  try {
    $msgs = @((Invoke-RestMethod -Uri ($base + '/session/' + $pair[1] + '/message') -Method Get -TimeoutSec 30))
  } catch {
    Write-Output ($pair[0] + ': unreachable - ' + $PSItem.Exception.Message)
    continue
  }

  $retry = $null
  if ($status) { $retry = $status.($pair[1]) }
  if ($retry -and $retry.type -eq 'retry') {
    $dueIn = [math]::Round(($retry.next - $now) / 60000)
    Write-Output ($pair[0] + ': RETRY  attempt=' + $retry.attempt + '  reason=' + $retry.action.reason + '  due in ' + $dueIn + 'm  ' + $retry.message)
    continue
  }

  if ($msgs.Count -eq 0) {
    # Normal for the verifier: it is only prompted once the work turn returns.
    Write-Output ($pair[0] + ': not prompted yet  messages=0')
    continue
  }
  $last = $msgs[-1]
  $done = [bool]$last.info.time.completed
  $lastPart = @($last.parts)[-1]
  $stamp = $last.info.time.completed
  if (-not $done) { $stamp = $last.info.time.created }
  # Clamped: the server's clock and this one disagree by a second or two, which otherwise shows as a
  # negative age.
  $age = [math]::Max(0, [math]::Round(($now - $stamp) / 1000))
  $state = 'RUNNING'
  if ($done) { $state = 'idle   ' }
  $tool = ''
  if ($lastPart.tool) { $tool = '  tool=' + $lastPart.tool }
  Write-Output ($pair[0] + ': ' + $state + '  messages=' + $msgs.Count + '  lastPart=' + $lastPart.type + $tool + '  ' + $age + 's ago')
}

Write-Output ''
Write-Output ('--- ' + $logFile + ' ---')
Write-Output ($log -join "`n")
