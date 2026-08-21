Set-StrictMode -Version 2.0

$script:QvwHermesVisionModel = 'qwen3.7-plus'
$script:QvwHermesVisionProvider = 'alibaba'
$script:QvwHermesDefaultBaseUrl = 'https://dashscope.aliyuncs.com/compatible-mode/v1'

$moduleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$dependencyCommands = @{
    'Qvw.Result.psm1' = 'New-QvwResult'
    'Qvw.Process.psm1' = 'Invoke-QvwCommand'
    'Qvw.Security.psm1' = 'Get-QvwSecretFingerprint'
    'Qvw.State.psm1' = 'Start-QvwTransaction'
}
foreach ($dependency in @('Qvw.Result.psm1', 'Qvw.Process.psm1', 'Qvw.Security.psm1', 'Qvw.State.psm1')) {
    $dependencyPath = Join-Path $moduleRoot (Join-Path 'modules' $dependency)
    $commandName = [string]$dependencyCommands[$dependency]
    if ((Test-Path -LiteralPath $dependencyPath -PathType Leaf) -and $null -eq (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
        Import-Module -Name $dependencyPath -Force -ErrorAction Stop
    }
}

function Get-QvwHermesProperty {
    param(
        $Object,
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }
    if ($null -eq $property.Value) {
        return $Default
    }
    return $property.Value
}

function Get-QvwHermesEnvironmentValue {
    param(
        [hashtable]$Environment,
        [string]$Name
    )

    if ($null -ne $Environment) {
        if ($Environment.ContainsKey($Name)) {
            return [string]$Environment[$Name]
        }
        # A supplied environment has test-seam semantics: do not leak values
        # from the host process into a deterministic probe.
        return $null
    }
    return [Environment]::GetEnvironmentVariable($Name, 'Process')
}

function Resolve-QvwHermesRoot {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) {
        return $null
    }
    try {
        if (Test-Path -LiteralPath $Root -PathType Container) {
            return (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
        }
    }
    catch {
    }
    return [IO.Path]::GetFullPath($Root)
}

function ConvertFrom-QvwHermesCliPath {
    param(
        [AllowNull()]
        [string]$Text,
        [string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    $value = ($Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
    if ($null -eq $value) {
        return $null
    }
    $value = ([string]$value).Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }
    if (-not [IO.Path]::IsPathRooted($value)) {
        $value = Join-Path $Root $value
    }
    try {
        return [IO.Path]::GetFullPath($value)
    }
    catch {
        return $value
    }
}

function ConvertFrom-QvwHermesVersion {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    $match = [regex]::Match($Text, '(?i)(?:v)?(?<version>\d+\.\d+\.\d+(?:[-+][A-Za-z0-9._-]+)?)')
    if ($match.Success) {
        return $match.Groups['version'].Value
    }
    return $null
}

function Invoke-QvwHermesProbe {
    param(
        [scriptblock]$Probe,
        [string]$CliPath,
        [string[]]$Arguments,
        [string]$Root
    )

    try {
        # Keep the seam positional. A parameter named $Home is a read-only
        # automatic variable in PowerShell, so named binding would make an
        # otherwise valid probe fail before it can inspect the arguments.
        $value = & $Probe $CliPath $Arguments $Root 2>$null
        return [string]::Join("`n", @($value | ForEach-Object { [string]$_ }))
    }
    catch {
        return ''
    }
}

function Get-QvwHermesSourceCli {
    param(
        [string]$Root,
        [hashtable]$Environment,
        [switch]$AllowGlobalLookup
    )

    $inside = Join-Path $Root 'bin\hermes.cmd'
    if (Test-Path -LiteralPath $inside -PathType Leaf) {
        return (Resolve-Path -LiteralPath $inside -ErrorAction Stop).Path
    }
    $rootCli = Join-Path $Root 'hermes.cmd'
    if (Test-Path -LiteralPath $rootCli -PathType Leaf) {
        return (Resolve-Path -LiteralPath $rootCli -ErrorAction Stop).Path
    }
    if ($AllowGlobalLookup) {
        $command = Get-Command -Name 'hermes.cmd' -CommandType Application -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return [string]$command.Source
        }
    }
    return $null
}

function Get-QvwHermesCandidateRoots {
    param(
        [string]$SelectedRoot,
        [hashtable]$Environment
    )

    $candidates = New-Object System.Collections.ArrayList
    $localAppData = Get-QvwHermesEnvironmentValue -Environment $Environment -Name 'LOCALAPPDATA'
    $userProfile = Get-QvwHermesEnvironmentValue -Environment $Environment -Name 'USERPROFILE'
    $appData = Get-QvwHermesEnvironmentValue -Environment $Environment -Name 'APPDATA'
    $raw = @()
    if (-not [string]::IsNullOrWhiteSpace($localAppData)) { $raw += Join-Path $localAppData 'hermes' }
    if (-not [string]::IsNullOrWhiteSpace($userProfile)) { $raw += Join-Path $userProfile '.hermes' }
    if (-not [string]::IsNullOrWhiteSpace($appData)) { $raw += Join-Path $appData 'hermes' }
    foreach ($candidate in $raw) {
        try {
            if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
            $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
            if ($resolved -ne $SelectedRoot -and -not ($candidates -contains $resolved)) {
                [void]$candidates.Add($resolved)
            }
        }
        catch {
        }
    }
    return @($candidates)
}

function Find-QvwHermes {
    [CmdletBinding()]
    param(
        [string]$ExplicitRoot,
        [hashtable]$Environment,
        [scriptblock]$Probe
    )

    if ($null -eq $Probe) {
        $Probe = {
            param([string]$CliPath, [string[]]$Arguments, [string]$Root)
            $result = Invoke-QvwCommand -FilePath $CliPath -ArgumentList $Arguments -WorkingDirectory $Root -TimeoutSeconds 30 -Secrets @()
            if ($result.Succeeded) { return $result.StdOut }
            return ''
        }
    }

    $selection = 'explicit'
    $home = Resolve-QvwHermesRoot -Root $ExplicitRoot
    if ([string]::IsNullOrWhiteSpace($home)) {
        $environmentHome = Get-QvwHermesEnvironmentValue -Environment $Environment -Name 'HERMES_HOME'
        if (-not [string]::IsNullOrWhiteSpace($environmentHome)) {
            $home = Resolve-QvwHermesRoot -Root $environmentHome
            $selection = 'environment'
        }
    }
    if ([string]::IsNullOrWhiteSpace($home)) {
        $source = $null
        $sourceOverride = Get-QvwHermesEnvironmentValue -Environment $Environment -Name 'HERMES_CLI_PATH'
        if (-not [string]::IsNullOrWhiteSpace($sourceOverride) -and (Test-Path -LiteralPath $sourceOverride -PathType Leaf)) {
            $source = Get-Item -LiteralPath $sourceOverride -ErrorAction Stop
        }
        if ($null -eq $source) {
            $source = Get-Command -Name 'hermes.cmd' -CommandType Application -ErrorAction SilentlyContinue
        }
        if ($null -ne $source) {
            $sourcePath = [string]$source.Source
            $sourceParent = Split-Path -Parent $sourcePath
            if ((Split-Path -Leaf $sourceParent) -ieq 'bin') {
                $home = Split-Path -Parent $sourceParent
            }
            else {
                $home = $sourceParent
            }
            $selection = 'path'
        }
    }
    if ([string]::IsNullOrWhiteSpace($home)) {
        throw 'Hermes CLI was not found.'
    }

    $cliPath = Get-QvwHermesSourceCli -Root $home -Environment $Environment -AllowGlobalLookup:($selection -eq 'path')
    if ([string]::IsNullOrWhiteSpace($cliPath)) {
        throw 'Hermes source CLI hermes.cmd was not found.'
    }
    $configOutput = Invoke-QvwHermesProbe -Probe $Probe -CliPath $cliPath -Arguments @('config', 'path') -Root $home
    $envOutput = Invoke-QvwHermesProbe -Probe $Probe -CliPath $cliPath -Arguments @('config', 'env-path') -Root $home
    $versionOutput = Invoke-QvwHermesProbe -Probe $Probe -CliPath $cliPath -Arguments @('--version') -Root $home
    $configPath = ConvertFrom-QvwHermesCliPath -Text $configOutput -Root $home
    $envPath = ConvertFrom-QvwHermesCliPath -Text $envOutput -Root $home
    $version = ConvertFrom-QvwHermesVersion -Text $versionOutput

    $legacyCli = Join-Path $home 'venv\Scripts\hermes.exe'
    $legacyVersion = $null
    if (Test-Path -LiteralPath $legacyCli -PathType Leaf) {
        $legacyOutput = Invoke-QvwHermesProbe -Probe $Probe -CliPath $legacyCli -Arguments @('--version') -Root $home
        $legacyVersion = ConvertFrom-QvwHermesVersion -Text $legacyOutput
    }

    $conflicts = @(
        Get-QvwHermesCandidateRoots -SelectedRoot $home -Environment $Environment |
            ForEach-Object { [pscustomobject][ordered]@{ Root = $_; Reason = 'candidate-root-not-selected' } }
    )
    $environmentHome = Get-QvwHermesEnvironmentValue -Environment $Environment -Name 'HERMES_HOME'
    if (-not [string]::IsNullOrWhiteSpace($ExplicitRoot) -and -not [string]::IsNullOrWhiteSpace($environmentHome)) {
        $other = Resolve-QvwHermesRoot -Root $environmentHome
        if ($other -and $other -ne $home) {
            $conflicts += [pscustomobject][ordered]@{ Root = $other; Reason = 'HERMES_HOME-not-selected' }
        }
    }

    return [pscustomobject][ordered]@{
        CliPath = $cliPath
        Home = $home
        ConfigPath = $configPath
        EnvPath = $envPath
        Version = $version
        LegacyCliPath = if (Test-Path -LiteralPath $legacyCli -PathType Leaf) { $legacyCli } else { $null }
        LegacyVersion = $legacyVersion
        Conflicts = @($conflicts)
        Selection = $selection
    }
}

function ConvertTo-QvwHermesCommandResult {
    param($Raw)

    if ($null -eq $Raw) {
        return [pscustomobject][ordered]@{ ExitCode = -1; Succeeded = $false; StdOut = ''; StdErr = ''; Error = 'No command result.' }
    }
    if ($Raw.PSObject.Properties['ExitCode'] -and $Raw.PSObject.Properties['Succeeded']) {
        return $Raw
    }
    if ($Raw -is [string]) {
        return [pscustomobject][ordered]@{ ExitCode = 0; Succeeded = $true; StdOut = [string]$Raw; StdErr = ''; Error = $null }
    }
    return [pscustomobject][ordered]@{ ExitCode = 0; Succeeded = $true; StdOut = [string]$Raw; StdErr = ''; Error = $null }
}

function Invoke-QvwHermesOperation {
    param(
        $Hermes,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 30
    )

    $command = Get-QvwHermesProperty -Object $Hermes -Name 'Command'
    if ($command -is [scriptblock]) {
        try {
            $raw = & $command -Arguments @($Arguments)
            $items = @($raw)
            if ($items.Count -gt 0) { return (ConvertTo-QvwHermesCommandResult -Raw $items[$items.Count - 1]) }
            return (ConvertTo-QvwHermesCommandResult -Raw $null)
        }
        catch {
            return [pscustomobject][ordered]@{ ExitCode = -1; Succeeded = $false; StdOut = ''; StdErr = ''; Error = 'Hermes command failed.' }
        }
    }
    return (Invoke-QvwCommand -FilePath ([string](Get-QvwHermesProperty $Hermes 'CliPath')) -ArgumentList $Arguments -WorkingDirectory ([string](Get-QvwHermesProperty $Hermes 'Home')) -TimeoutSeconds $TimeoutSeconds -Secrets @())
}

function Get-QvwHermesConfigValue {
    param($Hermes, [string]$Key)

    $result = Invoke-QvwHermesOperation -Hermes $Hermes -Arguments @('config', 'get', $Key) -TimeoutSeconds 30
    if (-not $result.Succeeded) { return $null }
    $lines = @([string]$result.StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) { return '' }

    # Hermes v0.20.4 returns scalar values for most leaf keys, but `config
    # get model` returns a small mapping whose first line is `default:`.
    # Selecting the last non-empty line would misreport `base_url` as the
    # active model while still allowing a false primary-model preservation
    # check. Parse a matching mapping key explicitly and fail closed when a
    # multi-line shape is unknown.
    $leaf = @($Key -split '\.')[-1]
    $preferredNames = if ($Key -eq 'model') { @('default', 'model') } else { @($leaf) }
    foreach ($preferred in $preferredNames) {
        foreach ($rawLine in $lines) {
            $match = [regex]::Match([string]$rawLine, '^\s*(?<name>[A-Za-z0-9_.-]+)\s*:\s*(?<value>.*)\s*$')
            if ($match.Success -and $match.Groups['name'].Value -ceq $preferred) {
                return $match.Groups['value'].Value.Trim().Trim('"').Trim("'")
            }
        }
    }
    if ($lines.Count -ne 1) { return $null }
    return ([string]$lines[0]).Trim().Trim('"').Trim("'")
}

function Test-QvwHermesProviderMarker {
    param($Hermes)

    $explicit = Get-QvwHermesProperty -Object $Hermes -Name 'ProviderMarker'
    if ($null -ne $explicit) { return [bool]$explicit }
    $markerPath = Get-QvwHermesProperty -Object $Hermes -Name 'ProviderMarkerPath'
    if (-not [string]::IsNullOrWhiteSpace([string]$markerPath) -and (Test-Path -LiteralPath $markerPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $true
    }
    $home = [string](Get-QvwHermesProperty -Object $Hermes -Name 'Home')
    if ([string]::IsNullOrWhiteSpace($home)) { return $false }
    $candidates = @(
        (Join-Path $home 'providers\alibaba.marker'),
        (Join-Path $home 'hermes-agent\agent\auxiliary_client.py'),
        (Join-Path $home 'hermes-agent\agent\image_routing.py'),
        (Join-Path $home 'hermes-agent\agent\model_metadata.py')
    )
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue)) { continue }
        try {
            $text = [IO.File]::ReadAllText($candidate)
            if ($text -match '(?i)alibaba' -and $text -match '(?i)(vision|qwen)') { return $true }
        }
        catch {
        }
    }
    return $false
}

