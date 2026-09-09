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
}
