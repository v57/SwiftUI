# Installs staged WinUI apps (build-app.ps1's .build\winui\<Product> folders) side by side with one shared runtime:
#   <Destination>\Runtime\       the host, .NET, the Windows App SDK and the Swift runtime, once
#   <Destination>\<App>\         <App>.exe and the runtime as hard links into Runtime, plus the app's own DLLs,
#                                Info.plist and swiftui-app.txt as real files
# Every app keeps its own exe in its own folder, so Foundation's main bundle (Info.plist: bundle identifier, settings
# file), the Windows App SDK's registration-free classes (resolved next to the exe) and the taskbar identity stay the
# app's; on disk the runtime exists once. A file counts as runtime when every app has it, byte for byte.
# Shortcuts to each app go to the desktop unless -NoShortcuts.
# Usage: Windows/scripts/install-apps.ps1 -Apps @{ Shell = "C:\dev\Shell\.build\winui\ShellWinUI"; ... }
#        [-Destination "$env:USERPROFILE\Desktop\v57 Apps"] [-NoShortcuts]
param(
    [Parameter(Mandatory)][hashtable]$Apps,
    [string]$Destination = (Join-Path ([Environment]::GetFolderPath("Desktop")) "v57 Apps"),
    [switch]$NoShortcuts
)
$ErrorActionPreference = "Stop"
$hostFiles = "SwiftUIHost.exe", "SwiftUIHost.pri", "SwiftUIHost.dll", "SwiftUIHost.deps.json", "SwiftUIHost.runtimeconfig.json"
$perApp = "Info.plist", "swiftui-app.txt"

# The files of each staged app (relative paths, debug symbols left out) and their hashes.
$staged = @{}
foreach ($name in $Apps.Keys) {
    $root = (Resolve-Path $Apps[$name]).Path
    if (-not (Test-Path "$root\SwiftUIHost.exe")) { throw "$name isn't staged: $root\SwiftUIHost.exe is missing" }
    $files = @{}
    Get-ChildItem $root -Recurse -File | Where-Object { $_.Extension -ne ".pdb" } | ForEach-Object {
        $files[$_.FullName.Substring($root.Length + 1)] = $_.FullName
    }
    $staged[$name] = $files
}

# Runtime: the files every app has with the same content (the host's always; its builds can differ in timestamps).
$first = @($Apps.Keys)[0]
$runtime = @{}
foreach ($path in $staged[$first].Keys) {
    if ($perApp -contains $path) { continue }
    if ($hostFiles -contains $path) { $runtime[$path] = $staged[$first][$path]; continue }
    $hash = (Get-FileHash $staged[$first][$path]).Hash
    $shared = $true
    foreach ($name in $Apps.Keys) {
        $other = $staged[$name][$path]
        if (-not $other -or (Get-Item $other).Length -ne (Get-Item $staged[$first][$path]).Length -or (Get-FileHash $other).Hash -ne $hash) {
            $shared = $false
            break
        }
    }
    if ($shared) { $runtime[$path] = $staged[$first][$path] }
}

New-Item -ItemType Directory -Force $Destination | Out-Null
$runtimeDir = Join-Path $Destination "Runtime"
if (Test-Path $runtimeDir) { Remove-Item -Recurse -Force $runtimeDir }
foreach ($path in $runtime.Keys) {
    $target = Join-Path $runtimeDir $path
    New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
    Copy-Item $runtime[$path] $target
}

$desktop = [Environment]::GetFolderPath("Desktop")
$shell = New-Object -ComObject WScript.Shell
$report = @()
foreach ($name in $Apps.Keys) {
    $appDir = Join-Path $Destination $name
    if (Test-Path $appDir) { Remove-Item -Recurse -Force $appDir }
    $own = 0
    foreach ($path in $staged[$name].Keys) {
        # The host's exe and resources take the app's name: WinUI reads <exe name>.pri.
        $leaf = switch ($path) { "SwiftUIHost.exe" { "$name.exe" } "SwiftUIHost.pri" { "$name.pri" } default { $path } }
        $target = Join-Path $appDir $leaf
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        if ($runtime.ContainsKey($path)) {
            New-Item -ItemType HardLink -Path $target -Target (Join-Path $runtimeDir $path) | Out-Null
        } else {
            Copy-Item $staged[$name][$path] $target
            $own += (Get-Item $target).Length
        }
    }
    if (-not $NoShortcuts) {
        $link = $shell.CreateShortcut((Join-Path $desktop "$name.lnk"))
        $link.TargetPath = Join-Path $appDir "$name.exe"
        $link.WorkingDirectory = $appDir
        $link.Save()
    }
    $report += "{0,-10} {1,6:N0} MB of its own" -f $name, ($own / 1MB)
}
$runtimeSize = (Get-ChildItem $runtimeDir -Recurse -File | Measure-Object Length -Sum).Sum
"{0,-10} {1,6:N0} MB, {2} files, shared" -f "Runtime", ($runtimeSize / 1MB), $runtime.Count
$report
