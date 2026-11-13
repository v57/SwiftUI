# Builds a SwiftUI app for Windows and stages it with the WinUI host:
# 1. builds the Swift app DLL (`swift build --product <Product>`, e.g. GalleryWinUI.dll),
# 2. builds the C# host (Windows/SwiftUIHost, unpackaged, self-contained Windows App SDK),
# 3. stages the app DLL and the Swift runtime next to SwiftUIHost.exe in .build\winui\<Product>,
# 4. optionally runs it (-Run; -Script/-Log are passed to the host).
# A release build is cut for size (363 → 108 MB for Markdown): the Swift code is built with dead-code flags and staged
# without its symbols (the unstripped DLLs and PDBs go to .build\winui\<Product>.symbols), the host is a Native AOT
# exe (no .NET runtime), ICU's data holds only the app's languages (build-icu.ps1; -FullICU keeps the toolchain's),
# and the folder holds only the runtime DLLs something imports, WinUI's translations for the app's languages (the
# Xcode project's knownRegions) and no WinRT metadata (.winmd), WebView2 or RestartAgent.
# Usage: Windows/scripts/build-app.ps1 [-Product GalleryWinUI] [-PackagePath dir] [-Configuration debug|release] [-Arch arm64|x64] [-Icon file.ico] [-Version X.Y.Z] [-Build N] [-Run] [-Script file] [-Log file] [-FullICU]
#   -PackagePath builds an app from another package that depends on SwiftUI (e.g. C:\dev\Get\App: a v57 app's package
#   is its repository's App\ folder).
#   -Icon: the app's icon (a multi-size .ico): the host exe carries it (Explorer, shortcuts, the pinned taskbar
#   button) and it is staged as AppIcon.ico, which the host gives its windows (title bar, taskbar, Alt+Tab).
#   -Version and -Build: the version and build number Info.plist names (a release's), else the Xcode project's.
#   -Arch: the architecture to build for, else this machine's. Another one is cross-compiled (an arm64 machine builds
#   x64 and the other way round: SwiftPM's --triple, the toolchain's SDK for it, MSVC's cross linker, Native AOT's
#   win-<arch> runtime) and staged in .build\winui\<Product>-<arch>, with that architecture's Swift runtime
#   (Get-SwiftRuntime below) and ICU.
param(
    [string]$Product = "GalleryWinUI",
    [string]$PackagePath,
    [ValidateSet("debug", "release")][string]$Configuration = "debug",
    [ValidateSet("arm64", "x64")][string]$Arch,
    [switch]$Run,
    [string]$Script,
    [string]$Log,
    [string]$Icon,
    [string]$Version,
    [string]$Build,
    [switch]$SkipHost,
    [switch]$FullICU
)
$ErrorActionPreference = "Stop"
# PowerShell's names ignore case: $version below is the Xcode project's, so the parameter is kept apart.
$releaseVersion, $releaseBuild = $Version, $Build
$root = (Resolve-Path "$PSScriptRoot\..\..").Path
# $arch is $Arch (PowerShell's names ignore case): the target, $hostArch this machine's.
$hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
if (-not $Arch) { $Arch = $hostArch }
$cross = $Arch -ne $hostArch
$triple = if ($Arch -eq "x64") { "x86_64-unknown-windows-msvc" } else { "aarch64-unknown-windows-msvc" }

