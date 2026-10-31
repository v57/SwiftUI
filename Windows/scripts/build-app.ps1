# Builds a SwiftUI app for Windows and stages it with the WinUI host:
# 1. builds the Swift app DLL (`swift build --product <Product>`, e.g. GalleryWinUI.dll),
# 2. builds the C# host (Windows/SwiftUIHost, unpackaged, self-contained Windows App SDK),
# 3. stages the app DLL and the Swift runtime next to SwiftUIHost.exe in .build\winui\<Product>,
# 4. optionally runs it (-Run; -Script/-Log are passed to the host).
# A release build is cut for size (363 → 110 MB for Markdown): the Swift code is built with dead-code flags and staged
# without its symbols (the unstripped DLLs and PDBs go to .build\winui\<Product>.symbols), the host is a Native AOT
# exe (no .NET runtime), and the folder holds only the runtime DLLs something imports, WinUI's translations for the
# app's languages (the Xcode project's knownRegions) and no WinRT metadata (.winmd), WebView2 or RestartAgent.
# Usage: Windows/scripts/build-app.ps1 [-Product GalleryWinUI] [-PackagePath dir] [-Configuration debug|release] [-Run] [-Script file] [-Log file]
#   -PackagePath builds an app from another package that depends on SwiftUI (e.g. C:\dev\Get\App: a v57 app's package
#   is its repository's App\ folder).
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

$release = $Configuration -eq "release"
# The symbol fonts (Windows/scripts/symbol-fonts.py) are cut to SymbolNames.swift's glyphs: a table changed since
# shows new symbols as their names.
$table = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText("$root\Sources\SwiftUIWinUI\SymbolNames.swift").Replace("`r`n", "`n"))
$tableHash = -join ([Security.Cryptography.SHA256]::Create().ComputeHash($table) | ForEach-Object { $_.ToString("x2") })
if ($tableHash -ne (Get-Content "$root\Windows\SwiftUIHost\Assets\symbol-fonts.sha256" -ErrorAction SilentlyContinue)) {
    Write-Warning "SymbolNames.swift changed since the symbol fonts were cut: rerun Windows/scripts/symbol-fonts.py (on a machine with fontTools)"
}
$package = if ($PackagePath) { (Resolve-Path $(if ([IO.Path]::IsPathRooted($PackagePath)) { $PackagePath } else { Join-Path $root $PackagePath })).Path } else { $root }

Write-Host "Building $Product ($Configuration)"
# CodeView debug info and PDBs, so cdb and WER dumps (C:\dev\dumps) show Swift frames.
$flags = @("-Xswiftc", "-g", "-Xswiftc", "-debug-info-format=codeview", "-Xlinker", "-debug")
if ($release) {
    # Dead code: functions and data in sections of their own, public symbols nothing outside uses internalized at
    # link, type metadata only for types something uses (with /OPT:REF, which swift-build passes; Markdown's DLL:
    # 16.0 → 12.5 MB stripped).
    $flags += @("-Xswiftc", "-Osize", "-Xswiftc", "-function-sections", "-Xswiftc", "-Xfrontend", "-Xswiftc", "-internalize-at-link",
        "-Xswiftc", "-Xfrontend", "-Xswiftc", "-conditional-runtime-records", "-Xcc", "-ffunction-sections", "-Xcc", "-fdata-sections")
}
swift build --package-path $package --product $Product -c $Configuration @flags
if ($LASTEXITCODE -ne 0) { throw "swift build failed" }
$bin = (swift build --package-path $package -c $Configuration @flags --show-bin-path).Trim()
$dll = Join-Path $bin "$Product.dll"
if (-not (Test-Path $dll)) { throw "Build failed: $dll missing" }

