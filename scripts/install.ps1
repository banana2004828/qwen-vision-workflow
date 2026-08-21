[CmdletBinding()]
param(
    [string]$HermesRoot,
    [string]$HarnessRoot,
    [switch]$Json,
    [switch]$NonInteractive
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $PSScriptRoot

Import-Module (Join-Path $scriptRoot 'modules\Qvw.Result.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $scriptRoot 'modules\Qvw.Process.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $scriptRoot 'modules\Qvw.Security.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $scriptRoot 'modules\Qvw.State.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $scriptRoot 'adapters\hermes\HermesAdapter.psm1') -Force -ErrorAction Stop

function New-QvwInstallCompositeResult {
    param($HermesResult, $HarnessResult)

    if ($null -eq $HarnessResult) { return $HermesResult }
    $hermesOk = [string]$HermesResult.status -eq 'installed'
    $harnessOk = [string]$HarnessResult.status -eq 'installed'
    if ($hermesOk -and $harnessOk) {
        return (New-QvwResult -Component 'qwen-vision-workflow' -Status 'installed' -Code 'QVW-INSTALL-COMPLETE' -Message 'Hermes vision and the compatible DeepSeek Harness bridge were installed and verified.' -Evidence @{ hermes = $HermesResult; deepseekHarness = $HarnessResult })
    }
    if ($hermesOk) {
        return (New-QvwResult -Component 'qwen-vision-workflow' -Status 'degraded' -Code 'QVW-INSTALL-HARNESS-BLOCKED' -Message 'Hermes vision was installed, but the requested DeepSeek Harness bridge was not changed because its compatibility gate did not pass.' -Evidence @{ hermes = $HermesResult; deepseekHarness = $HarnessResult })
    }
    return $HermesResult
}

function Get-QvwInstallExitCode {
    param([string]$Status)
    switch ($Status) {
        'blocked' { return 2 }
        'unverified' { return 3 }
        'failed' { return 4 }
        'degraded' { return 5 }
        default { return 0 }
    }
}

try {
    $hermes = Find-QvwHermes -ExplicitRoot $HermesRoot
    $doctor = Test-QvwHermesDoctor -Hermes $hermes
    if ([string]$doctor.status -notin @('discovered', 'tests-passed')) {
        $result = New-QvwResult -Component 'hermes' -Status 'blocked' -Code 'QVW-H-INSTALL-PREFLIGHT-BLOCKED' -Message 'Hermes compatibility was not accepted; no installation transaction was started.' -Evidence @{}
    }
    else {
        $credential = Get-QvwDashScopeCredential -Hermes $hermes -HarnessRoot $HarnessRoot -AllowPrompt:(-not $NonInteractive)
        if ($null -eq $credential -or $null -eq $credential.SecureValue) {
            $result = New-QvwResult -Component 'hermes' -Status 'blocked' -Code 'QVW-H-CRED-REQUIRED' -Message 'A DashScope credential was not available; no installation transaction was started.' -Evidence @{}
        }
        else {
            $hermesResult = Install-QvwHermesVision -Hermes $hermes -DashScopeKey $credential.SecureValue -BaseUrl 'https://dashscope.aliyuncs.com/compatible-mode/v1'
            $harnessResult = $null
            if ([string]$hermesResult.status -eq 'installed' -and -not [string]::IsNullOrWhiteSpace($HarnessRoot)) {
                Import-Module (Join-Path $scriptRoot 'adapters\deepseek-harness\DeepSeekHarnessAdapter.psm1') -Force -ErrorAction Stop
                $harness = Find-QvwDeepSeekHarness -ExplicitRoot $HarnessRoot
                $harnessResult = Install-QvwHarnessBridge -Harness $harness
            }
            $result = New-QvwInstallCompositeResult -HermesResult $hermesResult -HarnessResult $harnessResult
        }
    }
    Write-QvwResult -Result $result -AsJson
    exit (Get-QvwInstallExitCode -Status ([string]$result.status))
}
catch {
    $result = New-QvwResult -Component 'hermes' -Status 'failed' -Code 'QVW-H-INSTALL-SCRIPT-FAILED' -Message 'Hermes installation wrapper failed before a safe result was available.' -Evidence @{}
    Write-QvwResult -Result $result -AsJson
    exit 1
}
