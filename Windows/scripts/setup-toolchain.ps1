# Installs what building SwiftUI apps for Windows needs, on Windows 11 ARM64 (or x64):
#   - Visual Studio Build Tools: MSVC + Windows SDK (the Swift toolchain links with them)
#   - Swift (toolchain + Windows SDK + runtime; no IDE/debugger/Android extras)
#   - Git (MinGit: SwiftPM clones package dependencies with it)
#   - .NET SDK (builds the C# WinUI 3 host)
# Idempotent: installed pieces are skipped. Installers are deleted afterwards to save disk.
# Usage (elevated PowerShell): Windows/scripts/setup-toolchain.ps1 [-SwiftVersion 6.4.0]
param(
    [string]$SwiftVersion = "6.4.0",
    [string]$DotnetChannel = "10.0",
    [string]$Downloads = "C:\dev\downloads"
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
New-Item -ItemType Directory -Force $Downloads | Out-Null

function Fetch($url, $name) {
    $path = Join-Path $Downloads $name
    if (-not (Test-Path $path)) {
        Write-Host "Downloading $url"
        Invoke-WebRequest -Uri $url -OutFile "$path.part" -UseBasicParsing
        Move-Item "$path.part" $path
    }
    return $path
}

function Add-UserPath($dir) {
    $path = [Environment]::GetEnvironmentVariable("Path", "User")
    if (($path -split ";") -notcontains $dir) {
        [Environment]::SetEnvironmentVariable("Path", ($path.TrimEnd(";") + ";" + $dir).TrimStart(";"), "User")
    }
    if (($env:Path -split ";") -notcontains $dir) { $env:Path += ";$dir" }
}

Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force

# 1. Visual Studio Build Tools (MSVC for the host architecture + Windows 11 SDK). Don't create
#    "Windows Kits" beforehand: the SDK installer fails (1307) on a folder it doesn't own.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vc = if ($arch -eq "arm64") { "Microsoft.VisualStudio.Component.VC.Tools.ARM64" } else { "Microsoft.VisualStudio.Component.VC.Tools.x86.x64" }
$hasVC = (Test-Path $vswhere) -and (& $vswhere -products * -requires $vc -property installationPath)
if (-not $hasVC) {
    $installer = Fetch "https://aka.ms/vs/17/release/vs_BuildTools.exe" "vs_BuildTools.exe"
    Write-Host "Installing Visual Studio Build Tools ($vc, Windows 11 SDK)"
    $p = Start-Process $installer -Wait -PassThru -ArgumentList @(
        "--quiet", "--wait", "--norestart", "--nocache", "--installPath", "C:\BuildTools",
        "--add", $vc, "--add", "Microsoft.VisualStudio.Component.Windows11SDK.26100")
    if ($p.ExitCode -notin 0, 3010) { throw "Build Tools installer failed: $($p.ExitCode)" }
    Remove-Item $installer
}
# The MSVC runtime the Swift tools link against.
$redist = Fetch "https://aka.ms/vs/17/release/vc_redist.$(if ($arch -eq 'arm64') { 'arm64' } else { 'x64' }).exe" "vc_redist.exe"
Start-Process $redist -Wait -ArgumentList "/install", "/quiet", "/norestart"
Remove-Item $redist

# 2. Swift.
$swiftRoot = Join-Path $env:LOCALAPPDATA "Programs\Swift"
if (-not (Test-Path (Join-Path $swiftRoot "Toolchains"))) {
    $file = "swift-$SwiftVersion-RELEASE-windows10" + $(if ($arch -eq "arm64") { "-arm64" } else { "" }) + ".exe"
    $url = "https://download.swift.org/swift-$SwiftVersion-release/windows10" + $(if ($arch -eq "arm64") { "-arm64" } else { "" }) + "/swift-$SwiftVersion-RELEASE/$file"
    $installer = Fetch $url $file
    Write-Host "Installing Swift $SwiftVersion"
    # All components but the Android SDKs (leaving out the IDE/debugger packages breaks the tools).
    $p = Start-Process $installer -Wait -PassThru -ArgumentList @(
        "/quiet", "/norestart", "OptionsInstallAndroidPlatform=0", "OptionsInstallAndroidSDKARM64=0",
        "OptionsInstallAndroidSDKAMD64=0", "OptionsInstallAndroidSDKARMv7=0", "OptionsInstallAndroidSDKX86=0", "OptionsIncludeNoAsserts=0")
    if ($p.ExitCode -notin 0, 3010) { throw "Swift installer failed: $($p.ExitCode)" }
    Remove-Item $installer
}
& "$PSScriptRoot\fix-swift-toolchain.ps1" -SwiftVersion $SwiftVersion

# 3. Git (MinGit).
$git = "C:\dev\tools\git"
if (-not (Test-Path "$git\cmd\git.exe")) {
    $zip = Fetch "https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.2/MinGit-2.56.0.2-$(if ($arch -eq 'arm64') { 'arm64' } else { '64-bit' }).zip" "mingit.zip"
    Expand-Archive $zip -DestinationPath $git -Force
    Remove-Item $zip
}
Add-UserPath "$git\cmd"
& "$git\cmd\git.exe" config --global core.longpaths true
& "$git\cmd\git.exe" config --global core.symlinks true

# 4. .NET SDK.
$dotnet = "C:\dev\tools\dotnet"
if (-not (Test-Path "$dotnet\dotnet.exe")) {
    $script = Fetch "https://dot.net/v1/dotnet-install.ps1" "dotnet-install.ps1"
    & $script -Channel $DotnetChannel -InstallDir $dotnet -Architecture $(if ($arch -eq "arm64") { "arm64" } else { "x64" }) -NoPath
    Remove-Item $script
}
Add-UserPath $dotnet
[Environment]::SetEnvironmentVariable("DOTNET_CLI_TELEMETRY_OPTOUT", "1", "User")
[Environment]::SetEnvironmentVariable("DOTNET_NOLOGO", "1", "User")

Write-Host "Done. Free space on C: $([math]::Round((Get-PSDrive C).Free / 1GB, 1)) GB"