$out = Join-Path $package ".build\winui\$Product"
$hostProject = "$root\Windows\SwiftUIHost\SwiftUIHost.csproj"
if (-not $SkipHost -or -not (Test-Path "$out\SwiftUIHost.exe")) {
    if ($release) {
        Write-Host "Publishing the WinUI host (Native AOT)"
        # A fresh folder: a debug host's .NET runtime and assemblies would stay behind.
        if (Test-Path $out) {
            Get-Process | Where-Object { $_.Path -like "$out\*" } | Stop-Process -Force
            Remove-Item -Recurse -Force $out
        }
        # Native AOT links with MSVC's link.exe: its tools and libraries from the Visual Studio (Build Tools)
        # installation and the Windows SDK, set here since vcvarsall isn't run (IlcUseEnvironmentalTools).
        $vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath
        $msvc = Join-Path $vs "VC\Tools\MSVC\$((Get-Content "$vs\VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt").Trim())"
        $kits = "${env:ProgramFiles(x86)}\Windows Kits\10\Lib"
        $sdk = Get-ChildItem $kits -Directory | Where-Object { Test-Path "$($_.FullName)\um\$arch" } | Sort-Object { [version]$_.Name } | Select-Object -Last 1
        $saved = $env:PATH, $env:LIB
        $env:PATH = "$msvc\bin\Host$arch\$arch;$env:PATH"
        $env:LIB = "$msvc\lib\$arch;$($sdk.FullName)\um\$arch;$($sdk.FullName)\ucrt\$arch"
        try {
            dotnet publish $hostProject -c Release -r "win-$arch" -p:Platform=$($arch.ToUpper()) -p:PublishAot=true -p:IlcUseEnvironmentalTools=true -o $out --nologo -v quiet
            if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }
        } finally {
            $env:PATH, $env:LIB = $saved
        }
        # Publishing leaves out the host's resources index, which WinUI needs (as <exe name>.pri).
        $pri = Get-ChildItem "$root\Windows\SwiftUIHost\bin\$($arch.ToUpper())\Release" -Recurse -Filter SwiftUIHost.pri |
            Sort-Object LastWriteTime | Select-Object -Last 1
        Copy-Item $pri.FullName $out
    } else {
        Write-Host "Building the WinUI host"
        dotnet build $hostProject -c Debug -r "win-$arch" -p:Platform=$($arch.ToUpper()) -o $out --nologo -v quiet
        if ($LASTEXITCODE -ne 0) { throw "dotnet build failed" }
    }
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
# Test bundles (`<Target>Tests.dll`) share the bin folder but aren't the app's: left out (Code's came to 250 MB).
$isTest = { $_.BaseName -like "*Tests" }
Get-ChildItem $out -File -ErrorAction SilentlyContinue | Where-Object $isTest | Remove-Item -Force
$built = Get-ChildItem $bin -Filter *.dll | Where-Object { -not (& $isTest) }
$swiftCore = (Get-Command swiftCore.dll -ErrorAction SilentlyContinue).Source
if (-not $release) {
    $built | Copy-Item -Destination $out -Force
    Get-ChildItem $bin -Filter *.pdb | Where-Object { -not (& $isTest) } | Copy-Item -Destination $out -Force
    if ($swiftCore) {
        Get-ChildItem (Split-Path $swiftCore) -Filter *.dll | Copy-Item -Destination $out -Force
    } else {
        Write-Warning "Swift runtime (swiftCore.dll) not on PATH; the host will look for it on PATH at launch"
    }
} else {
    # Stripped: most of a DLL is its DWARF (swift-build links with -debug:dwarf) and symbol table (Markdown's:
    # 95.6 → 16 MB). The unstripped DLLs and the PDBs, for crash reports, go to <Product>.symbols.
    $symbols = "$out.symbols"
    if (Test-Path $symbols) { Remove-Item -Recurse -Force $symbols }
    New-Item -ItemType Directory $symbols | Out-Null
    $built | Copy-Item -Destination $symbols
    Get-ChildItem $bin -Filter *.pdb | Where-Object { -not (& $isTest) } | Copy-Item -Destination $symbols
    # The AOT host's own PDB (40 MB) too.
    Get-ChildItem $out -Filter *.pdb | Move-Item -Destination $symbols -Force
    foreach ($file in $built) {
        llvm-strip --strip-all $file.FullName -o (Join-Path $out $file.Name)
        if ($LASTEXITCODE -ne 0) { throw "llvm-strip failed on $($file.Name)" }
    }
    # Only the runtime DLLs (Swift's and the VC runtime it carries) that the staged files import, directly or
    # through each other: 19 of 35 for Markdown.
    if (-not $swiftCore) { throw "Swift runtime (swiftCore.dll) not on PATH" }
    $runtime = @{}
    Get-ChildItem (Split-Path $swiftCore) -Filter *.dll | ForEach-Object { $runtime[$_.Name.ToLowerInvariant()] = $_.FullName }
    Get-ChildItem $out -File | ForEach-Object { $runtime.Remove($_.Name.ToLowerInvariant()) }
    $queue = [Collections.Generic.Queue[string]]::new()
    Get-ChildItem $out -Recurse -Include *.dll, *.exe | ForEach-Object { $queue.Enqueue($_.FullName) }
    while ($queue.Count) {
        foreach ($import in (llvm-readobj --coff-imports $queue.Dequeue() | Select-String '^\s*Name: (\S+\.dll)$')) {
            $name = $import.Matches[0].Groups[1].Value.ToLowerInvariant()
            if (-not $runtime.ContainsKey($name)) { continue }
            Copy-Item $runtime[$name] $out
            $queue.Enqueue((Join-Path $out (Split-Path $runtime[$name] -Leaf)))
            $runtime.Remove($name)
        }
    }
}
Set-Content -Path "$out\swiftui-app.txt" -Value $Product -NoNewline

