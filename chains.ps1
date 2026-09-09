<#
.SYNOPSIS
    Chains -- "git for save data" command line interface.
.DESCRIPTION
    Version-control your emulator save files: snapshot battery saves
    (SNES .srm, GBA .sav) and save states, browse history, diff commits,
    and restore any point in time. Never lose a save again.
.EXAMPLE
    .\chains.ps1 init
    .\chains.ps1 watch -Known
    .\chains.ps1 commit -m "beat the Elite Four"
    .\chains.ps1 log
    .\chains.ps1 diff abc123 def456
    .\chains.ps1 restore abc123
#>
param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter()]
    [string]$Path = ".",

    [Parameter()]
    [string]$Add,

    [Parameter()]
    [switch]$Known,

    [Parameter()]
    [string]$m,

    [Parameter()]
    [string]$Message,

    [Parameter()]
    [switch]$NoBackup,

    [Parameter()]
    [switch]$Force
)

$ModuleRoot = Join-Path $PSScriptRoot "modules"
. (Join-Path $ModuleRoot "vault.ps1")

$VaultRoot = (Resolve-Path $Path -ErrorAction SilentlyContinue)
if (-not $VaultRoot) {
    Write-Host "  [FAIL] Path does not exist: $Path" -ForegroundColor Red
    Exit 1
}
$VaultRoot = $VaultRoot.Path

function Show-Usage {
    Write-Host ""
    Write-Host "  Chains -- git for save data" -ForegroundColor Cyan
    Write-Host "  ================================================================" -ForegroundColor DarkGray
    Write-Host "  .\chains.ps1 init                  Initialize a vault here" -ForegroundColor White
    Write-Host "  .\chains.ps1 watch -Known          Auto-watch emulator save dirs" -ForegroundColor White
    Write-Host "  .\chains.ps1 watch -Add <dir>      Watch an explicit directory" -ForegroundColor White
    Write-Host "  .\chains.ps1 commit -m ""msg""       Snapshot current saves" -ForegroundColor White
    Write-Host "  .\chains.ps1 status                Diff working tree vs HEAD" -ForegroundColor White
    Write-Host "  .\chains.ps1 log                   Show commit history" -ForegroundColor White
    Write-Host "  .\chains.ps1 diff <a> <b>          Compare two commits" -ForegroundColor White
    Write-Host "  .\chains.ps1 restore <ref>         Restore a commit (auto-backs up first)" -ForegroundColor White
    Write-Host ""
    Write-Host "  -Path <dir> selects the vault root (default: current directory)." -ForegroundColor DarkGray
    Write-Host ""
}

$CommitMessage = if ($m) { $m } elseif ($Message) { $Message } else { "" }

switch ($Command.ToLower()) {
    "init" {
        Initialize-Chains -Path $VaultRoot | Out-Null
    }
    "watch" {
        $Paths = Get-VaultPaths -VaultRoot $VaultRoot
        if (-not (Test-Path $Paths.Dir)) { Write-Host "  [FAIL] Not a Chains. Run 'init' first." -ForegroundColor Red; Exit 1 }
        if ($Known) {
            $Found = Get-KnownEmulatorSaveDir
            if ($Found.Count -eq 0) { Write-Host "  [i] No known emulator save dirs found on this machine." -ForegroundColor DarkGray }
            foreach ($k in $Found) {
                Write-Host "  [>] Found $($k.Emulator): $($k.Path)" -ForegroundColor Cyan
                Add-SaveWatchPath -Paths $Paths -WatchPath $k.Path | Out-Null
            }
        }
        elseif ($Add) {
            Add-SaveWatchPath -Paths $Paths -WatchPath $Add | Out-Null
        }
        else {
            Write-Host "  [FAIL] Specify -Known or -Add <dir>." -ForegroundColor Red
            Exit 1
        }
    }
    "commit" {
        $Paths = Get-VaultPaths -VaultRoot $VaultRoot
        New-SaveCommit -Paths $Paths -Message $CommitMessage | Out-Null
    }
    "status" {
        $Paths = Get-VaultPaths -VaultRoot $VaultRoot
        Get-SaveStatus -Paths $Paths
    }
    "log" {
        $Paths = Get-VaultPaths -VaultRoot $VaultRoot
        $Journal = Get-SaveJournal -Paths $Paths
        if ($Journal.Count -eq 0) { Write-Host "  [i] No commits yet." -ForegroundColor DarkGray; break }
        Write-Host ""
        foreach ($c in ($Journal | Sort-Object ts -Descending)) {
            $When = ([datetime]$c.ts).ToLocalTime().ToString("yyyy-MM-dd HH:mm")
            Write-Host "  $($c.id)  $When  ($($c.files.Count) files)" -ForegroundColor Cyan
            if ($c.message) { Write-Host "      $($c.message)" -ForegroundColor White }
        }
        Write-Host ""
    }
    "diff" {
        # diff takes two positional refs: .\chains.ps1 diff <a> <b>
        # $Path was consumed as vault root, so read raw args instead.
        $RawArgs = @($args)
        if ($RawArgs.Count -lt 2) { Write-Host "  [FAIL] Usage: .\chains.ps1 diff <commit-a> <commit-b>" -ForegroundColor Red; Exit 1 }
        $Paths = Get-VaultPaths -VaultRoot $VaultRoot
        Compare-SaveCommit -Paths $Paths -FromRef $RawArgs[0] -ToRef $RawArgs[1]
    }
    "restore" {
        $RawArgs = @($args)
        if ($RawArgs.Count -lt 1) { Write-Host "  [FAIL] Usage: .\chains.ps1 restore <commit>" -ForegroundColor Red; Exit 1 }
        if (-not $Force) {
            Write-Host "  [!] This overwrites current save files with commit $($RawArgs[0])." -ForegroundColor Yellow
            Write-Host "      A pre-restore backup commit is made first (skip with -NoBackup)." -ForegroundColor DarkGray
            $Confirm = Read-Host "      Continue? [y/N]"
            if ($Confirm -notmatch "^y(es)?$") { Write-Host "  [i] Aborted." -ForegroundColor DarkGray; Exit 0 }
        }
        $Paths = Get-VaultPaths -VaultRoot $VaultRoot
        Restore-SaveCommit -Paths $Paths -Ref $RawArgs[0] -NoBackup:$NoBackup | Out-Null
    }
    default {
        Show-Usage
    }
}