function Test-QvwHermesCapability {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Hermes)

    $imageMode = ((Get-QvwHermesConfigValue -Hermes $Hermes -Key 'agent.image_input_mode') -eq 'auto')
    $provider = Get-QvwHermesConfigValue -Hermes $Hermes -Key 'auxiliary.vision.provider'
    $model = Get-QvwHermesConfigValue -Hermes $Hermes -Key 'auxiliary.vision.model'
    $auxiliary = ($provider -eq $script:QvwHermesVisionProvider -and $model -eq $script:QvwHermesVisionModel)
    $alibaba = ($provider -eq $script:QvwHermesVisionProvider -and (Test-QvwHermesProviderMarker -Hermes $Hermes))
    $legacyMismatch = $false
    $legacyReason = $null
    $legacyVersion = [string](Get-QvwHermesProperty -Object $Hermes -Name 'LegacyVersion')
    $sourceVersion = [string](Get-QvwHermesProperty -Object $Hermes -Name 'Version')
    if (-not [string]::IsNullOrWhiteSpace($legacyVersion) -and -not [string]::IsNullOrWhiteSpace($sourceVersion) -and $legacyVersion -ne $sourceVersion) {
        $legacyMismatch = $true
        $legacyReason = 'legacy CLI version disagrees with source CLI'
    }
    $compatible = ($imageMode -and $auxiliary -and $alibaba -and -not $legacyMismatch)
    $reason = if ($legacyMismatch) { $legacyReason } elseif (-not $imageMode) { 'agent.image_input_mode is not auto' } elseif (-not $auxiliary) { 'auxiliary.vision is not alibaba/qwen3.7-plus' } elseif (-not $alibaba) { 'Alibaba provider marker is unavailable' } else { 'compatible' }
    return [pscustomobject][ordered]@{
        ImageInputMode = [bool]$imageMode
        AuxiliaryVision = [bool]$auxiliary
        AlibabaProvider = [bool]$alibaba
        Compatible = [bool]$compatible
        Reason = $reason
        Version = $sourceVersion
        LegacyVersion = $legacyVersion
    }
}

