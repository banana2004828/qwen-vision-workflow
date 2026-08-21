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

function Get-QvwDoctorExitCode {
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
    $harness = [ordered]@{ requested = (-not [string]::IsNullOrWhiteSpace($HarnessRoot)); available = $false; status = 'not-requested'; compatibility = 'not-requested' }
    if (-not [string]::IsNullOrWhiteSpace($HarnessRoot)) {
        Import-Module (Join-Path $scriptRoot 'adapters\deepseek-harness\DeepSeekHarnessAdapter.psm1') -Force -ErrorAction Stop
        $foundHarness = Find-QvwDeepSeekHarness -ExplicitRoot $HarnessRoot
        $harness.available = [bool]$foundHarness.Available
        if ($foundHarness.Available) {
            $compatibility = Get-QvwHarnessCompatibility -Harness $foundHarness
            $harness.compatibility = [string]$compatibility.State
            $harness.status = if ([string]$compatibility.State -in @('installed-matching', 'missing-matching')) { 'compatible' } else { 'blocked' }
            $harness.commit = [string]$compatibility.Commit
            $harness.dirtyPathCount = @($compatibility.DirtyPaths).Count
            $harness.mismatchCount = @($compatibility.Mismatches).Count
            $harness.requiredMountsSatisfied = (@($compatibility.RequiredMounts | Where-Object { $_.RequiredForLive -and -not $_.Satisfied }).Count -eq 0)
        }
        else {
            $harness.status = 'blocked'
            $harness.compatibility = 'not-found'
        }
    }
    $evidence = @{
        hermes = $doctor.evidence
        harness = $harness
        readOnly = $true
    }
    $status = [string]$doctor.status
    $code = [string]$doctor.code
    $message = [string]$doctor.message
    if ($harness.requested -and $harness.status -eq 'blocked' -and $status -in @('discovered', 'tests-passed')) {
        $status = 'degraded'
        $code = 'QVW-DOCTOR-HARNESS-BLOCKED'
        $message = 'Hermes is compatible, but the requested DeepSeek Harness checkout is not safe for automatic bridge installation.'
    }
    $result = New-QvwResult -Component 'qvw-doctor' -Status $status -Code $code -Message $message -Evidence $evidence
    Write-QvwResult -Result $result -AsJson
    exit (Get-QvwDoctorExitCode -Status $status)
}
catch {
    $result = New-QvwResult -Component 'qvw-doctor' -Status 'blocked' -Code 'QVW-DOCTOR-SCRIPT-FAILED' -Message 'Read-only diagnostics could not determine the active client state.' -Evidence @{ readOnly = $true }
    Write-QvwResult -Result $result -AsJson
    exit 2
}
