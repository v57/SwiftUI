# Opens an app once per page (`--page <id>`, e.g. the ComponentKit catalog's), screenshots each page into -Out and
# reports ok, CRASH (WER dumps go to C:\dev\dumps when LocalDumps is set for SwiftUIHost.exe) or HANG (with the main
# thread's stack in <page>.hang.txt; a HANG with the host idle is the screenshot step stalling, not the app).
#   Windows/scripts/pages.ps1 -Exe <staged SwiftUIHost.exe> -Pages a,b,c [-Seconds 15]
param([string]$Exe, [string[]]$Pages, [string]$Out = "C:\dev\shots\pages", [int]$Seconds = 10)
New-Item -ItemType Directory -Force $Out | Out-Null
Get-Process SwiftUIHost -ErrorAction SilentlyContinue | Stop-Process -Force
foreach ($page in $Pages) {
    $script = "$Out\$page.script"
    Set-Content $script "wait 4000`nscreenshot $Out\$page.png`nexit"
    Remove-Item "$Out\$page.png", "$Out\$page.log" -ErrorAction SilentlyContinue
    & C:\dev\SwiftUI\Windows\scripts\run-interactive.ps1 -Command $Exe -Arguments "--page $page --script $script --log $Out\$page.log" -NoWait | Out-Null
    $deadline = (Get-Date).AddSeconds($Seconds)
    do { Start-Sleep -Milliseconds 500; $p = Get-Process SwiftUIHost -ErrorAction SilentlyContinue } while ($p -and (Get-Date) -lt $deadline)
    if ($p) {
        $cpu = $p.CPU
        $cdb = "C:\Program Files (x86)\Windows Kits\10\Debuggers\arm64\cdb.exe"
        & $cdb -pv -p $p.Id -y (Split-Path $Exe) -c "~0kn 40; qd" 2>&1 | Select-String -Pattern "^[0-9a-f]{2} " | Select -First 40 | ForEach-Object { $_.Line.Substring(0, [Math]::Min(200, $_.Line.Length)) } | Set-Content "$Out\$page.hang.txt"
        Start-Sleep 2
        "{0,-16} cpu {1:N1}s -> {2:N1}s" -f $page, $cpu, (Get-Process -Id $p.Id).CPU
    }
    $status = if ($p) { "HANG"; $p | Stop-Process -Force } elseif (Test-Path "$Out\$page.png") { "ok" } else { "CRASH" }
    Get-ScheduledTask -TaskName "SwiftUI-Interactive-*" -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
    "{0,-16} {1}" -f $page, $status
}