function Test-QvwHermesInstallPreflight {
    param([Parameter(Mandatory = $true)]$Hermes)

    $reasons = New-Object System.Collections.ArrayList
    $home = [string](Get-QvwHermesProperty -Object $Hermes -Name 'Home')
    $configPath = [string](Get-QvwHermesProperty -Object $Hermes -Name 'ConfigPath')
    $envPath = [string](Get-QvwHermesProperty -Object $Hermes -Name 'EnvPath')
    $version = [string](Get-QvwHermesProperty -Object $Hermes -Name 'Version')
    $legacyVersion = [string](Get-QvwHermesProperty -Object $Hermes -Name 'LegacyVersion')

    if ([string]::IsNullOrWhiteSpace($home) -or -not (Test-Path -LiteralPath $home -PathType Container -ErrorAction SilentlyContinue)) {
        [void]$reasons.Add('active Hermes root is unavailable')
    }
    if ([string]::IsNullOrWhiteSpace($configPath) -or -not (Test-Path -LiteralPath $configPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        [void]$reasons.Add('active Hermes config path is unavailable')
    }
    if ([string]::IsNullOrWhiteSpace($envPath) -or -not (Test-Path -LiteralPath $envPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        [void]$reasons.Add('active Hermes environment path is unavailable')
    }
    if ([string]::IsNullOrWhiteSpace($version)) {
        [void]$reasons.Add('Hermes source CLI version is unknown')
    }
    if (-not [string]::IsNullOrWhiteSpace($legacyVersion) -and
        -not [string]::IsNullOrWhiteSpace($version) -and
        $legacyVersion -ne $version) {
        [void]$reasons.Add('source and legacy Hermes CLI versions conflict')
    }

    $sourceVenvConflict = Get-QvwHermesProperty -Object $Hermes -Name 'SourceVenvConflict'
    if ($null -ne $sourceVenvConflict -and [bool]$sourceVenvConflict) {
        [void]$reasons.Add('source and venv Hermes entry points conflict')
    }
    foreach ($conflict in @(Get-QvwHermesProperty -Object $Hermes -Name 'Conflicts' -Default @())) {
        $conflictReason = [string](Get-QvwHermesProperty -Object $conflict -Name 'Reason')
        if ($conflictReason -match '(?i)(version|legacy|venv).*conflict|conflict.*(version|legacy|venv)') {
            [void]$reasons.Add('Hermes source and venv conflict was reported')
            break
        }
    }

    $schemaSupported = Get-QvwHermesProperty -Object $Hermes -Name 'SchemaSupported'
    if ($null -ne $schemaSupported -and -not [bool]$schemaSupported) {
        [void]$reasons.Add('Hermes vision configuration schema is unavailable')
    }
    $providerSupported = Get-QvwHermesProperty -Object $Hermes -Name 'ProviderSupported'
    if ($null -ne $providerSupported -and -not [bool]$providerSupported) {
        [void]$reasons.Add('Alibaba vision provider capability is unavailable')
    }
    if (-not (Test-QvwHermesProviderMarker -Hermes $Hermes)) {
        [void]$reasons.Add('Alibaba provider marker is unavailable')
    }

    $command = Get-QvwHermesProperty -Object $Hermes -Name 'Command'
    $cliPath = [string](Get-QvwHermesProperty -Object $Hermes -Name 'CliPath')
    if ($command -isnot [scriptblock] -and [string]::IsNullOrWhiteSpace($cliPath)) {
        [void]$reasons.Add('Hermes config command is unavailable')
    }
    elseif ($command -isnot [scriptblock] -and -not (Test-Path -LiteralPath $cliPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        [void]$reasons.Add('Hermes CLI path is unavailable')
    }

    # A successful read-only probe distinguishes an installed schema from an
    # unset target value. Empty config values are therefore allowed here.
    foreach ($key in @('agent.image_input_mode', 'auxiliary.vision.provider', 'auxiliary.vision.model', 'model')) {
        if ($reasons.Count -gt 0 -and $key -eq 'agent.image_input_mode') { continue }
        $getResult = Invoke-QvwHermesOperation -Hermes $Hermes -Arguments @('config', 'get', $key) -TimeoutSeconds 30
        if (-not $getResult.Succeeded) {
            [void]$reasons.Add(('Hermes config get failed for {0}' -f $key))
        }
    }
    if ($reasons.Count -eq 0 -or $command -is [scriptblock] -or -not [string]::IsNullOrWhiteSpace($cliPath)) {
        $checkResult = Invoke-QvwHermesOperation -Hermes $Hermes -Arguments @('config', 'check') -TimeoutSeconds 30
        if (-not $checkResult.Succeeded) {
            [void]$reasons.Add('Hermes config check capability is unavailable')
        }
    }

    $uniqueReasons = @($reasons | Select-Object -Unique)
    return [pscustomobject][ordered]@{
        Supported = ($uniqueReasons.Count -eq 0)
        Reason = if ($uniqueReasons.Count -eq 0) { 'schema/provider/config checks passed' } else { [string]::Join('; ', $uniqueReasons) }
        Reasons = $uniqueReasons
        Version = $version
        LegacyVersion = $legacyVersion
        ProviderMarker = [bool](Test-QvwHermesProviderMarker -Hermes $Hermes)
    }
}

function ConvertTo-QvwSecureString {
    param([string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return $null }
    return (ConvertTo-SecureString -String $Value -AsPlainText -Force)
}

function Get-QvwHermesUserProfile {
    param($Hermes)

    $configured = Get-QvwHermesProperty -Object $Hermes -Name 'UserProfile'
    if (-not [string]::IsNullOrWhiteSpace([string]$configured)) {
        return [string]$configured
    }
    try {
        return [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    }
    catch {
        return $null
    }
}

function Resolve-QvwHarnessCredentialPath {
    param(
        $Hermes,
        [string]$HarnessCredentialPath,
        [string]$HarnessRoot
    )

    # HarnessCredentialPath is an adapter-resolved file path. It is never
    # interpreted relative to a repository root.
    if (-not [string]::IsNullOrWhiteSpace($HarnessCredentialPath)) {
        try { return [IO.Path]::GetFullPath($HarnessCredentialPath) }
        catch { return $null }
    }

    # Keep HarnessRoot as a narrow compatibility seam for callers that already
    # resolved the credential file. Do not guess .dsh children of a repository.
    if (-not [string]::IsNullOrWhiteSpace($HarnessRoot) -and (Test-Path -LiteralPath $HarnessRoot -PathType Leaf -ErrorAction SilentlyContinue)) {
        try { return (Resolve-Path -LiteralPath $HarnessRoot -ErrorAction Stop).Path }
        catch { return $null }
    }

    # The supported default is the current user's Harness credential store,
    # not a child of whichever project repository happens to be selected.
    $userProfile = Get-QvwHermesUserProfile -Hermes $Hermes
    if ([string]::IsNullOrWhiteSpace([string]$userProfile)) { return $null }
    try {
        $primary = Join-Path $userProfile '.dsh\.credentials.yaml'
        if (Test-Path -LiteralPath $primary -PathType Leaf -ErrorAction SilentlyContinue) {
            return (Resolve-Path -LiteralPath $primary -ErrorAction Stop).Path
        }
        $legacy = Join-Path $userProfile '.dsh\credentials.yaml'
        if (Test-Path -LiteralPath $legacy -PathType Leaf -ErrorAction SilentlyContinue) {
            return (Resolve-Path -LiteralPath $legacy -ErrorAction Stop).Path
        }
    }
    catch {
        return $null
    }
    return $null
}

function Get-QvwCredentialFromHarnessFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue)) { return $null }
    try {
        foreach ($line in [IO.File]::ReadAllLines($Path)) {
            $match = [regex]::Match($line, '(?i)^\s*["'']?DASHSCOPE_API_KEY["'']?\s*[:=]\s*["'']?(?<value>[^"''\s#]+)')
            if ($match.Success -and -not [string]::IsNullOrWhiteSpace($match.Groups['value'].Value)) {
                return $match.Groups['value'].Value
            }
        }
    }
    catch {
        return $null
    }
    return $null
}

function New-QvwDashScopeCredentialResult {
    param(
        [securestring]$SecureValue,
        [string]$Source
    )

    $fingerprint = $null
    if ($null -ne $SecureValue) {
        $fingerprint = Get-QvwSecretFingerprint -Secret $SecureValue
    }
    return [pscustomobject][ordered]@{
        SecureValue = $SecureValue
        Source = $Source
        Fingerprint = $fingerprint
    }
}

function Test-QvwSecureStringNonEmpty {
    param([AllowNull()][securestring]$Value)

    if ($null -eq $Value) { return $false }
    $bstr = [IntPtr]::Zero
    $plain = $null
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        return -not [string]::IsNullOrEmpty($plain)
    }
    catch {
        return $false
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        $plain = $null
    }
}

function Invoke-QvwHermesHiddenPrompt {
    param($Prompt)

    $captured = @()
    $errorCountBefore = $Error.Count
    $globalErrorCountBefore = $global:Error.Count
    try {
        if ($Prompt -is [scriptblock]) {
            # Capture all PowerShell streams inside the boundary. The objects
            # are inspected only for a valid SecureString and are never copied
            # into an exception, result, or diagnostic.
            $captured = @(& $Prompt *>&1)
        }
        else {
            $captured = @(Read-Host -AsSecureString -Prompt 'Enter DashScope API key (hidden input)')
        }
    }
    catch {
        $captured = @()
    }
    finally {
        $newErrorCount = $Error.Count - $errorCountBefore
        if ($newErrorCount -lt 0) { $newErrorCount = 0 }
        for ($index = 0; $index -lt $newErrorCount; $index++) {
            $Error.RemoveAt(0)
        }
        $newGlobalErrorCount = $global:Error.Count - $globalErrorCountBefore
        if ($newGlobalErrorCount -lt 0) { $newGlobalErrorCount = 0 }
        for ($index = 0; $index -lt $newGlobalErrorCount; $index++) {
            $global:Error.RemoveAt(0)
        }
    }

    if ($captured.Count -eq 0) { return $null }

    $secureValues = @($captured | Where-Object { $_ -is [securestring] })
    $unsafeValues = @($captured | Where-Object { $_ -isnot [securestring] })
    if ($unsafeValues.Count -gt 0 -or $secureValues.Count -eq 0) {
        return $null
    }
    $candidate = $secureValues[$secureValues.Count - 1]
    if (-not (Test-QvwSecureStringNonEmpty -Value $candidate)) {
        return $null
    }
    return $candidate
}

function Get-QvwDashScopeCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Hermes,
        [string]$HarnessRoot,
        [string]$HarnessCredentialPath,
        [switch]$AllowPrompt
    )

    foreach ($scope in @('Process', 'Machine', 'User')) {
        $value = [Environment]::GetEnvironmentVariable('DASHSCOPE_API_KEY', $scope)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            try {
                $secure = ConvertTo-QvwSecureString -Value $value
                return (New-QvwDashScopeCredentialResult -SecureValue $secure -Source ([string]$scope).ToLowerInvariant())
            }
            finally {
                $value = $null
            }
        }
    }

    $credentialPath = Resolve-QvwHarnessCredentialPath -Hermes $Hermes -HarnessCredentialPath $HarnessCredentialPath -HarnessRoot $HarnessRoot
    $harnessValue = Get-QvwCredentialFromHarnessFile -Path $credentialPath
    if (-not [string]::IsNullOrWhiteSpace($harnessValue)) {
        try {
            $secure = ConvertTo-QvwSecureString -Value $harnessValue
            return (New-QvwDashScopeCredentialResult -SecureValue $secure -Source 'harness-credentials')
        }
        finally {
            $harnessValue = $null
        }
    }

    if ($AllowPrompt) {
        $prompt = Get-QvwHermesProperty -Object $Hermes -Name 'Prompt'
        $securePrompt = Invoke-QvwHermesHiddenPrompt -Prompt $prompt
        if ($securePrompt -is [securestring] -and (Test-QvwSecureStringNonEmpty -Value $securePrompt)) {
            return (New-QvwDashScopeCredentialResult -SecureValue $securePrompt -Source 'prompt')
        }
        return (New-QvwDashScopeCredentialResult -SecureValue $null -Source 'prompt-failed')
    }
    return (New-QvwDashScopeCredentialResult -SecureValue $null -Source 'missing')
}

