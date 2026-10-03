# Removes FootGuide from Simply Love, undoing its edits to metrics.ini and en.ini.
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1 [-ITGmania "D:\Games\ITGmania"]
param(
    [string]$ITGmania = "C:\Games\ITGmania",
    [string]$Theme = "Simply Love"
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "tools\theme-patch.ps1")

$themeDir = Join-Path $ITGmania "Themes\$Theme"
if (-not (Test-Path $themeDir)) {
    Write-Error "Couldn't find $themeDir. Pass -ITGmania <your ITGmania folder>."
    exit 1
}

Remove-FootGuideEdits $themeDir
foreach ($f in $ModFiles) { Remove-Item (Join-Path $themeDir $f) -ErrorAction SilentlyContinue }
Remove-Item (Join-Path $themeDir "Modules\FootGuide") -ErrorAction SilentlyContinue   # only if empty

Write-Host "FootGuide removed from $themeDir. Restart ITGmania."
Write-Host "(Your saved Foot Guide settings, Save\FootGuide.txt in ITGmania's data folder, were left alone.)"
