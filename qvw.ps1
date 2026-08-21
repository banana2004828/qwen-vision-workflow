[CmdletBinding()]
param(
    [ValidateSet('install', 'doctor', 'verify', 'qwen-mm', 'rollback', 'status', 'diagnostics', 'package')]
    [string]$Action,
    [string]$HermesRoot,
    [string]$HarnessRoot,
    [string]$ImagePath,
    [switch]$Json,
    [switch]$NonInteractive,
    [switch]$ConfirmPaidCalls,
    [string]$Receipt,
    [string]$OutputPath,
    [string]$Version,
    [int]$TimeoutSeconds = 60
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:QvwRepoRoot = $PSScriptRoot
$script:QvwRouterInvocation = ($MyInvocation.InvocationName -ne '.')

# Execute child entry points in a separate PowerShell process.  PowerShell
# 5.1 treats an array splat containing switch tokens as positional values when
# the target is another script, which can bind -NonInteractive to HermesRoot.
# A real child process preserves the CLI contract and exit code on both PS5.1
# and PS7.
Import-Module (Join-Path $PSScriptRoot 'modules\Qvw.Result.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'modules\Qvw.Process.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'modules\Qvw.Security.psm1') -Force -ErrorAction Stop

function Resolve-QvwAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    $normalized = $Action.Trim().ToLowerInvariant()
    $targets = [ordered]@{
        install = 'scripts\install.ps1'
        doctor = 'scripts\doctor.ps1'
        verify = 'scripts\verify.ps1'
        'qwen-mm' = 'optional\qwen-mm\QwenMmAdapter.psm1'
        rollback = 'scripts\rollback.ps1'
        status = 'scripts\status.ps1'
        diagnostics = 'scripts\export-diagnostics.ps1'
        package = 'scripts\package.ps1'
    }
    if (-not $targets.Contains($normalized)) {
        throw 'Unknown QVW action.'
    }
    $relative = [string]$targets[$normalized]
    $targetPath = Join-Path $RepoRoot $relative
    return [pscustomobject][ordered]@{
        Action = $normalized
        RelativePath = $relative
        Target = $targetPath
        Available = (Test-Path -LiteralPath $targetPath -PathType Leaf)
    }
}

function ConvertTo-QvwForwardArguments {
    [CmdletBinding()]
    param(
        [string]$HermesRoot,
        [string]$HarnessRoot,
        [switch]$Json,
        [switch]$NonInteractive,
        [switch]$ConfirmPaidCalls,
        [string]$Receipt,
        [string]$OutputPath,
        [string]$ImagePath,
        [int]$TimeoutSeconds = 60,
        [string]$Version
    )

    $arguments = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($HermesRoot)) { [void]$arguments.Add('-HermesRoot'); [void]$arguments.Add($HermesRoot) }
    if (-not [string]::IsNullOrWhiteSpace($HarnessRoot)) { [void]$arguments.Add('-HarnessRoot'); [void]$arguments.Add($HarnessRoot) }
    if ($Json) { [void]$arguments.Add('-Json') }
    if ($NonInteractive) { [void]$arguments.Add('-NonInteractive') }
    if ($ConfirmPaidCalls) { [void]$arguments.Add('-ConfirmPaidCalls') }
    if (-not [string]::IsNullOrWhiteSpace($Receipt)) { [void]$arguments.Add('-Receipt'); [void]$arguments.Add($Receipt) }
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) { [void]$arguments.Add('-OutputPath'); [void]$arguments.Add($OutputPath) }
    if (-not [string]::IsNullOrWhiteSpace($ImagePath)) { [void]$arguments.Add('-ImagePath'); [void]$arguments.Add($ImagePath) }
    if ($TimeoutSeconds -gt 0 -and $TimeoutSeconds -ne 60) { [void]$arguments.Add('-TimeoutSeconds'); [void]$arguments.Add([string]$TimeoutSeconds) }
    if (-not [string]::IsNullOrWhiteSpace($Version)) { [void]$arguments.Add('-Version'); [void]$arguments.Add($Version) }
    return @($arguments)
}

function Get-QvwRouterResultExitCode {
    param([string]$JsonText)

    try {
        $parsed = $JsonText | ConvertFrom-Json -ErrorAction Stop
        switch ([string]$parsed.status) {
            'blocked' { return 2 }
            'unverified' { return 3 }
            'failed' { return 4 }
            'degraded' { return 5 }
            default { return 0 }
        }
    }
    catch {
        return 1
    }
}

function Get-QvwRouterProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function New-QvwRouterBlockedResult {
    param([string]$Code, [string]$Message)
    return (New-QvwResult -Component 'router' -Status 'blocked' -Code $Code -Message $Message -Evidence @{})
}

