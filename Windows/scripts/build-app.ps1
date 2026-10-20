# Builds a SwiftUI app for Windows and stages it with the WinUI host:
# 1. builds the Swift app DLL (`swift build --product <Product>`, e.g. GalleryWinUI.dll),
# 2. builds the C# host (Windows/SwiftUIHost, unpackaged, self-contained Windows App SDK),
# 3. stages the app DLL and the Swift runtime next to SwiftUIHost.exe in .build\winui\<Product>,
# 4. optionally runs it (-Run; -Script/-Log are passed to the host).
# Usage: Windows/scripts/build-app.ps1 [-Product GalleryWinUI] [-PackagePath dir] [-Configuration debug|release] [-Run] [-Script file] [-Log file]
#   -PackagePath builds an app from another package that depends on SwiftUI (e.g. Ports\hub-app\WindowsBuild).
param(
    [string]$Product = "GalleryWinUI",
    [string]$PackagePath,
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
$package = if ($PackagePath) { (Resolve-Path $(if ([IO.Path]::IsPathRooted($PackagePath)) { $PackagePath } else { Join-Path $root $PackagePath })).Path } else { $root }

Write-Host "Building $Product ($Configuration)"
# CodeView debug info and PDBs, so cdb and WER dumps (C:\dev\dumps) show Swift frames.
$debugInfo = @("-Xswiftc", "-g", "-Xswiftc", "-debug-info-format=codeview", "-Xlinker", "-debug")
swift build --package-path $package --product $Product -c $Configuration @debugInfo
if ($LASTEXITCODE -ne 0) { throw "swift build failed" }
$bin = (swift build --package-path $package -c $Configuration @debugInfo --show-bin-path).Trim()
$dll = Join-Path $bin "$Product.dll"
if (-not (Test-Path $dll)) { throw "Build failed: $dll missing" }

$out = Join-Path $package ".build\winui\$Product"
if (-not $SkipHost -or -not (Test-Path "$out\SwiftUIHost.exe")) {
    Write-Host "Building the WinUI host"
    dotnet build "$root\Windows\SwiftUIHost\SwiftUIHost.csproj" -c Debug -r "win-$arch" -p:Platform=$($arch.ToUpper()) -o $out --nologo -v quiet
    if ($LASTEXITCODE -ne 0) { throw "dotnet build failed" }
}

# SwiftUI's view graph recurses as deep as an app's views nest (generic metadata, layout, rendering), and
# Windows gives the main thread a 1 MB stack by default (macOS: 8 MB), which deep pages overflowed. Raise the
# host's stack reserve in its PE header (SizeOfStackReserve, PE32+ optional header offset 72).
$exe = "$out\SwiftUIHost.exe"
$bytes = [IO.File]::ReadAllBytes($exe)
$optional = [BitConverter]::ToInt32($bytes, 0x3C) + 24
if ([BitConverter]::ToUInt16($bytes, $optional) -eq 0x20B -and [BitConverter]::ToUInt64($bytes, $optional + 72) -ne 64MB) {
    [BitConverter]::GetBytes([UInt64]64MB).CopyTo($bytes, $optional + 72)
    [IO.File]::WriteAllBytes($exe, $bytes)
}

# The app DLL, other DLLs it built (dynamic dependencies), and the Swift runtime.
Copy-Item $dll $out -Force
Get-ChildItem $bin -Filter *.pdb | Copy-Item -Destination $out -Force
Get-ChildItem $bin -Filter *.dll | Where-Object { $_.Name -ne "$Product.dll" } | Copy-Item -Destination $out -Force
$swiftCore = (Get-Command swiftCore.dll -ErrorAction SilentlyContinue).Source
if ($swiftCore) {
    Get-ChildItem (Split-Path $swiftCore) -Filter *.dll | Copy-Item -Destination $out -Force
} else {
    Write-Warning "Swift runtime (swiftCore.dll) not on PATH; the host will look for it on PATH at launch"
}
Set-Content -Path "$out\swiftui-app.txt" -Value $Product -NoNewline

# Info.plist next to the host, which Foundation reads as the main bundle's: the app's name, version and bundle
# identifier from its Xcode project (the first target's), so its defaults are its own file
# (%LOCALAPPDATA%\<identifier>.plist) and not the host's, shared by every app.
$name = if ($Product -match '^(.+)WinUI$') { $Matches[1] } else { $Product }
$project = Get-ChildItem $package -Filter project.pbxproj -Recurse -Depth 2 -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\(\.build|Pods)\\' } | Select-Object -First 1
$identifier = "dev.v57.$($name.ToLowerInvariant())"
$version = "1.0"
if ($project) {
    $settings = Get-Content $project.FullName -Raw
    if ($settings -match 'PRODUCT_BUNDLE_IDENTIFIER = "?([A-Za-z0-9.\-]+)"?;') { $identifier = $Matches[1] }
    if ($settings -match 'MARKETING_VERSION = "?([0-9.]+)"?;') { $version = $Matches[1] }
}
$escape = { param($text) [Security.SecurityElement]::Escape($text) }
@"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$(& $escape $identifier)</string>
    <key>CFBundleName</key><string>$(& $escape $name)</string>
    <key>CFBundleShortVersionString</key><string>$(& $escape $version)</string>
</dict>
</plist>
"@ | Set-Content -Path "$out\Info.plist" -Encoding UTF8
Write-Host "Staged: $out ($identifier $version)"

if ($Run) {
    $arguments = @()
    if ($Script) { $arguments += @("--script", (Resolve-Path $Script).Path) }
    if ($Log) { $arguments += @("--log", $Log) }
    & "$out\SwiftUIHost.exe" @arguments
}
