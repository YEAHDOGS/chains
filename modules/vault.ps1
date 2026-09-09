# ==============================================================================
# Chains -- "git for save data" engine
# ==============================================================================
# Version control for emulator save files (battery saves like SNES .srm and
# GBA .sav, plus save states). Snapshots are content-addressed by SHA256 and
# recorded in an append-only JSON-lines journal -- a tiny git for the files
# that hold your progress.
#
# Vault layout (<vault>/.chains/):
#   config.json        { version, created, watchPaths: [...] }
#   journal.jsonl      one JSON object per commit (the history)
#   snapshots/<sha>    full file bytes, deduped by content hash
#
# Only save data is ever stored here -- never ROMs or firmware.
# ==============================================================================

$Script:SavePatterns = @("*.srm", "*.sav", "*.state*")

function Get-VaultPaths {
    param([Parameter(Mandatory = $true)][string]$VaultRoot)
    $sv = Join-Path $VaultRoot ".chains"
    return @{
        Root      = $VaultRoot
        Dir       = $sv
        Config    = Join-Path $sv "config.json"
        Journal   = Join-Path $sv "journal.jsonl"
        Snapshots = Join-Path $sv "snapshots"
    }
}

function Read-VaultConfig {
    param([hashtable]$Paths)
    if (-not (Test-Path $Paths.Config)) { return $null }
    return (Get-Content $Paths.Config -Raw | ConvertFrom-Json)
}

function Write-VaultConfig {
    param([hashtable]$Paths, [object]$Config)
    ($Config | ConvertTo-Json -Depth 4) | Set-Content $Paths.Config -Force
}

function Initialize-Chains {
    param([Parameter(Mandatory = $true)][string]$Path)
    $Paths = Get-VaultPaths -VaultRoot $Path
    if (Test-Path $Paths.Dir) {
        Write-Host "  [i] Chains already initialized at: $($Paths.Dir)" -ForegroundColor DarkGray
        return $Paths
    }
    New-Item -ItemType Directory -Path $Paths.Snapshots -Force | Out-Null
    "" | Set-Content $Paths.Journal -Force -NoNewline
    Write-VaultConfig -Paths $Paths -Config ([pscustomobject]@{
            version    = 1
            created    = (Get-Date).ToUniversalTime().ToString("o")
            watchPaths = @()
        })
    Write-Host "  [OK] Chains initialized at: $($Paths.Dir)" -ForegroundColor Green
    return $Paths
}

function Get-KnownEmulatorSaveDir {
    <#
    .SYNOPSIS
        Well-known emulator save locations that exist on this machine.
        Emulators not listed (or with custom paths) can be added explicitly
        via Add-SaveWatchPath -- this list is a convenience, not a limit.
    #>
    $IsWinOS = ($PSVersionTable.OS -like "*Windows*") -or ($IsWindows -eq $true)
    $Candidates = @()
    if ($IsWinOS) {
        $AppData = $env:APPDATA
        $Candidates += @{ Emulator = "RetroArch"; Path = (Join-Path $AppData (Join-Path "RetroArch" "saves")) }
        $Candidates += @{ Emulator = "mGBA"; Path = (Join-Path $AppData "mGBA") }
        $Candidates += @{ Emulator = "Snes9x"; Path = (Join-Path $AppData "Snes9x") }
    }
    else {
        $HomeDir = if ($env:HOME) { $env:HOME } else { "~" }
        $Candidates += @{ Emulator = "RetroArch"; Path = (Join-Path $HomeDir (Join-Path ".config" (Join-Path "retroarch" "saves"))) }
        $Candidates += @{ Emulator = "mGBA"; Path = (Join-Path $HomeDir (Join-Path ".config" "mgba")) }
        $Candidates += @{ Emulator = "Snes9x"; Path = (Join-Path $HomeDir (Join-Path ".config" "snes9x")) }
    }
    return @($Candidates | Where-Object { Test-Path $_.Path })
}

function Add-SaveWatchPath {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        [Parameter(Mandatory = $true)][string]$WatchPath
    )
    $Full = (Resolve-Path $WatchPath -ErrorAction SilentlyContinue)
    if (-not $Full) {
        Write-Host "  [FAIL] Directory does not exist: $WatchPath" -ForegroundColor Red
        return $false
    }
    $FullPath = $Full.Path
    $Config = Read-VaultConfig -Paths $Paths
    if (-not $Config) { Write-Host "  [FAIL] Not a Chains. Run 'init' first." -ForegroundColor Red; return $false }
    # Normalize: an empty JSON array can round-trip as $null.
    $WatchList = @($Config.watchPaths)
    if ($WatchList -contains $FullPath) {
        Write-Host "  [i] Already watched: $FullPath" -ForegroundColor DarkGray
        return $true
    }
    $WatchList += $FullPath
    $Config.watchPaths = $WatchList
    Write-VaultConfig -Paths $Paths -Config $Config
    Write-Host "  [OK] Watching: $FullPath" -ForegroundColor Green
    return $true
}