function Invoke-QvwChildScript {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Arguments = @()
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $missing = New-QvwRouterBlockedResult -Code 'QVW-ACTION-UNAVAILABLE' -Message 'The requested QVW action is not included in this checkout.'
        $jsonText = Write-QvwResult -Result $missing -AsJson
        return [pscustomobject][ordered]@{ Output = [string]$jsonText; ExitCode = 2 }
    }

    try {
        $shell = if ($PSVersionTable.PSEdition -eq 'Core') {
            $command = Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue
            if ($null -ne $command) { [string]$command.Source } else { Join-Path $PSHOME 'pwsh.exe' }
        }
        else {
            $command = Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue
            if ($null -ne $command) { [string]$command.Source } else { Join-Path $PSHOME 'powershell.exe' }
        }
        $childArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Path) + @($Arguments)
        $commandResult = Invoke-QvwCommand -FilePath $shell -ArgumentList $childArguments -WorkingDirectory $script:QvwRepoRoot -TimeoutSeconds 300 -Secrets @()
    }
    catch {
        $failed = New-QvwResult -Component 'router' -Status 'failed' -Code 'QVW-ROUTER-CHILD-FAILED' -Message 'The requested QVW action failed before it returned a result.' -Evidence @{}
        $jsonText = Write-QvwResult -Result $failed -AsJson
        return [pscustomobject][ordered]@{ Output = [string]$jsonText; ExitCode = 1 }
    }
    $text = [string](Get-QvwRouterProperty -Object $commandResult -Name 'StdOut')
    if ([string]::IsNullOrWhiteSpace($text)) {
        $failed = New-QvwResult -Component 'router' -Status 'failed' -Code 'QVW-ROUTER-NO-RESULT' -Message 'The requested QVW action returned no structured result.' -Evidence @{}
        $jsonText = Write-QvwResult -Result $failed -AsJson
        return [pscustomobject][ordered]@{ Output = [string]$jsonText; ExitCode = 1 }
    }
    $exitCode = Get-QvwRouterResultExitCode -JsonText $text
    if ($exitCode -eq 0 -and [int](Get-QvwRouterProperty -Object $commandResult -Name 'ExitCode' -Default 0) -ne 0) {
        $exitCode = [int](Get-QvwRouterProperty -Object $commandResult -Name 'ExitCode' -Default 1)
    }
    return [pscustomobject][ordered]@{ Output = $text; ExitCode = $exitCode }
}

function Invoke-QvwQwenMmAction {
    param(
        [string]$HermesRoot,
        [string]$HarnessRoot,
        [switch]$Json,
        [switch]$NonInteractive,
        [switch]$ConfirmPaidCalls,
        [string]$Receipt,
        [string]$ImagePath
    )

    try {
        $repoRoot = $script:QvwRepoRoot
        Import-Module (Join-Path $repoRoot 'modules\Qvw.Result.psm1') -Force -ErrorAction Stop
        Import-Module (Join-Path $repoRoot 'modules\Qvw.Process.psm1') -Force -ErrorAction Stop
        Import-Module (Join-Path $repoRoot 'modules\Qvw.Security.psm1') -Force -ErrorAction Stop
        Import-Module (Join-Path $repoRoot 'modules\Qvw.State.psm1') -Force -ErrorAction Stop
        Import-Module (Join-Path $repoRoot 'adapters\hermes\HermesAdapter.psm1') -Force -ErrorAction Stop
        Import-Module (Join-Path $repoRoot 'optional\qwen-mm\QwenMmAdapter.psm1') -Force -ErrorAction Stop
        $hermes = Find-QvwHermes -ExplicitRoot $HermesRoot
        $credential = Get-QvwDashScopeCredential -Hermes $hermes -HarnessRoot $HarnessRoot -AllowPrompt:(-not $NonInteractive)
        if ($null -eq $credential -or $null -eq $credential.SecureValue) {
            $result = New-QvwResult -Component 'qwen-mm' -Status 'blocked' -Code 'QVW-QMM-CRED-REQUIRED' -Message 'A DashScope credential was not available; no optional files were changed.' -Evidence @{}
        }
        else {
            $result = Install-QvwQwenMm -Hermes $hermes -DashScopeKey $credential.SecureValue
            if ($ConfirmPaidCalls -and -not [string]::IsNullOrWhiteSpace($ImagePath) -and [string]$result.status -eq 'installed') {
                $result = Invoke-QvwQwenMmLiveVerify -Hermes $hermes -ImagePath $ImagePath -ReceiptPath ([string]$result.evidence.receiptPath) -ConfirmPaidCalls
            }
        }
        return [pscustomobject][ordered]@{ Output = [string](Write-QvwResult -Result $result -AsJson); ExitCode = Get-QvwRouterResultExitCode -JsonText ([string](Write-QvwResult -Result $result -AsJson)) }
    }
    catch {
        $result = New-QvwResult -Component 'qwen-mm' -Status 'failed' -Code 'QVW-QMM-ROUTER-FAILED' -Message 'The optional Qwen-MM action could not be started safely.' -Evidence @{}
        $jsonText = [string](Write-QvwResult -Result $result -AsJson)
        return [pscustomobject][ordered]@{ Output = $jsonText; ExitCode = 1 }
    }
}

