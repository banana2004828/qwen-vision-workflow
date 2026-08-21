Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Describe-Qvw 'Windows CMD launchers' {
    It-Qvw 'keeps CMD launchers no-BOM CRLF' {
        foreach ($file in @('安装千问视觉.cmd', '千问视觉管理.cmd')) {
            $path = Join-Path $repoRoot $file
            Assert-QvwTrue (Test-Path -LiteralPath $path -PathType Leaf)
            $bytes = [IO.File]::ReadAllBytes($path)
            Assert-QvwTrue ($bytes.Length -gt 3)
            Assert-QvwFalse ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            $text = [Text.Encoding]::UTF8.GetString($bytes)
            Assert-QvwNotMatch $text '(?<!\r)\n'
        }
    }

    It-Qvw 'launches install and management entry points through real cmd without command-not-found errors' {
        Push-Location -LiteralPath $repoRoot
        try {
            $installOutput = (& cmd.exe /d /c 'set "QVW_TEST_MODE=1"&& call 安装千问视觉.cmd < nul' *>&1 | Out-String)
            $installCode = $LASTEXITCODE
            $manageOutput = (& cmd.exe /d /c 'set "QVW_TEST_MODE=1"&& call 千问视觉管理.cmd < nul' *>&1 | Out-String)
            $manageCode = $LASTEXITCODE
            Assert-QvwTrue ($installCode -ge 0)
            Assert-QvwTrue ($manageCode -ge 0)
            Assert-QvwNotMatch ($installOutput + $manageOutput) '(?i)not recognized|is not an internal or external command'
            Assert-QvwNotMatch ($installOutput + $manageOutput) '(?i)install-qwen|committed|receiptPath'
        }
        finally { Pop-Location }
    }
}