function Write-QvwHermesAtomicText {
    param([string]$Path, [string]$Text)

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $temp = "$Path.qvw-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temp, $Text, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try { [IO.File]::Replace($temp, $Path, [string]$null) }
            catch { Move-Item -LiteralPath $temp -Destination $Path -Force -ErrorAction Stop | Out-Null }
        }
        else { [IO.File]::Move($temp, $Path) }
    }
    finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue | Out-Null }
    }
}

function Get-QvwHermesSkillSource {
    $skillPath = Join-Path $PSScriptRoot 'skill\hermes-vision-setup\SKILL.md'
    if (Test-Path -LiteralPath $skillPath -PathType Leaf) {
        return [IO.File]::ReadAllText($skillPath)
    }
    return '# Hermes Qwen vision setup`r`n'
}

function Invoke-QvwHermesUndo {
    param(
        $Hermes,
        [string]$ReceiptPath
    )

    if ([string]::IsNullOrWhiteSpace($ReceiptPath)) { return $false }
    $customUndo = Get-QvwHermesProperty -Object $Hermes -Name 'Undo'
    $errorCountBefore = $Error.Count
    $globalErrorCountBefore = $global:Error.Count
    try {
        $raw = if ($customUndo -is [scriptblock]) {
            @(& $customUndo -ReceiptPath $ReceiptPath *>&1)
        }
        else {
            @(Undo-QvwTransaction -ReceiptPath $ReceiptPath *>&1)
        }
        $results = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
        if ($results.Count -eq 0) { return $false }
        $last = $results[$results.Count - 1]
        return ($null -ne $last.PSObject.Properties['State'] -and [string]$last.State -eq 'rolled-back')
    }
    catch {
        return $false
    }
    finally {
        $newErrorCount = $Error.Count - $errorCountBefore
        if ($newErrorCount -lt 0) { $newErrorCount = 0 }
        for ($index = 0; $index -lt $newErrorCount; $index++) { $Error.RemoveAt(0) }
        $newGlobalErrorCount = $global:Error.Count - $globalErrorCountBefore
        if ($newGlobalErrorCount -lt 0) { $newGlobalErrorCount = 0 }
        for ($index = 0; $index -lt $newGlobalErrorCount; $index++) { $global:Error.RemoveAt(0) }
    }
}

