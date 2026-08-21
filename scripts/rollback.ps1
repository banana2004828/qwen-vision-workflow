[CmdletBinding()]
param(
    [string]$HermesRoot,
    [string]$Receipt,
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
Import-Module (Join-Path $scriptRoot 'optional\qwen-mm\QwenMmAdapter.psm1') -Force -ErrorAction Stop

function Get-QvwRollbackExitCode {
    param([string]$Status)
    switch ($Status) {
        'blocked' { return 2 }
        'failed' { return 4 }
        'degraded' { return 5 }
        default { return 0 }
    }
}

function Get-QvwReceiptFiles {
    param([string]$Root)
    $backupRoot = Join-Path $Root 'backups\qwen-vision-workflow'
    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $backupRoot -Filter 'receipt.json' -File -Recurse -Force -ErrorAction SilentlyContinue)
}

function Get-QvwReceiptMeta {
    param([System.IO.FileInfo]$File)
    try {
        $receipt = [IO.File]::ReadAllText($File.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        return [pscustomobject][ordered]@{
            receiptId = [string]$receipt.receiptId
            state = [string]$receipt.state
            operation = [string]$receipt.operation
            createdUtc = [string]$receipt.createdUtc
            updatedUtc = [string]$receipt.updatedUtc
            entryCount = @($receipt.entries).Count
            file = $File
        }
    }
    catch { return $null }
}

try {
    $hermes = Find-QvwHermes -ExplicitRoot $HermesRoot
    $root = [string]$hermes.Home
    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) {
        $result = New-QvwResult -Component 'rollback' -Status 'blocked' -Code 'QVW-ROLLBACK-HERMES-REQUIRED' -Message 'An active Hermes root is required to list or roll back receipts.' -Evidence @{}
        Write-QvwResult -Result $result -AsJson
        exit 2
    }
    $files = @(Get-QvwReceiptFiles -Root $root)
    $metadata = @($files | ForEach-Object { Get-QvwReceiptMeta -File $_ } | Where-Object { $null -ne $_ } | Sort-Object updatedUtc -Descending)
    if ([string]::IsNullOrWhiteSpace($Receipt)) {
        $safeList = @($metadata | ForEach-Object {
            [pscustomobject][ordered]@{
                receiptId = $_.receiptId
                state = $_.state
                operation = $_.operation
                createdUtc = $_.createdUtc
                updatedUtc = $_.updatedUtc
                entryCount = $_.entryCount
            }
        })
        $result = New-QvwResult -Component 'rollback' -Status 'discovered' -Code 'QVW-ROLLBACK-RECEIPTS-LISTED' -Message 'Receipt metadata was listed; no rollback was started.' -Evidence @{ receiptCount = @($safeList).Count; receipts = $safeList; readOnly = $true }
        Write-QvwResult -Result $result -AsJson
        exit 0
    }

    $candidate = $null
    if ([IO.Path]::IsPathRooted($Receipt)) {
        try { $candidate = (Resolve-Path -LiteralPath $Receipt -ErrorAction Stop).Path } catch { $candidate = $null }
    }
    else {
        $match = @($metadata | Where-Object { [string]$_.receiptId -eq $Receipt })
        if ($match.Count -eq 1) { $candidate = [string]$match[0].file.FullName }
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $result = New-QvwResult -Component 'rollback' -Status 'blocked' -Code 'QVW-ROLLBACK-RECEIPT-NOT-FOUND' -Message 'The requested receipt id was not found under the active Hermes root.' -Evidence @{}
        Write-QvwResult -Result $result -AsJson
        exit 2
    }
    $rootFull = ([IO.Path]::GetFullPath($root)).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $candidateFull = [IO.Path]::GetFullPath($candidate)
    if (-not $candidateFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        $result = New-QvwResult -Component 'rollback' -Status 'blocked' -Code 'QVW-ROLLBACK-PATH-INVALID' -Message 'The receipt path is outside the active Hermes root.' -Evidence @{}
        Write-QvwResult -Result $result -AsJson
        exit 2
    }
    $before = Get-QvwReceiptMeta -File (Get-Item -LiteralPath $candidateFull -Force -ErrorAction Stop)
    if ($null -eq $before) { throw 'Receipt metadata is invalid.' }
    if ([string]$before.operation -eq 'install-qwen-mm-api') {
        $qwenMmRollback = Uninstall-QvwQwenMm -Hermes $hermes -ReceiptPath $candidateFull
        if ([string]$qwenMmRollback.status -eq 'failed' -or [string]$qwenMmRollback.evidence.rollback -ne 'verified') {
            throw 'Qwen-MM receipt rollback or directory cleanup was not verified.'
        }
        $result = New-QvwResult -Component 'rollback' -Status 'tests-passed' -Code 'QVW-ROLLBACK-QWEN-MM-VERIFIED' -Message 'The Qwen-MM receipt and its receipt-backed directory cleanup were verified.' -Evidence @{ receiptId = [string]$before.receiptId; state = 'rolled-back'; rollback = 'verified'; cleanup = $qwenMmRollback.evidence.cleanup }
    }
    elseif ([string]$before.state -eq 'rolled-back') {
        $result = New-QvwResult -Component 'rollback' -Status 'tests-passed' -Code 'QVW-ROLLBACK-ALREADY-ROLLED-BACK' -Message 'The requested receipt is already rolled back.' -Evidence @{ receiptId = [string]$before.receiptId; state = 'rolled-back'; rollback = 'verified' }
    }
    else {
        $undo = Undo-QvwTransaction -ReceiptPath $candidateFull
        $after = Get-QvwReceiptMeta -File (Get-Item -LiteralPath $candidateFull -Force -ErrorAction Stop)
        if ($null -eq $after -or [string]$after.state -ne 'rolled-back') { throw 'Receipt rollback state was not verified.' }
        $result = New-QvwResult -Component 'rollback' -Status 'tests-passed' -Code 'QVW-ROLLBACK-VERIFIED' -Message 'The requested receipt was rolled back and its state was verified.' -Evidence @{ receiptId = [string]$after.receiptId; state = [string]$after.state; rollback = 'verified' }
    }
    Write-QvwResult -Result $result -AsJson
    exit (Get-QvwRollbackExitCode -Status ([string]$result.status))
}
catch {
    $result = New-QvwResult -Component 'rollback' -Status 'failed' -Code 'QVW-ROLLBACK-FAILED' -Message 'The requested receipt could not be rolled back or verified safely.' -Evidence @{ rollback = 'manual-recovery-required' }
    Write-QvwResult -Result $result -AsJson
    exit 4
}