# The Swift runtime DLLs for $Arch: the toolchain's runtime folder (on PATH) for this machine's architecture. Another
# architecture's comes from the merge module the toolchain installs for it (Redistributables\<version>\
# rtl.shared.<amd64|arm64>.msm), unpacked once into <SwiftUI>\.build\swift-runtime\<version>\<arch>, with the VC
# runtime the toolchain's folder also carries (vcruntime140.dll & co., which the module leaves to an installer) from
# MSVC's redistributable folder for that architecture (Visual Studio Installer: MSVC <arch> build tools).
function Get-SwiftRuntime {
    $swiftCore = (Get-Command swiftCore.dll -ErrorAction SilentlyContinue).Source
    if (-not $swiftCore) { return $null }
    if (-not $cross) { return Split-Path $swiftCore }
    $runtimes = Split-Path (Split-Path (Split-Path $swiftCore))
    $toolchainVersion = Split-Path $runtimes -Leaf
    $dir = "$root\.build\swift-runtime\$toolchainVersion\$Arch"
    if (Test-Path "$dir\swiftCore.dll") { return $dir }
    $msm = "$(Split-Path (Split-Path $runtimes))\Redistributables\$toolchainVersion\rtl.shared.$(if ($Arch -eq 'x64') { 'amd64' } else { 'arm64' }).msm"
    if (-not (Test-Path $msm)) { throw "no Swift runtime for ${Arch}: $msm is missing" }
    $vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath
    $crt = Get-ChildItem "$vs\VC\Redist\MSVC\*\$Arch\Microsoft.VC*.CRT" -Directory -ErrorAction SilentlyContinue |
        Sort-Object FullName | Select-Object -Last 1
    if (-not $crt) { throw "no VC runtime for $Arch under $vs\VC\Redist\MSVC (Visual Studio Installer: MSVC $Arch build tools)" }
    Write-Host "Unpacking the Swift runtime for $Arch ($(Split-Path $msm -Leaf))"
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

// A merge module (.msm): an MSI database whose files are in the cabinet stream MergeModule.CABinet, each named by its
// File table key.
public static class MergeModule
{
    [DllImport("msi.dll", CharSet = CharSet.Unicode)] static extern uint MsiOpenDatabase(string path, IntPtr persist, out IntPtr db);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)] static extern uint MsiDatabaseOpenView(IntPtr db, string query, out IntPtr view);
    [DllImport("msi.dll")] static extern uint MsiViewExecute(IntPtr view, IntPtr record);
    [DllImport("msi.dll")] static extern uint MsiViewFetch(IntPtr view, out IntPtr record);
    [DllImport("msi.dll")] static extern uint MsiRecordReadStream(IntPtr record, uint field, byte[] buffer, ref uint size);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)] static extern uint MsiRecordGetString(IntPtr record, uint field, StringBuilder value, ref uint size);
    [DllImport("msi.dll")] static extern uint MsiCloseHandle(IntPtr handle);

    static List<IntPtr> Rows(IntPtr db, string query)
    {
        IntPtr view, record;
        if (MsiDatabaseOpenView(db, query, out view) != 0) throw new IOException("query failed: " + query);
        MsiViewExecute(view, IntPtr.Zero);
        var rows = new List<IntPtr>();
        while (MsiViewFetch(view, out record) == 0) rows.Add(record);
        MsiCloseHandle(view);
        return rows;
    }

    static string Text(IntPtr record, uint field)
    {
        uint size = 1024;
        var value = new StringBuilder((int)size);
        MsiRecordGetString(record, field, value, ref size);
        return value.ToString();
    }

    // Writes the cabinet to `cab`; returns the files: cabinet name -> long file name.
    public static Dictionary<string, string> Extract(string msm, string cab)
    {
        IntPtr db;
        if (MsiOpenDatabase(msm, IntPtr.Zero, out db) != 0) throw new IOException("can't open " + msm);
        try
        {
            using (var output = File.Create(cab))
            {
                foreach (var record in Rows(db, "SELECT `Name`, `Data` FROM `_Streams` WHERE `Name` = 'MergeModule.CABinet'"))
                {
                    var buffer = new byte[1 << 20];
                    for (uint size = (uint)buffer.Length; ; size = (uint)buffer.Length)
                    {
                        MsiRecordReadStream(record, 2, buffer, ref size);
                        if (size == 0) break;
                        output.Write(buffer, 0, (int)size);
                    }
                    MsiCloseHandle(record);
                }
            }
            var files = new Dictionary<string, string>();
            foreach (var record in Rows(db, "SELECT `File`, `FileName` FROM `File`"))
            {
                string name = Text(record, 2);
                int bar = name.IndexOf('|');
                files[Text(record, 1)] = bar < 0 ? name : name.Substring(bar + 1);
                MsiCloseHandle(record);
            }
            return files;
        }
        finally { MsiCloseHandle(db); }
    }
}
"@
    $work = "$dir.unpack"
    if (Test-Path $work) { Remove-Item -Recurse -Force $work }
    New-Item -ItemType Directory "$work\cab" | Out-Null
    $files = [MergeModule]::Extract($msm, "$work\rtl.cab")
    expand.exe "$work\rtl.cab" -F:* "$work\cab" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "expanding $msm failed" }
    New-Item -ItemType Directory -Force $dir | Out-Null
    foreach ($file in $files.GetEnumerator() | Where-Object { $_.Value -like "*.dll" }) {
        Move-Item "$work\cab\$($file.Key)" "$dir\$($file.Value)" -Force
    }
    Copy-Item "$($crt.FullName)\*.dll" $dir
    Remove-Item -Recurse -Force $work
    if (-not (Test-Path "$dir\swiftCore.dll")) { throw "$msm holds no swiftCore.dll" }
    return $dir
}

