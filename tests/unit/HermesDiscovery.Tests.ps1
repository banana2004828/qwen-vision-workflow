Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$adapterPath = Join-Path $repoRoot 'adapters\hermes\HermesAdapter.psm1'
Import-Module -Name $adapterPath -Force -ErrorAction Stop

Describe-Qvw 'Hermes discovery and credentials' {
    It-Qvw 'selects HERMES_HOME and reports competing roots' {
        $root = New-QvwTempDirectory
        try {
            $active = Join-Path $root 'active'
            $local = Join-Path $root 'local'
            $user = Join-Path $root 'user'
            [IO.Directory]::CreateDirectory((Join-Path $active 'bin')) | Out-Null
            [IO.Directory]::CreateDirectory((Join-Path $local 'hermes')) | Out-Null
            [IO.Directory]::CreateDirectory((Join-Path $user '.hermes')) | Out-Null
            [IO.File]::WriteAllText((Join-Path $active 'bin\hermes.cmd'), '@echo off')

            $fakeProbe = {
                param([string]$CliPath, [string[]]$Arguments, [string]$Root)
                $key = [string]::Join(' ', @($Arguments))
                if ($key -eq 'config path') { return (Join-Path $Root 'config.yaml') }
                if ($key -eq 'config env-path') { return (Join-Path $Root '.env') }
                if ($key -eq '--version') { return 'Hermes v0.20.4' }
                return ''
            }

            $found = Find-QvwHermes -Environment @{
                HERMES_HOME = $active
                LOCALAPPDATA = $local
                USERPROFILE = $user
                Path = ''
            } -Probe $fakeProbe

            Assert-QvwEqual $found.Home ([IO.Path]::GetFullPath($active))
            Assert-QvwEqual $found.ConfigPath (Join-Path ([IO.Path]::GetFullPath($active)) 'config.yaml')
            Assert-QvwEqual $found.EnvPath (Join-Path ([IO.Path]::GetFullPath($active)) '.env')
            Assert-QvwEqual $found.Version '0.20.4'
            Assert-QvwTrue ($found.Conflicts.Count -ge 2)
            Assert-QvwEqual ([IO.Path]::GetFileName($found.CliPath)) 'hermes.cmd'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }

    It-Qvw 'gives an explicit root precedence over HERMES_HOME and reports the displaced root' {
        $root = New-QvwTempDirectory
        try {
            $explicit = Join-Path $root 'explicit'
            $environmentHome = Join-Path $root 'environment'
            foreach ($candidate in @($explicit, $environmentHome)) {
                [IO.Directory]::CreateDirectory((Join-Path $candidate 'bin')) | Out-Null
                [IO.File]::WriteAllText((Join-Path $candidate 'bin\hermes.cmd'), '@echo off')
            }
            $fakeProbe = {
                param([string]$CliPath, [string[]]$Arguments, [string]$RootPath)
                $key = [string]::Join(' ', @($Arguments))
                if ($key -eq 'config path') { return (Join-Path $RootPath 'config.yaml') }
                if ($key -eq 'config env-path') { return (Join-Path $RootPath '.env') }
                if ($key -eq '--version') { return 'Hermes v0.20.4' }
                return ''
            }
            $found = Find-QvwHermes -ExplicitRoot $explicit -Environment @{ HERMES_HOME = $environmentHome } -Probe $fakeProbe
            Assert-QvwEqual $found.Selection 'explicit'
            Assert-QvwEqual $found.Home ([IO.Path]::GetFullPath($explicit))
            Assert-QvwTrue (@($found.Conflicts | Where-Object { $_.Root -eq ([IO.Path]::GetFullPath($environmentHome)) }).Count -ge 1)
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }

    It-Qvw 'returns exact capability booleans and requires the Alibaba provider marker' {
        $root = New-QvwTempDirectory
        try {
            $marker = Join-Path $root 'providers\alibaba.marker'
            [IO.Directory]::CreateDirectory((Split-Path -Parent $marker)) | Out-Null
            [IO.File]::WriteAllText($marker, 'provider=alibaba')
            $command = {
                param([string[]]$Arguments)
                $key = [string]::Join(' ', @($Arguments))
                $values = @{
                    'config get agent.image_input_mode' = 'auto'
                    'config get auxiliary.vision.provider' = 'alibaba'
                    'config get auxiliary.vision.model' = 'qwen3.7-plus'
                    'config get model' = 'deepseek-v4-pro'
                }
                $value = if ($values.ContainsKey($key)) { $values[$key] } else { '' }
                return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = $value; StdErr = ''; Error = $null }
            }
            $hermes = [pscustomobject][ordered]@{
                Home = $root
                CliPath = Join-Path $root 'bin\hermes.cmd'
                ProviderMarkerPath = $marker
                Command = $command
            }
            $capability = Test-QvwHermesCapability -Hermes $hermes
            Assert-QvwEqual $capability.ImageInputMode $true
            Assert-QvwEqual $capability.AuxiliaryVision $true
            Assert-QvwEqual $capability.AlibabaProvider $true
            Assert-QvwEqual $capability.Compatible $true

            Remove-Item -LiteralPath $marker -Force
            $withoutMarker = Test-QvwHermesCapability -Hermes $hermes
            Assert-QvwEqual $withoutMarker.AlibabaProvider $false
            Assert-QvwEqual $withoutMarker.Compatible $false
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }

    It-Qvw 'rejects a direct legacy CLI that disagrees with the source CLI' {
        $root = New-QvwTempDirectory
        try {
            $source = Join-Path $root 'bin\hermes.cmd'
            $legacy = Join-Path $root 'venv\Scripts\hermes.exe'
            [IO.Directory]::CreateDirectory((Split-Path -Parent $source)) | Out-Null
            [IO.Directory]::CreateDirectory((Split-Path -Parent $legacy)) | Out-Null
            [IO.File]::WriteAllText($source, '@echo off')
            [IO.File]::WriteAllText($legacy, 'legacy')
            $command = {
                param([string[]]$Arguments)
                $key = [string]::Join(' ', @($Arguments))
                $version = if ($key -eq '--version') { 'Hermes v0.19.0' } else { '' }
                return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = $version; StdErr = ''; Error = $null }
            }
            $hermes = [pscustomobject][ordered]@{
                Home = $root
                CliPath = $source
                LegacyCliPath = $legacy
                Command = $command
                Version = '0.20.4'
                LegacyVersion = '0.19.0'
            }
            $capability = Test-QvwHermesCapability -Hermes $hermes
            Assert-QvwEqual $capability.Compatible $false
            Assert-QvwMatch ([string]$capability.Reason) 'legacy'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }

    It-Qvw 'prefers process, machine, and user environment credentials before harness storage' {
        $old = [Environment]::GetEnvironmentVariable('DASHSCOPE_API_KEY', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('DASHSCOPE_API_KEY', 'fixture-process-secret', 'Process')
            $credential = Get-QvwDashScopeCredential -Hermes ([pscustomobject]@{}) -HarnessRoot (New-QvwTempDirectory)
            Assert-QvwEqual $credential.Source 'process'
            Assert-QvwTrue ($credential.SecureValue -is [securestring])
            Assert-QvwTrue ($null -eq $credential.PSObject.Properties['Plaintext'])
            Assert-QvwTrue ($credential.Fingerprint -like 'sha256:*')
        }
        finally {
            [Environment]::SetEnvironmentVariable('DASHSCOPE_API_KEY', $old, 'Process')
        }
    }

    It-Qvw 'reads an explicitly supplied harness credential file and never exposes plaintext' {
        $root = New-QvwTempDirectory
        try {
            $dsh = Join-Path $root '.dsh'
            [IO.Directory]::CreateDirectory($dsh) | Out-Null
            $path = Join-Path $dsh '.credentials.yaml'
            [IO.File]::WriteAllText($path, "DASHSCOPE_API_KEY: fixture-harness-secret`r`n")
            $old = [Environment]::GetEnvironmentVariable('DASHSCOPE_API_KEY', 'Process')
            [Environment]::SetEnvironmentVariable('DASHSCOPE_API_KEY', $null, 'Process')
            try {
                $credential = Get-QvwDashScopeCredential -Hermes ([pscustomobject]@{}) -HarnessCredentialPath $path
                Assert-QvwEqual $credential.Source 'harness-credentials'
                Assert-QvwTrue ($credential.SecureValue -is [securestring])
                Assert-QvwTrue ($null -eq $credential.PSObject.Properties['Plaintext'])
            }
            finally {
                [Environment]::SetEnvironmentVariable('DASHSCOPE_API_KEY', $old, 'Process')
            }
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }

    It-Qvw 'supports a HarnessRoot file compatibility path and the current user-level dsh credential path without guessing a repository child' {
        $root = New-QvwTempDirectory
        try {
            $explicitPath = Join-Path $root 'adapter-supplied.credentials.yaml'
            [IO.File]::WriteAllText($explicitPath, "DASHSCOPE_API_KEY: fixture-explicit-harness-secret`r`n")
            $userProfile = Join-Path $root 'user-profile'
            $userCredentialDirectory = Join-Path $userProfile '.dsh'
            [IO.Directory]::CreateDirectory($userCredentialDirectory) | Out-Null
            $userPath = Join-Path $userCredentialDirectory '.credentials.yaml'
            [IO.File]::WriteAllText($userPath, "DASHSCOPE_API_KEY: fixture-user-secret`r`n")
            $repoRoot = Join-Path $root 'harness-repository'
            [IO.Directory]::CreateDirectory($repoRoot) | Out-Null
            $repoChild = Join-Path $repoRoot '.dsh\.credentials.yaml'
            [IO.Directory]::CreateDirectory((Split-Path -Parent $repoChild)) | Out-Null
            [IO.File]::WriteAllText($repoChild, "DASHSCOPE_API_KEY: fixture-should-not-be-guessed`r`n")

            $old = [Environment]::GetEnvironmentVariable('DASHSCOPE_API_KEY', 'Process')
            [Environment]::SetEnvironmentVariable('DASHSCOPE_API_KEY', $null, 'Process')
            try {
                $compatibility = Get-QvwDashScopeCredential -Hermes ([pscustomobject]@{}) -HarnessRoot $explicitPath
                Assert-QvwEqual $compatibility.Source 'harness-credentials'
                Assert-QvwTrue ($compatibility.SecureValue -is [securestring])

                $userCredential = Get-QvwDashScopeCredential -Hermes ([pscustomobject]@{ UserProfile = $userProfile }) -HarnessRoot $repoRoot
                Assert-QvwEqual $userCredential.Source 'harness-credentials'
                Assert-QvwTrue ($userCredential.SecureValue -is [securestring])
                Assert-QvwNotMatch ($userCredential | ConvertTo-Json -Depth 8) 'fixture-should-not-be-guessed'
            }
            finally {
                [Environment]::SetEnvironmentVariable('DASHSCOPE_API_KEY', $old, 'Process')
            }
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }

    It-Qvw 'allows hidden prompt only when explicitly requested' {
        $profile = New-QvwTempDirectory
        $old = [Environment]::GetEnvironmentVariable('DASHSCOPE_API_KEY', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('DASHSCOPE_API_KEY', $null, 'Process')
            $prompt = {
                ConvertTo-SecureString 'fixture-prompt-secret' -AsPlainText -Force
            }
            $hermes = [pscustomobject]@{ Prompt = $prompt; UserProfile = $profile }
            $credential = Get-QvwDashScopeCredential -Hermes $hermes -HarnessRoot (New-QvwTempDirectory) -AllowPrompt
            Assert-QvwEqual $credential.Source 'prompt'
            Assert-QvwTrue ($credential.SecureValue -is [securestring])
            Assert-QvwTrue ($null -eq $credential.PSObject.Properties['Plaintext'])
        }
        finally {
            [Environment]::SetEnvironmentVariable('DASHSCOPE_API_KEY', $old, 'Process')
            Remove-Item -LiteralPath $profile -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }

    It-Qvw 'captures prompt streams and exceptions without returning credential-shaped output' {
        $profile = New-QvwTempDirectory
        $old = [Environment]::GetEnvironmentVariable('DASHSCOPE_API_KEY', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('DASHSCOPE_API_KEY', $null, 'Process')
            $prompt = {
                Write-Output 'DASHSCOPE_API_KEY=fixture-prompt-stream-secret'
                Write-Error 'Authorization: Bearer fixture-prompt-stream-secret'
                throw 'prompt failure fixture-prompt-stream-secret'
            }
            $hermes = [pscustomobject]@{ Prompt = $prompt; UserProfile = $profile }
            $credential = Get-QvwDashScopeCredential -Hermes $hermes -AllowPrompt
            Assert-QvwEqual $credential.Source 'prompt-failed'
            Assert-QvwTrue ($null -eq $credential.SecureValue)
            Assert-QvwNotMatch ($credential | ConvertTo-Json -Depth 8) 'fixture-prompt-stream-secret'
        }
        finally {
            [Environment]::SetEnvironmentVariable('DASHSCOPE_API_KEY', $old, 'Process')
            Remove-Item -LiteralPath $profile -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
}
