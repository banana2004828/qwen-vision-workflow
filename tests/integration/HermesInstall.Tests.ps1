Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$adapterPath = Join-Path $repoRoot 'adapters\hermes\HermesAdapter.psm1'
Import-Module -Name $adapterPath -Force -ErrorAction Stop

function New-QvwHermesFixture {
    param([switch]$FailCheck)

    $root = New-QvwTempDirectory
    $configPath = Join-Path $root 'config.yaml'
    $envPath = Join-Path $root '.env'
    $skillPath = Join-Path $root 'skills\hermes-vision-setup\SKILL.md'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $skillPath)) | Out-Null
    [IO.File]::WriteAllText($configPath, (Get-Content -LiteralPath (Join-Path $repoRoot 'tests\fixtures\hermes\active\config.yaml') -Raw))
    [IO.File]::WriteAllText($envPath, (Get-Content -LiteralPath (Join-Path $repoRoot 'tests\fixtures\hermes\active\.env.example') -Raw))
    [IO.File]::WriteAllText($skillPath, '# legacy skill`r`n')
    $state = @{
        'model' = 'deepseek-v4-pro'
        'agent.image_input_mode' = 'off'
        'auxiliary.vision.provider' = 'none'
        'auxiliary.vision.model' = 'none'
        'tools.vision' = 'legacy-disabled'
    }
    $command = {
        param([string[]]$Arguments)
        $key = [string]::Join(' ', @($Arguments))
        if ($key -eq 'config check' -and $FailCheck -and $state.ContainsKey('__vision_write_started') -and [bool]$state['__vision_write_started']) {
            return [pscustomobject]@{ ExitCode = 1; Succeeded = $false; StdOut = ''; StdErr = 'fixture check failed'; Error = 'fixture check failed' }
        }
        if ($Arguments.Count -ge 4 -and $Arguments[0] -eq 'config' -and $Arguments[1] -eq 'set') {
            $state['__vision_write_started'] = $true
            $state[[string]$Arguments[2]] = [string]$Arguments[3]
            return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = 'ok'; StdErr = ''; Error = $null }
        }
        if ($Arguments.Count -ge 3 -and $Arguments[0] -eq 'config' -and $Arguments[1] -eq 'get') {
            $value = if ($state.ContainsKey([string]$Arguments[2])) { $state[[string]$Arguments[2]] } else { '' }
            if ([string]$Arguments[2] -eq 'model') {
                $value = "default: $value`r`nprovider: deepseek`r`nbase_url: https://api.deepseek.com/v1"
            }
            return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = $value; StdErr = ''; Error = $null }
        }
        return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = 'ok'; StdErr = ''; Error = $null }
    }.GetNewClosure()
    return [pscustomobject][ordered]@{
        Root = $root
        Home = $root
        CliPath = Join-Path $root 'bin\hermes.cmd'
        ConfigPath = $configPath
        EnvPath = $envPath
        SkillPath = $skillPath
        Version = '0.20.4'
        LegacyVersion = $null
        ProviderMarker = $true
        ProviderSupported = $null
        SchemaSupported = $null
        SourceVenvConflict = $false
        Conflicts = @()
        Undo = $null
        Command = $command
        State = $state
        Cleanup = ({ Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null }).GetNewClosure()
    }
}

