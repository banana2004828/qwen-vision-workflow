Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$adapterPath = Join-Path $repoRoot 'adapters\deepseek-harness\DeepSeekHarnessAdapter.psm1'
Import-Module -Name $adapterPath -Force -ErrorAction Stop

function New-QvwHarnessInstallFixture {
    $root = New-QvwTempDirectory
    $template = Join-Path $repoRoot 'tests\fixtures\deepseek-harness\accepted'
    Copy-Item -Path (Join-Path $template '*') -Destination $root -Recurse -Force
    $mountPath = Join-Path $root 'runtime.mount.yml'
    [IO.File]::WriteAllBytes($mountPath, [Text.UTF8Encoding]::new($false).GetBytes("name: @deepseek-ai/dsh-prompt-image-bridge`n"))
    $readme = Join-Path $root 'README.txt'
    $before = (Get-FileHash -LiteralPath $readme -Algorithm SHA256).Hash.ToLowerInvariant()
    $afterBytes = [Text.UTF8Encoding]::new($false).GetBytes("bridge installed`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $afterSha = ([BitConverter]::ToString($sha.ComputeHash($afterBytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    git -C $root init -q | Out-Null
    git -C $root config core.autocrlf false | Out-Null
    git -C $root config user.email qvw-fixture@example.invalid | Out-Null
    git -C $root config user.name qvw-fixture | Out-Null
    git -C $root add -- README.txt | Out-Null
    git -C $root commit -q -m fixture | Out-Null
    $commit = (git -C $root rev-parse HEAD).Trim()
    $patch = Join-Path $root 'fixture.patch'
    $patchLines = @(
        'diff --git a/bridge.marker b/bridge.marker',
        'new file mode 100644',
        'index 0000000..607b537',
        '--- /dev/null',
        '+++ b/bridge.marker',
        '@@ -0,0 +1 @@',
        '+bridge installed',
        ''
    )
    $patchText = [string]::Join("`n", $patchLines)
    [IO.File]::WriteAllBytes($patch, [Text.UTF8Encoding]::new($false).GetBytes($patchText))
    $manifest = [pscustomobject][ordered]@{
        schemaVersion = 1
        adapterVersion = 'test'
        upstreamCommit = $commit
        packageVersion = 'fixture'
        controlledFiles = @(
            [pscustomobject][ordered]@{ path = 'README.txt'; beforeExists = $true; beforeSha256 = $before; afterSha256 = $before }
            [pscustomobject][ordered]@{ path = 'bridge.marker'; beforeExists = $false; beforeSha256 = $null; afterSha256 = $afterSha }
        )
        requiredMounts = @(
            [pscustomobject][ordered]@{
                path = 'runtime.mount.yml'
                scope = 'harness'
                requiredForLive = $true
                expectedContains = '@deepseek-ai/dsh-prompt-image-bridge'
            }
        )
        patchPlan = [pscustomobject][ordered]@{
            applyCheck = @('git', 'apply', '--check', '--whitespace=nowarn')
            reverseCheck = @('git', 'apply', '--reverse', '--check', '--whitespace=nowarn')
        }
        dependencyStrategy = [pscustomobject][ordered]@{
            offline = @('dependency-offline')
            pinned = @('dependency-pinned')
        }
        testCommands = @('fixture-test')
    }
    $state = @{ TestCalls = 0; DependencyCalls = @(); FailOffline = $false; FailTests = $false; WarningMessages = @() }
    $harness = [pscustomobject][ordered]@{
        Root = $root
        Manifest = $manifest
        PayloadPath = $patch
        Command = ({ param([string[]]$Arguments)
            if ($Arguments -contains 'dependency-offline') {
                $state.DependencyCalls += 'offline'
                if ($state.FailOffline) { return [pscustomobject]@{ ExitCode = 1; Succeeded = $false; StdOut = ''; StdErr = 'offline unavailable'; Error = 'offline unavailable' } }
            }
            if ($Arguments -contains 'dependency-pinned') { $state.DependencyCalls += 'pinned' }
            if ($Arguments -contains 'fixture-test') {
                $state.TestCalls++
                if ($state.FailTests) { return [pscustomobject]@{ ExitCode = 1; Succeeded = $false; StdOut = ''; StdErr = 'fixture test failed'; Error = 'fixture test failed' } }
            }
            return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = 'ok'; StdErr = ''; Error = $null }
        }.GetNewClosure())
        TestState = $state
        AllowNetworkFallback = $false
        WarningSink = ({ param([string]$Message) $state.WarningMessages += $Message }.GetNewClosure())
        Cleanup = ({ Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null }).GetNewClosure()
    }
    return $harness
}