function Install-QvwHermesVision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Hermes,
        [AllowNull()][securestring]$DashScopeKey,
        [Parameter(Mandatory = $true)][string]$BaseUrl
    )

    $transaction = $null
    $receiptPath = $null
    $stage = 'preflight'
    try {
        if (-not (Test-QvwSecureStringNonEmpty -Value $DashScopeKey)) {
            return (New-QvwResult -Component 'hermes' -Status 'blocked' -Code 'QVW-H-CRED-REQUIRED' -Message 'A non-empty DashScope credential is required; no transaction was started.' -Evidence @{})
        }
        if ([string]::IsNullOrWhiteSpace($BaseUrl)) { throw 'DashScope base URL is required.' }
        $uri = New-Object System.Uri($BaseUrl)
        if ($uri.Scheme -ne 'https') { throw 'DashScope base URL must use HTTPS.' }
        $home = [string](Get-QvwHermesProperty -Object $Hermes -Name 'Home')
        if ([string]::IsNullOrWhiteSpace($home) -or -not (Test-Path -LiteralPath $home -PathType Container)) { throw 'Hermes home is unavailable.' }
        $configPath = [string](Get-QvwHermesProperty -Object $Hermes -Name 'ConfigPath')
        $envPath = [string](Get-QvwHermesProperty -Object $Hermes -Name 'EnvPath')
        if ([string]::IsNullOrWhiteSpace($configPath) -or [string]::IsNullOrWhiteSpace($envPath)) { throw 'Hermes CLI did not report active config and environment paths.' }
        $skillPath = [string](Get-QvwHermesProperty -Object $Hermes -Name 'SkillPath')
        if ([string]::IsNullOrWhiteSpace($skillPath)) { $skillPath = Join-Path $home 'skills\hermes-vision-setup\SKILL.md' }

        $stage = 'preflight-capability'
        $preflight = Test-QvwHermesInstallPreflight -Hermes $Hermes
        if (-not $preflight.Supported) {
            return (New-QvwResult -Component 'hermes' -Status 'blocked' -Code 'QVW-H-PREFLIGHT-BLOCKED' -Message 'Hermes capability, provider, schema, or version preflight did not pass; no transaction was started.' -Evidence @{ preflight = $preflight })
        }

        $stage = 'read-primary-model'
        $beforeModel = Get-QvwHermesConfigValue -Hermes $Hermes -Key 'model'
        if ($null -eq $beforeModel) { throw 'Unable to read the active primary model.' }
        $stage = 'start-transaction'
        $transaction = Start-QvwTransaction -ClientRoot $home -Operation 'install-hermes-qwen-vision'
        $receiptPath = $transaction.ReceiptPath
        $stage = 'backup-files'
        [void](Backup-QvwFile -Transaction $transaction -Path $configPath -LogicalName 'hermes-config')
        [void](Backup-QvwFile -Transaction $transaction -Path $envPath -LogicalName 'hermes-env')
        [void](Backup-QvwFile -Transaction $transaction -Path $skillPath -LogicalName 'hermes-vision-skill')

        $stage = 'set-vision-config'
        foreach ($setting in @(
            @('agent.image_input_mode', 'auto'),
            @('auxiliary.vision.provider', $script:QvwHermesVisionProvider),
            @('auxiliary.vision.model', $script:QvwHermesVisionModel)
        )) {
            $setResult = Invoke-QvwHermesOperation -Hermes $Hermes -Arguments @('config', 'set', [string]$setting[0], [string]$setting[1]) -TimeoutSeconds 30
            if (-not $setResult.Succeeded) { throw 'Hermes config set failed.' }
        }

        $stage = 'check-and-readback'
        $checkResult = Invoke-QvwHermesOperation -Hermes $Hermes -Arguments @('config', 'check') -TimeoutSeconds 30
        if (-not $checkResult.Succeeded) { throw 'Hermes config check failed.' }
        $afterModel = Get-QvwHermesConfigValue -Hermes $Hermes -Key 'model'
        $readback = @{
            imageInputMode = Get-QvwHermesConfigValue -Hermes $Hermes -Key 'agent.image_input_mode'
            visionProvider = Get-QvwHermesConfigValue -Hermes $Hermes -Key 'auxiliary.vision.provider'
            visionModel = Get-QvwHermesConfigValue -Hermes $Hermes -Key 'auxiliary.vision.model'
            model = $afterModel
        }
        if ($afterModel -ne $beforeModel) { throw 'Hermes primary model changed during installation.' }
        if ($readback.imageInputMode -ne 'auto' -or $readback.visionProvider -ne $script:QvwHermesVisionProvider -or $readback.visionModel -ne $script:QvwHermesVisionModel) { throw 'Hermes vision configuration readback failed.' }

        $stage = 'write-environment'
        [void](Set-QvwEnvValue -Transaction $transaction -Path $envPath -Name 'DASHSCOPE_API_KEY' -Value $DashScopeKey)
        $baseUrlSecret = ConvertTo-QvwSecureString -Value $BaseUrl
        try { [void](Set-QvwEnvValue -Transaction $transaction -Path $envPath -Name 'DASHSCOPE_BASE_URL' -Value $baseUrlSecret) }
        finally { $baseUrlSecret = $null }
        $stage = 'write-skill'
        Write-QvwHermesAtomicText -Path $skillPath -Text (Get-QvwHermesSkillSource)

        $stage = 'commit'
        $commit = Complete-QvwTransaction -Transaction $transaction -Evidence @{
            configPath = $configPath
            envPath = $envPath
            skillPath = $skillPath
            primaryModel = $beforeModel
            imageInputMode = $readback.imageInputMode
            visionProvider = $readback.visionProvider
            visionModel = $readback.visionModel
        }
        return (New-QvwResult -Component 'hermes' -Status 'installed' -Code 'QVW-H-INSTALLED' -Message 'Hermes Qwen vision configuration installed.' -Evidence @{ receiptPath = $commit.ReceiptPath; readback = $readback })
    }
    catch {
        $rollbackSucceeded = $false
        if ($null -ne $transaction -and -not [string]::IsNullOrWhiteSpace($receiptPath)) {
            $rollbackSucceeded = Invoke-QvwHermesUndo -Hermes $Hermes -ReceiptPath $receiptPath
        }
        if ($rollbackSucceeded) {
            return (New-QvwResult -Component 'hermes' -Status 'failed' -Code 'QVW-H-INSTALL-ROLLED-BACK' -Message 'Hermes installation failed and the transaction rollback was verified.' -Evidence @{ receiptPath = $receiptPath; stage = $stage; rollback = 'verified' })
        }
        return (New-QvwResult -Component 'hermes' -Status 'failed' -Code 'QVW-H-ROLLBACK-FAILED' -Message 'Hermes installation failed and automatic rollback could not be verified; manual recovery is required.' -Evidence @{ receiptPath = $receiptPath; stage = $stage; rollback = 'manual-recovery-required' })
    }
}

function Test-QvwHermesDoctor {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Hermes)

    try {
        $preflight = Test-QvwHermesInstallPreflight -Hermes $Hermes
        if (-not $preflight.Supported) {
            return (New-QvwResult -Component 'hermes' -Status 'blocked' -Code 'QVW-H-DOCTOR-BLOCKED' -Message 'Hermes capability, provider, schema, or version preflight did not pass.' -Evidence @{ preflight = $preflight })
        }
        $capability = Test-QvwHermesCapability -Hermes $Hermes
        if ($capability.Compatible) {
            return (New-QvwResult -Component 'hermes' -Status 'tests-passed' -Code 'QVW-H-DOCTOR-OK' -Message 'Hermes capability check passed.' -Evidence @{ capability = $capability; preflight = $preflight })
        }
        return (New-QvwResult -Component 'hermes' -Status 'discovered' -Code 'QVW-H-READY' -Message 'Hermes schema and provider are available; the Qwen vision target is not configured yet.' -Evidence @{ capability = $capability; preflight = $preflight })
    }
    catch {
        return (New-QvwResult -Component 'hermes' -Status 'blocked' -Code 'QVW-H-DOCTOR-ERROR' -Message 'Hermes capability probe failed.' -Evidence @{})
    }
}