Describe-Qvw 'Hermes transactional installation' {
    It-Qvw 'sets only the three vision keys and preserves the primary model byte-for-byte' {
        $fixture = New-QvwHermesFixture
        try {
            $beforeConfig = [IO.File]::ReadAllBytes($fixture.ConfigPath)
            $beforeSkill = [IO.File]::ReadAllBytes($fixture.SkillPath)
            $secret = ConvertTo-SecureString 'fixture-install-secret' -AsPlainText -Force
            $result = Install-QvwHermesVision -Hermes $fixture -DashScopeKey $secret -BaseUrl 'https://dashscope.aliyuncs.com/compatible-mode/v1'
            Assert-QvwEqual $result.status 'installed'
            Assert-QvwEqual $result.evidence.readback.model 'deepseek-v4-pro'
            Assert-QvwTrue (Test-Path -LiteralPath ([string]$result.evidence.receiptPath) -PathType Leaf)
            Assert-QvwEqual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.ConfigPath))) ([Convert]::ToBase64String($beforeConfig))
            Assert-QvwEqual $fixture.State['model'] 'deepseek-v4-pro'
            Assert-QvwEqual $fixture.State['agent.image_input_mode'] 'auto'
            Assert-QvwEqual $fixture.State['auxiliary.vision.provider'] 'alibaba'
            Assert-QvwEqual $fixture.State['auxiliary.vision.model'] 'qwen3.7-plus'
            Assert-QvwEqual $fixture.State['tools.vision'] 'legacy-disabled'
            Assert-QvwMatch ([IO.File]::ReadAllText($fixture.EnvPath)) 'DASHSCOPE_API_KEY=fixture-install-secret'
            Assert-QvwMatch ([IO.File]::ReadAllText($fixture.EnvPath)) 'DASHSCOPE_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1'
            Assert-QvwNotMatch ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.SkillPath))) ([regex]::Escape([Convert]::ToBase64String($beforeSkill)))
            Assert-QvwNotMatch ($result | ConvertTo-Json -Depth 8) 'fixture-install-secret'
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'rolls back config, env, and skill when config check fails' {
        $fixture = New-QvwHermesFixture -FailCheck
        try {
            $beforeConfig = [IO.File]::ReadAllBytes($fixture.ConfigPath)
            $beforeEnv = [IO.File]::ReadAllBytes($fixture.EnvPath)
            $beforeSkill = [IO.File]::ReadAllBytes($fixture.SkillPath)
            $secret = ConvertTo-SecureString 'fixture-failure-secret' -AsPlainText -Force
            $result = Install-QvwHermesVision -Hermes $fixture -DashScopeKey $secret -BaseUrl 'https://dashscope.aliyuncs.com/compatible-mode/v1'
            Assert-QvwEqual $result.status 'failed'
            Assert-QvwTrue ($null -ne $result.evidence.receiptPath)
            Assert-QvwEqual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.ConfigPath))) ([Convert]::ToBase64String($beforeConfig))
            Assert-QvwEqual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.EnvPath))) ([Convert]::ToBase64String($beforeEnv))
            Assert-QvwEqual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.SkillPath))) ([Convert]::ToBase64String($beforeSkill))
            Assert-QvwNotMatch ($result | ConvertTo-Json -Depth 8) 'fixture-failure-secret'
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'rejects null and empty DashScope credentials before creating a transaction' {
        $fixture = New-QvwHermesFixture
        try {
            $before = Get-QvwTreeHash -Path $fixture.Root
            $nullResult = Install-QvwHermesVision -Hermes $fixture -DashScopeKey $null -BaseUrl 'https://dashscope.aliyuncs.com/compatible-mode/v1'
            Assert-QvwEqual $nullResult.status 'blocked'
            Assert-QvwEqual $nullResult.code 'QVW-H-CRED-REQUIRED'
            Assert-QvwEqual (Get-QvwTreeHash -Path $fixture.Root) $before

            $empty = New-Object System.Security.SecureString
            $emptyResult = Install-QvwHermesVision -Hermes $fixture -DashScopeKey $empty -BaseUrl 'https://dashscope.aliyuncs.com/compatible-mode/v1'
            Assert-QvwEqual $emptyResult.status 'blocked'
            Assert-QvwEqual $emptyResult.code 'QVW-H-CRED-REQUIRED'
            Assert-QvwEqual (Get-QvwTreeHash -Path $fixture.Root) $before
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'reports rollback failure and preserves the safe receipt path for manual recovery' {
        $fixture = New-QvwHermesFixture -FailCheck
        try {
            $fixture.Undo = {
                param([string]$ReceiptPath)
                throw 'fixture-rollback-secret'
            }
            $secret = ConvertTo-SecureString 'fixture-rollback-secret' -AsPlainText -Force
            $result = Install-QvwHermesVision -Hermes $fixture -DashScopeKey $secret -BaseUrl 'https://dashscope.aliyuncs.com/compatible-mode/v1'
            Assert-QvwEqual $result.status 'failed'
            Assert-QvwEqual $result.code 'QVW-H-ROLLBACK-FAILED'
            Assert-QvwMatch $result.message '(?i)manual|recover'
            Assert-QvwTrue (Test-Path -LiteralPath ([string]$result.evidence.receiptPath) -PathType Leaf)
            Assert-QvwNotMatch ($result | ConvertTo-Json -Depth 8) 'fixture-rollback-secret'
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'blocks before transaction when the provider marker is unavailable' {
        $fixture = New-QvwHermesFixture
        try {
            $fixture.ProviderMarker = $false
            $before = Get-QvwTreeHash -Path $fixture.Root
            $secret = ConvertTo-SecureString 'fixture-provider-secret' -AsPlainText -Force
            $result = Install-QvwHermesVision -Hermes $fixture -DashScopeKey $secret -BaseUrl 'https://dashscope.aliyuncs.com/compatible-mode/v1'
            Assert-QvwEqual $result.status 'blocked'
            Assert-QvwEqual $result.code 'QVW-H-PREFLIGHT-BLOCKED'
            Assert-QvwEqual (Get-QvwTreeHash -Path $fixture.Root) $before
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'blocks before transaction when the active config check is unavailable' {
        $fixture = New-QvwHermesFixture
        try {
            $state = $fixture.State
            $fixture.Command = {
                param([string[]]$Arguments)
                $key = [string]::Join(' ', @($Arguments))
                if ($key -eq 'config check') {
                    return [pscustomobject]@{ ExitCode = 1; Succeeded = $false; StdOut = ''; StdErr = ''; Error = 'fixture-preflight-check-failed' }
                }
                if ($Arguments.Count -ge 4 -and $Arguments[0] -eq 'config' -and $Arguments[1] -eq 'set') {
                    $state[[string]$Arguments[2]] = [string]$Arguments[3]
                }
                if ($Arguments.Count -ge 3 -and $Arguments[0] -eq 'config' -and $Arguments[1] -eq 'get') {
                    $value = if ($state.ContainsKey([string]$Arguments[2])) { $state[[string]$Arguments[2]] } else { '' }
                    return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = $value; StdErr = ''; Error = $null }
                }
                return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = 'ok'; StdErr = ''; Error = $null }
            }.GetNewClosure()
            $before = Get-QvwTreeHash -Path $fixture.Root
            $secret = ConvertTo-SecureString 'fixture-check-secret' -AsPlainText -Force
            $result = Install-QvwHermesVision -Hermes $fixture -DashScopeKey $secret -BaseUrl 'https://dashscope.aliyuncs.com/compatible-mode/v1'
            Assert-QvwEqual $result.status 'blocked'
            Assert-QvwEqual $result.code 'QVW-H-PREFLIGHT-BLOCKED'
            Assert-QvwEqual (Get-QvwTreeHash -Path $fixture.Root) $before
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'does not treat an unset vision target as an unsupported schema' {
        $fixture = New-QvwHermesFixture
        try {
            $result = Test-QvwHermesDoctor -Hermes $fixture
            Assert-QvwEqual $result.status 'discovered'
            Assert-QvwEqual $result.code 'QVW-H-READY'
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'blocks before transaction when the source and legacy Hermes versions conflict' {
        $fixture = New-QvwHermesFixture
        try {
            $fixture.LegacyVersion = '0.19.0'
            $before = Get-QvwTreeHash -Path $fixture.Root
            $secret = ConvertTo-SecureString 'fixture-version-secret' -AsPlainText -Force
            $result = Install-QvwHermesVision -Hermes $fixture -DashScopeKey $secret -BaseUrl 'https://dashscope.aliyuncs.com/compatible-mode/v1'
            Assert-QvwEqual $result.status 'blocked'
            Assert-QvwEqual $result.code 'QVW-H-PREFLIGHT-BLOCKED'
            Assert-QvwEqual (Get-QvwTreeHash -Path $fixture.Root) $before
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'blocks before transaction when the schema capability is explicitly unavailable' {
        $fixture = New-QvwHermesFixture
        try {
            $fixture.SchemaSupported = $false
            $before = Get-QvwTreeHash -Path $fixture.Root
            $secret = ConvertTo-SecureString 'fixture-schema-secret' -AsPlainText -Force
            $result = Install-QvwHermesVision -Hermes $fixture -DashScopeKey $secret -BaseUrl 'https://dashscope.aliyuncs.com/compatible-mode/v1'
            Assert-QvwEqual $result.status 'blocked'
            Assert-QvwEqual $result.code 'QVW-H-PREFLIGHT-BLOCKED'
            Assert-QvwEqual (Get-QvwTreeHash -Path $fixture.Root) $before
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'doctor reports a blocked incompatible Hermes target without changing files' {
        $fixture = New-QvwHermesFixture
        try {
            $fixture.Command = {
                param([string[]]$Arguments)
                return [pscustomobject]@{ ExitCode = 1; Succeeded = $false; StdOut = ''; StdErr = ''; Error = 'unsupported' }
            }
            $result = Test-QvwHermesDoctor -Hermes $fixture
            Assert-QvwEqual $result.status 'blocked'
            Assert-QvwEqual $result.component 'hermes'
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'skill documents the current schema and forbids the legacy tools vision route' {
        $skillPath = Join-Path $repoRoot 'adapters\hermes\skill\hermes-vision-setup\SKILL.md'
        $referencePath = Join-Path $repoRoot 'adapters\hermes\skill\hermes-vision-setup\references\provider-quick-ref.md'
        $skill = Get-Content -LiteralPath $skillPath -Raw
        $reference = Get-Content -LiteralPath $referencePath -Raw
        Assert-QvwMatch $skill 'agent\.image_input_mode\s*[:=]\s*auto'
        Assert-QvwMatch $skill 'auxiliary\.vision'
        Assert-QvwMatch $skill 'provider\s*[:=]\s*alibaba'
        Assert-QvwMatch $skill 'model\s*[:=]\s*qwen3\.7-plus'
        Assert-QvwMatch $skill '(?i)Qwen-MM'
        Assert-QvwMatch $skill '(?i)doctor'
        Assert-QvwMatch $skill '(?i)verify'
        Assert-QvwMatch $skill '(?i)rollback'
        Assert-QvwMatch $skill '(?i)Never edit security-sensitive config inside a Hermes conversation\.'
        Assert-QvwNotMatch $skill 'tools\.vision\s*[:=]'
        Assert-QvwMatch $reference 'qwen3\.7-plus'
        Assert-QvwMatch $reference 'DASHSCOPE_BASE_URL'
    }
}
