[CmdletBinding()]
param(
    [string]$HermesRoot,
    [string]$HarnessRoot,
    [Parameter(Mandatory = $false)][string]$OutputPath,
    [string]$AdditionalText,
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

$script:QvwDiagnosticsInvocation = ($MyInvocation.InvocationName -ne '.')

function Get-QvwDiagnosticsHash {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() } catch { return $null }
}

function Test-QvwEnvKeyPresent {
    param([string]$Path, [string]$Name)
    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        try {
            foreach ($line in [IO.File]::ReadAllLines($Path)) {
                if ($line -match ('^\s*' + [regex]::Escape($Name) + '\s*=')) { return $true }
            }
        }
        catch { }
    }
    foreach ($scope in @('Process', 'Machine', 'User')) {
        if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Name, $scope))) { return $true }
    }
    return $false
}

function Test-QvwHermesConfigKeyPresent {
    param($Hermes, [string]$Key)
    if ($null -eq $Hermes) { return $false }
    $cliPath = [string]$Hermes.CliPath
    $activeRoot = [string]$Hermes.Home
    if ([string]::IsNullOrWhiteSpace($cliPath) -or [string]::IsNullOrWhiteSpace($activeRoot) -or
        -not (Test-Path -LiteralPath $cliPath -PathType Leaf)) { return $false }
    try {
        $probe = Invoke-QvwCommand -FilePath $cliPath -ArgumentList @('config', 'get', $Key) -WorkingDirectory $activeRoot -TimeoutSeconds 30 -Secrets @()
        $value = [string]$probe.StdOut
        $present = [bool]$probe.Succeeded -and -not [string]::IsNullOrWhiteSpace($value) -and $value.Trim() -notmatch '^(?i)null|~|not\s+set$'
        $value = $null
        return $present
    }
    catch { return $false }
}

