Set-StrictMode -Version 2.0

# DeepSeek Harness adapter.  This module deliberately keeps the Harness
# boundary small: it discovers one explicit checkout, verifies the exact
# manifest preimage/postimage, and applies one reviewed git patch under a
# transaction.  It never edits the real checkout during discovery or verify.

$script:QvwDeepSeekAdapterRoot = $PSScriptRoot
$script:QvwDeepSeekDefaultManifest = Join-Path $PSScriptRoot 'manifest.json'
$script:QvwDeepSeekDefaultPayload = Join-Path $PSScriptRoot 'payload\prompt-image-bridge.patch'
$script:QvwDeepSeekUpstreamCommit = '47f943859bef60e4160492346772ded9b24f765a'

foreach ($dependency in @(
        @{ Name = 'Qvw.Result.psm1'; Command = 'New-QvwResult' },
        @{ Name = 'Qvw.Process.psm1'; Command = 'Invoke-QvwCommand' },
        @{ Name = 'Qvw.State.psm1'; Command = 'Start-QvwTransaction' }
    )) {
    if (-not (Get-Command -Name $dependency.Command -ErrorAction SilentlyContinue)) {
        $dependencyPath = Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules') $dependency.Name
        if (Test-Path -LiteralPath $dependencyPath -PathType Leaf) {
            Import-Module -Name $dependencyPath -Force -ErrorAction Stop
        }
    }
}

function Get-QvwHarnessProperty {
    param(
        $Object,
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    if ($null -eq $property.Value) { return $Default }
    return $property.Value
}

function Test-QvwHarnessSafeRelativePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ([IO.Path]::IsPathRooted($Path)) { return $false }
    if ($Path -match '^[\\/]') { return $false }
    if ($Path -match '(?i)(^|[\\/])\.\.([\\/]|$)') { return $false }
    if ($Path -match ':') { return $false }
    return $true
}

