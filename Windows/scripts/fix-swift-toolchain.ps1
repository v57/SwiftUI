# Works around missing side-by-side assemblies in the Swift for Windows toolchain (seen with
# 6.4.0 arm64): swift-build.exe & co. declare private assemblies (FoundationXML, swiftRegexBuilder,
# version <toolchain version>.0) that the installer doesn't put next to them, so they fail with
# error 14001 ("side-by-side configuration is incorrect"). Each missing assembly gets a folder with
# the runtime's DLL and a manifest carrying the version the tools ask for.
param([string]$SwiftVersion = "6.4.0")
$ErrorActionPreference = "Stop"
$swift = Join-Path $env:LOCALAPPDATA "Programs\Swift"
$bin = Get-ChildItem "$swift\Toolchains" -Directory | Where-Object Name -like "$SwiftVersion*" | Select-Object -First 1 | ForEach-Object { "$($_.FullName)\usr\bin" }
$runtime = "$swift\Runtimes\$SwiftVersion\usr\bin"
if (-not $bin -or -not (Test-Path $runtime)) { throw "Swift $SwiftVersion toolchain or runtime not found under $swift" }

# The private assemblies the tools depend on (from their embedded manifests).
$wanted = @{}
foreach ($exe in Get-ChildItem $bin -Filter *.exe) {
    $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($exe.FullName))
    foreach ($m in [regex]::Matches($text, 'name="([A-Za-z_]+)" version="([0-9.]+)" processorArchitecture="([A-Za-z0-9]+)"')) {
        $wanted[$m.Groups[1].Value] = @($m.Groups[2].Value, $m.Groups[3].Value)
    }
}
foreach ($name in $wanted.Keys) {
    $version, $arch = $wanted[$name]
    $dir = Join-Path $bin $name
    if ((Test-Path "$dir\$name.dll") -or (Test-Path "$bin\$name.dll")) {
        if (-not (Test-Path "$dir\$name.manifest")) {
            $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($(if (Test-Path "$dir\$name.dll") { "$dir\$name.dll" } else { "$bin\$name.dll" })))
            if ($text -match "name=`"$name`"[^>]*version=`"$([regex]::Escape($version))`"" -or $text -match "version=`"$([regex]::Escape($version))`"[^>]*name=`"$name`"") { continue }
        } else { continue }
    }
    if (-not (Test-Path "$runtime\$name.dll")) { Write-Warning "No runtime DLL for assembly $name"; continue }
    New-Item -ItemType Directory -Force $dir | Out-Null
    Copy-Item "$runtime\$name.dll" $dir -Force
    @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity type="win32" name="$name" version="$version" processorArchitecture="$arch"/>
  <file name="$name.dll"/>
</assembly>
"@ | Set-Content -Encoding UTF8 "$dir\$name.manifest"
    Write-Host "Added private assembly $name $version"
}
