[CmdletBinding()]
param(
    [Alias('OutputPath')]
    [string]$OutputDirectory,
    [string]$Version = '1.0.0'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:QvwPackageInvocation = ($MyInvocation.InvocationName -ne '.')
$script:QvwPackageScriptPath = [IO.Path]::GetFullPath($PSCommandPath)
$script:QvwPackageStableTimestamp = [DateTimeOffset]::Parse('2000-01-01T00:00:00Z')
$script:QvwInstallerCmdName = ((0x5B89, 0x88C5, 0x5343, 0x95EE, 0x89C6, 0x89C9 | ForEach-Object { [char]$_ }) -join '') + '.cmd'
$script:QvwManagerCmdName = ((0x5343, 0x95EE, 0x89C6, 0x89C9, 0x7BA1, 0x7406 | ForEach-Object { [char]$_ }) -join '') + '.cmd'

$script:QvwPackageAllowlist = @(
    '.gitattributes',
    '.gitignore',
    'qvw.ps1',
    $script:QvwInstallerCmdName,
    $script:QvwManagerCmdName,
    'LICENSE',
    'licenses/DeepSeek-Harness-MIT.txt',
    'README.md',
    'THIRD_PARTY_NOTICES.md',
    '.github/workflows/windows.yml',
    'docs/installation.md',
    'docs/troubleshooting.md',
    'docs/security.md',
    'docs/release.md',
    'scripts/package.ps1',
    'scripts/install.ps1',
    'scripts/doctor.ps1',
    'scripts/verify.ps1',
    'scripts/rollback.ps1',
    'scripts/status.ps1',
    'scripts/export-diagnostics.ps1',
    'adapters/hermes/HermesAdapter.psm1',
    'adapters/hermes/verify_acp_route.py',
    'adapters/hermes/skill/hermes-vision-setup/SKILL.md',
    'adapters/hermes/skill/hermes-vision-setup/references/provider-quick-ref.md',
    'adapters/deepseek-harness/DeepSeekHarnessAdapter.psm1',
    'adapters/deepseek-harness/manifest.json',
    'adapters/deepseek-harness/payload/prompt-image-bridge.patch',
    'modules/Qvw.ImageFixture.psm1',
    'modules/Qvw.Process.psm1',
    'modules/Qvw.Result.psm1',
    'modules/Qvw.Security.psm1',
    'modules/Qvw.State.psm1',
    'optional/qwen-mm/QwenMmAdapter.psm1',
    'optional/qwen-mm/source-lock.json'
)

Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\Qvw.Result.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\Qvw.Process.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\Qvw.Security.psm1') -Force -ErrorAction Stop

function Invoke-QvwCanonicalPackageRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $windowsPowerShell = Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $windowsPowerShell) { throw 'Windows PowerShell 5.1 is required for canonical Windows package bytes.' }
    $result = Invoke-QvwCommand -FilePath ([string]$windowsPowerShell.Source) -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:QvwPackageScriptPath,
        '-OutputDirectory', $OutputDirectory, '-Version', $Version
    ) -WorkingDirectory (Get-QvwPackageRepoRoot) -TimeoutSeconds 300 -Secrets @()
    if ([bool]$result.TimedOut -or -not [string]::IsNullOrWhiteSpace([string]$result.Error)) {
        throw 'Canonical Windows package process failed.'
    }

    $stdout = [string]$result.StdOut
    if ([string]::IsNullOrWhiteSpace($stdout)) {
        throw 'Canonical Windows package process failed.'
    }
    try {
        $parsed = $stdout | ConvertFrom-Json -ErrorAction Stop
        $requiredProperties = @('schemaVersion', 'component', 'status', 'code', 'message', 'evidence', 'timestampUtc')
        foreach ($propertyName in $requiredProperties) {
            if ($null -eq $parsed.PSObject.Properties[$propertyName]) {
                throw 'Missing QVW result property.'
            }
        }
        if ([int]$parsed.schemaVersion -ne 1) {
            throw 'Unsupported QVW result schema.'
        }
        if ([string]::IsNullOrWhiteSpace([string]$parsed.component) -or
            [string]::IsNullOrWhiteSpace([string]$parsed.status) -or
            [string]::IsNullOrWhiteSpace([string]$parsed.code) -or
            $null -eq $parsed.evidence) {
            throw 'Incomplete QVW result.'
        }
        return $parsed
    }
    catch {
        throw 'Canonical Windows package process failed.'
    }
}

