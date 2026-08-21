Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$adapterPath = Join-Path $repoRoot 'adapters\deepseek-harness\DeepSeekHarnessAdapter.psm1'
Import-Module -Name $adapterPath -Force -ErrorAction Stop

function New-QvwHarnessVerifyFixture {
    $root = New-QvwTempDirectory
    $image = Join-Path $root 'QVW-7319.png'
    [IO.File]::WriteAllBytes($image, [byte[]](0, 1, 2, 3))
    $readme = Join-Path $root 'README.txt'
    $beforeBytes = [Text.UTF8Encoding]::new($false).GetBytes("fixture before`n")
    $afterBytes = [Text.UTF8Encoding]::new($false).GetBytes("fixture after`n")
    [IO.File]::WriteAllBytes($readme, $beforeBytes)
    $mountPath = Join-Path $root 'runtime.mount.yml'
    [IO.File]::WriteAllBytes($mountPath, [Text.UTF8Encoding]::new($false).GetBytes("name: @deepseek-ai/dsh-prompt-image-bridge`n"))
    git -C $root init -q | Out-Null
    git -C $root config core.autocrlf false | Out-Null
    git -C $root config user.email qvw-verify@example.invalid | Out-Null
    git -C $root config user.name qvw-verify | Out-Null
    git -C $root add -- README.txt | Out-Null
    git -C $root commit -q -m fixture | Out-Null
    $upstreamCommit = (git -C $root rev-parse HEAD).Trim()
    [IO.File]::WriteAllBytes($readme, $afterBytes)
    $patchLines = @(& git -C $root -c core.autocrlf=false diff --no-ext-diff --binary -- README.txt)
    $patchText = [string]::Join("`n", $patchLines)
    if (-not $patchText.EndsWith("`n")) { $patchText += "`n" }
    $patchPath = Join-Path $root 'fixture.patch'
    [IO.File]::WriteAllBytes($patchPath, [Text.UTF8Encoding]::new($false).GetBytes($patchText))
    $beforeSha = ([BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($beforeBytes))).Replace('-', '').ToLowerInvariant()
    $afterSha = ([BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($afterBytes))).Replace('-', '').ToLowerInvariant()
    $state = [pscustomobject][ordered]@{ Evidence = $null }
    $manifest = [pscustomobject][ordered]@{
        schemaVersion = 1
        adapterVersion = 'test'
        upstreamCommit = $upstreamCommit
        packageVersion = 'fixture'
        controlledFiles = @(
            [pscustomobject][ordered]@{ path = 'README.txt'; beforeExists = $true; beforeSha256 = $beforeSha; afterSha256 = $afterSha }
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
    }
    $harness = [pscustomobject][ordered]@{
        Root = $root
        Manifest = $manifest
        PayloadPath = $patchPath
        ImagePath = $image
        TestState = $state
        TestSeam = $null
        Compatibility = $null
        LiveEvidence = $null
        LiveProbe = ({ param([string]$ImagePath) $state.Evidence }.GetNewClosure())
        Cleanup = ({ Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null }).GetNewClosure()
    }
    return $harness
}

Describe-Qvw 'DeepSeek Harness live evidence gate' {
    It-Qvw 'blocks a paid verification unless explicit confirmation is supplied' {
        $fixture = New-QvwHarnessVerifyFixture
        try {
            $result = Invoke-QvwHarnessLiveVerify -Harness $fixture -ImagePath $fixture.ImagePath
            Assert-QvwEqual $result.status 'blocked'
            Assert-QvwEqual $result.code 'QVW-D-PAID-CONFIRMATION-REQUIRED'
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'accepts only a complete parent-child evidence trace' {
        $fixture = New-QvwHarnessVerifyFixture
        try {
            $fixture.TestState.Evidence = [pscustomobject][ordered]@{
                parentProvider = 'deepseek-official'
                parentModel = 'deepseek-v4-pro'
                childModel = 'qwen3.7-plus'
                childImageCount = 1
                parentHasVisualContext = $true
                parentImageBlockCount = 0
                parentSteps = 1
                recursiveToolCalls = 0
                ocr = 'QVW-7319'
                finalText = 'detected QVW-7319 in the blue rectangle.'
            }
            $result = Invoke-QvwHarnessLiveVerify -Harness $fixture -ImagePath $fixture.ImagePath -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'target-accepted'
            Assert-QvwEqual $result.code 'QVW-D-LIVE-ACCEPTED'
            Assert-QvwMatch ([string]$result.evidence.finalText) 'QVW-7319'
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'returns unverified when final OCR text is correct but route evidence is missing' {
        $fixture = New-QvwHarnessVerifyFixture
        try {
            $fixture.TestState.Evidence = [pscustomobject]@{ finalText = 'QVW-7319' }
            $result = Invoke-QvwHarnessLiveVerify -Harness $fixture -ImagePath $fixture.ImagePath -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'unverified'
            Assert-QvwEqual $result.code 'QVW-D-EVIDENCE-INCOMPLETE'
            Assert-QvwTrue ($result.evidence.missing.Count -gt 0)
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'rejects a wrong parent or recursive child trace even with the expected OCR' {
        $fixture = New-QvwHarnessVerifyFixture
        try {
            $fixture.TestState.Evidence = [pscustomobject][ordered]@{
                parentProvider = 'deepseek'
                parentModel = 'deepseek-v4-pro'
                childModel = 'qwen3.7-plus'
                childImageCount = 1
                parentHasVisualContext = $true
                parentImageBlockCount = 0
                parentSteps = 1
                recursiveToolCalls = 2
                ocr = 'QVW-7319'
                finalText = 'QVW-7319'
            }
            $result = Invoke-QvwHarnessLiveVerify -Harness $fixture -ImagePath $fixture.ImagePath -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'unverified'
            Assert-QvwMatch ($result.evidence.missing -join ';') '(?i)parentProvider|recursiveToolCalls'
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'rejects string booleans and numeric strings instead of coercing them into evidence' {
        $fixture = New-QvwHarnessVerifyFixture
        try {
            $fixture.TestState.Evidence = [pscustomobject][ordered]@{
                parentProvider = 'deepseek-official'
                parentModel = 'deepseek-v4-pro'
                childModel = 'qwen3.7-plus'
                childImageCount = '1'
                parentHasVisualContext = 'true'
                parentImageBlockCount = 0
                parentSteps = 1
                recursiveToolCalls = 0
                ocr = 'QVW-7319'
                finalText = 'QVW-7319'
            }
            $result = Invoke-QvwHarnessLiveVerify -Harness $fixture -ImagePath $fixture.ImagePath -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'unverified'
            Assert-QvwContains $result.evidence.missing 'childImageCount'
            Assert-QvwContains $result.evidence.missing 'parentHasVisualContext'
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'does not let an unmarked compatibility or evidence override bypass the real mount/runtime gate' {
        $fixture = New-QvwHarnessVerifyFixture
        try {
            $fixture.Root = Join-Path $fixture.Root 'missing-root'
            $fixture.TestSeam = $true
            $fixture.Compatibility = [pscustomobject]@{ State = 'installed-matching'; Commit = ('a' * 40); ControlledFiles = @(); Mismatches = @() }
            $fixture.LiveEvidence = [pscustomobject][ordered]@{
                parentProvider = 'deepseek-official'
                parentModel = 'deepseek-v4-pro'
                childModel = 'qwen3.7-plus'
                childImageCount = 1
                parentHasVisualContext = $true
                parentImageBlockCount = 0
                parentSteps = 1
                recursiveToolCalls = 0
                ocr = 'QVW-7319'
                finalText = 'QVW-7319'
            }
            $result = Invoke-QvwHarnessLiveVerify -Harness $fixture -ImagePath $fixture.ImagePath -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'blocked'
            Assert-QvwEqual $result.code 'QVW-D-COMPATIBILITY-BLOCKED'
        }
        finally { & $fixture.Cleanup }
    }
}
