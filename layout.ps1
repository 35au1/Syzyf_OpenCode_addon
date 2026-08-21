# layout.ps1 - first-run window placement: Syzyf down the left edge, the opencode TUI filling the rest.
#
#   powershell -NoProfile -File .\layout.ps1 -Plan
#   powershell -NoProfile -File .\layout.ps1 -StartTui -Rect "614,0,1306,1032" -Port 4096
#   powershell -NoProfile -File .\layout.ps1 -MinimizeParent
#
# Why a separate script rather than a few lines in the launcher: the split has to be agreed on by two
# processes that never talk to each other. The review window has to size itself, and the launcher has to
# place a console window it did not draw. Computing it twice is how they would end up overlapping, so
# -Plan is the single answer both are handed.
#
# This is a STARTING layout only. Nothing re-applies it, so dragging either window afterwards sticks.
#
# Console windows cannot be sized by a WinForms property, only by MoveWindow on their handle, which is
# why this reaches for user32 at all.
#
# ASCII only, and no PowerShell 6+ syntax: this runs under Windows PowerShell 5.1.

[CmdletBinding()]
param(
  # Print "<gui rect>|<tui rect>", each as "x,y,width,height". The launcher reads this with for /f.
  [switch]$Plan,
  # Start the opencode TUI in its own console window and move it to -Rect. Prints the process id.
  [switch]$StartTui,
  # Minimise the console that invoked this script, i.e. the launcher's own window.
  [switch]$MinimizeParent,
  # Target rectangle for -StartTui, as "x,y,width,height".
  [string]$Rect = '',
  [int]$Port = 4096,
  # Where the TUI should run. opencode treats its working directory as the project, so this matters.
  [string]$WorkDir = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Add-Type -AssemblyName System.Windows.Forms

Add-Type -Namespace SyzyfLayout -Name Api -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool MoveWindow(System.IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT lpRect);

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumWindows(EnumProc lpEnumFunc, System.IntPtr lParam);
public delegate bool EnumProc(System.IntPtr hWnd, System.IntPtr lParam);

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr hWnd);

[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint processId);

public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@

# Finding a console window is not as simple as asking the process for its main window.
#
# When the default terminal application is Windows Terminal - the default on current Windows 11 - the
# console is drawn by a WindowsTerminal process that is no relation of the command you started. The
# cmd.exe you launched reports MainWindowHandle = 0 and owns only an invisible window, while the real
# window belongs to a process you never asked for.
#
# So: snapshot the top-level windows, start the process, and look for a window that is new. That holds
# for conhost and for Windows Terminal alike, and it deliberately finds nothing when Windows Terminal
# opens the console as a TAB in an existing window, because moving that window would drag every other
# tab in it across the screen.

function Get-WindowHandles {
  $handles = New-Object System.Collections.ArrayList
  [void][SyzyfLayout.Api]::EnumWindows({
      param($hWnd, $lParam)
      [void]$handles.Add($hWnd.ToString())
      return $true
    }, [System.IntPtr]::Zero)
  return $handles
}

function Get-WindowInfo($handle) {
  $builder = New-Object System.Text.StringBuilder 512
  [void][SyzyfLayout.Api]::GetWindowText($handle, $builder, 512)
  $owner = [uint32]0
  [void][SyzyfLayout.Api]::GetWindowThreadProcessId($handle, [ref]$owner)
  $name = ''
  try { $name = (Get-Process -Id $owner -ErrorAction Stop).ProcessName } catch {}
  return @{ Title = $builder.ToString(); Pid = [int]$owner; Process = $name }
}

# ShowWindow's "minimise without stealing activation".
$SW_SHOWMINNOACTIVE = 7

# ---------------------------------------------------------------------------------------------- plan

# How many Syzyf windows are already on screen.
#
# Each concurrent run gets its own review window, and without this they would stack exactly on top of
# each other: same plan in, same rectangle out. Counting them turns the second launch into a cascade.
function Get-SyzyfWindowCount {
  $count = 0
  foreach ($handle in (Get-WindowHandles)) {
    $window = [System.IntPtr]([int64]$handle)
    if (-not [SyzyfLayout.Api]::IsWindowVisible($window)) { continue }
    $info = Get-WindowInfo $window
    if ($info.Title -like 'Syzyf*') { $count++ }
  }
  return $count
}

function Get-LayoutPlan {
  # WorkingArea, not Bounds: it excludes the taskbar, so "full height" means full USABLE height.
  # Primary screen only. A run spread over two monitors is a preference, not a default.
  $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

  # The review window is a reading column: two text boxes and a session list. Past roughly 760px the
  # lines get too long to scan, and below 560 the button row starts wrapping.
  $width = [int]($area.Width * 0.32)
  if ($width -lt 560) { $width = 560 }
  if ($width -gt 760) { $width = 760 }
  # A narrow screen: never leave the TUI less than half, since that is where the work is read.
  if ($width -gt [int]($area.Width / 2)) { $width = [int]($area.Width / 2) }

  # Cascade, so a second concurrent run is visible rather than hidden under the first. Only the review
  # window shifts: the TUI slot is shared, because the second launcher attaches to the server the first
  # one started instead of opening another.
  $slot = Get-SyzyfWindowCount
  $shift = $slot * 34
  $guiX = $area.X + $shift
  $guiY = $area.Y + $shift
  $guiHeight = $area.Height - $shift
  # Past a handful of windows, start again at the top rather than walking off the screen.
  if ($guiHeight -lt 620 -or ($guiX + $width) -gt $area.Right) {
    $guiX = $area.X
    $guiY = $area.Y
    $guiHeight = $area.Height
  }

  return @{
    Gui = ('{0},{1},{2},{3}' -f $guiX, $guiY, $width, $guiHeight)
    Tui = ('{0},{1},{2},{3}' -f ($area.X + $width), $area.Y, ($area.Width - $width), $area.Height)
  }
}

