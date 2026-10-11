# Runs a command in the logged-on user's interactive desktop session (from SSH, where processes
# otherwise start without a visible desktop) and waits for it to finish.
# Usage: Windows/scripts/run-interactive.ps1 -Command "C:\path\app.exe" [-Arguments "..."] [-TimeoutSeconds 120] [-NoWait]
param(
    [Parameter(Mandatory)][string]$Command,
    [string]$Arguments = "",
    [string]$WorkingDirectory = "C:\dev",
    [int]$TimeoutSeconds = 300,
    [switch]$NoWait
)
$ErrorActionPreference = "Stop"
$name = "SwiftUI-Interactive-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$action = if ($Arguments) { New-ScheduledTaskAction -Execute $Command -Argument $Arguments -WorkingDirectory $WorkingDirectory }
          else { New-ScheduledTaskAction -Execute $Command -WorkingDirectory $WorkingDirectory }
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds ([Math]::Max($TimeoutSeconds, 60)))
Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings | Out-Null
try {
    Start-ScheduledTask -TaskName $name
    if ($NoWait) { Start-Sleep -Seconds 2; return }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 500
        $state = (Get-ScheduledTask -TaskName $name).State
    } while ($state -eq "Running" -and (Get-Date) -lt $deadline)
    if ($state -eq "Running") { Stop-ScheduledTask -TaskName $name; Write-Warning "Timed out after $TimeoutSeconds s" }
    $result = (Get-ScheduledTaskInfo -TaskName $name).LastTaskResult
    Write-Host "Exit code: $result"
} finally {
    if (-not $NoWait) { Unregister-ScheduledTask -TaskName $name -Confirm:$false }
}
