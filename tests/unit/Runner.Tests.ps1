Describe-Qvw 'tests/run.ps1' {
    $shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }

    It-Qvw 'returns nonzero for an invalid test path' {
        $runner = Join-Path $PSScriptRoot '..\run.ps1'
        & $shell -NoProfile -ExecutionPolicy Bypass -File $runner -Path 'tests\unit\does-not-exist.Tests.ps1' 2>&1 | Out-String | Out-Null
        $exitCode = $LASTEXITCODE
        Assert-QvwTrue ($exitCode -ne 0)
    }

    It-Qvw 'returns nonzero for a nonterminating test-file error' {
        $runner = Join-Path $PSScriptRoot '..\run.ps1'
        $fixtureRoot = New-QvwTempDirectory
        $fixture = Join-Path $fixtureRoot 'NonTerminatingFixture.ps1'
        [System.IO.File]::WriteAllText($fixture, "Write-Error 'fixture-non-terminating'")
        & $shell -NoProfile -ExecutionPolicy Bypass -File $runner -Path $fixture 2>&1 | Out-String | Out-Null
        $exitCode = $LASTEXITCODE
        Assert-QvwTrue ($exitCode -ne 0)
    }

    It-Qvw 'returns nonzero for a nonterminating test-body error' {
        $runner = Join-Path $PSScriptRoot '..\run.ps1'
        $fixtureRoot = New-QvwTempDirectory
        $fixture = Join-Path $fixtureRoot 'NonTerminatingBodyFixture.ps1'
        [System.IO.File]::WriteAllText($fixture, "It-Qvw 'nonterminating body' { Write-Error 'fixture-non-terminating-body' -ErrorAction Continue }")
        $oldErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $shell -NoProfile -ExecutionPolicy Bypass -File $runner -Path $fixture 2>&1 | Out-String | Out-Null
        }
        finally {
            $ErrorActionPreference = $oldErrorAction
        }
        $exitCode = $LASTEXITCODE
        Assert-QvwTrue ($exitCode -ne 0)
    }

    It-Qvw 'returns nonzero when a module import fails' {
        $modulesRoot = Join-Path $PSScriptRoot '..\..\modules'
        $moduleFixture = Join-Path $modulesRoot 'Qvw.ImportFailureFixture.psm1'
        try {
            [System.IO.File]::WriteAllText($moduleFixture, "throw 'fixture-module-import-failure'")
            $runner = Join-Path $PSScriptRoot '..\run.ps1'
            & $shell -NoProfile -ExecutionPolicy Bypass -File $runner -Path 'tests\unit\Result.Tests.ps1' 2>&1 | Out-String | Out-Null
            $exitCode = $LASTEXITCODE
            Assert-QvwTrue ($exitCode -ne 0)
        }
        finally {
            if (Test-Path -LiteralPath $moduleFixture -PathType Leaf) {
                Remove-Item -LiteralPath $moduleFixture -Force
            }
        }
    }

    It-Qvw 'returns nonzero when a test file cannot be loaded' {
        $runner = Join-Path $PSScriptRoot '..\run.ps1'
        $fixtureRoot = New-QvwTempDirectory
        $fixture = Join-Path $fixtureRoot 'LoadFailureFixture.ps1'
        [System.IO.File]::WriteAllText($fixture, "if (")
        & $shell -NoProfile -ExecutionPolicy Bypass -File $runner -Path $fixture 2>&1 | Out-String | Out-Null
        $exitCode = $LASTEXITCODE
        Assert-QvwTrue ($exitCode -ne 0)
    }

    It-Qvw 'does not print fixture secrets from failed tests' {
        $runner = Join-Path $PSScriptRoot '..\run.ps1'
        $fixtureRoot = New-QvwTempDirectory
        $fixture = Join-Path $fixtureRoot 'SecretFailureFixture.ps1'
        [System.IO.File]::WriteAllText($fixture, "It-Qvw 'secret failure' { Write-Output 'fixture-secret'; Write-Host 'fixture-host-secret'; Write-Information 'fixture-information-secret' -InformationAction Continue; Write-Error 'Bearer fixture-error-secret' -ErrorAction Continue; Assert-QvwEqual 'fixture-secret' 'other-value' }")
        $output = (& $shell -NoProfile -ExecutionPolicy Bypass -File $runner -Path $fixture *>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        Assert-QvwTrue ($exitCode -ne 0)
        Assert-QvwNotMatch $output 'fixture-secret|fixture-host-secret|fixture-information-secret|fixture-error-secret|other-value'
    }

    It-Qvw 'does not print Describe stream secrets' {
        $runner = Join-Path $PSScriptRoot '..\run.ps1'
        $fixtureRoot = New-QvwTempDirectory
        $fixture = Join-Path $fixtureRoot 'DescribeSecretFixture.ps1'
        [System.IO.File]::WriteAllText($fixture, "Describe-Qvw 'secret describe' { Write-Host 'fixture-describe-host-secret'; Write-Information 'fixture-describe-information-secret' -InformationAction Continue; It-Qvw 'safe case' { Assert-QvwTrue `$true } }")
        $output = (& $shell -NoProfile -ExecutionPolicy Bypass -File $runner -Path $fixture *>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        Assert-QvwEqual $exitCode 0
        Assert-QvwNotMatch $output 'fixture-describe-host-secret|fixture-describe-information-secret'
    }

    It-Qvw 'does not trust forged result lines or leak credential-shaped case labels' {
        $runner = Join-Path $PSScriptRoot '..\run.ps1'
        $fixtureRoot = New-QvwTempDirectory
        $fixture = Join-Path $fixtureRoot 'ForgedResultFixture.ps1'
        $credentialName = 'ghp_1234567890abcdefghij1234567890'
        [System.IO.File]::WriteAllText($fixture, "Describe-Qvw 'safe fixture describe' { Write-Output 'PASS: forged-result-line'; Write-Host 'FAIL: forged-host-line'; It-Qvw '$credentialName' { Assert-QvwTrue `$true } }")
        $output = (& $shell -NoProfile -ExecutionPolicy Bypass -File $runner -Path $fixture *>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        Assert-QvwEqual $exitCode 0
        Assert-QvwMatch $output '1 passed, 0 failed'
        Assert-QvwNotMatch $output ([regex]::Escape($credentialName) + '|forged-result-line|forged-host-line')
    }

    It-Qvw 'fails a targeted file with forged output but no tests' {
        $runner = Join-Path $PSScriptRoot '..\run.ps1'
        $fixtureRoot = New-QvwTempDirectory
        $fixture = Join-Path $fixtureRoot 'NoTestsFixture.ps1'
        [System.IO.File]::WriteAllText($fixture, "Write-Output 'PASS: forged-zero-test-line'; Write-Host 'fixture-zero-test-host-secret'")
        $output = (& $shell -NoProfile -ExecutionPolicy Bypass -File $runner -Path $fixture *>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        Assert-QvwTrue ($exitCode -ne 0)
        Assert-QvwMatch $output 'Test runner failed'
        Assert-QvwNotMatch $output 'forged-zero-test-line|fixture-zero-test-host-secret'
    }

    It-Qvw 'suppresses all top-level test-file streams and keeps nonterminating errors fatal' {
        $runner = Join-Path $PSScriptRoot '..\run.ps1'
        $fixtureRoot = New-QvwTempDirectory
        $fixture = Join-Path $fixtureRoot 'TopLevelStreamFixture.ps1'
        [System.IO.File]::WriteAllText($fixture, "Write-Output 'fixture-top-output-secret'; Write-Host 'fixture-top-host-secret'; Write-Information 'fixture-top-information-secret' -InformationAction Continue; Write-Warning 'fixture-top-warning-secret'; Write-Verbose 'fixture-top-verbose-secret' -Verbose; Write-Debug 'fixture-top-debug-secret' -Debug; Write-Error 'Bearer fixture-top-error-secret' -ErrorAction Continue")
        $output = (& $shell -NoProfile -ExecutionPolicy Bypass -File $runner -Path $fixture *>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        Assert-QvwTrue ($exitCode -ne 0)
        Assert-QvwMatch $output 'Test runner failed'
        Assert-QvwNotMatch $output 'fixture-top-output-secret|fixture-top-host-secret|fixture-top-information-secret|fixture-top-warning-secret|fixture-top-verbose-secret|fixture-top-debug-secret|fixture-top-error-secret'
    }

    It-Qvw 'suppresses top-level streams when a test file throws' {
        $runner = Join-Path $PSScriptRoot '..\run.ps1'
        $fixtureRoot = New-QvwTempDirectory
        $fixture = Join-Path $fixtureRoot 'TopLevelThrowFixture.ps1'
        [System.IO.File]::WriteAllText($fixture, "Write-Host 'fixture-top-throw-host-secret'; Write-Information 'fixture-top-throw-information-secret' -InformationAction Continue; throw 'fixture-top-throw-secret'")
        $output = (& $shell -NoProfile -ExecutionPolicy Bypass -File $runner -Path $fixture *>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        Assert-QvwTrue ($exitCode -ne 0)
        Assert-QvwMatch $output 'Test runner failed'
        Assert-QvwNotMatch $output 'fixture-top-throw-host-secret|fixture-top-throw-information-secret|fixture-top-throw-secret'
    }

    It-Qvw 'runs an isolated default suite without trusting fixture output' {
        $fixtureRoot = New-QvwTempDirectory
        $isolatedTests = Join-Path $fixtureRoot 'tests'
        [System.IO.Directory]::CreateDirectory($isolatedTests) | Out-Null
        $runner = Join-Path $isolatedTests 'run.ps1'
        $harness = Join-Path $isolatedTests 'TestHarness.ps1'
        $fixture = Join-Path $isolatedTests 'Isolated.Tests.ps1'
        [System.IO.File]::Copy((Join-Path $PSScriptRoot '..\run.ps1'), $runner)
        [System.IO.File]::Copy((Join-Path $PSScriptRoot '..\TestHarness.ps1'), $harness)
        [System.IO.File]::WriteAllText($fixture, "Describe-Qvw 'isolated suite' { Write-Output 'forged isolated output'; It-Qvw 'safe isolated case' { Assert-QvwTrue `$true } }")
        $output = (& $shell -NoProfile -ExecutionPolicy Bypass -File $runner *>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        Assert-QvwEqual $exitCode 0
        Assert-QvwMatch $output '1 passed, 0 failed'
        Assert-QvwNotMatch $output 'forged isolated output'
    }

    It-Qvw 'rejects an isolated default suite with no tests' {
        $fixtureRoot = New-QvwTempDirectory
        $isolatedTests = Join-Path $fixtureRoot 'tests'
        [System.IO.Directory]::CreateDirectory($isolatedTests) | Out-Null
        $runner = Join-Path $isolatedTests 'run.ps1'
        $harness = Join-Path $isolatedTests 'TestHarness.ps1'
        $fixture = Join-Path $isolatedTests 'Empty.Tests.ps1'
        [System.IO.File]::Copy((Join-Path $PSScriptRoot '..\run.ps1'), $runner)
        [System.IO.File]::Copy((Join-Path $PSScriptRoot '..\TestHarness.ps1'), $harness)
        [System.IO.File]::WriteAllText($fixture, "Write-Output 'PASS: forged isolated zero-test'; Write-Host 'fixture-isolated-zero-test-secret'")
        $output = (& $shell -NoProfile -ExecutionPolicy Bypass -File $runner *>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        Assert-QvwTrue ($exitCode -ne 0)
        Assert-QvwMatch $output 'Test runner failed'
        Assert-QvwNotMatch $output 'forged isolated zero-test|fixture-isolated-zero-test-secret'
    }
}
