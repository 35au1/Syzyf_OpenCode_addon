# definition-gui.ps1 - the review window shown before a run starts.
#
#   powershell -NoProfile -Sta -ExecutionPolicy Bypass -File .\definition-gui.ps1 -Path <definition.md> -RunId 00001
#
# WinForms, because it ships with Windows and needs no dependency the loop does not already have.
# There is nothing to install and nothing to keep in sync with package.json.
#
# The file stays ONE string: it is handed to the verifier whole. The two boxes are an editing view of
# it, split on the section headings and written back with those same headings, so nothing downstream
# has to know this window exists.
#
# THIS FILE IS PURE ASCII ON PURPOSE. Windows PowerShell 5.1 reads a BOM-less script as ANSI, so a
# literal block character here would arrive mangled on a machine with a different code page. The logo
# is drawn with '#' and the blocks are substituted in at runtime instead.
#
# Exit codes, which run-dod-loop.bat branches on:
#   0  launch this run
#   1  quit, keep the run folder
#   2  no GUI available here, fall back to a text editor

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [string]$RunId = '',
  # Print how the file splits and exit without opening a window. For checking that an existing
  # definition lands in the boxes you expect.
  [switch]$SelfTest,
  # Rewrite the file with the canonical headings and exit. Same save path the window uses, so an old
  # single-section definition can be brought into the two-section shape without opening anything.
  [switch]$Normalize
)

$ErrorActionPreference = 'Stop'

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
  if (Test-Path -LiteralPath $file) { $text = [System.IO.File]::ReadAllText($file) }

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
  # No BOM: the file is read back as UTF-8 text by Bun and pasted into a prompt, and a BOM there is
  # just three stray characters at the top of the rules.
  [System.IO.File]::WriteAllText($file, $body, (New-Object System.Text.UTF8Encoding($false)))
}

if ($SelfTest -or $Normalize) {
  $parsed = Read-Sections $Path
  if ($Normalize) {
    Write-Sections $Path $parsed.Task $parsed.Dod
    $parsed = Read-Sections $Path
    Write-Output ("rewrote " + $Path)
  }
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

$sections = Read-Sections $Path

$mono = New-Object System.Drawing.Font('Consolas', 10)
$logoFont = New-Object System.Drawing.Font('Consolas', 9)
$bold = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$subFont = New-Object System.Drawing.Font('Segoe UI', 11)
$small = New-Object System.Drawing.Font('Segoe UI', 9)
$tiny = New-Object System.Drawing.Font('Segoe UI', 8)

$form = New-Object System.Windows.Forms.Form
$title = 'Syzyf'
if ($RunId) { $title = "Syzyf - run $RunId" }
$form.Text = $title
# Narrow on purpose: the logo is 42 characters wide and the prose wraps below it, so extra width only
# stretches the text boxes into unreadable long lines.
$form.Size = New-Object System.Drawing.Size(600, 840)
$form.MinimumSize = New-Object System.Drawing.Size(520, 560)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor = $Bg
$form.ForeColor = $Fg

$grid = New-Object System.Windows.Forms.TableLayoutPanel
$grid.Dock = 'Fill'
$grid.BackColor = $Bg
$grid.ColumnCount = 1
$grid.RowCount = 6
$grid.Padding = New-Object System.Windows.Forms.Padding(14, 12, 14, 12)
foreach ($kind in @('AutoSize', 'AutoSize', 'Percent', 'AutoSize', 'Percent', 'AutoSize')) {
  $style = New-Object System.Windows.Forms.RowStyle
  $style.SizeType = $kind
  $grid.RowStyles.Add($style) | Out-Null
}
$grid.RowStyles[2].Height = 34
$grid.RowStyles[4].Height = 66
$form.Controls.Add($grid)

# -------------------------------------------------------------------------------------------- header
$header = New-Object System.Windows.Forms.Panel
$header.BackColor = $Panel
$header.Dock = 'Fill'
$header.AutoSize = $true
$header.AutoSizeMode = 'GrowAndShrink'
$header.Padding = New-Object System.Windows.Forms.Padding(18, 14, 18, 16)
$header.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 14)

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

