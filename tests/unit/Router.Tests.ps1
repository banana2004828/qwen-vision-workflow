Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$routerPath = Join-Path $repoRoot 'qvw.ps1'
. $routerPath

Describe-Qvw 'QVW command router' {
    It-Qvw 'maps every supported action to a script or deferred package route' {
        foreach ($action in @('install', 'doctor', 'verify', 'qwen-mm', 'rollback', 'status', 'diagnostics', 'package')) {
            $route = Resolve-QvwAction -Action $action -RepoRoot $repoRoot
            Assert-QvwEqual $route.Action $action
            Assert-QvwTrue (-not [string]::IsNullOrWhiteSpace([string]$route.Target))
        }
    }

    It-Qvw 'rejects unknown actions before starting a child process' {
        Assert-QvwThrows { Resolve-QvwAction -Action 'unknown' -RepoRoot $repoRoot } '*action*'
    }

    It-Qvw 'forwards common switches without placing credentials in arguments' {
        $args = ConvertTo-QvwForwardArguments -HermesRoot 'C:\fixture\hermes' -HarnessRoot 'C:\fixture\harness' -Json -NonInteractive -ConfirmPaidCalls -Receipt 'qvw-fixture-receipt' -OutputPath 'C:\fixture\diagnostics.zip'
        $joined = [string]::Join(' ', @($args))
        Assert-QvwMatch $joined '-HermesRoot.*C:\\fixture\\hermes'
        Assert-QvwMatch $joined '-HarnessRoot.*C:\\fixture\\harness'
        Assert-QvwContains $args '-Json'
        Assert-QvwContains $args '-NonInteractive'
        Assert-QvwContains $args '-ConfirmPaidCalls'
        Assert-QvwContains $args '-Receipt'
        Assert-QvwContains $args '-OutputPath'
        Assert-QvwNotMatch $joined '(?i)api[_-]?key|secret|token|password'
    }

    It-Qvw 'forwards the Harness root to the combined verification action' {
        $args = ConvertTo-QvwForwardArguments -HermesRoot 'C:\fixture\hermes' -HarnessRoot 'C:\fixture\harness' -ConfirmPaidCalls -ImagePath 'C:\fixture\image.png'
        Assert-QvwContains $args '-HarnessRoot'
        Assert-QvwContains $args 'C:\fixture\harness'
        Assert-QvwContains $args '-ConfirmPaidCalls'
        Assert-QvwContains $args '-ImagePath'
    }
}
