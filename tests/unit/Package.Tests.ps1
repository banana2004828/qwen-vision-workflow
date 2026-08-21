Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packagePath = Join-Path $repoRoot 'scripts\package.ps1'
. $packagePath
$installerName = ((0x5B89, 0x88C5, 0x5343, 0x95EE, 0x89C6, 0x89C9 | ForEach-Object { [char]$_ }) -join '') + '.cmd'
$managerName = ((0x5343, 0x95EE, 0x89C6, 0x89C9, 0x7BA1, 0x7406 | ForEach-Object { [char]$_ }) -join '') + '.cmd'

Describe-Qvw 'Deterministic Windows package' {
    It-Qvw 'accepts the router OutputPath name as an alias for the output directory' {
        $command = Get-Command -Name $packagePath -CommandType ExternalScript -ErrorAction Stop
        Assert-QvwContains @($command.Parameters['OutputDirectory'].Aliases) 'OutputPath'
    }

    It-Qvw 'keeps allowlisted PowerShell source parseable by Windows PowerShell 5.1' {
        foreach ($relative in @(Get-QvwPackageAllowlist | Where-Object { $_ -match '\.psm?1$' })) {
            $path = Join-Path $repoRoot ($relative -replace '/', '\')
            $bytes = [IO.File]::ReadAllBytes($path)
            $hasUtf8Bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
            $hasNonAscii = @($bytes | Where-Object { $_ -gt 0x7F }).Count -gt 0
            Assert-QvwTrue ($hasUtf8Bom -or -not $hasNonAscii)
        }
    }

    It-Qvw 'packages required entry points and excludes private state' {
        $testDrive = New-QvwTempDirectory
        try {
            $result = New-QvwPackage -OutputDirectory $testDrive -Version '1.0.0'
            Assert-QvwEqual $result.status 'tests-passed'
            $names = @(Get-QvwZipNames $result.evidence.zipPath | ForEach-Object { [string]$_ -replace '\\', '/' })
            Assert-QvwContains $names $installerName
            Assert-QvwContains $names $managerName
            Assert-QvwContains $names 'qvw.ps1'
            Assert-QvwContains $names 'scripts/package.ps1'
            Assert-QvwContains $names 'licenses/DeepSeek-Harness-MIT.txt'
            foreach ($pattern in @('^\.env(?:$|/)', '^\.git(?:$|/)', '^backups(?:$|/)', '^sessions(?:$|/)', '(?i)\.log$', '(^|/)task-[^/]+\.md$', '^docs/superpowers(?:$|/)')) {
                Assert-QvwFalse (($names -join "`n") -match $pattern)
            }
            Assert-QvwTrue ([int]$result.evidence.scanPasses -eq 2)
            Assert-QvwTrue (Test-Path -LiteralPath $result.evidence.sha256Path -PathType Leaf)
            $hashText = [IO.File]::ReadAllText($result.evidence.sha256Path, [Text.Encoding]::UTF8)
            Assert-QvwMatch $hashText "(?m)^[0-9a-f]{64}\s+qwen-vision-workflow-1\.0\.0-windows\.zip\r?\n$"
        }
        finally {
            Remove-Item -LiteralPath $testDrive -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }

    It-Qvw 'produces the same ZIP bytes from Windows PowerShell 5.1 and PowerShell 7' {
        $ps5Root = New-QvwTempDirectory
        $ps7Root = New-QvwTempDirectory
        try {
            $ps5Output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $packagePath -OutputDirectory $ps5Root -Version '1.0.0' 2>&1)
            Assert-QvwEqual $LASTEXITCODE 0
            $ps7Output = @(& pwsh.exe -NoProfile -File $packagePath -OutputDirectory $ps7Root -Version '1.0.0' 2>&1)
            Assert-QvwEqual $LASTEXITCODE 0
            Assert-QvwNotMatch ([string]::Join("`n", @($ps5Output + $ps7Output))) '(?i)package could not be created|canonical windows package process failed'
            $name = 'qwen-vision-workflow-1.0.0-windows.zip'
            $ps5Hash = (Get-FileHash -LiteralPath (Join-Path $ps5Root $name) -Algorithm SHA256).Hash.ToLowerInvariant()
            $ps7Hash = (Get-FileHash -LiteralPath (Join-Path $ps7Root $name) -Algorithm SHA256).Hash.ToLowerInvariant()
            Assert-QvwEqual $ps5Hash $ps7Hash
        }
        finally {
            Remove-Item -LiteralPath $ps5Root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
            Remove-Item -LiteralPath $ps7Root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }

    It-Qvw 'preserves a structured safety block from both package runtimes' {
        $isolatedRoot = New-QvwTempDirectory
        $ps5Output = Join-Path $isolatedRoot 'out-ps5'
        $ps7Output = Join-Path $isolatedRoot 'out-ps7'
        $fakeSecret = 'fixture-package-secret'
        try {
            # Build an isolated package root containing only the files that the
            # production package allowlist and its three runtime modules need.
            # The injected value is deliberately fake and never asserted in
            # output; the test only proves the safe blocked result is retained.
            $runtimeEntries = @(
                'modules/Qvw.Result.psm1',
                'modules/Qvw.Process.psm1',
                'modules/Qvw.Security.psm1'
            )
            foreach ($relative in @((Get-QvwPackageAllowlist) + $runtimeEntries)) {
                $source = Join-Path $repoRoot ($relative -replace '/', '\')
                $target = Join-Path $isolatedRoot ($relative -replace '/', '\')
                [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
                Copy-Item -LiteralPath $source -Destination $target -Force
            }
            $readmePath = Join-Path $isolatedRoot 'README.md'
            [IO.File]::AppendAllText(
                $readmePath,
                ("`nDASHSCOPE_API_KEY={0}`n" -f $fakeSecret),
                (New-Object Text.UTF8Encoding($false))
            )

            $runtimes = @(
                [pscustomobject]@{ Name = 'Windows PowerShell 5.1'; File = 'powershell.exe'; Output = $ps5Output },
                [pscustomobject]@{ Name = 'PowerShell 7'; File = 'pwsh.exe'; Output = $ps7Output }
            )
            foreach ($runtime in $runtimes) {
                $packageScript = Join-Path $isolatedRoot 'scripts\package.ps1'
                $output = @(& $runtime.File -NoProfile -ExecutionPolicy Bypass -File $packageScript -OutputDirectory $runtime.Output -Version '1.0.0' 2>&1)
                $exitCode = $LASTEXITCODE
                $jsonText = [string]::Join("`n", @($output | ForEach-Object { [string]$_ }))
                Assert-QvwEqual $exitCode 2
                Assert-QvwNotMatch $jsonText ([regex]::Escape($fakeSecret))
                try {
                    $result = $jsonText | ConvertFrom-Json -ErrorAction Stop
                }
                catch {
                    throw ("{0} did not return structured JSON." -f $runtime.Name)
                }
                Assert-QvwEqual ([string]$result.status) 'blocked'
                Assert-QvwEqual ([string]$result.code) 'QVW-PACKAGE-SENSITIVE-DATA'
                Assert-QvwTrue ([int]$result.evidence.scanPasses -eq 1)
                Assert-QvwTrue ([int]$result.evidence.findingCount -gt 0)
                Assert-QvwTrue (@(Get-ChildItem -LiteralPath $runtime.Output -Filter '*.zip' -File -ErrorAction SilentlyContinue).Count -eq 0)
                Assert-QvwTrue (@(Get-ChildItem -LiteralPath $runtime.Output -Filter '*.sha256' -File -ErrorAction SilentlyContinue).Count -eq 0)
            }
        }
        finally {
            Remove-Item -LiteralPath $isolatedRoot -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }

    It-Qvw 'produces byte-identical ZIPs with a stable entry timestamp' {
        $firstRoot = New-QvwTempDirectory
        $secondRoot = New-QvwTempDirectory
        try {
            $first = New-QvwPackage -OutputDirectory $firstRoot -Version '1.0.0'
            $second = New-QvwPackage -OutputDirectory $secondRoot -Version '1.0.0'
            $firstHash = (Get-FileHash -LiteralPath $first.evidence.zipPath -Algorithm SHA256).Hash
            $secondHash = (Get-FileHash -LiteralPath $second.evidence.zipPath -Algorithm SHA256).Hash
            Assert-QvwEqual $firstHash $secondHash
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [System.IO.Compression.ZipFile]::OpenRead($first.evidence.zipPath)
            try {
                $expectedStamp = $null
                foreach ($entry in $archive.Entries) {
                    $stamp = $entry.LastWriteTime.ToUniversalTime()
                    if ($null -eq $expectedStamp) {
                        $expectedStamp = $stamp.ToString('o')
                    }
                    else {
                        Assert-QvwEqual $stamp.ToString('o') $expectedStamp
                    }
                }
            }
            finally {
                $archive.Dispose()
            }
        }
        finally {
            Remove-Item -LiteralPath $firstRoot -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
            Remove-Item -LiteralPath $secondRoot -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }

    It-Qvw 'rejects a reparse-point source before creating a package' {
        $root = New-QvwTempDirectory
        try {
            $link = Join-Path $root 'link'
            try {
                New-Item -ItemType SymbolicLink -Path $link -Target (Join-Path $repoRoot 'README.md') -ErrorAction Stop | Out-Null
            }
            catch {
                # The production package test remains meaningful on Windows
                # hosts where creating a link requires a privilege not granted
                # to the test process.
                return
            }
            Assert-QvwThrows { Assert-QvwPackageSourceSafe -Path $link } '*reparse*'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }

    It-Qvw 'does not exempt a tampered staged Qwen-MM source using the repository copy' {
        $root = New-QvwTempDirectory
        try {
            $relative = 'optional/qwen-mm/QwenMmAdapter.psm1'
            $target = Join-Path $root ($relative -replace '/', '\')
            [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
            Copy-Item -LiteralPath (Join-Path $repoRoot ($relative -replace '/', '\')) -Destination $target -Force
            $lines = @(Get-Content -LiteralPath $target)
            $lines[1060] = "`$bytes = 'DASHSCOPE_API_KEY=fixture-secret'"
            [IO.File]::WriteAllLines($target, $lines, (New-Object Text.UTF8Encoding($false)))
            $scan = Assert-QvwArtifactSafe -Path $target
            Assert-QvwFalse (Test-QvwPackageAllowedStaticFinding -RelativePath $relative -Scan $scan -Root $root)
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
}