function Get-SaveWorkingTree {
    <#
    .SYNOPSIS
        Scans all watched paths for save files. Returns objects with:
        Key (watch-relative identity), FullPath, Sha256, Bytes.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Paths)
    $Config = Read-VaultConfig -Paths $Paths
    if (-not $Config) { return @() }
    $Files = @()
    foreach ($Watch in $Config.watchPaths) {
        if (-not (Test-Path $Watch)) { continue }
        foreach ($Pattern in $Script:SavePatterns) {
            foreach ($f in (Get-ChildItem -Path $Watch -Filter $Pattern -File -Recurse -ErrorAction SilentlyContinue)) {
                $Rel = $f.FullName.Substring($Watch.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
                $Hash = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash.ToLower()
                $Files += [pscustomobject]@{
                    Key      = "$Watch::$Rel"
                    FullPath = $f.FullName
                    Rel      = $Rel
                    Sha256   = $Hash
                    Bytes    = $f.Length
                }
            }
        }
    }
    return $Files
}

function Get-SaveJournal {
    param([Parameter(Mandatory = $true)][hashtable]$Paths)
    if (-not (Test-Path $Paths.Journal)) { return @() }
    $Entries = @()
    foreach ($Line in (Get-Content $Paths.Journal -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($Line)) { continue }
        $Entries += ($Line | ConvertFrom-Json)
    }
    return $Entries
}

function Find-SaveCommit {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        [Parameter(Mandatory = $true)][string]$Ref
    )
    $Journal = Get-SaveJournal -Paths $Paths
    if ($Journal.Count -eq 0) { return $null }
    if ($Ref -eq "HEAD") { return $Journal[-1] }
    $Matched = @($Journal | Where-Object { $_.id -eq $Ref -or $_.id.StartsWith($Ref) })
    if ($Matched.Count -eq 1) { return $Matched[0] }
    return $null  # none, or ambiguous prefix
}

function New-SaveCommitId {
    <#
    .SYNOPSIS
        Derives a 12-hex-char commit id from the parent commit id, timestamp,
        message, and file list. Including the parent id chains every commit
        to its predecessor: same-tick commits can never collide, a
        restore-then-recommit always yields a fresh id, and the journal is
        tamper-evident end to end.
    #>
    param(
        [string]$ParentId = "",
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [string]$Message = "",
        [array]$FileList = @()
    )
    $TreePart = (($FileList | ForEach-Object { "$($_.key)=$($_.sha256)" } | Sort-Object) -join ",")
    $Seed = "$ParentId|$Timestamp|$Message|$TreePart"
    return ((Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($Seed))) -Algorithm SHA256).Hash.ToLower()).Substring(0, 12)
}

function New-SaveCommit {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        [string]$Message = ""
    )
    $Config = Read-VaultConfig -Paths $Paths
    if (-not $Config) { Write-Host "  [FAIL] Not a Chains. Run 'init' first." -ForegroundColor Red; return $null }
    if (@($Config.watchPaths).Count -eq 0) {
        Write-Host "  [FAIL] No watched paths. Run 'watch' first." -ForegroundColor Red
        return $null
    }

    $Tree = Get-SaveWorkingTree -Paths $Paths
    $Journal = Get-SaveJournal -Paths $Paths
    $Head = if ($Journal.Count -gt 0) { $Journal[-1] } else { $null }

    # Build the file list for this commit; store any blobs we haven't seen.
    $FileList = @()
    $NewBlobs = 0
    foreach ($f in $Tree) {
        $BlobPath = Join-Path $Paths.Snapshots $f.Sha256
        if (-not (Test-Path $BlobPath)) {
            Copy-Item $f.FullPath $BlobPath -Force
            $NewBlobs++
        }
        $FileList += [pscustomobject]@{ key = $f.Key; rel = $f.Rel; sha256 = $f.Sha256; bytes = $f.Bytes }
    }

    # Nothing-to-commit check: same key->hash mapping as HEAD.
    if ($Head) {
        $HeadMap = @{}
        foreach ($hf in $Head.files) { $HeadMap[$hf.key] = $hf.sha256 }
        $Same = ($Tree.Count -eq $Head.files.Count)
        if ($Same) {
            foreach ($f in $Tree) {
                if ($HeadMap[$f.Key] -ne $f.Sha256) { $Same = $false; break }
            }
        }
        if ($Same) {
            Write-Host "  [i] Nothing to commit -- working tree matches $($Head.id)." -ForegroundColor DarkGray
            return $Head
        }
    }

    $Ts = (Get-Date).ToUniversalTime().ToString("o")
    $ParentId = if ($Head) { $Head.id } else { "" }
    $Id = New-SaveCommitId -ParentId $ParentId -Timestamp $Ts -Message $Message -FileList $FileList

    $Entry = [pscustomobject]@{
        id      = $Id
        parent  = $ParentId
        ts      = $Ts
        message = $Message
        files   = $FileList
    }
    ($Entry | ConvertTo-Json -Depth 5 -Compress) | Add-Content $Paths.Journal

    Write-Host "  [OK] Committed $Id -- $($Tree.Count) save file(s), $NewBlobs new blob(s)." -ForegroundColor Green
    if ($Message) { Write-Host "       ""$Message""" -ForegroundColor DarkGray }
    return $Entry
}