$task = New-Box $sections.Task
$dod = New-Box $sections.Dod
$taskBox = $task.Box
$dodBox = $dod.Box

$grid.Controls.Add((New-Label '1. Task to perform' 0), 0, 1)
$grid.Controls.Add($task.Frame, 0, 2)
$grid.Controls.Add((New-Label '2. Definition of Done' 12), 0, 3)
$grid.Controls.Add($dod.Frame, 0, 4)

# ------------------------------------------------------------------------------------------- buttons
$buttons = New-Object System.Windows.Forms.TableLayoutPanel
$buttons.Dock = 'Fill'
$buttons.AutoSize = $true
$buttons.BackColor = $Bg
$buttons.ColumnCount = 3
$buttons.RowCount = 1
$buttons.Margin = New-Object System.Windows.Forms.Padding(0, 12, 0, 0)
foreach ($width in @(100, 0, 0)) {
  $style = New-Object System.Windows.Forms.ColumnStyle
  if ($width -gt 0) { $style.SizeType = 'Percent'; $style.Width = $width } else { $style.SizeType = 'AutoSize' }
  $buttons.ColumnStyles.Add($style) | Out-Null
}

$hint = New-Object System.Windows.Forms.Label
$hint.AutoSize = $false
$hint.Dock = 'Fill'
$hint.Font = $tiny
$hint.ForeColor = $Muted
$hint.BackColor = $Bg
$hint.TextAlign = 'MiddleLeft'
$hint.Text = 'Both sections are saved as one file and judged as one whole.  Ctrl+Enter launches.' + [Environment]::NewLine + $Path
$buttons.Controls.Add($hint, 0, 0)

function Set-ButtonStyle($button, $back) {
  $button.AutoSize = $true
  $button.FlatStyle = 'Flat'
  $button.BackColor = $back
  $button.ForeColor = $Fg
  $button.FlatAppearance.BorderSize = 0
  $button.Padding = New-Object System.Windows.Forms.Padding(18, 6, 18, 6)
  $button.Margin = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
}

$quit = New-Object System.Windows.Forms.Button
$quit.Text = 'Quit'
Set-ButtonStyle $quit $BtnFace
$buttons.Controls.Add($quit, 1, 0)

$launch = New-Object System.Windows.Forms.Button
$launch.Text = 'Save and launch'
Set-ButtonStyle $launch $BtnGo
$launch.Font = $bold
$launch.ForeColor = [System.Drawing.Color]::White
$buttons.Controls.Add($launch, 2, 0)

$grid.Controls.Add($buttons, 0, 5)

# Quit is the default outcome, so closing the window with the X cannot be read as approval.
$script:result = 1

$launch.Add_Click({
    if (-not $dodBox.Text.Trim()) {
      [System.Windows.Forms.MessageBox]::Show(
        'The Definition of Done is empty, so there is nothing to verify against and the run can never pass.',
        'Nothing to work towards', 'OK', 'Warning') | Out-Null
      $dodBox.Focus() | Out-Null
      return
    }
    try {
      Write-Sections $Path $taskBox.Text $dodBox.Text
    } catch {
      [System.Windows.Forms.MessageBox]::Show("Could not save:`r`n$($_.Exception.Message)", 'Save failed', 'OK', 'Error') | Out-Null
      return
    }
    $script:result = 0
    $form.Close()
  })

$quit.Add_Click({
    $script:result = 1
    $form.Close()
  })

$form.CancelButton = $quit
$form.Add_Shown({
    Set-DarkTitleBar $form.Handle
    $taskBox.Focus() | Out-Null
  })

# Ctrl+Enter launches from either box, since plain Enter belongs to the text.
$onKey = {
  param($sender, $e)
  if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
    $e.SuppressKeyPress = $true
    $launch.PerformClick()
  }
}
$taskBox.Add_KeyDown($onKey)
$dodBox.Add_KeyDown($onKey)

[void]$form.ShowDialog()
$form.Dispose()
exit $script:result
