# Sends real (OS-level) input to the desktop: clicks at screen coordinates (physical pixels) and
# keystrokes in SendKeys syntax (^ Ctrl, + Shift, % Alt, {ESC}, {ENTER}, ...). Run in the
# interactive session (run-interactive.ps1) when invoked over SSH.
# Keystrokes go to the foreground window: first -Process's main window (default SwiftUIHost).
# -Shot saves a screenshot after the input from this same process (starting another one would
# take the focus and close open menus/flyouts).
# -Steps runs several actions in one process (e.g. open a menu, then click an item):
#   "click:146,72; wait:400; click:204,175; keys:^i; text:hi" (move:x,y moves the pointer without clicking)
# Usage: input.ps1 -X 120 -Y 80 [-Right] | -Keys "^i" | -Text "hello" | -Steps "..." [-Process name] [-DelayMs 300] [-Shot path.png]
param([int]$X = -1, [int]$Y = -1, [switch]$Right, [string]$Keys, [string]$Text, [string]$Steps, [string]$Process = "SwiftUIHost", [int]$DelayMs = 300, [string]$Shot)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Input {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    public static void Click(int x, int y, bool right) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(60);
        mouse_event(right ? 0x0008u : 0x0002u, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(60);
        mouse_event(right ? 0x0010u : 0x0004u, 0, 0, 0, UIntPtr.Zero);
    }
}
"@
[Input]::SetProcessDPIAware() | Out-Null
if ($X -ge 0 -and $Y -ge 0) { [Input]::Click($X, $Y, $Right.IsPresent) }
if ($Keys -or $Text -or $Steps) {
    $target = Get-Process $Process -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1
    if ($target) { [Input]::SetForegroundWindow($target.MainWindowHandle) | Out-Null; Start-Sleep -Milliseconds 150 }
}
if ($Keys) { [System.Windows.Forms.SendKeys]::SendWait($Keys) }
if ($Text) { [System.Windows.Forms.SendKeys]::SendWait(($Text -replace '([+^%~(){}\[\]])', '{$1}')) }
foreach ($step in ($Steps -split ";")) {
    $step = $step.Trim()
    if (-not $step) { continue }
    $kind, $value = $step -split ":", 2
    switch ($kind) {
        "move" { $p = $value -split ","; [Input]::SetCursorPos([int]$p[0], [int]$p[1]) | Out-Null }
        "click" { $p = $value -split ","; [Input]::Click([int]$p[0], [int]$p[1], $false) }
        "rclick" { $p = $value -split ","; [Input]::Click([int]$p[0], [int]$p[1], $true) }
        "keys" { [System.Windows.Forms.SendKeys]::SendWait($value) }
        "text" { [System.Windows.Forms.SendKeys]::SendWait(($value -replace '([+^%~(){}\[\]])', '{$1}')) }
        "wait" { Start-Sleep -Milliseconds ([int]$value) }
    }
    Start-Sleep -Milliseconds 150
}
Start-Sleep -Milliseconds $DelayMs
if ($Shot) {
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
    $bitmap.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose()
}