$release = $Configuration -eq "release"
# The symbol fonts (Windows/scripts/symbol-fonts.py) are cut to SymbolNames.swift's glyphs: a table changed since
# shows new symbols as their names.
$table = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText("$root\Sources\SwiftUIWinUI\SymbolNames.swift").Replace("`r`n", "`n"))
$tableHash = -join ([Security.Cryptography.SHA256]::Create().ComputeHash($table) | ForEach-Object { $_.ToString("x2") })
if ($tableHash -ne (Get-Content "$root\Windows\SwiftUIHost\Assets\symbol-fonts.sha256" -ErrorAction SilentlyContinue)) {
    Write-Warning "SymbolNames.swift changed since the symbol fonts were cut: rerun Windows/scripts/symbol-fonts.py (on a machine with fontTools)"
}
$package = if ($PackagePath) { (Resolve-Path $(if ([IO.Path]::IsPathRooted($PackagePath)) { $PackagePath } else { Join-Path $root $PackagePath })).Path } else { $root }

Write-Host "Building $Product ($Configuration, $Arch)"
# CodeView debug info and PDBs, so cdb and WER dumps (C:\dev\dumps) show Swift frames.
$flags = @("-Xswiftc", "-g", "-Xswiftc", "-debug-info-format=codeview", "-Xlinker", "-debug")
if ($release) {
    # Dead code: functions and data in sections of their own, public symbols nothing outside uses internalized at
    # link, type metadata only for types something uses (with /OPT:REF, which swift-build passes; Markdown's DLL:
    # 16.0 → 12.5 MB stripped).
    $flags += @("-Xswiftc", "-Osize", "-Xswiftc", "-function-sections", "-Xswiftc", "-Xfrontend", "-Xswiftc", "-internalize-at-link",
        "-Xswiftc", "-Xfrontend", "-Xswiftc", "-conditional-runtime-records", "-Xcc", "-ffunction-sections", "-Xcc", "-fdata-sections")
}
# Another architecture: SwiftPM's native build system with --triple (.build\<triple>\<configuration>), linked with
# that architecture's Swift SDK, MSVC and Windows SDK libraries. Not swift-build (the default): it ignores --triple,
# and with --arch it builds the macros (SwiftUI's and the packages') for the target too while linking them with this
# machine's prebuilt swift-syntax ("could not find module 'SwiftCompilerPlugin' for target x86_64"; without the
# prebuilts it builds no swift-syntax at all). The native build system builds macros for this machine.
# Its swift-driver doesn't know -function-sections (a frontend flag the default build system passes on): it says so,
# passes it to the frontend anyway, and its next (incremental) build dies on it, so it goes there by -Xfrontend.
if ($cross) {
    $at = [Array]::IndexOf($flags, "-function-sections")
    if ($at -ge 0) { $flags = $flags[0..($at - 1)] + @("-Xfrontend", "-Xswiftc", "-function-sections") + $flags[($at + 1)..($flags.Count - 1)] }
    $flags += @("--build-system", "native", "--triple", $triple)
}
swift build --package-path $package --product $Product -c $Configuration @flags
if ($LASTEXITCODE -ne 0) { throw "swift build failed" }
$bin = (swift build --package-path $package -c $Configuration @flags --show-bin-path).Trim()
$dll = Join-Path $bin "$Product.dll"
if (-not (Test-Path $dll)) { throw "Build failed: $dll missing" }