function Get-QvwDiagnosticsReceiptMetadata {
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

function New-QvwDiagnosticsPayload {
    param(
        [string]$HermesRoot,
        [string]$HarnessRoot,
        [AllowNull()][string]$ExtraText
    )

    $errors = New-Object System.Collections.ArrayList
    $hermes = $null
    try { $hermes = Find-QvwHermes -ExplicitRoot $HermesRoot } catch { [void]$errors.Add('QVW-HERMES-DISCOVERY-FAILED') }
    $activeRoot = if ($null -ne $hermes) { [string]$hermes.Home } else { $null }
    $config = if ($null -ne $hermes) { [string]$hermes.ConfigPath } else { $null }
    $envPath = if ($null -ne $hermes) { [string]$hermes.EnvPath } else { $null }
    if ($null -eq $hermes -or [string]::IsNullOrWhiteSpace($activeRoot)) { [void]$errors.Add('QVW-HERMES-NOT-FOUND') }
    $payload = [ordered]@{
        schemaVersion = 1
        workflowVersion = '1.0.0'
        generatedUtc = [DateTime]::UtcNow.ToString('o')
        client = [ordered]@{
            hermesAvailable = ($null -ne $hermes -and -not [string]::IsNullOrWhiteSpace($activeRoot))
            hermesVersion = if ($null -ne $hermes) { [string]$hermes.Version } else { $null }
            configPresent = (-not [string]::IsNullOrWhiteSpace($config) -and (Test-Path -LiteralPath $config -PathType Leaf))
            environmentPresent = (-not [string]::IsNullOrWhiteSpace($envPath) -and (Test-Path -LiteralPath $envPath -PathType Leaf))
            harnessRequested = (-not [string]::IsNullOrWhiteSpace($HarnessRoot))
        }
        credentials = [ordered]@{
            dashscopeApiKey = Test-QvwEnvKeyPresent -Path $envPath -Name 'DASHSCOPE_API_KEY'
            dashscopeBaseUrl = Test-QvwEnvKeyPresent -Path $envPath -Name 'DASHSCOPE_BASE_URL'
        }
        controlledKeys = [ordered]@{
            imageInputMode = Test-QvwHermesConfigKeyPresent -Hermes $hermes -Key 'agent.image_input_mode'
            visionProvider = Test-QvwHermesConfigKeyPresent -Hermes $hermes -Key 'auxiliary.vision.provider'
            visionModel = Test-QvwHermesConfigKeyPresent -Hermes $hermes -Key 'auxiliary.vision.model'
        }
        hashes = [ordered]@{
            configSha256 = Get-QvwDiagnosticsHash -Path $config
            environmentSha256 = Get-QvwDiagnosticsHash -Path $envPath
        }
        receipts = if ($null -ne $hermes -and -not [string]::IsNullOrWhiteSpace($activeRoot)) { Get-QvwDiagnosticsReceiptMetadata -Root $activeRoot } else { @() }
        errors = @($errors)
    }
    return $payload
}

function Remove-QvwDiagnosticsTemp {
    param([string[]]$Paths)
    foreach ($path in @($Paths)) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

function Export-QvwDiagnostics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [AllowNull()][string]$AdditionalText,
        [string]$HermesRoot,
        [string]$HarnessRoot
    )

    $stageRoot = $null
    $extractRoot = $null
    $tempZip = $null
    $finalPath = $null
    $stage = 'validate-output'
    try {
        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            return (New-QvwResult -Component 'diagnostics' -Status 'blocked' -Code 'QVW-DIAG-OUTPUT-REQUIRED' -Message 'A diagnostic ZIP output path is required.' -Evidence @{})
        }
        $finalPath = [IO.Path]::GetFullPath($OutputPath)
        $parent = Split-Path -Parent $finalPath
        if ([string]::IsNullOrWhiteSpace($parent)) { throw 'Diagnostic output parent is unavailable.' }
        [IO.Directory]::CreateDirectory($parent) | Out-Null

        $stage = 'create-stage'
        $stageRoot = Join-Path ([IO.Path]::GetTempPath()) ('qvw-diagnostics-' + [guid]::NewGuid().ToString('N'))
        $payloadRoot = Join-Path $stageRoot 'diagnostics'
        $extractRoot = Join-Path ([IO.Path]::GetTempPath()) ('qvw-diagnostics-extract-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($payloadRoot) | Out-Null
        $payload = New-QvwDiagnosticsPayload -HermesRoot $HermesRoot -HarnessRoot $HarnessRoot -ExtraText $AdditionalText
        $statusJson = $payload | ConvertTo-Json -Depth 12
        [IO.File]::WriteAllText((Join-Path $payloadRoot 'status.json'), $statusJson, (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $payloadRoot 'README.txt'), 'QVW diagnostics are redacted status metadata only.`r`n', (New-Object Text.UTF8Encoding($false)))
        if ($null -ne $AdditionalText) {
            # This parameter is intentionally a test seam. Production callers
            # omit it; the scan must still block an injected fixture secret.
            [IO.File]::WriteAllText((Join-Path $payloadRoot 'test-injection.txt'), [string]$AdditionalText, (New-Object Text.UTF8Encoding($false)))
        }

        $stage = 'scan-source'
        $firstScan = Assert-QvwArtifactSafe -Path $payloadRoot
        if (-not $firstScan.Safe) {
            return (New-QvwResult -Component 'diagnostics' -Status 'blocked' -Code 'QVW-DIAG-SENSITIVE-DATA' -Message 'Diagnostic source data failed the redaction scan; no ZIP was created.' -Evidence @{ scanPasses = 1; findingCount = [int]$firstScan.FindingCount })
        }

        $stage = 'compress'
        # Windows PowerShell's Compress-Archive requires a .zip destination;
        # keep the name temporary while retaining that extension.
        $tempZip = Join-Path $parent ((Split-Path -Leaf $finalPath) + '.qvw-' + [guid]::NewGuid().ToString('N') + '.tmp.zip')
        Compress-Archive -Path $payloadRoot -DestinationPath $tempZip -Force -ErrorAction Stop
        $stage = 'scan-extracted'
        [IO.Directory]::CreateDirectory($extractRoot) | Out-Null
        Expand-Archive -LiteralPath $tempZip -DestinationPath $extractRoot -Force -ErrorAction Stop
        $secondScan = Assert-QvwArtifactSafe -Path $extractRoot
        if (-not $secondScan.Safe) {
            return (New-QvwResult -Component 'diagnostics' -Status 'blocked' -Code 'QVW-DIAG-ZIP-SENSITIVE-DATA' -Message 'The extracted diagnostic ZIP failed the second redaction scan; no ZIP was published.' -Evidence @{ scanPasses = 2; findingCount = [int]$secondScan.FindingCount })
        }

        $stage = 'atomic-move'
        if (Test-Path -LiteralPath $finalPath -PathType Leaf) {
            try { [IO.File]::Replace($tempZip, $finalPath, [string]$null) }
            catch { Move-Item -LiteralPath $tempZip -Destination $finalPath -Force -ErrorAction Stop | Out-Null }
        }
        else { [IO.File]::Move($tempZip, $finalPath) }
        $tempZip = $null
        $fileCount = @(Get-ChildItem -LiteralPath (Join-Path $extractRoot 'diagnostics') -File -Recurse -Force -ErrorAction SilentlyContinue).Count
        $hash = Get-QvwDiagnosticsHash -Path $finalPath
        return (New-QvwResult -Component 'diagnostics' -Status 'tests-passed' -Code 'QVW-DIAG-EXPORTED' -Message 'Redacted diagnostics were scanned before and after ZIP extraction and moved atomically.' -Evidence @{ outputPath = $finalPath; sha256 = $hash; scanPasses = 2; fileCount = $fileCount })
    }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($finalPath) -and (Test-Path -LiteralPath $finalPath -PathType Leaf) -and $null -eq $tempZip) {
            # Do not remove a pre-existing user file after a failed replacement.
        }
        return (New-QvwResult -Component 'diagnostics' -Status 'failed' -Code 'QVW-DIAG-EXPORT-FAILED' -Message 'Diagnostic export failed before a safe archive could be published.' -Evidence @{ stage = $stage })
    }
    finally {
        Remove-QvwDiagnosticsTemp -Paths @($stageRoot, $extractRoot, $tempZip)
    }
}

if ($script:QvwDiagnosticsInvocation) {
    try {
        $path = $OutputPath
        if ([string]::IsNullOrWhiteSpace($path)) {
            $path = Join-Path (Get-Location).Path 'qwen-vision-diagnostics.zip'
        }
        $result = Export-QvwDiagnostics -OutputPath $path -AdditionalText $null -HermesRoot $HermesRoot -HarnessRoot $HarnessRoot
        Write-QvwResult -Result $result -AsJson
        if ([string]$result.status -eq 'blocked') { exit 2 }
        if ([string]$result.status -eq 'failed') { exit 4 }
        exit 0
    }
    catch {
        $result = New-QvwResult -Component 'diagnostics' -Status 'failed' -Code 'QVW-DIAG-SCRIPT-FAILED' -Message 'Diagnostic wrapper failed before a safe result was available.' -Evidence @{}
        Write-QvwResult -Result $result -AsJson
        exit 1
    }
}
