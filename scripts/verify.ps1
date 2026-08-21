[CmdletBinding()]
param(
    [string]$HermesRoot,
    [string]$HarnessRoot,
    [string]$ImagePath,
    [switch]$Json,
    [switch]$NonInteractive,
    [switch]$ConfirmPaidCalls,
    [int]$TimeoutSeconds = 60
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $scriptRoot 'modules\Qvw.Result.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $scriptRoot 'modules\Qvw.Process.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $scriptRoot 'modules\Qvw.Security.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $scriptRoot 'modules\Qvw.State.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $scriptRoot 'modules\Qvw.ImageFixture.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $scriptRoot 'adapters\hermes\HermesAdapter.psm1') -Force -ErrorAction Stop

function New-QvwVerifyCompositeResult {
    param($HermesResult, $HarnessResult)

    if ($null -eq $HarnessResult) { return $HermesResult }
    if ([string]$HermesResult.status -eq 'target-accepted' -and [string]$HarnessResult.status -eq 'target-accepted') {
        return (New-QvwResult -Component 'qwen-vision-workflow' -Status 'target-accepted' -Code 'QVW-VERIFY-COMPLETE' -Message 'Hermes and DeepSeek Harness image routes were both accepted with provider-bound evidence.' -Evidence @{ hermes = $HermesResult; deepseekHarness = $HarnessResult })
    }
    if ([string]$HermesResult.status -eq 'target-accepted') {
        return (New-QvwResult -Component 'qwen-vision-workflow' -Status 'degraded' -Code 'QVW-VERIFY-HARNESS-NOT-ACCEPTED' -Message 'Hermes image routing was accepted, but the requested DeepSeek Harness route remains blocked or unverified.' -Evidence @{ hermes = $HermesResult; deepseekHarness = $HarnessResult })
    }
    return $HermesResult
}

$fixtureRoot = $null
try {
    if (-not $ConfirmPaidCalls) {
        $result = New-QvwResult -Component 'hermes' -Status 'blocked' -Code 'QVW-H-PAID-CONFIRMATION-REQUIRED' -Message 'Real Hermes image verification requires explicit confirmation; no command was started.' -Evidence @{}
        Write-QvwResult -Result $result -AsJson
        exit 2
    }

    if ([string]::IsNullOrWhiteSpace($ImagePath)) {
        $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('qvw-verify-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
        $ImagePath = (New-QvwImageFixture -Path (Join-Path $fixtureRoot 'qvw.png')).Path
    }
    $hermes = Find-QvwHermes -ExplicitRoot $HermesRoot
    $hermesResult = Invoke-QvwHermesLiveVerify -Hermes $hermes -ImagePath $ImagePath -ConfirmPaidCalls -TimeoutSeconds $TimeoutSeconds
    $harnessResult = $null
    if ([string]$hermesResult.status -eq 'target-accepted' -and -not [string]::IsNullOrWhiteSpace($HarnessRoot)) {
        Import-Module (Join-Path $scriptRoot 'adapters\deepseek-harness\DeepSeekHarnessAdapter.psm1') -Force -ErrorAction Stop
        $harness = Find-QvwDeepSeekHarness -ExplicitRoot $HarnessRoot
        $harnessResult = Invoke-QvwHarnessLiveVerify -Harness $harness -ImagePath $ImagePath -ConfirmPaidCalls
    }
    $result = New-QvwVerifyCompositeResult -HermesResult $hermesResult -HarnessResult $harnessResult
    Write-QvwResult -Result $result -AsJson
    if ($result.status -eq 'target-accepted') { exit 0 }
    if ($result.status -eq 'degraded') { exit 5 }
    if ($result.status -eq 'unverified') { exit 3 }
    if ($result.status -eq 'failed') { exit 4 }
    exit 2
}
catch {
    $result = New-QvwResult -Component 'hermes' -Status 'failed' -Code 'QVW-H-VERIFY-SCRIPT-FAILED' -Message 'Hermes verification wrapper failed before acceptance.' -Evidence @{}
    Write-QvwResult -Result $result -AsJson
    exit 1
}
finally {
    if ($null -ne $fixtureRoot -and (Test-Path -LiteralPath $fixtureRoot -PathType Container)) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
}
