[CmdletBinding()]
param(
    [string]$Path
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$testsRoot = $PSScriptRoot
$repoRoot = Split-Path -Parent $testsRoot
try {
    . (Join-Path $testsRoot 'TestHarness.ps1')

    $modulesRoot = Join-Path $repoRoot 'modules'
    if (Test-Path -LiteralPath $modulesRoot -PathType Container) {
        $moduleFiles = @(Get-ChildItem -LiteralPath $modulesRoot -Filter '*.psm1' -File -Recurse -ErrorAction Stop | Sort-Object FullName)
        foreach ($moduleFile in $moduleFiles) {
            $Error.Clear()
            $moduleOutput = @(Import-Module -Name $moduleFile.FullName -Force -ErrorAction Stop *>&1)
            $moduleErrors = @($moduleOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
            if ($moduleErrors.Count -gt 0 -or $Error.Count -gt 0) {
                throw 'Module import emitted a non-terminating error'
            }
        }
    }

    if ($Path) {
        if ([System.IO.Path]::IsPathRooted($Path)) {
            $testFiles = @(Get-Item -LiteralPath $Path -ErrorAction Stop)
        }
        else {
            $testFiles = @(Get-Item -LiteralPath (Join-Path $repoRoot $Path) -ErrorAction Stop)
        }
        if ($testFiles.Count -ne 1 -or $testFiles[0].PSIsContainer) {
            throw 'Requested test path is not a file'
        }
    }
    else {
        $testFiles = @(Get-ChildItem -LiteralPath $testsRoot -Filter '*.Tests.ps1' -File -Recurse -ErrorAction Stop | Sort-Object FullName)
    }

    foreach ($testFile in $testFiles) {
        $Error.Clear()
        $testFileOutput = @()
        try {
            $testFileOutput = @(. $testFile.FullName *>&1)
        }
        catch {
            throw 'Test file failed while loading'
        }
        $testFileErrors = @($testFileOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        if ($testFileErrors.Count -gt 0 -or $Error.Count -gt 0) {
            throw 'Test file emitted a non-terminating error'
        }
    }

    $cases = @(Get-QvwTestCases)
    if ($cases.Count -eq 0) {
        throw 'No tests were discovered'
    }
    $passed = @($cases | Where-Object { $_.Passed }).Count
    $failed = @($cases | Where-Object { -not $_.Passed }).Count
    Write-Output ("{0} passed, {1} failed" -f $passed, $failed)

    if ($failed -gt 0) {
        exit 1
    }
    exit 0
}
catch {
    $errorType = if ($null -eq $_.Exception) { 'Unknown' } else { $_.Exception.GetType().Name }
    Write-Output ("Test runner failed (errorType={0})" -f $errorType)
    exit 1
}
