Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$adapterPath = Join-Path $repoRoot 'adapters\deepseek-harness\DeepSeekHarnessAdapter.psm1'
Import-Module -Name $adapterPath -Force -ErrorAction Stop

Describe-Qvw 'DeepSeek Harness discovery and compatibility' {
    It-Qvw 'finds an explicitly selected Harness root without guessing another checkout' {
        $root = New-QvwTempDirectory
        try {
            $result = Find-QvwDeepSeekHarness -ExplicitRoot $root
            Assert-QvwEqual $result.Root ([IO.Path]::GetFullPath($root))
            Assert-QvwEqual $result.Selection 'explicit'
            Assert-QvwTrue $result.Available
            Assert-QvwTrue ($null -ne $result.GitPath)
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }

    It-Qvw 'reports a missing explicit root as unavailable without throwing' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('qvw-missing-harness-' + [guid]::NewGuid().ToString('N'))
        $result = Find-QvwDeepSeekHarness -ExplicitRoot $root
        Assert-QvwFalse $result.Available
        Assert-QvwEqual $result.Selection 'explicit'
        Assert-QvwMatch $result.Error '(?i)not found|unavailable|directory'
    }

    It-Qvw 'returns unknown for a non-git root and exposes only safe mismatch names' {
        $root = New-QvwTempDirectory
        try {
            $harness = [pscustomobject]@{
                Root = $root
                Manifest = [pscustomobject]@{
                    schemaVersion = 1
                    upstreamCommit = ('a' * 40)
                    controlledFiles = @()
                    requiredMounts = @()
                }
            }
            $compat = Get-QvwHarnessCompatibility $harness
            Assert-QvwEqual $compat.State 'unknown'
            Assert-QvwFalse ([string]::IsNullOrWhiteSpace([string]$compat.Commit))
            Assert-QvwTrue ($compat.Mismatches.Count -gt 0)
            Assert-QvwNotMatch ($compat | ConvertTo-Json -Depth 8) '(?i)authorization|bearer|api[_-]?key|secret|token'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }

    It-Qvw 'ships an exact bridge manifest with explicit exclusions and regression commands' {
        $manifestPath = Join-Path $repoRoot 'adapters\deepseek-harness\manifest.json'
        $payloadPath = Join-Path $repoRoot 'adapters\deepseek-harness\payload\prompt-image-bridge.patch'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        Assert-QvwEqual $manifest.upstreamCommit '47f943859bef60e4160492346772ded9b24f765a'
        Assert-QvwEqual $manifest.packageVersion '0.1.0-rc.5'
        Assert-QvwEqual $manifest.controlledFiles.Count 12
        Assert-QvwEqual $manifest.testCommands.Count 2
        Assert-QvwEqual $manifest.patchPlan.applyCheck[1] 'apply'
        Assert-QvwEqual $manifest.patchPlan.reverseCheck[1] 'apply'
        Assert-QvwEqual $manifest.requiredMounts.Count 1
        Assert-QvwEqual $manifest.requiredMounts[0].requiredForLive $true
        Assert-QvwMatch ([string]$manifest.requiredMounts[0].path) '(?i)%USERPROFILE%.*cordis\.patch\.yml'
        Assert-QvwMatch ([string]$manifest.requiredMounts[0].expectedContains) 'prompt-image-bridge'
        Assert-QvwTrue (Test-Path -LiteralPath $payloadPath -PathType Leaf)
        $payloadBytes = [IO.File]::ReadAllBytes($payloadPath)
        Assert-QvwFalse ([bool](@($payloadBytes | Where-Object { $_ -eq 13 }).Count -gt 0))
        foreach ($entry in @($manifest.controlledFiles)) {
            Assert-QvwMatch ([string]$entry.afterSha256) '^[0-9a-f]{64}$'
            if ([string]$entry.path -like 'packages/attachment/prompt-image-bridge/*') {
                Assert-QvwFalse ([bool]$entry.beforeExists)
                Assert-QvwTrue ($null -eq $entry.beforeSha256)
            }
        }
        Assert-QvwTrue (@($manifest.excludedPaths | Where-Object { $_ -eq 'packages/subagent/**' }).Count -eq 1)
        Assert-QvwTrue (@($manifest.excludedPaths | Where-Object { $_ -eq 'packages/**/workspace-browser/**' }).Count -eq 1)
        Assert-QvwTrue (@($manifest.excludedPaths | Where-Object { $_ -eq 'packages/**/session-delete/**' }).Count -eq 1)
        Assert-QvwTrue ($null -ne $manifest.dependencyStrategy.offline)
        Assert-QvwTrue ($null -ne $manifest.dependencyStrategy.pinned)
    }
}