function ConvertFrom-Rect([string]$text) {
  $parts = @($text.Split(','))
  if ($parts.Count -ne 4) { throw "expected a rect as x,y,width,height but got '$text'" }
  return @{
    X = [int]$parts[0].Trim()
    Y = [int]$parts[1].Trim()
    W = [int]$parts[2].Trim()
    H = [int]$parts[3].Trim()
  }
}

if ($Plan) {
  # $layout, not $plan: PowerShell variable names are case-insensitive, so assigning a hashtable to
  # $plan would be assigning it to the -Plan switch parameter, which refuses anything but a boolean.
  $layout = Get-LayoutPlan
  Write-Output ($layout.Gui + '|' + $layout.Tui)
  exit 0
}

# ------------------------------------------------------------------------------------- minimise self

if ($MinimizeParent) {
  # The caller is a batch file, so this script's parent process IS that console. Nothing else can be
  # asked for its window handle from here.
  try {
    $parentId = (Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $PID").ParentProcessId
    $parent = Get-Process -Id $parentId -ErrorAction Stop
    if ($parent.MainWindowHandle -ne [System.IntPtr]::Zero) {
      [void][SyzyfLayout.Api]::ShowWindow($parent.MainWindowHandle, $SW_SHOWMINNOACTIVE)
      Write-Output ('minimised ' + $parent.ProcessName + ' pid ' + $parent.Id)
      exit 0
    }
    Write-Output 'parent console has no window to minimise'
  } catch {
    Write-Output ('could not minimise the launcher window: ' + $_.Exception.Message)
  }
  exit 0
}

# ----------------------------------------------------------------------------------------- start tui

if ($StartTui) {
  if (-not $WorkDir) { $WorkDir = $PSScriptRoot }
  $target = $null
  if ($Rect) { $target = ConvertFrom-Rect $Rect } else { $target = ConvertFrom-Rect (Get-LayoutPlan).Tui }

  # Everything on screen before we start. Anything new afterwards is a candidate.
  $existing = @{}
  foreach ($handle in (Get-WindowHandles)) { $existing[$handle] = $true }

  # `cmd /k` so the window survives opencode exiting and its last output stays readable.
  $process = Start-Process -FilePath 'cmd.exe' `
    -ArgumentList '/k', 'opencode', '--port', ([string]$Port) `
    -WorkingDirectory $WorkDir -PassThru

  if (-not $process) {
    Write-Output 'ERROR could not start the TUI'
    exit 1
  }

  # The window appears a moment after the process, and long before opencode has bound its port, so this
  # wait costs nothing against the port check that follows.
  $found = [System.IntPtr]::Zero
  $foundWhat = ''
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    Start-Sleep -Milliseconds 250
    foreach ($handle in (Get-WindowHandles)) {
      if ($existing.ContainsKey($handle)) { continue }
      $candidate = [System.IntPtr]([int64]$handle)
      if (-not [SyzyfLayout.Api]::IsWindowVisible($candidate)) { continue }
      $info = Get-WindowInfo $candidate
      # An untitled window is the invisible one cmd.exe keeps for itself, not the console.
      if (-not $info.Title) { continue }
      $isTerminal = @('WindowsTerminal', 'OpenConsole', 'conhost', 'cmd') -contains $info.Process
      $looksRight = ($info.Title -like '*opencode*') -or ($info.Title -like '*cmd.exe*')
      if ($isTerminal -or $looksRight) {
        $found = $candidate
        $foundWhat = $info.Process + ' "' + $info.Title + '"'
        break
      }
    }
    if ($found -ne [System.IntPtr]::Zero) { break }
    try {
      $process.Refresh()
      if ($process.HasExited) { break }
    } catch { break }
  }

  if ($found -ne [System.IntPtr]::Zero) {
    [void][SyzyfLayout.Api]::MoveWindow($found, $target.X, $target.Y, $target.W, $target.H, $true)
    Write-Output ('placed ' + $foundWhat)
  }
  # Placement is cosmetic, so a window that cannot be found is reported and then ignored: the run
  # matters more than the geometry. The usual cause is Windows Terminal reusing an existing window as a
  # new tab, which is deliberately left alone.
  else {
    Write-Output 'NOTE could not find the TUI window to place it; position it yourself'
  }

  Write-Output ('PID=' + $process.Id)
  exit 0
}

Write-Output 'nothing to do: pass -Plan, -StartTui or -MinimizeParent'
exit 1
