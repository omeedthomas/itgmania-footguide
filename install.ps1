# Installs FootGuide into Simply Love for ITGmania.
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -ITGmania "D:\Games\ITGmania"
# See INSTALL.md for details and for manual installation.
param(
    # Your ITGmania folder (the one containing Themes\)
    [string]$ITGmania = "C:\Games\ITGmania",
    [string]$Theme = "Simply Love"
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "tools\theme-patch.ps1")

$themeDir = Join-Path $ITGmania "Themes\$Theme"
if (-not (Test-Path (Join-Path $themeDir "Modules"))) {
    Write-Error "Couldn't find Simply Love at $themeDir. Pass -ITGmania <your ITGmania folder> (and -Theme if your Simply Love folder is named differently)."
    exit 1
}

# 1. Copy the mod's files (new files only; nothing of Simply Love's is replaced).
foreach ($f in $ModFiles) {
    $dest = Join-Path $themeDir $f
    New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
    Copy-Item (Join-Path $PSScriptRoot "mod\$f") $dest -Force
}

# 2. Small edits to metrics.ini and Languages\en.ini: back up the originals once,
#    clear out any edits from an older FootGuide, then apply.
foreach ($name in @("metrics.ini", "Languages\en.ini")) {
    $path = Join-Path $themeDir $name
    if (-not (Test-Path "$path.footguide-backup")) { Copy-Item $path "$path.footguide-backup" }
}
Remove-FootGuideEdits $themeDir
Add-FootGuideEdits $themeDir

Write-Host "FootGuide installed into $themeDir"
Write-Host "Restart ITGmania, then set 'Foot Guide' on the Player Options screen."