$script:QvwHermesVisionVerifyPrompt = 'Read only image facts: OCR the code and describe the red circle, blue square, and green triangle positions.'

function Get-QvwHermesActiveMainModel {
    param($Hermes)

    $explicit = Get-QvwHermesProperty -Object $Hermes -Name 'ActiveMainModel'
    if (-not [string]::IsNullOrWhiteSpace([string]$explicit)) {
        return [string]$explicit
    }
    return Get-QvwHermesConfigValue -Hermes $Hermes -Key 'model'
}

function Get-QvwHermesRoutePart {
    param($Route, [string[]]$Names)

    foreach ($name in @($Names)) {
        $value = Get-QvwHermesProperty -Object $Route -Name $name
        if ($null -ne $value) { return $value }
    }
    return $null
}

function Invoke-QvwHermesAcpRouteProbe {
    param(
        $Hermes,
        [string]$ImagePath,
        [int]$TimeoutSeconds
    )

    $customProbe = Get-QvwHermesProperty -Object $Hermes -Name 'AcpProbe'
    if ($customProbe -is [scriptblock]) {
        try {
            $raw = @(& $customProbe -ImagePath $ImagePath -TimeoutSeconds $TimeoutSeconds *>&1)
            $errors = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
            if ($errors.Count -gt 0) { return $null }
            $objects = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
            if ($objects.Count -gt 0) { return $objects[$objects.Count - 1] }
        }
        catch {
        }
        return $null
    }

    $providedRoute = Get-QvwHermesProperty -Object $Hermes -Name 'AcpRoute'
    if ($null -ne $providedRoute) { return $providedRoute }

    $probeScript = Join-Path $PSScriptRoot 'verify_acp_route.py'
    if (-not (Test-Path -LiteralPath $probeScript -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $null
    }
    $home = [string](Get-QvwHermesProperty -Object $Hermes -Name 'Home')
    if ([string]::IsNullOrWhiteSpace($home)) { return $null }
    $pythonPath = [string](Get-QvwHermesProperty -Object $Hermes -Name 'PythonPath')
    if ([string]::IsNullOrWhiteSpace($pythonPath)) {
        $pythonPath = [string](Get-QvwHermesProperty -Object $Hermes -Name 'PythonExe')
    }
    if (-not [string]::IsNullOrWhiteSpace($pythonPath) -and -not [IO.Path]::IsPathRooted($pythonPath)) {
        $pythonPath = Join-Path $home $pythonPath
    }
    if ([string]::IsNullOrWhiteSpace($pythonPath)) {
        foreach ($candidate in @(
            (Join-Path $home 'hermes-agent\venv\Scripts\python.exe'),
            (Join-Path $home 'hermes-agent\venv\bin\python'),
            (Join-Path $home 'venv\Scripts\python.exe'),
            (Join-Path $home 'venv\bin\python')
        )) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) {
                $pythonPath = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
                break
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($pythonPath)) {
        $python = @(Get-Command -Name 'python.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)[0]
        if ($null -eq $python) {
            $python = @(Get-Command -Name 'python' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)[0]
        }
        if ($null -ne $python) { $pythonPath = [string]$python.Source }
    }
    if ([string]::IsNullOrWhiteSpace($pythonPath) -or -not (Test-Path -LiteralPath $pythonPath -PathType Leaf -ErrorAction SilentlyContinue)) { return $null }
    $result = Invoke-QvwCommand -FilePath $pythonPath -ArgumentList @(
        '-E', '-s',
        $probeScript,
        '--hermes-home', $home,
        '--image', $ImagePath,
        '--timeout', [string]$TimeoutSeconds
    ) -WorkingDirectory $home -TimeoutSeconds $TimeoutSeconds -Secrets @()
    if (-not $result.Succeeded -or [string]::IsNullOrWhiteSpace([string]$result.StdOut)) {
        return $null
    }
    try {
        return ([string]$result.StdOut | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function ConvertTo-QvwHermesRouteEvidence {
    param($Route)

    if ($null -eq $Route) {
        return [pscustomobject][ordered]@{
            Available = $false
            Auxiliary = [pscustomobject][ordered]@{ Task = $null; Provider = $null; Model = $null; RequestHasImage = $false }
            Main = [pscustomobject][ordered]@{ BeforeHasImage = $false; AfterHasImage = $null; AfterHasVisualTextNote = $false }
        }
    }
    $auxiliary = Get-QvwHermesProperty -Object $Route -Name 'auxiliary'
    $main = Get-QvwHermesProperty -Object $Route -Name 'main'
    $available = Get-QvwHermesProperty -Object $Route -Name 'instrumentation_available'
    # The PowerShell AcpProbe is a test seam and predates the Python JSON
    # contract, so its complete fixed-shape object may omit the availability
    # marker.  Do not promote a flat/arbitrary object to route evidence.
    if ($null -eq $available -and $null -ne $auxiliary -and $null -ne $main) { $available = $true }
    if ($null -eq $auxiliary -or $null -eq $main) { $available = $false }
    return [pscustomobject][ordered]@{
        Available = [bool]$available
        Auxiliary = [pscustomobject][ordered]@{
            Task = [string](Get-QvwHermesProperty -Object $auxiliary -Name 'task')
            Provider = [string](Get-QvwHermesProperty -Object $auxiliary -Name 'provider')
            Model = [string](Get-QvwHermesProperty -Object $auxiliary -Name 'model')
            RequestHasImage = [bool](Get-QvwHermesProperty -Object $auxiliary -Name 'request_has_image')
        }
        Main = [pscustomobject][ordered]@{
            BeforeHasImage = [bool](Get-QvwHermesProperty -Object $main -Name 'before_has_image')
            AfterHasImage = Get-QvwHermesProperty -Object $main -Name 'after_has_image'
            AfterHasVisualTextNote = [bool](Get-QvwHermesProperty -Object $main -Name 'after_has_visual_text_note')
        }
    }
}

function Test-QvwHermesVisionFacts {
    param([string]$Text)

    $value = if ($null -eq $Text) { '' } else { $Text }
    $hasText = ($value -match '(?i)\bQVW-7319\b')
    $redLeft = ($value -match '(?i)(red\s+circle.{0,80}(left|west|\u5de6|\u5de6\u4fa7).{0,80}blue\s+square|red.{0,80}(left|\u5de6).{0,80}blue|\u7ea2\u5706.{0,80}(\u5de6|\u5de6\u4fa7).{0,80}\u84dd\u65b9\u5757)')
    # Parse complete subject -> relation -> object clauses.  A bounded
    # wildcard is deliberately not used here: a relation is accepted only
    # when the target object immediately follows the relation grammar in the
    # same sentence/clause.  This prevents "below red but above blue" from
    # becoming two positive below relations merely because both colors occur
    # within a large text window.
    $subject = '(?:green\s+triangle|\u7eff\s*\u4e09\u89d2)'
    $copula = '(?:\s+(?:is|are|was|were|sits?|lies?|located|positioned))?'
    $qualifier = '(?:\s+(?:directly|just|right))?'
    $below = '(?:below|under|beneath|lower\s+than)'
    $above = '(?:above|over|higher\s+than)'
    $redObject = '(?:red\s+circle|\u7ea2\s*\u5706)'
    $blueObject = '(?:blue\s+square|\u84dd\s*\u65b9\s*\u5757)'

    $belowRedPattern = "(?i)$subject$copula$qualifier\s+$below\s+(?:the\s+)?$redObject"
    $belowBluePattern = "(?i)$subject$copula$qualifier\s+$below\s+(?:the\s+)?$blueObject"
    $belowBothRedBluePattern = "(?i)$subject$copula$qualifier\s+$below\s+(?:both\s+)?(?:the\s+)?$redObject\s+(?:and|&)\s+(?:the\s+)?$blueObject"
    $belowBothBlueRedPattern = "(?i)$subject$copula$qualifier\s+$below\s+(?:both\s+)?(?:the\s+)?$blueObject\s+(?:and|&)\s+(?:the\s+)?$redObject"
    $relationContinuation = '(?:\s+(?:and|but|while)\s+)(?:(?:it|the\s+green\s+triangle)\s+)?(?:is\s+)?'
    $belowRedAndBelowBluePattern = "(?i)$subject$copula$qualifier\s+$below\s+(?:the\s+)?$redObject$relationContinuation$below\s+(?:the\s+)?$blueObject"
    $belowBlueAndBelowRedPattern = "(?i)$subject$copula$qualifier\s+$below\s+(?:the\s+)?$blueObject$relationContinuation$below\s+(?:the\s+)?$redObject"

    $notBelowRedPattern = "(?i)$subject$copula$qualifier\s+(?:not|never|isn't|cannot|can't)\s+$below\s+(?:the\s+)?$redObject"
    $notBelowBluePattern = "(?i)$subject$copula$qualifier\s+(?:not|never|isn't|cannot|can't)\s+$below\s+(?:the\s+)?$blueObject"
    $aboveRedPattern = "(?i)$subject$copula$qualifier\s+$above\s+(?:the\s+)?$redObject"
    $aboveBluePattern = "(?i)$subject$copula$qualifier\s+$above\s+(?:the\s+)?$blueObject"
    $notBelowBlueAfterRedPattern = "(?i)$subject$copula$qualifier\s+$below\s+(?:the\s+)?$redObject(?:$relationContinuation$below\s+(?:the\s+)?$blueObject)?$relationContinuation(?:not|never|isn't|cannot|can't)\s+$below\s+(?:the\s+)?$blueObject"
    $notBelowRedAfterBluePattern = "(?i)$subject$copula$qualifier\s+$below\s+(?:the\s+)?$blueObject(?:$relationContinuation$below\s+(?:the\s+)?$redObject)?$relationContinuation(?:not|never|isn't|cannot|can't)\s+$below\s+(?:the\s+)?$redObject"
    $aboveBlueAfterRedPattern = "(?i)$subject$copula$qualifier\s+$below\s+(?:the\s+)?$redObject$relationContinuation$above\s+(?:the\s+)?$blueObject"
    $aboveRedAfterBluePattern = "(?i)$subject$copula$qualifier\s+$below\s+(?:the\s+)?$blueObject$relationContinuation$above\s+(?:the\s+)?$redObject"
    # A later clause or sentence may contradict an earlier positive claim.
    # Match the contradiction itself from either the explicit subject or the
    # unambiguous pronoun used by the verifier prompt; do not require it to be
    # adjacent to the first relation.
    $conflictSubject = '(?:green\s+triangle|the\s+green\s+triangle|it|\u7eff\s*\u4e09\u89d2)'
    $notBelowRedAnywherePattern = "(?i)$conflictSubject[^.!?;]{0,160}?(?:not|never|isn't|cannot|can't)\s+$below\s+(?:the\s+)?$redObject"
    $notBelowBlueAnywherePattern = "(?i)$conflictSubject[^.!?;]{0,160}?(?:not|never|isn't|cannot|can't)\s+$below\s+(?:the\s+)?$blueObject"
    $aboveRedAnywherePattern = "(?i)$conflictSubject[^.!?;]{0,160}?$above\s+(?:the\s+)?$redObject"
    $aboveBlueAnywherePattern = "(?i)$conflictSubject[^.!?;]{0,160}?$above\s+(?:the\s+)?$blueObject"
    $exceptRedPattern = "(?i)$subject(?:\s+[^.!?;]{0,40})?\s+except(?:\s+for)?\s+(?:the\s+)?$redObject"
    $exceptBluePattern = "(?i)$subject(?:\s+[^.!?;]{0,40})?\s+except(?:\s+for)?\s+(?:the\s+)?$blueObject"
    $cnBelowRedPattern = '(?i)\u7eff\s*\u4e09\u89d2\s*(?:\u5728|\u4f4d\u4e8e)\s*\u7ea2\s*\u5706\s*(?:\u7684)?\s*(?:\u4e0b\u65b9|\u4e0b\u9762|\u4e4b\u4e0b)'
    $cnBelowBluePattern = '(?i)\u7eff\s*\u4e09\u89d2\s*(?:\u5728|\u4f4d\u4e8e)\s*\u84dd\s*\u65b9\s*\u5757\s*(?:\u7684)?\s*(?:\u4e0b\u65b9|\u4e0b\u9762|\u4e4b\u4e0b)'
    $cnBelowBothPattern = '(?i)\u7eff\s*\u4e09\u89d2\s*(?:\u5728|\u4f4d\u4e8e)\s*(?:\u7ea2\s*\u5706\s*(?:\u548c|\u53ca|\u4e0e)\s*\u84dd\s*\u65b9\s*\u5757|\u84dd\s*\u65b9\s*\u5757\s*(?:\u548c|\u53ca|\u4e0e)\s*\u7ea2\s*\u5706)\s*(?:\u7684)?\s*(?:\u4e0b\u65b9|\u4e0b\u9762|\u4e4b\u4e0b)'
    $cnNotBelowRedPattern = '(?i)\u7eff\s*\u4e09\u89d2\s*(?:\u4e0d\s*(?:\u5728|\u4f4d\u4e8e)|\u4e0d)\s*\u7ea2\s*\u5706\s*(?:\u7684)?\s*(?:\u4e0b\u65b9|\u4e0b\u9762|\u4e4b\u4e0b)'
    $cnNotBelowBluePattern = '(?i)\u7eff\s*\u4e09\u89d2\s*(?:\u4e0d\s*(?:\u5728|\u4f4d\u4e8e)|\u4e0d)\s*\u84dd\s*\u65b9\s*\u5757\s*(?:\u7684)?\s*(?:\u4e0b\u65b9|\u4e0b\u9762|\u4e4b\u4e0b)'
    $cnAboveRedPattern = '(?i)\u7eff\s*\u4e09\u89d2\s*(?:\u5728|\u4f4d\u4e8e)?\s*\u7ea2\s*\u5706\s*(?:\u7684)?\s*(?:\u4e0a\u65b9|\u4e0a\u9762|\u4e4b\u4e0a)'
    $cnAboveBluePattern = '(?i)\u7eff\s*\u4e09\u89d2\s*(?:\u5728|\u4f4d\u4e8e)?\s*\u84dd\s*\u65b9\s*\u5757\s*(?:\u7684)?\s*(?:\u4e0a\u65b9|\u4e0a\u9762|\u4e4b\u4e0a)'

    $greenBelowRed = $false
    $greenBelowBlue = $false
    $redContradiction = $false
    $blueContradiction = $false
    $fullWidthSentencePunctuation = -join @(
        [char]0x3002
        [char]0xFF01
        [char]0xFF1F
        [char]0xFF1B
    )
    $sentenceBoundaryPattern = '[.!?;\r\n' + [regex]::Escape($fullWidthSentencePunctuation) + ']+'
    $segments = @([regex]::Split($value, $sentenceBoundaryPattern) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    foreach ($rawSegment in $segments) {
        $segment = ([string]$rawSegment -replace '\s+', ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }

        $belowBothRedBlue = ($segment -match $belowBothRedBluePattern -or $segment -match $cnBelowBothPattern)
        $belowBothBlueRed = ($segment -match $belowBothBlueRedPattern)
        if ($belowBothRedBlue -or $belowBothBlueRed) {
            $greenBelowRed = $true
            $greenBelowBlue = $true
        }
        if ($segment -match $belowRedAndBelowBluePattern -or $segment -match $belowBlueAndBelowRedPattern) {
            $greenBelowRed = $true
            $greenBelowBlue = $true
        }
        if ($segment -match $belowRedPattern -or $segment -match $cnBelowRedPattern) { $greenBelowRed = $true }
        if ($segment -match $belowBluePattern -or $segment -match $cnBelowBluePattern) { $greenBelowBlue = $true }

        # Contradictions have priority over positive observations.  This
        # includes explicit above/not-below language and an exception clause.
        if ($segment -match $notBelowRedPattern -or $segment -match $aboveRedPattern -or $segment -match $notBelowRedAfterBluePattern -or $segment -match $aboveRedAfterBluePattern -or $segment -match $notBelowRedAnywherePattern -or $segment -match $aboveRedAnywherePattern -or $segment -match $exceptRedPattern -or $segment -match $cnNotBelowRedPattern -or $segment -match $cnAboveRedPattern) { $redContradiction = $true }
        if ($segment -match $notBelowBluePattern -or $segment -match $aboveBluePattern -or $segment -match $notBelowBlueAfterRedPattern -or $segment -match $aboveBlueAfterRedPattern -or $segment -match $notBelowBlueAnywherePattern -or $segment -match $aboveBlueAnywherePattern -or $segment -match $exceptBluePattern -or $segment -match $cnNotBelowBluePattern -or $segment -match $cnAboveBluePattern) { $blueContradiction = $true }
    }
    if ($redContradiction) { $greenBelowRed = $false }
    if ($blueContradiction) { $greenBelowBlue = $false }
    $greenBelowBoth = ([bool]$greenBelowRed -and [bool]$greenBelowBlue -and -not $redContradiction -and -not $blueContradiction)
    return [pscustomobject][ordered]@{
        Code = [bool]$hasText
        RedCircleLeftOfBlueSquare = [bool]$redLeft
        GreenTriangleBelowRedCircle = [bool]$greenBelowRed
        GreenTriangleBelowBlueSquare = [bool]$greenBelowBlue
        GreenTriangleBelowBoth = [bool]$greenBelowBoth
        GreenTriangleBelow = [bool]$greenBelowBoth
        Complete = ([bool]($hasText -and $redLeft -and $greenBelowBoth))
    }
}

function Invoke-QvwHermesLiveVerify {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Hermes,
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [switch]$ConfirmPaidCalls,
        [int]$TimeoutSeconds = 60
    )

    if (-not $ConfirmPaidCalls) {
        return (New-QvwResult -Component 'hermes' -Status 'blocked' -Code 'QVW-H-PAID-CONFIRMATION-REQUIRED' -Message 'Real Hermes image verification may consume provider quota and requires explicit confirmation; no command was started.' -Evidence @{})
    }
    if ([string]::IsNullOrWhiteSpace($ImagePath) -or -not (Test-Path -LiteralPath $ImagePath -PathType Leaf -ErrorAction SilentlyContinue)) {
        return (New-QvwResult -Component 'hermes' -Status 'blocked' -Code 'QVW-H-IMAGE-REQUIRED' -Message 'A readable PNG image path is required; no command was started.' -Evidence @{})
    }
    $timeout = if ($TimeoutSeconds -le 0) { 60 } else { $TimeoutSeconds }
    $beforeModel = Get-QvwHermesActiveMainModel -Hermes $Hermes
    if ([string]::IsNullOrWhiteSpace([string]$beforeModel)) {
        return (New-QvwResult -Component 'hermes' -Status 'unverified' -Code 'QVW-H-MAIN-MODEL-UNKNOWN' -Message 'The active primary model could not be read before verification.' -Evidence @{})
    }

    $arguments = @(
        'chat', '-q', $script:QvwHermesVisionVerifyPrompt,
        '--image', $ImagePath,
        '-Q', '--ignore-rules', '--source', 'tool',
        '--max-turns', '1', '--run-budget', [string]$timeout
    )
    $commandResult = Invoke-QvwHermesOperation -Hermes $Hermes -Arguments $arguments -TimeoutSeconds $timeout
    if ([bool](Get-QvwHermesProperty -Object $commandResult -Name 'TimedOut')) {
        return (New-QvwResult -Component 'hermes' -Status 'failed' -Code 'QVW-H-VERIFY-TIMEOUT' -Message 'Hermes image verification timed out; no acceptance was inferred.' -Evidence @{ timeoutSeconds = $timeout; command = 'hermes chat' })
    }
    if (-not [bool](Get-QvwHermesProperty -Object $commandResult -Name 'Succeeded')) {
        return (New-QvwResult -Component 'hermes' -Status 'failed' -Code 'QVW-H-VERIFY-FAILED' -Message 'Hermes image verification command failed; no acceptance was inferred.' -Evidence @{ command = 'hermes chat' })
    }

    $afterModel = Get-QvwHermesActiveMainModel -Hermes $Hermes
    $facts = Test-QvwHermesVisionFacts -Text ([string](Get-QvwHermesProperty -Object $commandResult -Name 'StdOut' -Default ''))
    $route = ConvertTo-QvwHermesRouteEvidence -Route (Invoke-QvwHermesAcpRouteProbe -Hermes $Hermes -ImagePath $ImagePath -TimeoutSeconds $timeout)
    $missing = New-Object System.Collections.ArrayList
    if (-not $facts.Complete) { [void]$missing.Add('response-facts') }
    if ([string]::IsNullOrWhiteSpace([string]$afterModel) -or [string]$afterModel -cne [string]$beforeModel) { [void]$missing.Add('main-model-unchanged') }
    if (-not $route.Available) { [void]$missing.Add('acp-instrumentation') }
    if ($route.Auxiliary.Task -ine 'vision') { [void]$missing.Add('auxiliary-task-vision') }
    if ($route.Auxiliary.Provider -ine $script:QvwHermesVisionProvider) { [void]$missing.Add('auxiliary-provider-alibaba') }
    if ($route.Auxiliary.Model -ine $script:QvwHermesVisionModel) { [void]$missing.Add('auxiliary-model-qwen3.7-plus') }
    if (-not $route.Auxiliary.RequestHasImage) { [void]$missing.Add('auxiliary-request-image') }
    if (-not $route.Main.BeforeHasImage) { [void]$missing.Add('main-boundary-before-image') }
    if ($null -eq $route.Main.AfterHasImage -or [bool]$route.Main.AfterHasImage) { [void]$missing.Add('main-boundary-after-text-only') }
    if (-not $route.Main.AfterHasVisualTextNote) { [void]$missing.Add('main-boundary-visual-text-note') }

    $evidence = @{
        command = 'hermes chat'
        primaryModelBefore = [string]$beforeModel
        primaryModelAfter = [string]$afterModel
        responseFacts = $facts
        route = $route
        missingBoundaries = @($missing)
    }
    if ($missing.Count -eq 0) {
        return (New-QvwResult -Component 'hermes' -Status 'target-accepted' -Code 'QVW-H-TARGET-ACCEPTED' -Message 'Hermes Qwen vision route passed the response and both model-boundary checks.' -Evidence $evidence)
    }
    return (New-QvwResult -Component 'hermes' -Status 'unverified' -Code 'QVW-H-ROUTE-EVIDENCE-MISSING' -Message ('Final text or route evidence was incomplete: {0}.' -f ([string]::Join(', ', @($missing)))) -Evidence $evidence)
}

Export-ModuleMember -Function Find-QvwHermes, Test-QvwHermesCapability, Get-QvwDashScopeCredential, Install-QvwHermesVision, Test-QvwHermesDoctor, Invoke-QvwHermesLiveVerify