$out = Join-Path $package ".build\winui\$Product$(if ($cross) { "-$Arch" })"
$hostProject = "$root\Windows\SwiftUIHost\SwiftUIHost.csproj"
# The exe's icon: ApplicationIcon puts it in the host assembly's Win32 resources, which Native AOT copies into the exe.
$iconProperty = @()
if ($Icon) {
    $Icon = (Resolve-Path $Icon).Path
    $iconProperty = @("-p:ApplicationIcon=$Icon")
}
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
        # The linker for $Arch that runs here (bin\Host<this machine>\<target>), else the x64-hosted one, which
        # Windows on Arm runs emulated.
        $linker = @("$msvc\bin\Host$hostArch\$Arch", "$msvc\bin\Hostx64\$Arch") | Where-Object { Test-Path "$_\link.exe" } | Select-Object -First 1
        if (-not $linker) { throw "MSVC has no linker for $Arch under $msvc\bin (Visual Studio Installer: MSVC $Arch build tools)" }
        $env:PATH = "$linker;$env:PATH"
        $env:LIB = "$msvc\lib\$arch;$($sdk.FullName)\um\$arch;$($sdk.FullName)\ucrt\$arch"
        try {
            dotnet publish $hostProject -c Release -r "win-$arch" -p:Platform=$($arch.ToUpper()) -p:PublishAot=true -p:IlcUseEnvironmentalTools=true @iconProperty -o $out --nologo -v quiet
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
        dotnet build $hostProject -c Debug -r "win-$arch" -p:Platform=$($arch.ToUpper()) @iconProperty -o $out --nologo -v quiet
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
$runtimeDir = Get-SwiftRuntime
if (-not $release) {
    $built | Copy-Item -Destination $out -Force
    Get-ChildItem $bin -Filter *.pdb | Where-Object { -not (& $isTest) } | Copy-Item -Destination $out -Force
    if ($runtimeDir) {
        Get-ChildItem $runtimeDir -Filter *.dll | Copy-Item -Destination $out -Force
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
    if (-not $runtimeDir) { throw "Swift runtime (swiftCore.dll) for $Arch not found" }
    $runtime = @{}
    Get-ChildItem $runtimeDir -Filter *.dll | ForEach-Object { $runtime[$_.Name.ToLowerInvariant()] = $_.FullName }
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
# Resource bundles, as on Linux: Bundle.module and PlatformLanguages' English plural table ("1 server", not
# "1 servers") look next to the executable. SwiftPM names them `<Package>_<Target>.resources`, swift-build (SwiftPM 6.4
# on Windows) `<Package>_<Target>.bundle`.
foreach ($pattern in "*.resources", "*.bundle") {
    Get-ChildItem $out -Directory -Filter $pattern -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
    Get-ChildItem $bin -Directory -Filter $pattern | Where-Object { -not ($_.BaseName -like "*Tests*") } |
        Copy-Item -Destination $out -Recurse -Force
}
Set-Content -Path "$out\swiftui-app.txt" -Value $Product -NoNewline
if ($Icon) { Copy-Item $Icon "$out\AppIcon.ico" -Force } else { Remove-Item "$out\AppIcon.ico" -ErrorAction SilentlyContinue }

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
if ($releaseVersion) { $version = $releaseVersion }
$buildKey = if ($releaseBuild) { "`n    <key>CFBundleVersion</key><string>$([Security.SecurityElement]::Escape($releaseBuild))</string>" } else { "" }
if ($release) {
    # The app's languages: English and the Xcode project's.
    $languages = @("en")
    if ($project -and $settings -match 'knownRegions = \(([^)]*)\)') {
        $languages += $Matches[1] -split '[,\s"]+' | Where-Object { $_ -and $_ -ne "Base" } | ForEach-Object { ($_ -split '-')[0].ToLowerInvariant() }
    }
    # ICU with only these languages' data: 36 → 8 MB for English alone. Other languages' formats come from a language
    # pack the app offers to download (ICULanguagePack in SwiftUI): Info.plist names the built-in languages and the
    # ICU version the packs must match.
    $icu = Get-ChildItem $out -Filter _FoundationICU.dll
    if ($icu -and -not $FullICU) {
        try {
            $icuBuild = & "$PSScriptRoot\build-icu.ps1" -Languages $languages -Arch $Arch -Runtime $runtimeDir | Select-Object -Last 1
            Copy-Item $icuBuild.Path $icu.FullName -Force
            $icuKeys = "`n    <key>SwiftUIICUVersion</key><string>$($icuBuild.Version)</string>" +
                "`n    <key>SwiftUIICULanguages</key><string>$($icuBuild.Languages -join ' ')</string>"
        } catch {
            Write-Warning "Keeping the toolchain's ICU (36 MB): $_"
        }
    }
}
$escape = { param($text) [Security.SecurityElement]::Escape($text) }
@"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$(& $escape $identifier)</string>
    <key>CFBundleName</key><string>$(& $escape $name)</string>
    <key>CFBundleShortVersionString</key><string>$(& $escape $version)</string>$buildKey$icuKeys
</dict>
</plist>
"@ | Set-Content -Path "$out\Info.plist" -Encoding UTF8

if ($release) {
    # WinUI's translations (a folder of .mui files per culture).
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