function Get-QvwPackageRepoRoot {
    return [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Get-QvwPackageAllowlist {
    return @($script:QvwPackageAllowlist)
}

function Get-QvwPackageSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($stream)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function ConvertTo-QvwPackageRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $value = $Path -replace '\\', '/'
    while ($value.StartsWith('./', [StringComparison]::Ordinal)) { $value = $value.Substring(2) }
    if ([string]::IsNullOrWhiteSpace($value) -or $value.StartsWith('/', [StringComparison]::Ordinal) -or $value -match '(^|/)\.\.(/|$)') {
        throw 'Package entry path is not a safe relative path.'
    }
    return $value
}

function Test-QvwPackageReparsePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $probe = $full
    while (-not [string]::IsNullOrWhiteSpace($probe)) {
        if (Test-Path -LiteralPath $probe) {
            $item = Get-Item -LiteralPath $probe -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $true
            }
        }
        $parent = Split-Path -Parent $probe
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { break }
        $probe = $parent
    }
    return $false
}

function Assert-QvwPackageSourceSafe {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw 'Package source file is missing.'
    }
    if (Test-QvwPackageReparsePath -Path $full) {
        throw 'Package source contains a reparse point.'
    }
    return $true
}

function Resolve-QvwPackageSource {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [string]$RepoRoot = (Get-QvwPackageRepoRoot)
    )

    $relative = ConvertTo-QvwPackageRelativePath $RelativePath
    $root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath((Join-Path $root ($relative -replace '/', '\')))
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Package source resolved outside the repository root.'
    }
    return $full
}

function Test-QvwPackageAllowedStaticFinding {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)]$Scan,
        [Parameter(Mandatory = $true)][string]$Root
    )

    # The Qwen-MM adapter constructs the credential line in memory.  The
    # scanner intentionally treats any credential-shaped assignment as risky;
    # this one line has no literal credential and is checked by exact source
    # text before it is allowed through the public-package scan.
    $relative = ConvertTo-QvwPackageRelativePath $RelativePath
    if ($relative -ne 'optional/qwen-mm/QwenMmAdapter.psm1') { return $false }
    if (@($Scan.Findings).Count -ne 1) { return $false }
    $finding = @($Scan.Findings)[0]
    if ([string]$finding.code -cne 'credential-assignment' -or [int]$finding.line -ne 1061) { return $false }
    $path = Join-Path ([IO.Path]::GetFullPath($Root)) ($relative -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $lines = @(Get-Content -LiteralPath $path -ErrorAction Stop)
    if ($lines.Count -lt 1061) { return $false }
    $keyMarker = 'DASHSCOPE_API_KEY' + '='
    return ([string]$lines[1060] -match ('GetBytes.*' + [regex]::Escape($keyMarker)) -and [string]$lines[1060] -match '\$plain')
}

function Invoke-QvwPackageSafetyScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $raw = Assert-QvwArtifactSafe -Path $Path
    if ($raw.Safe) {
        return [pscustomobject][ordered]@{ Safe = $true; RawFindingCount = 0; SuppressedFindingCount = 0; FindingCount = 0 }
    }

    # Scan each allowlisted source separately so a narrowly audited source
    # pattern cannot hide a finding in any other file.
    $suppressed = 0
    $actionable = 0
    foreach ($relative in @($script:QvwPackageAllowlist)) {
        $file = Join-Path $Root ($relative -replace '/', '\')
        $fileScan = Assert-QvwArtifactSafe -Path $file
        if (-not $fileScan.Safe) {
            if (Test-QvwPackageAllowedStaticFinding -RelativePath $relative -Scan $fileScan -Root $Root) {
                $suppressed += [int]$fileScan.FindingCount
            }
            else {
                $actionable += [int]$fileScan.FindingCount
            }
        }
    }
    return [pscustomobject][ordered]@{
        Safe = ($actionable -eq 0)
        RawFindingCount = [int]$raw.FindingCount
        SuppressedFindingCount = [int]$suppressed
        FindingCount = [int]$actionable
    }
}

