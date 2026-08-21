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

function Get-QvwReceiptMetadata {
    param([string]$Root)
    $items = New-Object System.Collections.ArrayList
    $backupRoot = Join-Path $Root 'backups\qwen-vision-workflow'
    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) { return @() }
    foreach ($file in @(Get-ChildItem -LiteralPath $backupRoot -Filter 'receipt.json' -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        try {
            $receipt = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            [void]$items.Add([pscustomobject][ordered]@{
                receiptId = [string]$receipt.receiptId
                state = [string]$receipt.state
                operation = [string]$receipt.operation
                createdUtc = [string]$receipt.createdUtc
                updatedUtc = [string]$receipt.updatedUtc
                entryCount = @($receipt.entries).Count
            })
        }
        catch { }
    }
    return @($items | Sort-Object updatedUtc -Descending)
}

try {
    $hermes = Find-QvwHermes -ExplicitRoot $HermesRoot
    $doctor = Test-QvwHermesDoctor -Hermes $hermes
    $root = [string]$hermes.Home
    $receipts = if (-not [string]::IsNullOrWhiteSpace($root)) { Get-QvwReceiptMetadata -Root $root } else { @() }
    $result = New-QvwResult -Component 'qvw-status' -Status ([string]$doctor.status) -Code ([string]$doctor.code) -Message 'Current QVW status was read without modifying client files.' -Evidence @{
        hermesStatus = [string]$doctor.status
        receiptCount = @($receipts).Count
        receipts = $receipts
        readOnly = $true
    }
    Write-QvwResult -Result $result -AsJson
    if ([string]$result.status -eq 'blocked') { exit 2 }
    exit 0
}
catch {
    $result = New-QvwResult -Component 'qvw-status' -Status 'blocked' -Code 'QVW-STATUS-FAILED' -Message 'Current QVW status could not be read safely.' -Evidence @{ readOnly = $true }
    Write-QvwResult -Result $result -AsJson
    exit 2
}
