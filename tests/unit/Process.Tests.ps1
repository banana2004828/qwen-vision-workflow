Describe-Qvw 'Qvw.Process' {
    It-Qvw 'captures and redacts stdout and stderr without a shell' {
        $command = Get-Command powershell.exe -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            $command = Get-Command pwsh.exe -ErrorAction Stop
        }
        $script = 'Write-Output "stdout-fixture-secret"; [Console]::Error.WriteLine("Authorization: Bearer stderr-fixture-secret")'
        $result = Invoke-QvwCommand -FilePath $command.Source -ArgumentList @('-NoProfile', '-Command', $script) -WorkingDirectory (Get-Location).Path -TimeoutSeconds 10 -Secrets @('stdout-fixture-secret', 'stderr-fixture-secret')
        Assert-QvwEqual $result.ExitCode 0
        Assert-QvwFalse $result.TimedOut
        Assert-QvwNotMatch ([string]$result.StdOut) 'stdout-fixture-secret'
        Assert-QvwNotMatch ([string]$result.StdErr) 'stderr-fixture-secret'
        Assert-QvwMatch ([string]$result.StdErr) '\[REDACTED\]'
    }

    It-Qvw 'preserves an argument containing spaces' {
        $command = Get-Command powershell.exe -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            $command = Get-Command pwsh.exe -ErrorAction Stop
        }
        $fixtureRoot = New-QvwTempDirectory
        $scriptPath = Join-Path $fixtureRoot 'echo-argument.ps1'
        [IO.File]::WriteAllText($scriptPath, 'param([string]$Value) [Console]::Out.Write($Value)')
        $result = Invoke-QvwCommand -FilePath $command.Source -ArgumentList @('-NoProfile', '-File', $scriptPath, 'hello from qvw') -WorkingDirectory $fixtureRoot -TimeoutSeconds 10 -Secrets @()
        Assert-QvwEqual $result.ExitCode 0
        Assert-QvwEqual ([string]$result.StdOut).Trim() 'hello from qvw'
    }

    It-Qvw 'preserves Windows backslashes quotes and a trailing slash in one argument' {
        $command = Get-Command powershell.exe -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            $command = Get-Command pwsh.exe -ErrorAction Stop
        }
        $fixtureRoot = New-QvwTempDirectory
        $scriptPath = Join-Path $fixtureRoot 'echo-argument.ps1'
        [IO.File]::WriteAllText($scriptPath, 'param([string]$Value) [Console]::Out.Write($Value)')
        $expected = 'C:\Program Files\QVW\a"b\trail\'
        $result = Invoke-QvwCommand -FilePath $command.Source -ArgumentList @('-NoProfile', '-File', $scriptPath, $expected) -WorkingDirectory $fixtureRoot -TimeoutSeconds 10 -Secrets @()
        Assert-QvwEqual $result.ExitCode 0
        Assert-QvwEqual ([string]$result.StdOut).Trim() $expected
    }

    It-Qvw 'reports and terminates a timed out process' {
        $command = Get-Command powershell.exe -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            $command = Get-Command pwsh.exe -ErrorAction Stop
        }
        $result = Invoke-QvwCommand -FilePath $command.Source -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 5') -WorkingDirectory (Get-Location).Path -TimeoutSeconds 1 -Secrets @()
        Assert-QvwTrue $result.TimedOut
        Assert-QvwFalse $result.Succeeded
    }
}