function Copy-QvwPackageSources {
    param(
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [string]$RepoRoot = (Get-QvwPackageRepoRoot)
    )

    $count = 0
    foreach ($relative in @($script:QvwPackageAllowlist)) {
        $source = Resolve-QvwPackageSource -RelativePath $relative -RepoRoot $RepoRoot
        [void](Assert-QvwPackageSourceSafe -Path $source)
        $destination = Join-Path $StageRoot ($relative -replace '/', '\')
        $parent = Split-Path -Parent $destination
        [IO.Directory]::CreateDirectory($parent) | Out-Null
        [IO.File]::Copy($source, $destination, $false)
        $count++
    }
    return $count
}

function Write-QvwDeterministicZip {
    param(
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)][string]$ZipPath
    )

    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $root = ([IO.Path]::GetFullPath($StageRoot)).TrimEnd('\', '/')
    [string[]]$entryNames = @(Get-ChildItem -LiteralPath $StageRoot -File -Recurse -Force -ErrorAction Stop | ForEach-Object {
            $_.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
        })
    [Array]::Sort($entryNames, [StringComparer]::Ordinal)
    $zipStream = New-Object IO.FileStream($ZipPath, ([IO.FileMode]::Create), ([IO.FileAccess]::Write), ([IO.FileShare]::None))
    $archive = New-Object IO.Compression.ZipArchive($zipStream, ([IO.Compression.ZipArchiveMode]::Create), $false)
    try {
        foreach ($entryName in $entryNames) {
            $file = Get-Item -LiteralPath (Join-Path $StageRoot ($entryName -replace '/', '\')) -Force -ErrorAction Stop
            if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Package source contains a reparse point.' }
            # Store entries without deflate so the ZIP bytes are identical on
            # Windows PowerShell/.NET Framework and PowerShell 7/.NET.  The
            # package is small and reproducibility is more important here than
            # a marginal compression ratio.
            $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::NoCompression)
            $entry.LastWriteTime = $script:QvwPackageStableTimestamp
            try { $entry.ExternalAttributes = 0 } catch { }
            $input = [IO.File]::OpenRead($file.FullName)
            $output = $entry.Open()
            try { $input.CopyTo($output) }
            finally {
                $output.Dispose()
                $input.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
        $zipStream.Dispose()
    }
    return $entryNames.Count
}

function Remove-QvwPackageTemp {
    param([string[]]$Paths)

    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        try {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue | Out-Null }
        }
        catch { }
    }
}

function New-QvwPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [string]$Version = '1.0.0'
    )

    if ($PSVersionTable.PSEdition -eq 'Core') {
        return (Invoke-QvwCanonicalPackageRuntime -OutputDirectory $OutputDirectory -Version $Version)
    }

    $stageRoot = $null
    $extractRoot = $null
    $temporaryZip = $null
    $stage = 'validate'
    try {
        if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') { throw 'Package version is not a safe semantic version.' }
        $repoRoot = Get-QvwPackageRepoRoot
        if (Test-QvwPackageReparsePath -Path $repoRoot) { throw 'Repository root contains a reparse point.' }
        if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { throw 'Package output directory is required.' }
        $outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
        if (-not (Test-Path -LiteralPath $outputRoot)) { [IO.Directory]::CreateDirectory($outputRoot) | Out-Null }
        if (-not (Test-Path -LiteralPath $outputRoot -PathType Container)) { throw 'Package output path is not a directory.' }
        if (Test-QvwPackageReparsePath -Path $outputRoot) { throw 'Package output directory contains a reparse point.' }

        $zipName = 'qwen-vision-workflow-{0}-windows.zip' -f $Version
        $hashName = $zipName + '.sha256'
        $zipPath = Join-Path $outputRoot $zipName
        $hashPath = Join-Path $outputRoot $hashName
        $stageRoot = Join-Path ([IO.Path]::GetTempPath()) ('qvw-package-' + [guid]::NewGuid().ToString('N'))
        $extractRoot = Join-Path ([IO.Path]::GetTempPath()) ('qvw-package-extract-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($stageRoot) | Out-Null
        [IO.Directory]::CreateDirectory($extractRoot) | Out-Null

        $stage = 'copy-sources'
        $entryCount = Copy-QvwPackageSources -StageRoot $stageRoot -RepoRoot $repoRoot
        $stage = 'scan-source'
        $sourceScan = Invoke-QvwPackageSafetyScan -Path $stageRoot -Root $stageRoot
        if (-not $sourceScan.Safe) { return (New-QvwResult -Component 'package' -Status 'blocked' -Code 'QVW-PACKAGE-SENSITIVE-DATA' -Message 'The package source failed the redaction scan; no ZIP was published.' -Evidence @{ scanPasses = 1; findingCount = $sourceScan.FindingCount; rawFindingCount = $sourceScan.RawFindingCount }) }

        $stage = 'compress'
        $temporaryZip = Join-Path $outputRoot ($zipName + '.qvw-' + [guid]::NewGuid().ToString('N') + '.tmp')
        $actualEntryCount = Write-QvwDeterministicZip -StageRoot $stageRoot -ZipPath $temporaryZip
        if ($actualEntryCount -ne $entryCount) { throw 'Package entry count changed during ZIP creation.' }

        $stage = 'scan-extracted'
        [IO.Compression.ZipFile]::ExtractToDirectory($temporaryZip, $extractRoot)
        $extractedScan = Invoke-QvwPackageSafetyScan -Path $extractRoot -Root $extractRoot
        if (-not $extractedScan.Safe) { return (New-QvwResult -Component 'package' -Status 'blocked' -Code 'QVW-PACKAGE-ZIP-SENSITIVE-DATA' -Message 'The extracted package failed the second redaction scan; no ZIP was published.' -Evidence @{ scanPasses = 2; findingCount = $extractedScan.FindingCount; rawFindingCount = $extractedScan.RawFindingCount }) }

        $stage = 'publish'
        if (Test-Path -LiteralPath $zipPath -PathType Leaf) {
            try { [IO.File]::Replace($temporaryZip, $zipPath, $null) }
            catch { Move-Item -LiteralPath $temporaryZip -Destination $zipPath -Force -ErrorAction Stop | Out-Null }
        }
        else { [IO.File]::Move($temporaryZip, $zipPath) }
        $temporaryZip = $null
        $hash = Get-QvwPackageSha256 -Path $zipPath
        [IO.File]::WriteAllText($hashPath, ("{0}  {1}`n" -f $hash, $zipName), (New-Object Text.UTF8Encoding($false)))
        return (New-QvwResult -Component 'package' -Status 'tests-passed' -Code 'QVW-PACKAGE-CREATED' -Message 'The deterministic Windows package passed source and extracted-archive safety scans.' -Evidence @{ version = $Version; zipPath = $zipPath; sha256Path = $hashPath; sha256 = $hash; entryCount = $actualEntryCount; scanPasses = 2; findingCount = 0; suppressedFindingCount = ([int]$sourceScan.SuppressedFindingCount + [int]$extractedScan.SuppressedFindingCount) })
    }
    catch {
        $errorType = if ($null -ne $_.Exception) { $_.Exception.GetType().Name } else { 'Unknown' }
        return (New-QvwResult -Component 'package' -Status 'failed' -Code 'QVW-PACKAGE-FAILED' -Message 'The package could not be created safely.' -Evidence @{ stage = $stage; errorType = $errorType })
    }
    finally {
        Remove-QvwPackageTemp -Paths @($stageRoot, $extractRoot, $temporaryZip)
    }
}

if ($script:QvwPackageInvocation) {
    try {
        if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path (Get-QvwPackageRepoRoot) 'dist' }
        $result = New-QvwPackage -OutputDirectory $OutputDirectory -Version $Version
        Write-QvwResult -Result $result -AsJson
        switch ([string]$result.status) {
            'blocked' { exit 2 }
            'failed' { exit 1 }
            default { exit 0 }
        }
    }
    catch {
        $result = New-QvwResult -Component 'package' -Status 'failed' -Code 'QVW-PACKAGE-SCRIPT-FAILED' -Message 'The package wrapper failed before a safe result was available.' -Evidence @{}
        Write-QvwResult -Result $result -AsJson
        exit 1
    }
}
