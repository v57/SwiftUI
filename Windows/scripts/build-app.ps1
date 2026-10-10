# Builds a SwiftUI2 app for Windows and stages it with the WinUI host:
# 1. builds the Swift app DLL (`swift build --product <Product>`, e.g. GalleryWinUI.dll),
# 2. builds the C# host (Windows/SwiftUI2Host, unpackaged, self-contained Windows App SDK),
# 3. stages the app DLL and the Swift runtime next to SwiftUI2Host.exe in .build\winui\<Product>,
# 4. optionally runs it (-Run; -Script/-Log are passed to the host).
# Usage: Windows/scripts/build-app.ps1 [-Product GalleryWinUI] [-Configuration debug|release] [-Run] [-Script file] [-Log file]
param(
    [string]$Product = "GalleryWinUI",
    [ValidateSet("debug", "release")][string]$Configuration = "debug",
    [switch]$Run,
    [string]$Script,
    [string]$Log,
    [switch]$SkipHost
)
$ErrorActionPreference = "Stop"
$root = (Resolve-Path "$PSScriptRoot\..\..").Path
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }

& "$PSScriptRoot\fetch-assets.ps1" | Out-Null

Write-Host "Building $Product ($Configuration)"
swift build --package-path $root --product $Product -c $Configuration
if ($LASTEXITCODE -ne 0) { throw "swift build failed" }
$bin = (swift build --package-path $root -c $Configuration --show-bin-path).Trim()
$dll = Join-Path $bin "$Product.dll"
if (-not (Test-Path $dll)) { throw "Build failed: $dll missing" }

$out = Join-Path $root ".build\winui\$Product"
if (-not $SkipHost -or -not (Test-Path "$out\SwiftUI2Host.exe")) {
    Write-Host "Building the WinUI host"
    dotnet build "$root\Windows\SwiftUI2Host\SwiftUI2Host.csproj" -c Debug -r "win-$arch" -p:Platform=$($arch.ToUpper()) -o $out --nologo -v quiet
    if ($LASTEXITCODE -ne 0) { throw "dotnet build failed" }
}

# The app DLL, other DLLs it built (dynamic dependencies), and the Swift runtime.
Copy-Item $dll $out -Force
Get-ChildItem $bin -Filter *.dll | Where-Object { $_.Name -ne "$Product.dll" } | Copy-Item -Destination $out -Force
$swiftCore = (Get-Command swiftCore.dll -ErrorAction SilentlyContinue).Source
if ($swiftCore) {
    Get-ChildItem (Split-Path $swiftCore) -Filter *.dll | Copy-Item -Destination $out -Force
} else {
    Write-Warning "Swift runtime (swiftCore.dll) not on PATH; the host will look for it on PATH at launch"
}
Set-Content -Path "$out\swiftui2-app.txt" -Value $Product -NoNewline
Write-Host "Staged: $out"

if ($Run) {
    $arguments = @()
    if ($Script) { $arguments += @("--script", (Resolve-Path $Script).Path) }
    if ($Log) { $arguments += @("--log", $Log) }
    & "$out\SwiftUI2Host.exe" @arguments
}