Describe-Qvw 'DeepSeek Harness transactional installation' {
    It-Qvw 'classifies an exact clean root with the preimage as missing-matching' {
        $fixture = New-QvwHarnessInstallFixture
        try {
            $compat = Get-QvwHarnessCompatibility $fixture
            Assert-QvwEqual $compat.State 'missing-matching'
            Assert-QvwEqual $compat.Commit $fixture.Manifest.upstreamCommit
            Assert-QvwEqual $compat.ControlledFiles.Count 2
            Assert-QvwTrue $compat.PatchChecks.ApplyCheck
            Assert-QvwFalse ([bool]$compat.PatchChecks.ReverseCheck)
            Assert-QvwTrue $compat.RequiredMounts[0].Satisfied
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'installs only the manifest payload and reaches installed-matching' {
        $fixture = New-QvwHarnessInstallFixture
        try {
            $result = Install-QvwHarnessBridge -Harness $fixture
            Assert-QvwEqual $result.status 'installed'
            Assert-QvwTrue (Test-Path -LiteralPath (Join-Path $fixture.Root 'bridge.marker') -PathType Leaf)
            Assert-QvwEqual $fixture.TestState.TestCalls 1
            $compat = Get-QvwHarnessCompatibility $fixture
            Assert-QvwEqual $compat.State 'installed-matching'
            Assert-QvwTrue $compat.PatchChecks.ReverseCheck
            $receiptPath = [string]$result.evidence.receiptPath
            Assert-QvwTrue (Test-Path -LiteralPath $receiptPath -PathType Leaf)
            $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
            Assert-QvwEqual $receipt.entries.Count 2
            Assert-QvwContains $fixture.TestState.DependencyCalls 'offline'
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'returns dirty-overlap and never writes over a user edit' {
        $fixture = New-QvwHarnessInstallFixture
        try {
            Add-Content -LiteralPath (Join-Path $fixture.Root 'README.txt') -Value 'user edit'
            $before = Get-QvwTreeHash $fixture.Root
            $compat = Get-QvwHarnessCompatibility $fixture
            Assert-QvwEqual $compat.State 'dirty-overlap'
            $result = Install-QvwHarnessBridge -Harness $fixture
            Assert-QvwEqual $result.status 'blocked'
            Assert-QvwEqual (Get-QvwTreeHash $fixture.Root) $before
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'refuses an unknown revision without changing files' {
        $fixture = New-QvwHarnessInstallFixture
        try {
            $fixture.Manifest.upstreamCommit = 'b' * 40
            $before = Get-QvwTreeHash $fixture.Root
            $compat = Get-QvwHarnessCompatibility $fixture
            Assert-QvwEqual $compat.State 'unknown'
            $result = Install-QvwHarnessBridge -Harness $fixture
            Assert-QvwEqual $result.status 'blocked'
            Assert-QvwEqual (Get-QvwTreeHash $fixture.Root) $before
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'rolls back every controlled file when the manifest test fails' {
        $fixture = New-QvwHarnessInstallFixture
        try {
            $fixture.TestState.FailTests = $true
            $readmePath = Join-Path $fixture.Root 'README.txt'
            $before = (Get-FileHash -LiteralPath $readmePath -Algorithm SHA256).Hash
            $result = Install-QvwHarnessBridge -Harness $fixture
            Assert-QvwEqual $result.status 'failed'
            Assert-QvwEqual (Get-FileHash -LiteralPath $readmePath -Algorithm SHA256).Hash $before
            Assert-QvwFalse (Test-Path -LiteralPath (Join-Path $fixture.Root 'bridge.marker') -PathType Leaf)
            Assert-QvwTrue (Test-Path -LiteralPath ([string]$result.evidence.receiptPath) -PathType Leaf)
            Assert-QvwEqual (Get-QvwHarnessCompatibility $fixture).State 'missing-matching'
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'falls back to the pinned lock install when offline dependencies are unavailable' {
        $fixture = New-QvwHarnessInstallFixture
        try {
            $fixture.TestState.FailOffline = $true
            $fixture.AllowNetworkFallback = $true
            $result = Install-QvwHarnessBridge -Harness $fixture
            Assert-QvwEqual $result.status 'installed'
            Assert-QvwContains $fixture.TestState.DependencyCalls 'offline'
            Assert-QvwContains $fixture.TestState.DependencyCalls 'pinned'
            Assert-QvwTrue ($fixture.TestState.WarningMessages.Count -eq 1)
            Assert-QvwMatch $fixture.TestState.WarningMessages[0] '(?i)network|fallback'
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'does not use a pinned network fallback without an explicit policy flag' {
        $fixture = New-QvwHarnessInstallFixture
        try {
            $fixture.TestState.FailOffline = $true
            $result = Install-QvwHarnessBridge -Harness $fixture
            Assert-QvwEqual $result.status 'failed'
            Assert-QvwContains $fixture.TestState.DependencyCalls 'offline'
            Assert-QvwFalse ([bool]($fixture.TestState.DependencyCalls -contains 'pinned'))
            Assert-QvwTrue ($fixture.TestState.WarningMessages.Count -eq 1)
            Assert-QvwMatch ([string]$result.evidence.error) '(?i)AllowNetworkFallback|network fallback'
            Assert-QvwEqual (Get-QvwHarnessCompatibility $fixture).State 'missing-matching'
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'blocks installation when the required external bridge mount is absent' {
        $fixture = New-QvwHarnessInstallFixture
        try {
            Remove-Item -LiteralPath (Join-Path $fixture.Root 'runtime.mount.yml') -Force
            $result = Install-QvwHarnessBridge -Harness $fixture
            Assert-QvwEqual $result.status 'blocked'
            Assert-QvwEqual $result.code 'QVW-D-REQUIRED-MOUNT-MISSING'
            Assert-QvwEqual (Get-QvwHarnessCompatibility $fixture).State 'missing-matching'
        }
        finally { & $fixture.Cleanup }
    }
}
