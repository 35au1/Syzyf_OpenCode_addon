# preflight.ps1 - is the folder ready for a clean run?
Write-Output '--- port 4096 ---'
$open = $false
try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', 4096); $c.Dispose(); $open = $true } catch { }
Write-Output ('  in use: ' + $open)
foreach ($t in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
  if ($t.LocalPort -eq 4096) {
    $p = Get-Process -Id $t.OwningProcess -ErrorAction SilentlyContinue
    Write-Output ('  owner pid=' + $t.OwningProcess + ' proc=' + $p.ProcessName)
  }
}

Write-Output '--- leftover processes ---'
$oc = @(Get-Process -Name opencode -ErrorAction SilentlyContinue)
Write-Output ('  opencode: ' + $oc.Count)
foreach ($p in $oc) { Write-Output ('    pid=' + $p.Id) }
$bun = @(Get-Process -Name bun -ErrorAction SilentlyContinue)
Write-Output ('  bun (a running dod-loop.ts is one of these): ' + $bun.Count)
foreach ($p in $bun) { Write-Output ('    pid=' + $p.Id) }

Write-Output '--- folder ---'
Get-ChildItem -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object FullName -NotLike '*node_modules*' |
  Where-Object FullName -NotLike '*\projectfiles\*' |
  Sort-Object Name |
  Select-Object Name, Length |
  Format-Table -AutoSize | Out-String -Width 120

Write-Output '--- runs (projectfiles) ---'
$root = Join-Path $PSScriptRoot 'projectfiles'
if (-not (Test-Path $root)) {
  Write-Output '  none yet'
} else {
  foreach ($d in @(Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Where-Object Name -Match '^\d{5}$' | Sort-Object Name)) {
    $log = Join-Path $d.FullName 'run.log'
    $size = 0
    if (Test-Path $log) { $size = (Get-Item $log).Length }
    Write-Output ('  ' + $d.Name + '  run.log=' + $size + ' bytes  ' + $d.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
  }
}