function Invoke-QvwRouter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$HermesRoot,
        [string]$HarnessRoot,
        [string]$ImagePath,
        [switch]$Json,
        [switch]$NonInteractive,
        [switch]$ConfirmPaidCalls,
        [string]$Receipt,
        [string]$OutputPath,
        [string]$Version,
        [int]$TimeoutSeconds = 60
    )

    $route = Resolve-QvwAction -Action $Action -RepoRoot $script:QvwRepoRoot
    if ($route.Action -eq 'qwen-mm') {
        return (Invoke-QvwQwenMmAction -HermesRoot $HermesRoot -HarnessRoot $HarnessRoot -Json:$Json -NonInteractive:$NonInteractive -ConfirmPaidCalls:$ConfirmPaidCalls -Receipt $Receipt -ImagePath $ImagePath)
    }

    $forward = New-Object System.Collections.Generic.List[string]
    switch ($route.Action) {
        'install' {
            foreach ($value in (ConvertTo-QvwForwardArguments -HermesRoot $HermesRoot -HarnessRoot $HarnessRoot -Json:$Json -NonInteractive:$NonInteractive)) { [void]$forward.Add([string]$value) }
        }
        'doctor' {
            foreach ($value in (ConvertTo-QvwForwardArguments -HermesRoot $HermesRoot -HarnessRoot $HarnessRoot -Json:$Json -NonInteractive:$NonInteractive)) { [void]$forward.Add([string]$value) }
        }
        'verify' {
            foreach ($value in (ConvertTo-QvwForwardArguments -HermesRoot $HermesRoot -HarnessRoot $HarnessRoot -Json:$Json -NonInteractive:$NonInteractive -ConfirmPaidCalls:$ConfirmPaidCalls -ImagePath $ImagePath -TimeoutSeconds $TimeoutSeconds)) { [void]$forward.Add([string]$value) }
        }
        'rollback' {
            foreach ($value in (ConvertTo-QvwForwardArguments -HermesRoot $HermesRoot -Json:$Json -NonInteractive:$NonInteractive -Receipt $Receipt)) { [void]$forward.Add([string]$value) }
        }
        'status' {
            foreach ($value in (ConvertTo-QvwForwardArguments -HermesRoot $HermesRoot -HarnessRoot $HarnessRoot -Json:$Json -NonInteractive:$NonInteractive)) { [void]$forward.Add([string]$value) }
        }
        'diagnostics' {
            foreach ($value in (ConvertTo-QvwForwardArguments -HermesRoot $HermesRoot -HarnessRoot $HarnessRoot -Json:$Json -NonInteractive:$NonInteractive -OutputPath $OutputPath)) { [void]$forward.Add([string]$value) }
        }
        'package' {
            # package.ps1 always returns the shared JSON result contract. Do
            # not forward common switches that are not part of its interface.
            foreach ($value in (ConvertTo-QvwForwardArguments -OutputPath $OutputPath -Version $Version)) { [void]$forward.Add([string]$value) }
        }
    }
    # Do not wrap the List[string] in another array: PowerShell 5.1 would
    # bind that nested object positionally (for example into HermesRoot).
    return (Invoke-QvwChildScript -Path $route.Target -Arguments ([string[]]$forward.ToArray()))
}

if ($script:QvwRouterInvocation) {
    try {
        if ([string]::IsNullOrWhiteSpace($Action)) { throw 'An action is required.' }
        $result = Invoke-QvwRouter -Action $Action -HermesRoot $HermesRoot -HarnessRoot $HarnessRoot -ImagePath $ImagePath -Json:$Json -NonInteractive:$NonInteractive -ConfirmPaidCalls:$ConfirmPaidCalls -Receipt $Receipt -OutputPath $OutputPath -Version $Version -TimeoutSeconds $TimeoutSeconds
        Write-Output $result.Output
        exit ([int]$result.ExitCode)
    }
    catch {
        try {
            Import-Module (Join-Path $PSScriptRoot 'modules\Qvw.Result.psm1') -Force -ErrorAction Stop
            $result = New-QvwResult -Component 'router' -Status 'blocked' -Code 'QVW-ROUTER-INVALID-REQUEST' -Message 'The QVW request could not be routed safely.' -Evidence @{}
            Write-QvwResult -Result $result -AsJson
        }
        catch {
            Write-Output '{"schemaVersion":1,"component":"router","status":"blocked","code":"QVW-ROUTER-INVALID-REQUEST","message":"The QVW request could not be routed safely.","evidence":{}}'
        }
        exit 2
    }
}