function Get-SaveStatus {
    param([Parameter(Mandatory = $true)][hashtable]$Paths)
    $Journal = Get-SaveJournal -Paths $Paths
    if ($Journal.Count -eq 0) {
        Write-Host "  [i] No commits yet." -ForegroundColor DarkGray
        return
    }
    $Head = $Journal[-1]
    $HeadMap = @{}
    foreach ($hf in $Head.files) { $HeadMap[$hf.key] = $hf }
    $Tree = Get-SaveWorkingTree -Paths $Paths
    $TreeMap = @{}
    foreach ($f in $Tree) { $TreeMap[$f.Key] = $f }

    $Changed = @()
    foreach ($Key in $TreeMap.Keys) {
        if (-not $HeadMap.ContainsKey($Key)) { $Changed += "  + added:    $($TreeMap[$Key].Rel)"; continue }
        if ($HeadMap[$Key].sha256 -ne $TreeMap[$Key].Sha256) { $Changed += "  ~ modified: $($TreeMap[$Key].Rel)" }
    }
    foreach ($Key in $HeadMap.Keys) {
        if (-not $TreeMap.ContainsKey($Key)) { $Changed += "  - deleted:  $($HeadMap[$Key].rel)" }
    }
    if ($Changed.Count -eq 0) {
        Write-Host "  [OK] Clean -- working tree matches $($Head.id)." -ForegroundColor Green
    }
    else {
        Write-Host "  [~] Changes vs $($Head.id):" -ForegroundColor Yellow
        $Changed | ForEach-Object { Write-Host $_ -ForegroundColor White }
    }
}

function Compare-SaveCommit {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        [Parameter(Mandatory = $true)][string]$FromRef,
        [Parameter(Mandatory = $true)][string]$ToRef
    )
    $From = Find-SaveCommit -Paths $Paths -Ref $FromRef
    $To = Find-SaveCommit -Paths $Paths -Ref $ToRef
    if (-not $From) { Write-Host "  [FAIL] Unknown commit: $FromRef" -ForegroundColor Red; return }
    if (-not $To) { Write-Host "  [FAIL] Unknown commit: $ToRef" -ForegroundColor Red; return }

    $FromMap = @{}; foreach ($f in $From.files) { $FromMap[$f.key] = $f }
    $ToMap = @{}; foreach ($f in $To.files) { $ToMap[$f.key] = $f }

    Write-Host ""
    Write-Host "  diff $($From.id) -> $($To.id)" -ForegroundColor Cyan
    $Any = $false
    foreach ($Key in $ToMap.Keys) {
        if (-not $FromMap.ContainsKey($Key)) {
            Write-Host "  + $($ToMap[$Key].rel) (new, $($ToMap[$Key].bytes) bytes)" -ForegroundColor Green
            $Any = $true
        }
        elseif ($FromMap[$Key].sha256 -ne $ToMap[$Key].sha256) {
            $Delta = $ToMap[$Key].bytes - $FromMap[$Key].bytes
            $DeltaStr = if ($Delta -ge 0) { "+$Delta" } else { "$Delta" }
            $ByteDiff = Get-BlobByteDiff -Paths $Paths -ShaA $FromMap[$Key].sha256 -ShaB $ToMap[$Key].sha256
            Write-Host "  ~ $($ToMap[$Key].rel) (size $DeltaStr bytes$ByteDiff)" -ForegroundColor Yellow
            $Any = $true
        }
    }
    foreach ($Key in $FromMap.Keys) {
        if (-not $ToMap.ContainsKey($Key)) {
            Write-Host "  - $($FromMap[$Key].rel) (deleted)" -ForegroundColor Red
            $Any = $true
        }
    }
    if (-not $Any) { Write-Host "  (identical)" -ForegroundColor DarkGray }
    Write-Host ""
}