# Info.plist next to the host, which Foundation reads as the main bundle's: the app's name, version and bundle
# identifier from its Xcode project (the first target's), so its defaults are its own file
# (%LOCALAPPDATA%\<identifier>.plist) and not the host's, shared by every app. The project is in the package, or beside
# it when the package is a repository's App\ folder (the Xcode project is at the repository's root).
$name = if ($Product -match '^(.+)WinUI$') { $Matches[1] } else { $Product }
$project = Get-ChildItem $package -Filter project.pbxproj -Recurse -Depth 2 -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\(\.build|Pods)\\' } | Select-Object -First 1
if (-not $project -and (Split-Path $package -Leaf) -eq 'App') {
    $project = Get-ChildItem (Split-Path $package) -Filter project.pbxproj -Recurse -Depth 1 -ErrorAction SilentlyContinue |
        Select-Object -First 1
}
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

if ($release) {
    # WinUI's translations (a folder of .mui files per culture): only the app's languages, and US English.
    $languages = @("en")
    if ($project -and $settings -match 'knownRegions = \(([^)]*)\)') {
        $languages += $Matches[1] -split '[,\s"]+' | Where-Object { $_ -and $_ -ne "Base" } | ForEach-Object { ($_ -split '-')[0].ToLowerInvariant() }
    }
    Get-ChildItem $out -Directory | Where-Object {
        $files = @(Get-ChildItem $_.FullName -Recurse -File)
        $files.Count -and -not ($files | Where-Object Extension -ne ".mui") -and $languages -notcontains ($_.Name -split '-')[0].ToLowerInvariant()
    } | Remove-Item -Recurse -Force
    # WinRT metadata (the AOT host compiled its projections in), the WebView2 projection and the restart helper
    # (the host uses neither). Microsoft.UI.Xaml.Phone.dll stays: TimePicker's flyout is in it.
    Get-ChildItem $out -Recurse -Include *.winmd, Microsoft.Web.WebView2.Core.dll, RestartAgent.exe | Remove-Item -Force
    $files = Get-ChildItem $out -Recurse -File
    Write-Host ("{0:N1} MB, {1} files" -f (($files | Measure-Object Length -Sum).Sum / 1MB), $files.Count)
}
Write-Host "Staged: $out ($identifier $version)"

if ($Run) {
    $arguments = @()
    if ($Script) { $arguments += @("--script", (Resolve-Path $Script).Path) }
    if ($Log) { $arguments += @("--log", $Log) }
    & "$out\SwiftUIHost.exe" @arguments
}
