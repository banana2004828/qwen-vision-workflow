Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$diagnosticsPath = Join-Path $repoRoot 'scripts\export-diagnostics.ps1'
. $diagnosticsPath

Describe-Qvw 'Redacted diagnostics export' {
    It-Qvw 'refuses a diagnostic ZIP containing a fixture secret and leaves no output' {
        $root = New-QvwTempDirectory
        $output = Join-Path $root 'diag.zip'
        try {
            $result = Export-QvwDiagnostics -OutputPath $output -AdditionalText 'DASHSCOPE_API_KEY=fixture-secret'
            Assert-QvwEqual $result.status 'blocked'
            Assert-QvwFalse (Test-Path -LiteralPath $output -PathType Leaf)
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }

    It-Qvw 'exports a clean ZIP only after scanning the source and extracted archive' {
        $root = New-QvwTempDirectory
        $output = Join-Path $root 'diag.zip'
        try {
            $result = Export-QvwDiagnostics -OutputPath $output -AdditionalText 'fixture-note=clean'
            Assert-QvwEqual $result.status 'tests-passed'
            Assert-QvwTrue (Test-Path -LiteralPath $output -PathType Leaf)
            Assert-QvwTrue ([int]$result.evidence.scanPasses -eq 2)
            Assert-QvwTrue ([int]$result.evidence.fileCount -gt 0)
            $names = @(Get-QvwZipNames $output | ForEach-Object { [string]$_ -replace '\\', '/' })
            Assert-QvwContains $names 'diagnostics/status.json'
            Assert-QvwNotMatch ([string]::Join("`n", @($names))) '(?i)\.env|credential|session|\.log'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
}