function Get-BlobByteDiff {
    param([hashtable]$Paths, [string]$ShaA, [string]$ShaB)
    # Byte-level diff summary for small binary saves; skipped for large files.
    $MaxBytes = 4MB
    $A = Join-Path $Paths.Snapshots $ShaA
    $B = Join-Path $Paths.Snapshots $ShaB
    if (-not (Test-Path $A) -or -not (Test-Path $B)) { return "" }
    if ((Get-Item $A).Length -gt $MaxBytes -or (Get-Item $B).Length -gt $MaxBytes) { return ", diff skipped (>4MB)" }
    $BytesA = [IO.File]::ReadAllBytes($A)
    $BytesB = [IO.File]::ReadAllBytes($B)
    $Len = [Math]::Max($BytesA.Length, $BytesB.Length)
    $Diff = 0
    for ($i = 0; $i -lt $Len; $i++) {
        $ba = if ($i -lt $BytesA.Length) { $BytesA[$i] } else { -1 }
        $bb = if ($i -lt $BytesB.Length) { $BytesB[$i] } else { -1 }
        if ($ba -ne $bb) { $Diff++ }
    }
    return ", $Diff of $Len bytes differ"
}

function Restore-SaveCommit {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        [Parameter(Mandatory = $true)][string]$Ref,
        [switch]$NoBackup
    )
    $Commit = Find-SaveCommit -Paths $Paths -Ref $Ref
    if (-not $Commit) { Write-Host "  [FAIL] Unknown commit: $Ref" -ForegroundColor Red; return $false }

    if (-not $NoBackup) {
        Write-Host "  [i] Auto-committing current state as pre-restore backup..." -ForegroundColor DarkGray
        New-SaveCommit -Paths $Paths -Message "pre-restore auto-backup" | Out-Null
    }

    $Restored = 0
    foreach ($f in $Commit.files) {
        $Blob = Join-Path $Paths.Snapshots $f.sha256
        if (-not (Test-Path $Blob)) {
            Write-Host "  [FAIL] Missing blob for $($f.rel) -- vault is corrupt." -ForegroundColor Red
            continue
        }
        # Key format is "<watchdir>::<relative>"; recover the watch dir.
        $WatchDir = $f.key.Substring(0, $f.key.IndexOf("::"))
        $Dest = Join-Path $WatchDir $f.rel
        $DestDir = Split-Path $Dest -Parent
        if (-not (Test-Path $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }
        Copy-Item $Blob $Dest -Force
        $Restored++
    }
    Write-Host "  [OK] Restored $Restored file(s) from commit $($Commit.id)." -ForegroundColor Green
    return $true
}

function Test-SaveChain {
    <#
    .SYNOPSIS
        Verifies the vault end to end. For every journal entry it checks the
        parent link, then re-derives the commit id from parent id, timestamp,
        message, and file list -- any edit to the journal breaks the chain.
        It also re-hashes every stored blob and compares it to the recorded
        SHA256, so silent corruption of snapshots is caught too. Returns
        $true only when the whole vault is intact.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Paths)
    $Journal = Get-SaveJournal -Paths $Paths
    if ($Journal.Count -eq 0) {
        Write-Host "  [i] No commits to verify." -ForegroundColor DarkGray
        return $true
    }
    $PrevId = ""
    $Legacy = 0
    foreach ($c in $Journal) {
        if ($c.PSObject.Properties.Name -contains "parent") {
            if ($c.parent -ne $PrevId) {
                Write-Host "  [FAIL] Commit $($c.id) has a broken parent link (expected '$PrevId')." -ForegroundColor Red
                return $false
            }
            $Recomputed = New-SaveCommitId -ParentId $PrevId -Timestamp $c.ts -Message $c.message -FileList @($c.files)
            if ($Recomputed -ne $c.id) {
                Write-Host "  [FAIL] Commit $($c.id) fails the integrity check -- journal entry was modified." -ForegroundColor Red
                return $false
            }
        }
        else {
            # Commits written before parent-chaining existed can't be
            # re-derived; their blobs can still be integrity-checked.
            $Legacy++
        }
        foreach ($f in @($c.files)) {
            $Blob = Join-Path $Paths.Snapshots $f.sha256
            if (-not (Test-Path $Blob)) {
                Write-Host "  [FAIL] Missing blob for $($f.rel) ($($f.sha256))." -ForegroundColor Red
                return $false
            }
            $Actual = (Get-FileHash -Path $Blob -Algorithm SHA256).Hash.ToLower()
            if ($Actual -ne $f.sha256) {
                Write-Host "  [FAIL] Blob for $($f.rel) no longer matches its recorded hash." -ForegroundColor Red
                return $false
            }
        }
        $PrevId = $c.id
    }
    $Note = if ($Legacy -gt 0) { " ($Legacy legacy pre-chain commit(s) checked by blob only)" } else { "" }
    Write-Host "  [OK] Chain intact: $($Journal.Count) commit(s), all blobs verified.$Note" -ForegroundColor Green
    return $true
}