function Test-QvwHarnessPathWithinRoot {
    param(
        [string]$Root,
        [string]$Path
    )

    try {
        $rootFull = ([IO.Path]::GetFullPath($Root)).TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
        $pathFull = [IO.Path]::GetFullPath($Path)
        return $pathFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Get-QvwHarnessFullPath {
    param(
        [string]$Root,
        [string]$RelativePath
    )

    if (-not (Test-QvwHarnessSafeRelativePath $RelativePath)) {
        throw 'Manifest contains an unsafe controlled path.'
    }
    $fullPath = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    if (-not (Test-QvwHarnessPathWithinRoot -Root $Root -Path $fullPath)) {
        throw 'Manifest controlled path escaped the Harness root.'
    }
    return $fullPath
}

function Get-QvwHarnessSha256 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $stream = $null
    $sha = $null
    try {
        $stream = [IO.File]::OpenRead($Path)
        $sha = [Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        if ($stream) { $stream.Dispose() }
        if ($sha) { $sha.Dispose() }
    }
}

function Get-QvwHarnessManifest {
    param($Harness)

    $supplied = Get-QvwHarnessProperty -Object $Harness -Name 'Manifest'
    if ($null -ne $supplied) { return $supplied }

    $manifestPath = [string](Get-QvwHarnessProperty -Object $Harness -Name 'ManifestPath' -Default $script:QvwDeepSeekDefaultManifest)
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'DeepSeek Harness manifest was not found.'
    }
    try {
        return [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw 'DeepSeek Harness manifest is invalid JSON.'
    }
}

function Test-QvwHarnessStrictBoolean {
    param($Value)

    return $Value -is [bool]
}

function Test-QvwHarnessStrictInteger {
    param($Value)

    if ($null -eq $Value) { return $false }
    $typeName = $Value.GetType().FullName
    return $typeName -in @(
        'System.Byte', 'System.SByte', 'System.Int16', 'System.UInt16',
        'System.Int32', 'System.UInt32', 'System.Int64', 'System.UInt64'
    )
}

function Get-QvwHarnessRequiredMounts {
    param($Manifest)

    $rawMounts = @(Get-QvwHarnessProperty -Object $Manifest -Name 'requiredMounts' -Default @())
    $mounts = @()
    foreach ($raw in $rawMounts) {
        if ($raw -is [string]) {
            throw 'Manifest requiredMounts entries must be structured objects.'
        }
        $path = [string](Get-QvwHarnessProperty -Object $raw -Name 'path')
        $scope = [string](Get-QvwHarnessProperty -Object $raw -Name 'scope' -Default 'harness')
        $requiredProperty = $raw.PSObject.Properties['requiredForLive']
        if ($null -eq $requiredProperty -or -not (Test-QvwHarnessStrictBoolean $requiredProperty.Value)) {
            throw 'Manifest requiredMounts.requiredForLive must be an explicit boolean.'
        }
        if ([string]::IsNullOrWhiteSpace($path)) { throw 'Manifest required mount path is missing.' }
        if ($scope -notin @('harness', 'machine-local')) { throw 'Manifest required mount scope is invalid.' }
        if ($scope -eq 'harness' -and -not (Test-QvwHarnessSafeRelativePath $path)) {
            throw 'Harness-scoped required mount must be a safe relative path.'
        }
        if ($scope -eq 'machine-local' -and -not ([IO.Path]::IsPathRooted([Environment]::ExpandEnvironmentVariables($path)))) {
            throw 'Machine-local required mount must resolve to an absolute path.'
        }
        $expected = [string](Get-QvwHarnessProperty -Object $raw -Name 'expectedContains' -Default '')
        $mounts += [pscustomobject][ordered]@{
            Path = $path.Replace('\', '/')
            Scope = $scope
            RequiredForLive = [bool]$requiredProperty.Value
            ExpectedContains = $expected
        }
    }
    return @($mounts)
}

function Get-QvwHarnessMountEvidence {
    param(
        [string]$Root,
        $Mounts
    )

    $evidence = @()
    foreach ($mount in @($Mounts)) {
        $resolvedPath = $null
        $exists = $false
        $containsExpected = $false
        $errorText = $null
        try {
            if ([string]$mount.Scope -eq 'harness') {
                $resolvedPath = Get-QvwHarnessFullPath -Root $Root -RelativePath ([string]$mount.Path)
            }
            else {
                $expanded = [Environment]::ExpandEnvironmentVariables([string]$mount.Path)
                if ($expanded -match '%[^%]+%') { throw 'Required mount environment variable is not defined.' }
                $resolvedPath = [IO.Path]::GetFullPath($expanded)
            }
            $exists = Test-Path -LiteralPath $resolvedPath -PathType Leaf
            if (-not $exists) {
                $errorText = 'required mount is missing'
            }
            else {
                $contents = [IO.File]::ReadAllText($resolvedPath, [Text.Encoding]::UTF8)
                $expected = [string]$mount.ExpectedContains
                $containsExpected = [string]::IsNullOrEmpty($expected) -or $contents.IndexOf($expected, [StringComparison]::Ordinal) -ge 0
                if (-not $containsExpected) { $errorText = 'required mount does not contain the expected bridge marker' }
            }
        }
        catch {
            $errorText = $_.Exception.Message
        }
        $evidence += [pscustomobject][ordered]@{
            Path = [string]$mount.Path
            Scope = [string]$mount.Scope
            RequiredForLive = [bool]$mount.RequiredForLive
            ExpectedContains = [string]$mount.ExpectedContains
            ResolvedPath = $resolvedPath
            Exists = [bool]$exists
            ContainsExpected = [bool]$containsExpected
            Satisfied = [bool]($exists -and $containsExpected)
            Error = $errorText
        }
    }
    return @($evidence)
}

function Test-QvwHarnessPayloadLineEndings {
    param([string]$PayloadPath)

    if (-not (Test-Path -LiteralPath $PayloadPath -PathType Leaf)) { return $false }
    $bytes = [IO.File]::ReadAllBytes($PayloadPath)
    foreach ($byte in $bytes) {
        if ($byte -eq 13) { return $false }
    }
    return $true
}

function Get-QvwHarnessControlledEntries {
    param($Manifest)

    if ($null -eq $Manifest) { throw 'DeepSeek Harness manifest is missing.' }
    $upstream = [string](Get-QvwHarnessProperty -Object $Manifest -Name 'upstreamCommit')
    if ($upstream -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'Manifest upstreamCommit must be a full Git commit.'
    }
    $rawEntries = @(Get-QvwHarnessProperty -Object $Manifest -Name 'controlledFiles' -Default @())
    $entries = @()
    foreach ($raw in $rawEntries) {
        $relative = [string](Get-QvwHarnessProperty -Object $raw -Name 'path')
        if (-not (Test-QvwHarnessSafeRelativePath $relative)) {
            throw 'Manifest contains an unsafe controlled path.'
        }
        $beforeExistsProperty = $raw.PSObject.Properties['beforeExists']
        $beforeSha = Get-QvwHarnessProperty -Object $raw -Name 'beforeSha256'
        $afterSha = [string](Get-QvwHarnessProperty -Object $raw -Name 'afterSha256')
        if ($null -eq $beforeExistsProperty) {
            $beforeExists = -not [string]::IsNullOrWhiteSpace([string]$beforeSha)
        }
        else {
            $beforeExists = [bool]$beforeExistsProperty.Value
        }
        if ($beforeExists -and [string]$beforeSha -notmatch '^[0-9a-fA-F]{64}$') {
            throw 'Manifest beforeSha256 is required for an existing preimage.'
        }
        if (-not $beforeExists -and -not [string]::IsNullOrWhiteSpace([string]$beforeSha)) {
            throw 'Manifest beforeSha256 must be empty for an absent preimage.'
        }
        if ($afterSha -notmatch '^[0-9a-fA-F]{64}$') {
            throw 'Manifest afterSha256 must be a full SHA-256 hash.'
        }
        $entries += [pscustomobject][ordered]@{
            Path = $relative.Replace('\', '/')
            BeforeExists = $beforeExists
            BeforeSha256 = if ($beforeExists) { ([string]$beforeSha).ToLowerInvariant() } else { $null }
            AfterSha256 = $afterSha.ToLowerInvariant()
        }
    }
    $patchPlan = Get-QvwHarnessProperty -Object $Manifest -Name 'patchPlan' -Default $null
    if ($null -eq $patchPlan) { throw 'Manifest patchPlan is missing.' }
    $applyCheck = @(Get-QvwHarnessProperty -Object $patchPlan -Name 'applyCheck' -Default @())
    $reverseCheck = @(Get-QvwHarnessProperty -Object $patchPlan -Name 'reverseCheck' -Default @())
    if ($applyCheck.Count -eq 0 -or $reverseCheck.Count -eq 0) {
        throw 'Manifest patchPlan must require both apply and reverse checks.'
    }
    return [pscustomobject][ordered]@{
        SchemaVersion = [int](Get-QvwHarnessProperty -Object $Manifest -Name 'schemaVersion' -Default 1)
        UpstreamCommit = $upstream.ToLowerInvariant()
        Entries = @($entries)
        RequiredMounts = @(Get-QvwHarnessRequiredMounts -Manifest $Manifest)
        PatchPlan = [pscustomobject][ordered]@{
            ApplyCheck = @($applyCheck | ForEach-Object { [string]$_ })
            ReverseCheck = @($reverseCheck | ForEach-Object { [string]$_ })
        }
        TestCommands = @(Get-QvwHarnessProperty -Object $Manifest -Name 'testCommands' -Default @())
        DependencyCommands = @(Get-QvwHarnessProperty -Object $Manifest -Name 'dependencyCommands' -Default @())
        DependencyStrategy = Get-QvwHarnessProperty -Object $Manifest -Name 'dependencyStrategy' -Default $null
        ExcludedPaths = @((Get-QvwHarnessProperty -Object $Manifest -Name 'excludedPaths' -Default @()) | ForEach-Object { [string]$_ })
        SourceAudit = Get-QvwHarnessProperty -Object $Manifest -Name 'sourceAudit' -Default $null
    }
}

function Find-QvwDeepSeekHarness {
    [CmdletBinding()]
    param([string]$ExplicitRoot)

    $selection = 'environment'
    $candidate = $ExplicitRoot
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = $env:QVW_DEEPSEEK_HARNESS_ROOT
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            $candidate = $env:DEEPSEEK_HARNESS_ROOT
        }
    }
    else {
        $selection = 'explicit'
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return [pscustomobject][ordered]@{
            Root = $null
            Selection = 'none'
            Available = $false
            GitPath = $null
            Error = 'No Harness root was selected; pass -ExplicitRoot or set QVW_DEEPSEEK_HARNESS_ROOT.'
        }
    }

    $rootFull = $candidate
    try { $rootFull = [IO.Path]::GetFullPath($candidate) } catch { }
    $available = Test-Path -LiteralPath $rootFull -PathType Container
    $gitCommand = Get-Command -Name git -ErrorAction SilentlyContinue
    $gitPath = if ($null -ne $gitCommand) { [string]$gitCommand.Source } else { $null }
    $errorText = $null
    if (-not $available) {
        $errorText = 'Harness root directory was not found or is unavailable.'
    }
    elseif ($null -eq $gitCommand) {
        $errorText = 'Git is unavailable; compatibility cannot be determined.'
    }
    return [pscustomobject][ordered]@{
        Root = $rootFull
        Selection = $selection
        Available = [bool]$available
        GitPath = $gitPath
        Error = $errorText
        ManifestPath = $script:QvwDeepSeekDefaultManifest
        PayloadPath = $script:QvwDeepSeekDefaultPayload
    }
}

function Invoke-QvwHarnessGit {
    param(
        $Harness,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 120
    )

    $root = [string](Get-QvwHarnessProperty -Object $Harness -Name 'Root')
    $gitPath = [string](Get-QvwHarnessProperty -Object $Harness -Name 'GitPath')
    if ([string]::IsNullOrWhiteSpace($gitPath)) {
        $gitCommand = Get-Command -Name git -ErrorAction SilentlyContinue
        if ($null -ne $gitCommand) { $gitPath = [string]$gitCommand.Source }
    }
    if ([string]::IsNullOrWhiteSpace($gitPath)) {
        return [pscustomobject][ordered]@{ ExitCode = -1; Succeeded = $false; StdOut = ''; StdErr = ''; Error = 'Git is unavailable.' }
    }
    $fullArguments = @('-C', $root) + @($Arguments)
    return Invoke-QvwCommand -FilePath $gitPath -ArgumentList $fullArguments -WorkingDirectory $root -TimeoutSeconds $TimeoutSeconds
}

function Get-QvwHarnessStatusPaths {
    param(
        [string]$StatusText,
        [string[]]$ControlledPaths
    )

    $result = @{}
    foreach ($line in @($StatusText -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -lt 4) { continue }
        $pathText = $line.Substring(3).Trim()
        if ($pathText -match ' -> ') { $pathText = ($pathText -split ' -> ')[-1] }
        $pathText = $pathText.Replace('\', '/').TrimStart('./')
        foreach ($controlled in @($ControlledPaths)) {
            if ($pathText.Equals($controlled.Replace('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
                $result[$controlled.Replace('\', '/')] = $true
            }
        }
    }
    return $result
}

function Invoke-QvwHarnessPatchCheck {
    param(
        $Harness,
        $Normalized,
        [string]$PayloadPath,
        [switch]$Reverse
    )

    $plan = if ($Reverse) { @($Normalized.PatchPlan.ReverseCheck) } else { @($Normalized.PatchPlan.ApplyCheck) }
    if ($plan.Count -eq 0) {
        return [pscustomobject][ordered]@{ Succeeded = $false; ExitCode = -1; StdOut = ''; StdErr = ''; Error = 'Manifest patch plan is missing the requested check.' }
    }
    if (-not (Test-QvwHarnessPayloadLineEndings -PayloadPath $PayloadPath)) {
        return [pscustomobject][ordered]@{ Succeeded = $false; ExitCode = -1; StdOut = ''; StdErr = ''; Error = 'Payload must use LF-only bytes.' }
    }
    # The payload and manifest hashes are byte-level.  Disable Git's working
    # tree text conversion for the controlled apply/reverse operation even if
    # the target checkout globally uses core.autocrlf=true.
    $arguments = @('-c', 'core.autocrlf=false', 'apply')
    if ($Reverse) { $arguments += '--reverse' }
    $arguments += @('--check', '--whitespace=nowarn', $PayloadPath)
    return Invoke-QvwHarnessGit -Harness $Harness -Arguments $arguments -TimeoutSeconds 120
}

function Get-QvwHarnessCompatibility {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Harness)

    $root = [string](Get-QvwHarnessProperty -Object $Harness -Name 'Root')
    $manifest = $null
    try { $manifest = Get-QvwHarnessManifest -Harness $Harness } catch { $manifest = $null }
    $normalized = $null
    try { if ($null -ne $manifest) { $normalized = Get-QvwHarnessControlledEntries -Manifest $manifest } } catch { $normalized = $null }
    $controlled = if ($null -ne $normalized) { @($normalized.Entries) } else { @() }
    $safePaths = @($controlled | ForEach-Object { [string]$_.Path })
    $commit = 'unavailable'
    $mismatches = @()
    $dirtyPaths = @()

    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        $mismatches += 'harness-root-unavailable'
        return [pscustomobject][ordered]@{
            State = 'unknown'; Commit = $commit; ControlledFiles = $controlled; RequiredMounts = @(); PatchChecks = @{}; Mismatches = @($mismatches); DirtyPaths = @($dirtyPaths)
        }
    }
    $rev = Invoke-QvwHarnessGit -Harness $Harness -Arguments @('rev-parse', 'HEAD')
    if ($rev.Succeeded -and -not [string]::IsNullOrWhiteSpace([string]$rev.StdOut)) {
        $commit = ([string]$rev.StdOut).Trim().ToLowerInvariant()
    }
    else {
        $mismatches += 'git-revision-unavailable'
    }
    if ($null -eq $normalized) {
        $mismatches += 'manifest-invalid'
        return [pscustomobject][ordered]@{
            State = 'unknown'; Commit = $commit; ControlledFiles = $controlled; RequiredMounts = @(); PatchChecks = @{}; Mismatches = @($mismatches); DirtyPaths = @($dirtyPaths)
        }
    }

    $status = Invoke-QvwHarnessGit -Harness $Harness -Arguments (@('status', '--porcelain=v1', '--untracked-files=all', '--') + $safePaths)
    $statusPaths = if ($status.Succeeded) { Get-QvwHarnessStatusPaths -StatusText ([string]$status.StdOut) -ControlledPaths $safePaths } else { @{} }
    $allBefore = $true
    $allAfter = $true
    foreach ($entry in @($controlled)) {
        $fullPath = Get-QvwHarnessFullPath -Root $root -RelativePath $entry.Path
        $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
        $actual = if ($exists) { Get-QvwHarnessSha256 -Path $fullPath } else { $null }
        $beforeMatches = if ($entry.BeforeExists) { $exists -and $actual -eq $entry.BeforeSha256 } else { -not $exists }
        $afterMatches = $exists -and $actual -eq $entry.AfterSha256
        if (-not $beforeMatches) { $allBefore = $false }
        if (-not $afterMatches) { $allAfter = $false }
        if (-not $beforeMatches -and -not $afterMatches) {
            $mismatches += ('content:{0}' -f $entry.Path)
        }
        if ($statusPaths.ContainsKey($entry.Path) -and -not $afterMatches) {
            $dirtyPaths += $entry.Path
        }
    }
    $mountEvidence = @(Get-QvwHarnessMountEvidence -Root $root -Mounts $normalized.RequiredMounts)
    foreach ($mount in @($mountEvidence | Where-Object { $_.RequiredForLive -and -not $_.Satisfied })) {
        $allAfter = $false
        $mismatches += ('mount:{0}' -f $mount.Path)
    }
    $payloadPath = [string](Get-QvwHarnessProperty -Object $Harness -Name 'PayloadPath' -Default $script:QvwDeepSeekDefaultPayload)
    $patchChecks = [ordered]@{
        ApplyCheck = $null
        ReverseCheck = $null
    }
    if ($allBefore) {
        $applyCheck = Invoke-QvwHarnessPatchCheck -Harness $Harness -Normalized $normalized -PayloadPath $payloadPath
        $patchChecks.ApplyCheck = [bool]$applyCheck.Succeeded
        if (-not $applyCheck.Succeeded) {
            $allBefore = $false
            $mismatches += 'patch-apply-check'
        }
    }
    if ($allAfter) {
        $reverseCheck = Invoke-QvwHarnessPatchCheck -Harness $Harness -Normalized $normalized -PayloadPath $payloadPath -Reverse
        $patchChecks.ReverseCheck = [bool]$reverseCheck.Succeeded
        if (-not $reverseCheck.Succeeded) {
            $allAfter = $false
            $mismatches += 'patch-reverse-check'
        }
    }
    if ($dirtyPaths.Count -gt 0) {
        $state = 'dirty-overlap'
    }
    elseif ($commit -ne $normalized.UpstreamCommit) {
        $state = 'unknown'
        $mismatches += 'upstream-commit'
    }
    elseif ($allAfter) {
        $state = 'installed-matching'
    }
    elseif ($allBefore) {
        $state = 'missing-matching'
    }
    else {
        $state = 'unknown'
    }
    return [pscustomobject][ordered]@{
        State = $state
        Commit = $commit
        ControlledFiles = $controlled
        RequiredMounts = $mountEvidence
        PatchChecks = [pscustomobject]$patchChecks
        Mismatches = @($mismatches | Select-Object -Unique)
        DirtyPaths = @($dirtyPaths | Select-Object -Unique)
    }
}

function Invoke-QvwHarnessNamedCommand {
    param(
        $Harness,
        $CommandSpec,
        [int]$TimeoutSeconds = 900
    )

    $customCommand = Get-QvwHarnessProperty -Object $Harness -Name 'Command'
    if ($null -ne $customCommand -and $customCommand -is [scriptblock]) {
        $arguments = if ($CommandSpec -is [System.Array]) { @($CommandSpec) } else { @([string]$CommandSpec) }
        $raw = @(& $customCommand -Arguments ([string[]]$arguments))
        if ($raw.Count -eq 0) {
            return [pscustomobject][ordered]@{ ExitCode = -1; Succeeded = $false; StdOut = ''; StdErr = ''; Error = 'Command seam returned no result.' }
        }
        return $raw[-1]
    }
    $parts = if ($CommandSpec -is [System.Array]) { @($CommandSpec | ForEach-Object { [string]$_ }) } else { @([string]$CommandSpec) }
    if ($parts.Count -eq 0 -or [string]::IsNullOrWhiteSpace($parts[0])) {
        return [pscustomobject][ordered]@{ ExitCode = -1; Succeeded = $false; StdOut = ''; StdErr = ''; Error = 'Empty Harness command.' }
    }
    $command = Get-Command -Name $parts[0] -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return [pscustomobject][ordered]@{ ExitCode = -1; Succeeded = $false; StdOut = ''; StdErr = ''; Error = ('Command unavailable: {0}' -f $parts[0]) }
    }
    $filePath = [string]$command.Source
    $arguments = @($parts | Select-Object -Skip 1)
    if ($filePath -match '(?i)\.(cmd|bat)$') {
        $commandLine = ('"{0}"' -f $filePath) + ' ' + ([string]::Join(' ', @($arguments | ForEach-Object { '"{0}"' -f ([string]$_ -replace '"', '\"') })))
        return Invoke-QvwCommand -FilePath $env:ComSpec -ArgumentList @('/d', '/s', '/c', $commandLine) -WorkingDirectory ([string](Get-QvwHarnessProperty -Object $Harness -Name 'Root')) -TimeoutSeconds $TimeoutSeconds
    }
    return Invoke-QvwCommand -FilePath $filePath -ArgumentList $arguments -WorkingDirectory ([string](Get-QvwHarnessProperty -Object $Harness -Name 'Root')) -TimeoutSeconds $TimeoutSeconds
}

function Invoke-QvwHarnessDependencyPlan {
    param(
        $Harness,
        $Normalized
    )

    $results = @()
    $warnings = @()
    $strategy = $Normalized.DependencyStrategy
    if ($null -ne $strategy) {
        $offline = Get-QvwHarnessProperty -Object $strategy -Name 'offline'
        $pinned = Get-QvwHarnessProperty -Object $strategy -Name 'pinned'
        if ($null -ne $offline) {
            $offlineResult = Invoke-QvwHarnessNamedCommand -Harness $Harness -CommandSpec $offline -TimeoutSeconds 1200
            $results += $offlineResult
            if ($offlineResult.Succeeded) {
                return [pscustomobject][ordered]@{ Results = @($results); Mode = 'offline'; Warnings = @($warnings) }
            }
            if ($null -eq $pinned) {
                throw 'Offline dependency installation failed and no pinned fallback was supplied.'
            }
            $warning = 'Network fallback warning: offline dependency installation failed; the pinned-lock command may access the network. No credentials are accepted or emitted.'
            Write-Warning $warning
            $warnings += $warning
            $warningSink = Get-QvwHarnessProperty -Object $Harness -Name 'WarningSink'
            if ($null -ne $warningSink -and $warningSink -is [scriptblock]) {
                & $warningSink -Message $warning
            }
            $allowNetwork = Get-QvwHarnessProperty -Object $Harness -Name 'AllowNetworkFallback'
            if (-not (Test-QvwHarnessStrictBoolean $allowNetwork) -or -not [bool]$allowNetwork) {
                throw 'Offline dependency installation failed; pinned-lock network fallback requires AllowNetworkFallback = true.'
            }
            $pinnedResult = Invoke-QvwHarnessNamedCommand -Harness $Harness -CommandSpec $pinned -TimeoutSeconds 1200
            $results += $pinnedResult
            if (-not $pinnedResult.Succeeded) {
                throw 'Pinned-lock dependency installation failed after the offline attempt.'
            }
            return [pscustomobject][ordered]@{ Results = @($results); Mode = 'pinned-lock-network-warning'; Warnings = @($warnings) }
        }
    }

    foreach ($dependency in @($Normalized.DependencyCommands)) {
        $dependencyResult = Invoke-QvwHarnessNamedCommand -Harness $Harness -CommandSpec $dependency -TimeoutSeconds 1200
        $results += $dependencyResult
        if (-not $dependencyResult.Succeeded) { throw 'Dependency installation failed.' }
    }
    $explicitDependency = Get-QvwHarnessProperty -Object $Harness -Name 'DependencyCommand'
    if ($null -ne $explicitDependency) {
        $dependencyResult = Invoke-QvwHarnessNamedCommand -Harness $Harness -CommandSpec $explicitDependency -TimeoutSeconds 1200
        $results += $dependencyResult
        if (-not $dependencyResult.Succeeded) { throw 'Dependency installation failed.' }
    }
    return [pscustomobject][ordered]@{
        Results = @($results)
        Mode = if ($results.Count -eq 0) { 'not-required-in-patch' } else { 'manifest-command' }
        Warnings = @($warnings)
    }
}

function New-QvwHarnessResult {
    param(
        [string]$Status,
        [string]$Code,
        [string]$Message,
        [hashtable]$Evidence = @{}
    )
    return New-QvwResult -Component 'deepseek-harness' -Status $Status -Code $Code -Message $Message -Evidence $Evidence
}

function Install-QvwHarnessBridge {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Harness)

    $root = [string](Get-QvwHarnessProperty -Object $Harness -Name 'Root')
    $compat = Get-QvwHarnessCompatibility -Harness $Harness
    if ($compat.State -eq 'installed-matching') {
        return New-QvwHarnessResult -Status 'installed' -Code 'QVW-D-ALREADY-INSTALLED' -Message 'DeepSeek Harness bridge is already installed.' -Evidence @{ compatibility = $compat }
    }
    if ($compat.State -ne 'missing-matching') {
        return New-QvwHarnessResult -Status 'blocked' -Code 'QVW-D-COMPATIBILITY-BLOCKED' -Message 'Harness is not an exact clean supported preimage.' -Evidence @{ compatibility = $compat }
    }
    $missingMounts = @($compat.RequiredMounts | Where-Object { $_.RequiredForLive -and -not $_.Satisfied })
    if ($missingMounts.Count -gt 0) {
        return New-QvwHarnessResult -Status 'blocked' -Code 'QVW-D-REQUIRED-MOUNT-MISSING' -Message 'The external prompt-image-bridge mount is missing or does not contain the reviewed marker; the adapter will not create or modify it.' -Evidence @{ compatibility = $compat; requiredMounts = $missingMounts }
    }
    $manifest = $null
    $normalized = $null
    try {
        $manifest = Get-QvwHarnessManifest -Harness $Harness
        $normalized = Get-QvwHarnessControlledEntries -Manifest $manifest
    }
    catch {
        return New-QvwHarnessResult -Status 'blocked' -Code 'QVW-D-MANIFEST-INVALID' -Message 'Harness bridge manifest is invalid.' -Evidence @{ error = $_.Exception.Message }
    }
    $payloadPath = [string](Get-QvwHarnessProperty -Object $Harness -Name 'PayloadPath' -Default $script:QvwDeepSeekDefaultPayload)
    if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) {
        return New-QvwHarnessResult -Status 'blocked' -Code 'QVW-D-PAYLOAD-MISSING' -Message 'Harness bridge payload was not found.' -Evidence @{ payload = $payloadPath }
    }
    if (-not (Test-QvwHarnessPayloadLineEndings -PayloadPath $payloadPath)) {
        return New-QvwHarnessResult -Status 'blocked' -Code 'QVW-D-PAYLOAD-LINE-ENDINGS' -Message 'Harness bridge payload must be byte-level LF; refusing a CRLF-transcoded patch.' -Evidence @{ payload = $payloadPath }
    }
    $transaction = $null
    try {
        $transaction = Start-QvwTransaction -ClientRoot $root -Operation 'deepseek-harness-prompt-image-bridge'
        foreach ($entry in @($normalized.Entries)) {
            $fullPath = Get-QvwHarnessFullPath -Root $root -RelativePath $entry.Path
            [void](Backup-QvwFile -Transaction $transaction -Path $fullPath -LogicalName ('deepseek-harness/' + $entry.Path))
        }

        $check = Invoke-QvwHarnessGit -Harness $Harness -Arguments @('-c', 'core.autocrlf=false', 'apply', '--check', '--whitespace=nowarn', $payloadPath) -TimeoutSeconds 120
        if (-not $check.Succeeded) { throw 'git apply --check failed.' }
        $apply = Invoke-QvwHarnessGit -Harness $Harness -Arguments @('-c', 'core.autocrlf=false', 'apply', '--whitespace=nowarn', $payloadPath) -TimeoutSeconds 120
        if (-not $apply.Succeeded) { throw 'git apply failed.' }

        $dependencyPlan = Invoke-QvwHarnessDependencyPlan -Harness $Harness -Normalized $normalized
        $dependencyResults = @($dependencyPlan.Results)

        $testResults = @()
        foreach ($testCommand in @($normalized.TestCommands)) {
            $testResult = Invoke-QvwHarnessNamedCommand -Harness $Harness -CommandSpec $testCommand -TimeoutSeconds 1200
            $testResults += $testResult
            if (-not $testResult.Succeeded) { throw 'Manifest regression test failed.' }
        }
        $afterCompat = Get-QvwHarnessCompatibility -Harness $Harness
        if ($afterCompat.State -ne 'installed-matching') { throw 'Installed files did not match the manifest postimage.' }
        $commitResult = Complete-QvwTransaction -Transaction $transaction -Evidence @{ compatibility = $afterCompat; dependencyMode = [string]$dependencyPlan.Mode; warnings = @($dependencyPlan.Warnings); tests = @($testResults | ForEach-Object { @{ succeeded = [bool]$_.Succeeded; exitCode = [int]$_.ExitCode } }) }
        return New-QvwHarnessResult -Status 'installed' -Code 'QVW-D-INSTALLED' -Message 'DeepSeek Harness prompt-image bridge installed and verified.' -Evidence @{ receiptPath = $commitResult.ReceiptPath; receiptId = $commitResult.ReceiptId; compatibility = $afterCompat; dependencyMode = [string]$dependencyPlan.Mode; warnings = @($dependencyPlan.Warnings); tests = @($testResults | ForEach-Object { @{ succeeded = [bool]$_.Succeeded; exitCode = [int]$_.ExitCode } }) }
    }
    catch {
        $receiptPath = if ($null -ne $transaction) { [string]$transaction.ReceiptPath } else { $null }
        $rollbackState = 'not-started'
        $rollbackError = $null
        if ($null -ne $transaction -and (Test-Path -LiteralPath $transaction.ReceiptPath -PathType Leaf)) {
            try {
                $rollback = Undo-QvwTransaction -ReceiptPath $transaction.ReceiptPath
                $rollbackState = [string]$rollback.State
            }
            catch {
                $rollbackState = 'rollback-failed'
                $rollbackError = $_.Exception.Message
            }
        }
        $failureCode = 'QVW-D-INSTALL-FAILED'
        if ($rollbackState -eq 'rollback-failed') { $failureCode = 'QVW-D-ROLLBACK-FAILED' }
        return New-QvwHarnessResult -Status 'failed' -Code $failureCode -Message 'DeepSeek Harness bridge installation failed; rollback was attempted.' -Evidence @{ receiptPath = $receiptPath; rollback = $rollbackState; rollbackError = $rollbackError; error = $_.Exception.Message }
    }
}

function Invoke-QvwHarnessLiveVerify {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Harness,
        [string]$ImagePath,
        [switch]$ConfirmPaidCalls
    )

    if (-not $ConfirmPaidCalls) {
        return New-QvwHarnessResult -Status 'blocked' -Code 'QVW-D-PAID-CONFIRMATION-REQUIRED' -Message 'Live Harness verification is a paid call and requires explicit confirmation.'
    }
    $image = if ([string]::IsNullOrWhiteSpace($ImagePath)) { [string](Get-QvwHarnessProperty -Object $Harness -Name 'ImagePath') } else { $ImagePath }
    if ([string]::IsNullOrWhiteSpace($image) -or -not (Test-Path -LiteralPath $image -PathType Leaf)) {
        return New-QvwHarnessResult -Status 'blocked' -Code 'QVW-D-IMAGE-MISSING' -Message 'Live verification image is missing.' -Evidence @{ imagePath = $image }
    }
    # Compatibility is always read from the selected checkout and manifest.  Do
    # not accept caller-provided Compatibility/TestSeam/LiveEvidence fields:
    # those would let a missing root manufacture a target-accepted result.
    $compat = Get-QvwHarnessCompatibility -Harness $Harness
    if ([string](Get-QvwHarnessProperty -Object $compat -Name 'State') -ne 'installed-matching') {
        return New-QvwHarnessResult -Status 'blocked' -Code 'QVW-D-COMPATIBILITY-BLOCKED' -Message 'Live verification requires an installed-matching Harness bridge.' -Evidence @{ compatibility = $compat }
    }

    $evidence = $null
    $liveProbe = Get-QvwHarnessProperty -Object $Harness -Name 'LiveProbe'
    if ($null -ne $liveProbe -and $liveProbe -is [scriptblock]) {
        $raw = @(& $liveProbe -ImagePath $image)
        if ($raw.Count -gt 0) { $evidence = $raw[-1] }
    }
    else {
        $verifyCommand = Get-QvwHarnessProperty -Object $Harness -Name 'VerifyCommand'
        if ($null -ne $verifyCommand -and $verifyCommand -is [scriptblock]) {
            $raw = @(& $verifyCommand -ImagePath $image)
            if ($raw.Count -gt 0) { $evidence = $raw[-1] }
        }
    }
    if ($null -eq $evidence) {
        return New-QvwHarnessResult -Status 'unverified' -Code 'QVW-D-EVIDENCE-INCOMPLETE' -Message 'No live route evidence was returned; a final sentence alone is not acceptance.' -Evidence @{ missing = @('liveEvidence'); compatibility = $compat }
    }
    if ($evidence -is [string]) {
        try { $evidence = $evidence | ConvertFrom-Json -ErrorAction Stop } catch { }
    }
    $requirements = [ordered]@{
        parentProvider = 'deepseek-official'
        parentModel = 'deepseek-v4-pro'
        childModel = 'qwen3.7-plus'
        childImageCount = 1
        parentHasVisualContext = $true
        parentImageBlockCount = 0
        parentSteps = 1
        recursiveToolCalls = 0
    }
    $missing = @()
    foreach ($name in $requirements.Keys) {
        $actual = Get-QvwHarnessProperty -Object $evidence -Name $name
        $expected = $requirements[$name]
        $matches = if ($expected -is [bool]) {
            (Test-QvwHarnessStrictBoolean $actual) -and [bool]$actual -eq [bool]$expected
        }
        elseif ($expected -is [int]) {
            (Test-QvwHarnessStrictInteger $actual) -and [int64]$actual -eq [int64]$expected
        }
        else {
            ($actual -is [string]) -and [string]$actual -ceq [string]$expected
        }
        if (-not $matches) { $missing += $name }
    }
    $ocrValue = Get-QvwHarnessProperty -Object $evidence -Name 'ocr'
    $ocr = if ($ocrValue -is [string]) { [string]$ocrValue } else { '' }
    if ($ocr -cnotmatch 'QVW-7319') { $missing += 'ocr' }
    $finalValue = Get-QvwHarnessProperty -Object $evidence -Name 'finalText'
    $finalText = if ($finalValue -is [string]) { [string]$finalValue } else { '' }
    if ($missing.Count -gt 0) {
        return New-QvwHarnessResult -Status 'unverified' -Code 'QVW-D-EVIDENCE-INCOMPLETE' -Message 'Live response is unverified because required parent/child route evidence is incomplete.' -Evidence @{ missing = @($missing | Select-Object -Unique); finalText = $finalText; compatibility = $compat }
    }
    return New-QvwHarnessResult -Status 'target-accepted' -Code 'QVW-D-LIVE-ACCEPTED' -Message 'DeepSeek Harness parent-child image bridge evidence is complete.' -Evidence @{ parentProvider = $requirements.parentProvider; parentModel = $requirements.parentModel; childModel = $requirements.childModel; childImageCount = 1; parentHasVisualContext = $true; parentImageBlockCount = 0; parentSteps = 1; recursiveToolCalls = 0; ocr = 'QVW-7319'; finalText = $finalText; compatibility = $compat }
}

Export-ModuleMember -Function Find-QvwDeepSeekHarness, Get-QvwHarnessCompatibility, Install-QvwHarnessBridge, Invoke-QvwHarnessLiveVerify
