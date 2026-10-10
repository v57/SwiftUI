# Downloads the Material Symbols variable font (Apache 2.0, google/material-design-icons) that the
# WinUI host uses for Image(systemName:), like the Android backend — SF Symbols can't be shipped.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$dir = Join-Path $PSScriptRoot "..\SwiftUI2Host\Assets"
New-Item -ItemType Directory -Force $dir | Out-Null
$font = Join-Path $dir "MaterialSymbolsOutlined.ttf"
if (-not (Test-Path $font) -or (Get-Item $font).Length -eq 0) {
    Invoke-WebRequest -UseBasicParsing -OutFile "$font.tmp" -Uri "https://raw.githubusercontent.com/google/material-design-icons/master/variablefont/MaterialSymbolsOutlined%5BFILL%2CGRAD%2Copsz%2Cwght%5D.ttf"
    Move-Item "$font.tmp" $font -Force
    Invoke-WebRequest -UseBasicParsing -OutFile (Join-Path $dir "MaterialSymbols-LICENSE.txt") -Uri "https://raw.githubusercontent.com/google/material-design-icons/master/LICENSE"
}
Get-Item $font
