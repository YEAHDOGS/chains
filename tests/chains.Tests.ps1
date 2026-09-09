# ==============================================================================
# Chains regression tests (Pester v5)
# ==============================================================================
# Locks in the save -> commit -> diff -> restore cycle so future changes
# can't silently break it (the #1 recurring pain).
#
# Run (Pester ships with Windows PowerShell 5.1 and PowerShell 7+):
#   Invoke-Pester -Path ./tests
#
# The suite is hermetic: every test builds a fresh vault + save dir under the
# OS temp folder and tears it down afterwards. Nothing touches real saves.
# ==============================================================================

BeforeAll {
    . (Join-Path $PSScriptRoot ".." "modules" "vault.ps1")

    function New-TestBytes {
        param([int]$Seed = 0)
        $b = [byte[]](0..255)
        for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [byte](($i + $Seed) % 256) }
        return $b
    }

    function Write-TestSave {
        param([string]$Dir, [string]$Name, [byte[]]$Bytes)
        [IO.File]::WriteAllBytes((Join-Path $Dir $Name), $Bytes)
    }

    function Get-TestFileBytesHex {
        param([string]$File)
        return [BitConverter]::ToString([IO.File]::ReadAllBytes($File))
    }
}

Describe "Chains save-data engine" {
    BeforeEach {
        $Script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("chains-test-" + [Guid]::NewGuid().ToString("N"))
        $Script:Vault = Join-Path $Script:Tmp "vault"
        $Script:Saves = Join-Path $Script:Tmp "saves"
        New-Item -ItemType Directory -Path $Script:Vault | Out-Null
        New-Item -ItemType Directory -Path $Script:Saves | Out-Null
        $Script:Paths = Initialize-Chains -Path $Script:Vault
        Add-SaveWatchPath -Paths $Script:Paths -WatchPath $Script:Saves | Out-Null
    }

    AfterEach {
        Remove-Item -Recurse -Force $Script:Tmp -ErrorAction SilentlyContinue
    }

    It "initializes the vault layout" {
        Test-Path (Join-Path $Script:Vault ".chains" "config.json") | Should -BeTrue
        Test-Path (Join-Path $Script:Vault ".chains" "snapshots") | Should -BeTrue
        Test-Path (Join-Path $Script:Vault ".chains" "journal.jsonl") | Should -BeTrue
        $Config = Read-VaultConfig -Paths $Script:Paths
        $Config.version | Should -Be 1
        @(Get-SaveJournal -Paths $Script:Paths).Count | Should -Be 0
    }

    It "watches a directory exactly once" {
        Add-SaveWatchPath -Paths $Script:Paths -WatchPath $Script:Saves | Out-Null
        $Config = Read-VaultConfig -Paths $Script:Paths
        @($Config.watchPaths).Count | Should -Be 1
    }

    It "commits a save and reports nothing-to-commit on a clean tree" {
        Write-TestSave -Dir $Script:Saves -Name "game.sav" -Bytes (New-TestBytes -Seed 1)
        $A = New-SaveCommit -Paths $Script:Paths -Message "first blood"
        $A | Should -Not -BeNullOrEmpty
        $A.id | Should -Not -BeNullOrEmpty
        $A.id.Length | Should -Be 12
        @(Get-SaveJournal -Paths $Script:Paths).Count | Should -Be 1

        # Clean re-commit returns HEAD without appending.
        $B = New-SaveCommit -Paths $Script:Paths -Message "nothing new"
        $B.id | Should -Be $A.id
        @(Get-SaveJournal -Paths $Script:Paths).Count | Should -Be 1
    }

    It "restores an earlier commit byte-for-byte and auto-backs-up first" {
        $SaveFile = Join-Path $Script:Saves "zelda.sav"
        $V1 = New-TestBytes -Seed 7
        Write-TestSave -Dir $Script:Saves -Name "zelda.sav" -Bytes $V1
        $A = New-SaveCommit -Paths $Script:Paths -Message "v1"
        Write-TestSave -Dir $Script:Saves -Name "zelda.sav" -Bytes (New-TestBytes -Seed 42)
        $B = New-SaveCommit -Paths $Script:Paths -Message "v2"
        $B.id | Should -Not -Be $A.id

        $Restored = Restore-SaveCommit -Paths $Script:Paths -Ref $A.id
        $Restored | Should -BeTrue
        Get-TestFileBytesHex -File $SaveFile | Should -Be ([BitConverter]::ToString($V1))

        # Auto-backup preserved the pre-restore state in the journal.
        $Journal = @(Get-SaveJournal -Paths $Script:Paths)
        $Journal.Count | Should -Be 3
        $Journal[-1].message | Should -Be "pre-restore auto-backup"

        # The restore is itself undoable: HEAD's blob matches the pre-restore bytes.
        $BackupBlob = Join-Path $Script:Paths.Snapshots (@($Journal[-1].files))[0].sha256
        Get-TestFileBytesHex -File $BackupBlob | Should -Be ([BitConverter]::ToString((New-TestBytes -Seed 42)))
    }

    It "tracks added and deleted files across commits" {
        Write-TestSave -Dir $Script:Saves -Name "one.sav" -Bytes (New-TestBytes -Seed 1)
        $null = New-SaveCommit -Paths $Script:Paths -Message "one file"
        Remove-Item (Join-Path $Script:Saves "one.sav")
        Write-TestSave -Dir $Script:Saves -Name "two.sav" -Bytes (New-TestBytes -Seed 2)
        $null = New-SaveCommit -Paths $Script:Paths -Message "swapped"

        $Journal = @(Get-SaveJournal -Paths $Script:Paths)
        $Journal.Count | Should -Be 2
        $KeysA = @(@($Journal[0].files) | ForEach-Object { $_.rel })
        $KeysB = @(@($Journal[1].files) | ForEach-Object { $_.rel })
        $KeysA | Should -Contain "one.sav"
        $KeysB | Should -Contain "two.sav"
        $KeysB | Should -Not -Contain "one.sav"
    }

    It "summarizes byte-level diffs between commits" {
        $V1 = [byte[]](0..255)
        Write-TestSave -Dir $Script:Saves -Name "diffme.sav" -Bytes $V1
        $null = New-SaveCommit -Paths $Script:Paths -Message "before"
        $V2 = [byte[]](0..255)
        $V2[0] = 1; $V2[10] = 11; $V2[200] = 201   # exactly 3 bytes flip
        Write-TestSave -Dir $Script:Saves -Name "diffme.sav" -Bytes $V2
        $null = New-SaveCommit -Paths $Script:Paths -Message "after"

        $Journal = @(Get-SaveJournal -Paths $Script:Paths)
        $ShaA = @($Journal[0].files)[0].sha256
        $ShaB = @($Journal[1].files)[0].sha256
        Get-BlobByteDiff -Paths $Script:Paths -ShaA $ShaA -ShaB $ShaB | Should -Be ", 3 of 256 bytes differ"
    }

    It "resolves commits by full id, unique prefix, and HEAD" {
        Write-TestSave -Dir $Script:Saves -Name "a.sav" -Bytes (New-TestBytes -Seed 1)
        $A = New-SaveCommit -Paths $Script:Paths -Message "first"
        Write-TestSave -Dir $Script:Saves -Name "a.sav" -Bytes (New-TestBytes -Seed 2)
        $B = New-SaveCommit -Paths $Script:Paths -Message "second"

        (Find-SaveCommit -Paths $Script:Paths -Ref $A.id).id | Should -Be $A.id
        (Find-SaveCommit -Paths $Script:Paths -Ref $A.id.Substring(0, 8)).id | Should -Be $A.id
        (Find-SaveCommit -Paths $Script:Paths -Ref "HEAD").id | Should -Be $B.id
        Find-SaveCommit -Paths $Script:Paths -Ref "zzzzzzzzzzzz" | Should -BeNullOrEmpty
    }

    It "refuses to restore an unknown commit" {
        Restore-SaveCommit -Paths $Script:Paths -Ref "deadbeefcafe" | Should -BeFalse
    }

    It "never reuses a commit id across the journal" {
        Write-TestSave -Dir $Script:Saves -Name "c.sav" -Bytes (New-TestBytes -Seed 1)
        $A = New-SaveCommit -Paths $Script:Paths -Message "same message"
        Write-TestSave -Dir $Script:Saves -Name "c.sav" -Bytes (New-TestBytes -Seed 2)
        $B = New-SaveCommit -Paths $Script:Paths -Message "same message"
        $null = Restore-SaveCommit -Paths $Script:Paths -Ref $A.id -NoBackup
        $C = New-SaveCommit -Paths $Script:Paths -Message "same message"

        $Ids = @(Get-SaveJournal -Paths $Script:Paths) | ForEach-Object { $_.id }
        $Ids.Count | Should -Be 3
        ($Ids | Select-Object -Unique).Count | Should -Be 3
        $C.id | Should -Not -Be $A.id   # restore-then-recommit must not collide
    }

    It "verifies an intact journal and blob store end to end" {
        Write-TestSave -Dir $Script:Saves -Name "a.sav" -Bytes (New-TestBytes -Seed 1)
        $null = New-SaveCommit -Paths $Script:Paths -Message "first"
        Write-TestSave -Dir $Script:Saves -Name "a.sav" -Bytes (New-TestBytes -Seed 2)
        $null = New-SaveCommit -Paths $Script:Paths -Message "second"

        Test-SaveChain -Paths $Script:Paths | Should -BeTrue
    }

    It "detects journal tampering (message edit breaks the chain)" {
        Write-TestSave -Dir $Script:Saves -Name "a.sav" -Bytes (New-TestBytes -Seed 1)
        $null = New-SaveCommit -Paths $Script:Paths -Message "honest message"

        $Lines = @(Get-Content $Script:Paths.Journal | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $Tampered = $Lines[-1] | ConvertFrom-Json
        $Tampered.message = "forged message"
        $Lines[-1] = ($Tampered | ConvertTo-Json -Depth 5 -Compress)
        $Lines | Set-Content $Script:Paths.Journal

        Test-SaveChain -Paths $Script:Paths | Should -BeFalse
    }

    It "detects blob tampering (silent snapshot corruption)" {
        Write-TestSave -Dir $Script:Saves -Name "a.sav" -Bytes (New-TestBytes -Seed 1)
        $null = New-SaveCommit -Paths $Script:Paths -Message "first"
        $Sha = @((Get-SaveJournal -Paths $Script:Paths)[-1].files)[0].sha256
        $Blob = Join-Path $Script:Paths.Snapshots $Sha
        [IO.File]::AppendAllBytes($Blob, [byte[]]@(0xFF))

        Test-SaveChain -Paths $Script:Paths | Should -BeFalse
    }

    It "derives commit ids deterministically from parent, timestamp, message, and tree" {
        $Files = @([pscustomobject]@{ key = "w::a.sav"; sha256 = "abc123" })
        $Id1 = New-SaveCommitId -Timestamp "2026-01-01T00:00:00Z" -Message "m" -FileList $Files
        $Id2 = New-SaveCommitId -Timestamp "2026-01-01T00:00:00Z" -Message "m" -FileList $Files
        $Id1 | Should -Be $Id2
        $Id1.Length | Should -Be 12
        New-SaveCommitId -ParentId "deadbeefcafe" -Timestamp "2026-01-01T00:00:00Z" -Message "m" -FileList $Files |
            Should -Not -Be $Id1   # parent chains the id
        New-SaveCommitId -Timestamp "2026-01-01T00:00:00Z" -Message "other" -FileList $Files |
            Should -Not -Be $Id1   # message is part of the id
    }

    It "pushes a vault to a local remote and fetches it onto a second machine" {
        $Remote = Join-Path $Script:Tmp "remote"
        Write-TestSave -Dir $Script:Saves -Name "game.srm" -Bytes (New-TestBytes -Seed 3)
        $A = New-SaveCommit -Paths $Script:Paths -Message "machine a"
        $Push = Push-Chains -Paths $Script:Paths -RemoteRoot $Remote
        $Push | Should -Not -BeNullOrEmpty
        $Push.BlobsPushed | Should -Be 1

        # "Another machine": a fresh vault with its own id.
        $VaultB = Join-Path $Script:Tmp "vaultB"
        $SavesB = Join-Path $Script:Tmp "savesB"
        New-Item -ItemType Directory -Path $VaultB | Out-Null
        New-Item -ItemType Directory -Path $SavesB | Out-Null
        $PathsB = Initialize-Chains -Path $VaultB
        Add-SaveWatchPath -Paths $PathsB -WatchPath $SavesB | Out-Null

        $Fetch = Fetch-Chains -Paths $PathsB -RemoteRoot $Remote -VaultId $Push.VaultId
        $Fetch | Should -Not -BeNullOrEmpty
        $Fetch.EntriesAdded | Should -Be 1
        $Fetch.BlobsFetched | Should -Be 1

        # The fetched vault carries the same history and verifies clean.
        @(Get-SaveJournal -Paths $PathsB).Count | Should -Be 1
        (Find-SaveCommit -Paths $PathsB -Ref $A.id).id | Should -Be $A.id
        Test-SaveChain -Paths $PathsB | Should -BeTrue

        # Idempotent: a second fetch transfers nothing.
        $Again = Fetch-Chains -Paths $PathsB -RemoteRoot $Remote
        $Again.EntriesAdded | Should -Be 0
        $Again.BlobsFetched | Should -Be 0
    }

    It "merges divergent histories from two machines without losing commits" {
        $Remote = Join-Path $Script:Tmp "remote"
        Write-TestSave -Dir $Script:Saves -Name "a.srm" -Bytes (New-TestBytes -Seed 1)
        $null = New-SaveCommit -Paths $Script:Paths -Message "from a"
        $Push = Push-Chains -Paths $Script:Paths -RemoteRoot $Remote

        $VaultB = Join-Path $Script:Tmp "vaultB"
        $SavesB = Join-Path $Script:Tmp "savesB"
        New-Item -ItemType Directory -Path $VaultB | Out-Null
        New-Item -ItemType Directory -Path $SavesB | Out-Null
        $PathsB = Initialize-Chains -Path $VaultB
        Add-SaveWatchPath -Paths $PathsB -WatchPath $SavesB | Out-Null
        $null = Fetch-Chains -Paths $PathsB -RemoteRoot $Remote -VaultId $Push.VaultId

        # Machine B diverges: new save, new commit, push back up.
        Write-TestSave -Dir $SavesB -Name "b.sav" -Bytes (New-TestBytes -Seed 9)
        $B = New-SaveCommit -Paths $PathsB -Message "from b"
        $null = Push-Chains -Paths $PathsB -RemoteRoot $Remote

        # Machine A fetches: both histories present, both verify.
        $FetchA = Fetch-Chains -Paths $Script:Paths -RemoteRoot $Remote
        $FetchA.EntriesAdded | Should -Be 1
        @(Get-SaveJournal -Paths $Script:Paths).Count | Should -Be 2
        @(Get-SaveJournal -Paths $PathsB).Count | Should -Be 2
        (Find-SaveCommit -Paths $Script:Paths -Ref $B.id).id | Should -Be $B.id
        Test-SaveChain -Paths $Script:Paths | Should -BeTrue
        Test-SaveChain -Paths $PathsB | Should -BeTrue
    }

    It "rejects a tampered remote blob on fetch" {
        $Remote = Join-Path $Script:Tmp "remote"
        Write-TestSave -Dir $Script:Saves -Name "game.srm" -Bytes (New-TestBytes -Seed 5)
        $null = New-SaveCommit -Paths $Script:Paths -Message "clean"
        $Push = Push-Chains -Paths $Script:Paths -RemoteRoot $Remote

        # Tamper with the blob on the remote side.
        $Sha = @((Get-SaveJournal -Paths $Script:Paths)[0].files)[0].sha256
        $RemoteBlob = [IO.Path]::Combine($Remote, "vaults", $Push.VaultId, "blobs", $Sha)
        [IO.File]::AppendAllBytes($RemoteBlob, [byte[]]@(0xFF))

        $VaultB = Join-Path $Script:Tmp "vaultB"
        $SavesB = Join-Path $Script:Tmp "savesB"
        New-Item -ItemType Directory -Path $VaultB | Out-Null
        New-Item -ItemType Directory -Path $SavesB | Out-Null
        $PathsB = Initialize-Chains -Path $VaultB
        Add-SaveWatchPath -Paths $PathsB -WatchPath $SavesB | Out-Null

        $Fetch = Fetch-Chains -Paths $PathsB -RemoteRoot $Remote -VaultId $Push.VaultId
        $Fetch | Should -BeNullOrEmpty
        # The local journal was never extended with the poisoned entry.
        @(Get-SaveJournal -Paths $PathsB).Count | Should -Be 0
    }

    It "reports per-commit deltas in the log, newest first" {
        Write-TestSave -Dir $Script:Saves -Name "game.sav" -Bytes (New-TestBytes -Seed 1)
        $A = New-SaveCommit -Paths $Script:Paths -Message "v1"
        Write-TestSave -Dir $Script:Saves -Name "game.sav" -Bytes (New-TestBytes -Seed 2)
        Write-TestSave -Dir $Script:Saves -Name "extra.srm" -Bytes (New-TestBytes -Seed 3)
        $B = New-SaveCommit -Paths $Script:Paths -Message "v2"

        $Log = @(Get-SaveLog -Paths $Script:Paths)
        $Log.Count | Should -Be 2
        $Log[0].Id | Should -Be $B.id
        $Log[0].Added | Should -Be 1
        $Log[0].Modified | Should -Be 1
        $Log[0].Deleted | Should -Be 0
        $Log[1].Id | Should -Be $A.id
        $Log[1].Added | Should -Be 1   # root commit: everything counts as added
        $Log[1].Modified | Should -Be 0

        $Limited = @(Get-SaveLog -Paths $Script:Paths -Count 1)
        $Limited.Count | Should -Be 1
        $Limited[0].Id | Should -Be $B.id
    }

    It "round-trips real-world save sizes byte-identical (.srm 32KB, .sav 64KB)" {
        # SNES HiROM battery SRAM is 32KB; GBA flash saves are 64KB (512Kbit).
        # Chains never parses these -- it stores opaque bytes. This locks in
        # the byte-identity guarantee at realistic sizes.
        $Srm = [byte[]]::new(32768)
        for ($i = 0; $i -lt $Srm.Length; $i++) { $Srm[$i] = [byte](($i * 7 + 3) % 256) }
        [IO.File]::WriteAllBytes((Join-Path $Script:Saves "game.srm"), $Srm)
        $Sav = [byte[]]::new(65536)
        for ($i = 0; $i -lt $Sav.Length; $i++) { $Sav[$i] = [byte](($i * 13 + 11) % 256) }
        [IO.File]::WriteAllBytes((Join-Path $Script:Saves "game.sav"), $Sav)

        $C = New-SaveCommit -Paths $Script:Paths -Message "real sizes"
        @($C.files).Count | Should -Be 2

        # Scramble the working copies, then restore the commit.
        [IO.File]::WriteAllBytes((Join-Path $Script:Saves "game.srm"), [byte[]]::new(32768))
        [IO.File]::WriteAllBytes((Join-Path $Script:Saves "game.sav"), [byte[]]::new(65536))
        $null = Restore-SaveCommit -Paths $Script:Paths -Ref $C.id -NoBackup

        Get-TestFileBytesHex -File (Join-Path $Script:Saves "game.srm") | Should -Be ([BitConverter]::ToString($Srm))
        Get-TestFileBytesHex -File (Join-Path $Script:Saves "game.sav") | Should -Be ([BitConverter]::ToString($Sav))
    }
}

Describe "Chains remote fingerprint pinning" {
    BeforeAll {
        . (Join-Path $PSScriptRoot ".." "modules" "vault.ps1")

        function New-TestBytes {
            param([int]$Seed = 0)
            $b = [byte[]](0..255)
            for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [byte](($i + $Seed) % 256) }
            return $b
        }

        function Write-TestSave {
            param([string]$Dir, [string]$Name, [byte[]]$Bytes)
            [IO.File]::WriteAllBytes((Join-Path $Dir $Name), $Bytes)
        }

        function New-SecondVault {
            param([string]$Tmp)
            $VaultB = Join-Path $Tmp "vaultB"
            $SavesB = Join-Path $Tmp "savesB"
            New-Item -ItemType Directory -Path $VaultB | Out-Null
            New-Item -ItemType Directory -Path $SavesB | Out-Null
            $PathsB = Initialize-Chains -Path $VaultB
            Add-SaveWatchPath -Paths $PathsB -WatchPath $SavesB | Out-Null
            return $PathsB
        }
    }

    BeforeEach {
        $Script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("chains-pin-" + [Guid]::NewGuid().ToString("N"))
        $Script:Vault = Join-Path $Script:Tmp "vault"
        $Script:Saves = Join-Path $Script:Tmp "saves"
        New-Item -ItemType Directory -Path $Script:Vault | Out-Null
        New-Item -ItemType Directory -Path $Script:Saves | Out-Null
        $Script:Paths = Initialize-Chains -Path $Script:Vault
        Add-SaveWatchPath -Paths $Script:Paths -WatchPath $Script:Saves | Out-Null
        $Script:Remote = Join-Path $Script:Tmp "remote"
    }

    AfterEach {
        Remove-Item -Recurse -Force $Script:Tmp -ErrorAction SilentlyContinue
    }

    It "pins the remote on first sync and keeps syncing as history grows" {
        Write-TestSave -Dir $Script:Saves -Name "game.srm" -Bytes (New-TestBytes -Seed 1)
        $null = New-SaveCommit -Paths $Script:Paths -Message "v1"
        $Push = Push-Chains -Paths $Script:Paths -RemoteRoot $Script:Remote
        $Push | Should -Not -BeNullOrEmpty

        $Pins = Get-RemotePins -Paths $Script:Paths
        $Key = Get-PinKey -RemoteRoot $Script:Remote -VaultId $Push.VaultId
        $Pins.ContainsKey($Key) | Should -BeTrue
        $Pins[$Key].fingerprint | Should -Be (Get-JournalFingerprint -Entries @(Get-SaveJournal -Paths $Script:Paths))

        # A second commit pushes fine against the existing pin, and the pin moves forward.
        Write-TestSave -Dir $Script:Saves -Name "game.srm" -Bytes (New-TestBytes -Seed 2)
        $null = New-SaveCommit -Paths $Script:Paths -Message "v2"
        $Push2 = Push-Chains -Paths $Script:Paths -RemoteRoot $Script:Remote
        $Push2 | Should -Not -BeNullOrEmpty
        (Get-RemotePins -Paths $Script:Paths)[$Key].fingerprint |
            Should -Be (Get-JournalFingerprint -Entries @(Get-SaveJournal -Paths $Script:Paths))
    }

    It "aborts fetch when the remote journal is rolled back (replay)" {
        Write-TestSave -Dir $Script:Saves -Name "game.srm" -Bytes (New-TestBytes -Seed 1)
        $A = New-SaveCommit -Paths $Script:Paths -Message "v1"
        $Push = Push-Chains -Paths $Script:Paths -RemoteRoot $Script:Remote

        $PathsB = New-SecondVault -Tmp $Script:Tmp
        $null = Fetch-Chains -Paths $PathsB -RemoteRoot $Script:Remote -VaultId $Push.VaultId
        @(Get-SaveJournal -Paths $PathsB).Count | Should -Be 1

        # Attacker rolls the remote back: empty the journal entirely.
        $RJ = Join-Path $Script:Remote "vaults" $Push.VaultId "journal.jsonl"
        "" | Set-Content $RJ -Force -NoNewline

        $Fetch = Fetch-Chains -Paths $PathsB -RemoteRoot $Script:Remote
        $Fetch | Should -BeNullOrEmpty
        # Local vault untouched: the pinned commit is still there.
        @(Get-SaveJournal -Paths $PathsB).Count | Should -Be 1
        (Find-SaveCommit -Paths $PathsB -Ref $A.id).id | Should -Be $A.id
    }

    It "aborts push when the remote journal was swapped for another vault's" {
        Write-TestSave -Dir $Script:Saves -Name "game.srm" -Bytes (New-TestBytes -Seed 1)
        $null = New-SaveCommit -Paths $Script:Paths -Message "v1"
        $Push = Push-Chains -Paths $Script:Paths -RemoteRoot $Script:Remote

        # Attacker swaps in a different vault's journal under the same id dir.
        $PathsC = New-SecondVault -Tmp $Script:Tmp
        Write-TestSave -Dir (Join-Path $Script:Tmp "savesB") -Name "evil.sav" -Bytes (New-TestBytes -Seed 99)
        $null = New-SaveCommit -Paths $PathsC -Message "evil history"
        $RJ = Join-Path $Script:Remote "vaults" $Push.VaultId "journal.jsonl"
        Get-Content (Join-Path $PathsC.Root ".chains" "journal.jsonl") | Set-Content $RJ -Force

        $Again = Push-Chains -Paths $Script:Paths -RemoteRoot $Script:Remote
        $Again | Should -BeNullOrEmpty
        # The swapped journal was not merged into the local vault.
        @(Get-SaveJournal -Paths $Script:Paths).Count | Should -Be 1
    }

    It "rejects a remote that drops a middle commit but keeps the tip" {
        Write-TestSave -Dir $Script:Saves -Name "game.srm" -Bytes (New-TestBytes -Seed 1)
        $A = New-SaveCommit -Paths $Script:Paths -Message "v1"
        Write-TestSave -Dir $Script:Saves -Name "game.srm" -Bytes (New-TestBytes -Seed 2)
        $null = New-SaveCommit -Paths $Script:Paths -Message "v2"
        $Push = Push-Chains -Paths $Script:Paths -RemoteRoot $Script:Remote

        $PathsB = New-SecondVault -Tmp $Script:Tmp
        $null = Fetch-Chains -Paths $PathsB -RemoteRoot $Script:Remote -VaultId $Push.VaultId

        # Attacker deletes the v1 line from the remote journal, keeps v2.
        # Match on the "id" field specifically: v2's parent field also names v1.
        $RJ = Join-Path $Script:Remote "vaults" $Push.VaultId "journal.jsonl"
        $IdField = '"id":"' + $A.id + '"'
        $Rest = @(Get-Content $RJ | Where-Object { $_ -notmatch [regex]::Escape($IdField) -and -not [string]::IsNullOrWhiteSpace($_) })
        $Rest | Set-Content $RJ -Force

        $Fetch = Fetch-Chains -Paths $PathsB -RemoteRoot $Script:Remote
        $Fetch | Should -BeNullOrEmpty
        @(Get-SaveJournal -Paths $PathsB).Count | Should -Be 2
    }

    It "keeps pins independent per remote root" {
        $Remote2 = Join-Path $Script:Tmp "remote2"
        Write-TestSave -Dir $Script:Saves -Name "game.srm" -Bytes (New-TestBytes -Seed 1)
        $null = New-SaveCommit -Paths $Script:Paths -Message "v1"
        $null = Push-Chains -Paths $Script:Paths -RemoteRoot $Script:Remote
        $null = Push-Chains -Paths $Script:Paths -RemoteRoot $Remote2

        # Roll back the first remote only.
        $RJ = Join-Path $Script:Remote "vaults" (Get-ChainsVaultId -Paths $Script:Paths) "journal.jsonl"
        "" | Set-Content $RJ -Force -NoNewline

        (Push-Chains -Paths $Script:Paths -RemoteRoot $Script:Remote) | Should -BeNullOrEmpty
        (Push-Chains -Paths $Script:Paths -RemoteRoot $Remote2) | Should -Not -BeNullOrEmpty
    }
}
