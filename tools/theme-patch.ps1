# Shared by install.ps1 / uninstall.ps1.

# Files FootGuide adds to the Simply Love folder (paths relative to mod/ and to the theme).
$ModFiles = @(
    "Modules\FootGuide.lua",
    "Modules\FootGuide\Solver.lua",
    "Modules\FootGuide\Trainer.lua",
    "Scripts\FootGuide-Settings.lua"
)

# The edits FootGuide makes to Simply Love's own files.
#   metrics.ini      - the "Foot Guide" row on Player Options, and the trainer screen
#   Languages/en.ini - the row's title and help text
# Each edit inserts $Add directly after the (unique) text $Find. Remove-FootGuideEdits
# takes out these edits *and* those made by older FootGuide versions, so installing
# over an old version, re-installing, and uninstalling are all exact.

$nl = "`n"   # replaced with the file's own line ending
$ThemeEdits = @(
    # Row on the first Player Options page, just before "what's next".
    @{ File = "metrics.ini"; Find = 'MusicRate,Stepchart'; Add = ',FootGuide' },
    @{ File = "metrics.ini"; Find = "LineStepchart=""lua,CustomOptionRow('Stepchart')"""; Add = "${nl}LineFootGuide=""lua,FootGuideSettings.OptionRow()""" },
    # The step-by-step trainer screen (its actors live in Modules/FootGuide/Trainer.lua).
    @{ File = "metrics.ini"; Find = 'EditMode="EditMode_Practice"'; Add = (@(
        "", "",
        "# --- FootGuide trainer (added by FootGuide install.ps1) ---",
        "[ScreenFootGuideTrainer]",
        'Fallback="ScreenWithMenuElements"',
        'PrevScreen="ScreenPlayerOptions"',
        'NextScreen="ScreenPlayerOptions"',
        "HeaderOnCommand=visible,false",
        "FooterOnCommand=visible,false",
        "ShowCreditDisplay=false",
        "TimerSeconds=-1",
        "# --- end FootGuide trainer ---") -join $nl) },
    # Row title and the help text shown at the bottom of Player Options.
    @{ File = "Languages\en.ini"; Find = "${nl}Stepchart=Stepchart"; Add = "${nl}FootGuide=Foot Guide" },
    @{ File = "Languages\en.ini"; Find = "${nl}Stepchart=Choose the stepchart you wish to play."; Add = "${nl}FootGuide=On Notes: L/R on every arrow. Tricky Only: just around crossovers, footswitches and brackets. Side Panel: pad diagram beside the notes. Trainer: practice step by step instead of playing." }
)

# Patterns that find every FootGuide edit, current or older.
$RemovePatterns = @(
    @{ File = "metrics.ini"; Pattern = 'MusicRate,Stepchart,FootGuide'; Replace = 'MusicRate,Stepchart' },
    @{ File = "metrics.ini"; Pattern = '\r?\nLineFootGuide=[^\r\n]*'; Replace = '' },
    @{ File = "metrics.ini"; Pattern = '(\r?\n){2}# --- FootGuide trainer[\s\S]*?# --- end FootGuide trainer ---'; Replace = '' },
    @{ File = "Languages\en.ini"; Pattern = '\r?\nFootGuide=[^\r\n]*'; Replace = '' }
)

function Read-ThemeFile([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [IO.File]::ReadAllText($Path)
    return @{ Text = $text; Bom = $hasBom; NL = $(if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }) }
}

function Write-ThemeFile([string]$Path, $File) {
    [IO.File]::WriteAllText($Path, $File.Text, (New-Object Text.UTF8Encoding($File.Bom)))
}

function Remove-FootGuideEdits([string]$ThemeDir) {
    foreach ($name in ($RemovePatterns | ForEach-Object { $_.File } | Select-Object -Unique)) {
        $path = Join-Path $ThemeDir $name
        $file = Read-ThemeFile $path
        $before = $file.Text
        foreach ($p in ($RemovePatterns | Where-Object { $_.File -eq $name })) {
            $file.Text = [regex]::Replace($file.Text, $p.Pattern, $p.Replace)
        }
        if ($file.Text -ne $before) { Write-ThemeFile $path $file }
    }
}

function Add-FootGuideEdits([string]$ThemeDir) {
    foreach ($edit in $ThemeEdits) {
        $path = Join-Path $ThemeDir $edit.File
        $file = Read-ThemeFile $path
        $find = $edit.Find.Replace("`n", $file.NL)
        $add = $edit.Add.Replace("`n", $file.NL)
        $count = ([regex]::Matches($file.Text, [regex]::Escape($find))).Count
        if ($count -ne 1) {
            Write-Warning "Skipped an edit to $($edit.File) (expected 1 match for '$($edit.Find.Trim())', found $count). Foot Guide may not appear in Player Options."
            continue
        }
        $file.Text = $file.Text.Replace($find, $find + $add)
        Write-ThemeFile $path $file
    }
}
