Set-StrictMode -Version 2.0

function Protect-QvwProcessText {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,
        [string[]]$Secrets = @()
    )

    if ($null -eq $Text) {
        return $null
    }
    $redactor = Get-Command -Name Protect-QvwText -ErrorAction SilentlyContinue
    if ($redactor) {
        return Protect-QvwText -Text $Text -Secrets $Secrets
    }

    $result = $Text
    foreach ($secret in @($Secrets)) {
        if (-not [string]::IsNullOrEmpty([string]$secret)) {
            $result = $result.Replace([string]$secret, '[REDACTED]')
        }
    }
    $result = [regex]::Replace($result, '(?i)(authorization\s*:\s*bearer\s+)\S+', '$1[REDACTED]')
    $result = [regex]::Replace($result, '(?i)((?:api[-_ ]?key|access[-_ ]?token|secret|password|passwd|cookie)\s*[=:]\s*)\S+', '$1[REDACTED]')
    return $result
}

function ConvertTo-QvwProcessArgument {
    param([AllowEmptyString()][string]$Argument)

    if ($null -eq $Argument -or $Argument.Length -eq 0) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    # Windows CreateProcess receives one command-line string even when the
    # caller supplied an argument array. .NET Framework lacks ArgumentList, so
    # encode exactly by the CommandLineToArgvW/CRT rules: ordinary backslashes
    # remain single, backslashes before a quote are doubled plus one, and
    # trailing backslashes inside surrounding quotes are doubled.
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }
        if ($character -eq [char]34) {
            if ($backslashes -gt 0) {
                [void]$builder.Append((New-Object string ([char]92, ($backslashes * 2 + 1))))
            }
            else {
                [void]$builder.Append([char]92)
            }
            [void]$builder.Append([char]34)
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append((New-Object string ([char]92, $backslashes)))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append((New-Object string ([char]92, ($backslashes * 2))))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-QvwCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds = 30,
        [string[]]$Secrets = @()
    )

    $timeout = if ($TimeoutSeconds -le 0) { 30 } else { $TimeoutSeconds }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }

    $argumentListProperty = $startInfo.PSObject.Properties['ArgumentList']
    if ($null -ne $argumentListProperty) {
        foreach ($argument in @($ArgumentList)) {
            [void]$startInfo.ArgumentList.Add([string]$argument)
        }
    }
    else {
        $encodedArguments = @($ArgumentList | ForEach-Object { ConvertTo-QvwProcessArgument -Argument ([string]$_) })
        $startInfo.Arguments = [string]::Join(' ', $encodedArguments)
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $timedOut = $false
    $started = $false
    $stdout = ''
    $stderr = ''
    $errorText = $null
    $exitCode = -1
    try {
        try {
            $started = $process.Start()
            if (-not $started) {
                throw 'Process did not start.'
            }
        }
        catch {
            $errorText = Protect-QvwProcessText -Text $_.Exception.Message -Secrets $Secrets
            return [pscustomobject][ordered]@{
                FilePath = [IO.Path]::GetFileName($FilePath)
                ExitCode = -1
                Succeeded = $false
                TimedOut = $false
                StdOut = ''
                StdErr = ''
                Error = $errorText
            }
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($timeout * 1000)) {
            $timedOut = $true
            try {
                # The Boolean overload kills the child process tree on modern
                # runtimes; the fallback keeps PowerShell 5.1 compatible.
                $process.Kill($true)
            }
            catch {
                try { $process.Kill() } catch { }
            }
            try { $process.WaitForExit() } catch { }
        }
        try { $stdout = $stdoutTask.GetAwaiter().GetResult() } catch { $stdout = '' }
        try { $stderr = $stderrTask.GetAwaiter().GetResult() } catch { $stderr = '' }
        if ($process.HasExited) {
            $exitCode = $process.ExitCode
        }
    }
    catch {
        $errorText = Protect-QvwProcessText -Text $_.Exception.Message -Secrets $Secrets
    }
    finally {
        if ($process) {
            $process.Dispose()
        }
    }

    $safeStdOut = Protect-QvwProcessText -Text $stdout -Secrets $Secrets
    $safeStdErr = Protect-QvwProcessText -Text $stderr -Secrets $Secrets
    return [pscustomobject][ordered]@{
        FilePath = [IO.Path]::GetFileName($FilePath)
        ExitCode = $exitCode
        Succeeded = ($started -and -not $timedOut -and $exitCode -eq 0)
        TimedOut = $timedOut
        StdOut = $safeStdOut
        StdErr = $safeStdErr
        Error = $errorText
    }
}

Export-ModuleMember -Function Invoke-QvwCommand
