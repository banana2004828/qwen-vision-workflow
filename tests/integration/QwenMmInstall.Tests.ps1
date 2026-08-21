Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$adapterPath = Join-Path $repoRoot 'optional\qwen-mm\QwenMmAdapter.psm1'
Import-Module -Name $adapterPath -Force -ErrorAction Stop

function New-QvwQwenMmFixture {
    param([switch]$ConnectionFails, [switch]$DownloadHashFails)

    $root = New-QvwTempDirectory
    $configPath = Join-Path $root 'config.yaml'
    $skillDir = Join-Path $root 'skills\qwen-mm-plugins-api'
    [IO.Directory]::CreateDirectory($skillDir) | Out-Null
    [IO.File]::WriteAllText($configPath, "mcp_servers:`r`n  existing:`r`n    command: uvx`r`n")
    $skillPath = Join-Path $skillDir 'SKILL.md'
    [IO.File]::WriteAllText($skillPath, '# before`r`n')

    $state = @{ AddCalled = $false; TestCalled = $false; ReadbackCalled = $false; Args = @(); AddArgs = @(); InputText = $null; FirstInputText = $null; AddInputText = $null; InputCalls = 0; PromptMode = 'target'; UndoFails = $false; AddCancelled = $false; BadReadback = $false; AclFails = $false }
    $command = {
        param([string[]]$Arguments)
        $state['Args'] = @($Arguments)
        $key = [string]::Join(' ', @($Arguments))
        if ($key -eq 'mcp add --help') {
            return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = 'usage: mcp add'; StdErr = ''; Error = $null }
        }
        if ($key -eq 'mcp test qwen-mm-api') {
            $state['TestCalled'] = $true
            if ($ConnectionFails) {
                return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = 'Connection failed; 0 tools'; StdErr = ''; Error = $null }
            }
            return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = "Connected (123ms)`nTools discovered: 3"; StdErr = ''; Error = $null }
        }
        return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = 'ok'; StdErr = ''; Error = $null }
    }.GetNewClosure()

    $download = {
        param([string]$Url)
        $rel = $Url -replace '^.*?/src/capabilities/api/skill/', ''
        if ($rel -eq 'SKILL.md') { return [Text.Encoding]::UTF8.GetBytes("---`nname: qwen-mm-plugins-api`n---`n") }
        if ($rel -eq 'references/vision_chat.md') { return [Text.Encoding]::UTF8.GetBytes("# vision_chat`n") }
        return [Text.Encoding]::UTF8.GetBytes("# launcher`n")
    }.GetNewClosure()
    if ($DownloadHashFails) {
        $download = { param([string]$Url) return [Text.Encoding]::UTF8.GetBytes('tampered') }.GetNewClosure()
    }

    $lock = Get-Content -LiteralPath (Join-Path $repoRoot 'optional\qwen-mm\source-lock.json') -Raw | ConvertFrom-Json
    foreach ($sourceFile in @($lock.skillFiles)) {
        $rel = [string]$sourceFile.path
        $bytes = if ($rel -eq 'SKILL.md') {
            [Text.Encoding]::UTF8.GetBytes("---`nname: qwen-mm-plugins-api`n---`n")
        }
        elseif ($rel -eq 'references/vision_chat.md') {
            [Text.Encoding]::UTF8.GetBytes("# vision_chat`n")
        }
        else {
            [Text.Encoding]::UTF8.GetBytes("# launcher`n")
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $sourceFile.sha256 = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }

    $commandWithInput = {
        param([string[]]$Arguments, [AllowNull()][object]$InputText)
        $state['Args'] = @($Arguments)
        $state['InputText'] = $InputText
        $state['InputCalls'] = [int]$state['InputCalls'] + 1
        if ([int]$state['InputCalls'] -eq 1) { $state['FirstInputText'] = $InputText }
        $key = [string]::Join(' ', @($Arguments))
        if ($Arguments.Count -ge 3 -and $Arguments[0] -eq 'mcp' -and $Arguments[1] -eq 'add') {
            $state['AddArgs'] = @($Arguments)
            if ($Arguments -contains '--yes') {
                $state['AddCalled'] = $true
                return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = 'added'; StdErr = ''; Error = $null; InputSent = $false }
            }
            if ($null -eq $InputText) {
                if ($state['PromptMode'] -eq 'overwrite') { return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = 'Overwrite existing server? [y/N]'; StdErr = ''; Error = $null; InputSent = $false } }
                if ($state['PromptMode'] -eq 'auth') { return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = 'Authentication token:'; StdErr = ''; Error = $null; InputSent = $false } }
                if ($state['PromptMode'] -eq 'unknown') { return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = 'Continue with server registration?'; StdErr = ''; Error = $null; InputSent = $false } }
                if ($state['PromptMode'] -eq 'deceptive') { return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = ('Authentication token:' + [Environment]::NewLine + 'Enable all 3 tools? [Y/n/select]'); StdErr = ''; Error = $null; InputSent = $false } }
                if ($state['PromptMode'] -eq 'none') { return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = 'added'; StdErr = ''; Error = $null; InputSent = $false } }
                return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = 'Enable all 3 tools? [Y/n/select]'; StdErr = ''; Error = $null; InputSent = $false }
            }
            $state['AddInputText'] = $InputText
            $state['AddCalled'] = $true
            if ($state['AddCancelled']) { return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = 'Cancelled after prompt'; StdErr = ''; Error = $null; InputSent = $true } }
            return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = 'added'; StdErr = ''; Error = $null; InputSent = $true }
        }
        if ($key -eq 'mcp test qwen-mm-api') {
            $state['TestCalled'] = $true
            if ($ConnectionFails) { return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = 'Connection failed; 0 tools'; StdErr = ''; Error = $null; InputSent = $true } }
            return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = "Connected! Found 3 tool(s)"; StdErr = ''; Error = $null; InputSent = $true }
        }
        return [pscustomobject]@{ ExitCode = 0; Succeeded = $true; StdOut = 'ok'; StdErr = ''; Error = $null; InputSent = $true }
    }.GetNewClosure()

    $readback = {
        param([string]$Name)
        $state['ReadbackCalled'] = $true
        if ($state['BadReadback']) { return [pscustomobject]@{ Count = 2; ServerName = $Name; Command = 'uvx'; Args = @() } }
        return [pscustomobject]@{ Count = 1; ServerName = $Name; Command = 'uvx'; Args = @('--from', 'qwen-mm-plugins[api] @ git+https://github.com/QwenLM/Qwen-MM-Plugins.git@ef18102f374cf9465188081622222b284a823174', 'qwen-mm-plugins-api') }
    }.GetNewClosure()

    $applyAcl = { param($Path) return (-not $state['AclFails']) }.GetNewClosure()

    return [pscustomobject][ordered]@{
        Home = $root
        ConfigPath = $configPath
        QwenMmSkillPath = $skillDir
        QwenMmConfigPath = (Join-Path $root 'qwen-mm-plugins\config')
        UvxAvailable = $true
        McpAddSupported = $true
        NetworkCheck = { param($Url) return $true }
        Command = $command
        CommandWithInput = $commandWithInput
        McpReadback = $readback
        ApplyConfigAcl = $applyAcl
        Download = $download
        SourceLock = $lock
        TestMode = $true
        State = $state
        Cleanup = ({ Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null }).GetNewClosure()
    }
}

Describe-Qvw 'Optional Qwen-MM transactional installation' {
    It-Qvw 'backs up Skill and MCP config, registers one pinned server without a key argument, and connects' {
        $fixture = New-QvwQwenMmFixture
        try {
            $beforeConfig = [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.ConfigPath))
            $secret = ConvertTo-SecureString 'fixture-qwen-mm-secret' -AsPlainText -Force
            $result = Install-QvwQwenMm -Hermes $fixture -DashScopeKey $secret
            Assert-QvwEqual $result.status 'installed'
            Assert-QvwTrue (Test-Path -LiteralPath ([string]$result.evidence.receiptPath) -PathType Leaf)
            Assert-QvwTrue $fixture.State['AddCalled']
            Assert-QvwTrue $fixture.State['TestCalled']
            Assert-QvwTrue $fixture.State['ReadbackCalled']
            Assert-QvwTrue ([int]$fixture.State['InputCalls'] -ge 2)
            Assert-QvwTrue ($null -eq $fixture.State['FirstInputText'])
            Assert-QvwMatch ([string]$fixture.State['AddInputText']) '(?im)^y'
            Assert-QvwEqual ([string]$fixture.State['AddArgs'][0]) 'mcp'
            Assert-QvwEqual ([string]$fixture.State['AddArgs'][1]) 'add'
            Assert-QvwEqual ([string]$fixture.State['AddArgs'][5]) '--args'
            Assert-QvwNotMatch ([string]::Join(' ', $fixture.State['Args'])) '(?i)DASHSCOPE_API_KEY|fixture-qwen-mm-secret|--env'
            Assert-QvwEqual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.ConfigPath))) $beforeConfig
            Assert-QvwTrue (Test-Path -LiteralPath $fixture.QwenMmConfigPath -PathType Leaf)
            Assert-QvwMatch ([IO.File]::ReadAllText((Join-Path $fixture.QwenMmSkillPath 'SKILL.md'))) 'qwen-mm-plugins-api'
            Assert-QvwEqual $result.evidence.toolCount 3
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'rejects an exit-zero cancelled mcp add and rolls back the optional receipt' {
        $fixture = New-QvwQwenMmFixture
        try {
            $fixture.State['AddCancelled'] = $true
            $secret = ConvertTo-SecureString 'fixture-qwen-mm-cancel-secret' -AsPlainText -Force
            $result = Install-QvwQwenMm -Hermes $fixture -DashScopeKey $secret
            Assert-QvwEqual $result.status 'degraded'
            Assert-QvwEqual $result.evidence.rollback 'verified'
            Assert-QvwFalse $fixture.State['ReadbackCalled']
            Assert-QvwFalse (Test-Path -LiteralPath $fixture.QwenMmConfigPath -PathType Leaf)
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'blocks overwrite, authentication, unknown, and no-prompt responses without sending stdin' {
        foreach ($mode in @('overwrite', 'auth', 'unknown', 'deceptive', 'none')) {
            $fixture = New-QvwQwenMmFixture
            try {
                $fixture.State['PromptMode'] = $mode
                $secret = ConvertTo-SecureString ('fixture-qwen-mm-' + $mode + '-secret') -AsPlainText -Force
                $result = Install-QvwQwenMm -Hermes $fixture -DashScopeKey $secret
                Assert-QvwEqual $result.status 'degraded'
                Assert-QvwEqual $result.evidence.rollback 'verified'
                Assert-QvwFalse $fixture.State['AddCalled']
                Assert-QvwTrue ($null -eq $fixture.State['AddInputText'])
                Assert-QvwFalse $fixture.State['ReadbackCalled']
            }
            finally { & $fixture.Cleanup }
        }
    }

    It-Qvw 'uses an allowlisted official flag before args and never writes stdin' {
        $fixture = New-QvwQwenMmFixture
        try {
            $fixture | Add-Member -NotePropertyName McpAddNonInteractiveFlag -NotePropertyValue '--yes' -Force
            $secret = ConvertTo-SecureString 'fixture-qwen-mm-flag-secret' -AsPlainText -Force
            $result = Install-QvwQwenMm -Hermes $fixture -DashScopeKey $secret
            Assert-QvwEqual $result.status 'installed'
            Assert-QvwEqual $result.evidence.mcpAddInteraction 'official-flag'
            Assert-QvwTrue ($fixture.State['AddCalled'])
            Assert-QvwTrue ($null -eq $fixture.State['AddInputText'])
            $flagIndex = [array]::IndexOf([string[]]$fixture.State['AddArgs'], '--yes')
            $argsIndex = [array]::IndexOf([string[]]$fixture.State['AddArgs'], '--args')
            Assert-QvwTrue ($flagIndex -ge 0 -and $flagIndex -lt $argsIndex)
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'rejects a non-unique or mismatched mcp readback and rolls back' {
        $fixture = New-QvwQwenMmFixture
        try {
            $fixture.State['BadReadback'] = $true
            $secret = ConvertTo-SecureString 'fixture-qwen-mm-readback-secret' -AsPlainText -Force
            $result = Install-QvwQwenMm -Hermes $fixture -DashScopeKey $secret
            Assert-QvwEqual $result.status 'degraded'
            Assert-QvwEqual $result.evidence.rollback 'verified'
            Assert-QvwTrue $fixture.State['ReadbackCalled']
            Assert-QvwFalse (Test-Path -LiteralPath $fixture.QwenMmConfigPath -PathType Leaf)
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'rolls back when ACL protection cannot be applied to the persistent credential config' {
        $fixture = New-QvwQwenMmFixture
        try {
            $fixture.State['AclFails'] = $true
            $secret = ConvertTo-SecureString 'fixture-qwen-mm-acl-secret' -AsPlainText -Force
            $result = Install-QvwQwenMm -Hermes $fixture -DashScopeKey $secret
            Assert-QvwEqual $result.status 'degraded'
            Assert-QvwEqual $result.evidence.rollback 'verified'
            Assert-QvwFalse (Test-Path -LiteralPath $fixture.QwenMmConfigPath -PathType Leaf)
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'rolls back only the optional layer and returns degraded when MCP test exits zero but is not connected' {
        $fixture = New-QvwQwenMmFixture -ConnectionFails
        try {
            $beforeConfig = [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.ConfigPath))
            $beforeSkill = [IO.File]::ReadAllText((Join-Path $fixture.QwenMmSkillPath 'SKILL.md'))
            $secret = ConvertTo-SecureString 'fixture-qwen-mm-failure-secret' -AsPlainText -Force
            $result = Install-QvwQwenMm -Hermes $fixture -DashScopeKey $secret
            Assert-QvwEqual $result.status 'degraded'
            Assert-QvwEqual $result.evidence.rollback 'verified'
            Assert-QvwEqual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.ConfigPath))) $beforeConfig
            Assert-QvwEqual ([IO.File]::ReadAllText((Join-Path $fixture.QwenMmSkillPath 'SKILL.md'))) $beforeSkill
            Assert-QvwFalse (Test-Path -LiteralPath $fixture.QwenMmConfigPath -PathType Leaf)
            Assert-QvwFalse (Test-Path -LiteralPath (Join-Path $fixture.QwenMmSkillPath 'references') -PathType Container)
            Assert-QvwNotMatch ($result | ConvertTo-Json -Depth 8) 'fixture-qwen-mm-failure-secret'
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'rejects hash mismatch before writing or registering MCP' {
        $fixture = New-QvwQwenMmFixture -DownloadHashFails
        try {
            $before = Get-QvwTreeHash $fixture.Home
            $secret = ConvertTo-SecureString 'fixture-qwen-mm-hash-secret' -AsPlainText -Force
            $result = Install-QvwQwenMm -Hermes $fixture -DashScopeKey $secret
            Assert-QvwEqual $result.status 'blocked'
            Assert-QvwMatch $result.code 'HASH'
            Assert-QvwFalse $fixture.State['AddCalled']
            Assert-QvwEqual (Get-QvwTreeHash $fixture.Home) $before
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'requires explicit confirmation for live paid verification' {
        $fixture = New-QvwQwenMmFixture
        try {
            $result = Invoke-QvwQwenMmLiveVerify -Hermes $fixture -ImagePath (Join-Path $fixture.Home 'missing.png')
            Assert-QvwEqual $result.status 'blocked'
            Assert-QvwEqual $result.code 'QVW-QMM-PAID-CONFIRMATION-REQUIRED'
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'requires an explicit current receipt and does not scan timestamped backups' {
        $fixture = New-QvwQwenMmFixture
        try {
            $imagePath = Join-Path $fixture.Home 'fixture.png'
            [IO.File]::WriteAllBytes($imagePath, [byte[]](0, 1, 2))
            $fixture | Add-Member -NotePropertyName QwenMmLiveVerify -NotePropertyValue ({ param($Path) throw 'callback must not run without a receipt' }.GetNewClosure()) -Force
            $result = Invoke-QvwQwenMmLiveVerify -Hermes $fixture -ImagePath $imagePath -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'failed'
            Assert-QvwEqual $result.code 'QVW-QMM-RECEIPT-REQUIRED'
            Assert-QvwEqual ([string]$result.evidence.hermesNativePreserved) 'unknown'
            Assert-QvwNotMatch ([string]$result.message) '(?i)native vision remains preserved'
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'rejects a foreign receipt schema before live callback or rollback' {
        $fixture = New-QvwQwenMmFixture
        try {
            $secret = ConvertTo-SecureString 'fixture-qwen-mm-schema-secret' -AsPlainText -Force
            $installed = Install-QvwQwenMm -Hermes $fixture -DashScopeKey $secret
            Assert-QvwEqual $installed.status 'installed'
            $receiptPath = [string]$installed.evidence.receiptPath
            $receipt = [IO.File]::ReadAllText($receiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $receipt.evidence.serverName = 'foreign-server'
            [IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
            $imagePath = Join-Path $fixture.Home 'fixture.png'
            [IO.File]::WriteAllBytes($imagePath, [byte[]](0, 1, 2))
            $fixture | Add-Member -NotePropertyName QwenMmLiveVerify -NotePropertyValue ({ param($Path) throw 'callback must not run for a foreign receipt' }.GetNewClosure()) -Force
            $result = Invoke-QvwQwenMmLiveVerify -Hermes $fixture -ImagePath $imagePath -ReceiptPath $receiptPath -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'failed'
            Assert-QvwEqual $result.code 'QVW-QMM-RECEIPT-REQUIRED'
            Assert-QvwEqual ([string]$result.evidence.hermesNativePreserved) 'unknown'
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'rolls back the validated Qwen-MM receipt on confirmed live failure and preserves Hermes native vision' {
        $fixture = New-QvwQwenMmFixture
        try {
            $secret = ConvertTo-SecureString 'fixture-qwen-mm-live-secret' -AsPlainText -Force
            $installed = Install-QvwQwenMm -Hermes $fixture -DashScopeKey $secret
            Assert-QvwEqual $installed.status 'installed'
            $imagePath = Join-Path $fixture.Home 'fixture.png'
            [IO.File]::WriteAllBytes($imagePath, [byte[]](0, 1, 2))
            $fixture | Add-Member -NotePropertyName QwenMmLiveVerify -NotePropertyValue ({ param($Path) return [pscustomobject]@{ Accepted = $false; Text = 'wrong' } }.GetNewClosure()) -Force
            $result = Invoke-QvwQwenMmLiveVerify -Hermes $fixture -ImagePath $imagePath -ReceiptPath ([string]$installed.evidence.receiptPath) -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'degraded'
            Assert-QvwEqual $result.evidence.rollback 'verified'
            Assert-QvwTrue $result.evidence.hermesNativePreserved
            Assert-QvwEqual $result.evidence.nativeVisionRoute 'preserved'
            Assert-QvwEqual ([string](([IO.File]::ReadAllText([string]$installed.evidence.receiptPath) | ConvertFrom-Json).state)) 'rolled-back'
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'reports failed manual recovery when the validated Qwen-MM receipt rollback fails' {
        $fixture = New-QvwQwenMmFixture
        try {
            $secret = ConvertTo-SecureString 'fixture-qwen-mm-live-rollback-secret' -AsPlainText -Force
            $installed = Install-QvwQwenMm -Hermes $fixture -DashScopeKey $secret
            Assert-QvwEqual $installed.status 'installed'
            $imagePath = Join-Path $fixture.Home 'fixture.png'
            [IO.File]::WriteAllBytes($imagePath, [byte[]](0, 1, 2))
            $fixture.State['UndoFails'] = $true
            $fixture | Add-Member -NotePropertyName Undo -NotePropertyValue ({ param($Path) throw 'fixture rollback failure' }.GetNewClosure()) -Force
            $fixture | Add-Member -NotePropertyName QwenMmLiveVerify -NotePropertyValue ({ param($Path) throw 'fixture live failure' }.GetNewClosure()) -Force
            $result = Invoke-QvwQwenMmLiveVerify -Hermes $fixture -ImagePath $imagePath -ReceiptPath ([string]$installed.evidence.receiptPath) -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'failed'
            Assert-QvwEqual $result.evidence.rollback 'manual-recovery-required'
            Assert-QvwMatch $result.code 'ROLLBACK-FAILED'
            Assert-QvwEqual ([string]$result.evidence.hermesNativePreserved) 'unknown'
            Assert-QvwNotMatch ([string]$result.message) '(?i)native vision remains preserved'
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'preserves and reports a nonempty newly-created directory during receipt rollback' {
        $fixture = New-QvwQwenMmFixture
        try {
            $secret = ConvertTo-SecureString 'fixture-qwen-mm-directory-secret' -AsPlainText -Force
            $installed = Install-QvwQwenMm -Hermes $fixture -DashScopeKey $secret
            Assert-QvwEqual $installed.status 'installed'
            $references = Join-Path $fixture.QwenMmSkillPath 'references'
            $sentinel = Join-Path $references 'user-owned.txt'
            [IO.File]::WriteAllText($sentinel, 'keep')
            $result = Uninstall-QvwQwenMm -Hermes $fixture -ReceiptPath ([string]$installed.evidence.receiptPath)
            Assert-QvwEqual $result.status 'degraded'
            Assert-QvwTrue $result.evidence.cleanup.Verified
            Assert-QvwContains @($result.evidence.cleanup.PreservedNonEmpty) $references
            Assert-QvwTrue (Test-Path -LiteralPath $sentinel -PathType Leaf)
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'marks a directory deletion exception unverified and never claims native preservation' {
        $fixture = New-QvwQwenMmFixture
        try {
            $secret = ConvertTo-SecureString 'fixture-qwen-mm-delete-secret' -AsPlainText -Force
            $installed = Install-QvwQwenMm -Hermes $fixture -DashScopeKey $secret
            Assert-QvwEqual $installed.status 'installed'
            $fixture | Add-Member -NotePropertyName RemoveDirectory -NotePropertyValue ({ param($Path) return $false }.GetNewClosure()) -Force
            $result = Uninstall-QvwQwenMm -Hermes $fixture -ReceiptPath ([string]$installed.evidence.receiptPath)
            Assert-QvwEqual $result.status 'failed'
            Assert-QvwFalse $result.evidence.cleanup.Verified
            Assert-QvwEqual ([string]$result.evidence.hermesNativePreserved) 'unknown'
            Assert-QvwNotMatch ([string]$result.message) '(?i)native vision remains preserved'

            $again = Uninstall-QvwQwenMm -Hermes $fixture -ReceiptPath ([string]$installed.evidence.receiptPath)
            Assert-QvwEqual $again.status 'failed'
            Assert-QvwFalse $again.evidence.cleanup.Verified
            Assert-QvwEqual ([string]$again.evidence.hermesNativePreserved) 'unknown'
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'records and removes every newly-created parent in the receipt-backed directory plan' {
        $fixture = New-QvwQwenMmFixture
        try {
            $nestedSkill = Join-Path $fixture.Home 'fresh-parent\nested\skill\qwen-mm-plugins-api'
            $fixture | Add-Member -NotePropertyName QwenMmSkillPath -NotePropertyValue $nestedSkill -Force
            $secret = ConvertTo-SecureString 'fixture-qwen-mm-parent-chain-secret' -AsPlainText -Force
            $installed = Install-QvwQwenMm -Hermes $fixture -DashScopeKey $secret
            Assert-QvwEqual $installed.status 'installed'

            $receipt = [IO.File]::ReadAllText([string]$installed.evidence.receiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $plan = @($receipt.evidence.directoryPlan | ForEach-Object { [string]$_.relativePath })
            foreach ($relative in @(
                    'fresh-parent',
                    'fresh-parent/nested',
                    'fresh-parent/nested/skill',
                    'fresh-parent/nested/skill/qwen-mm-plugins-api',
                    'fresh-parent/nested/skill/qwen-mm-plugins-api/references',
                    'qwen-mm-plugins')) {
                Assert-QvwContains $plan $relative
            }

            $uninstalled = Uninstall-QvwQwenMm -Hermes $fixture -ReceiptPath ([string]$installed.evidence.receiptPath)
            Assert-QvwEqual $uninstalled.status 'degraded'
            Assert-QvwTrue $uninstalled.evidence.cleanup.Verified
            Assert-QvwFalse (Test-Path -LiteralPath (Join-Path $fixture.Home 'fresh-parent') -PathType Container)
            Assert-QvwFalse (Test-Path -LiteralPath (Join-Path $fixture.Home 'qwen-mm-plugins') -PathType Container)
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'does not false-green a second uninstall after incomplete directory cleanup' {
        $fixture = New-QvwQwenMmFixture
        try {
            $secret = ConvertTo-SecureString 'fixture-qwen-mm-retry-cleanup-secret' -AsPlainText -Force
            $installed = Install-QvwQwenMm -Hermes $fixture -DashScopeKey $secret
            Assert-QvwEqual $installed.status 'installed'

            $removeState = @{ Calls = 0 }
            $fixture | Add-Member -NotePropertyName RemoveDirectory -NotePropertyValue ({
                    param($Path)
                    $removeState['Calls'] = [int]$removeState['Calls'] + 1
                    if ([int]$removeState['Calls'] -eq 1) { return $false }
                    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
                    return $true
                }.GetNewClosure()) -Force

            $first = Uninstall-QvwQwenMm -Hermes $fixture -ReceiptPath ([string]$installed.evidence.receiptPath)
            Assert-QvwEqual $first.status 'failed'
            Assert-QvwFalse $first.evidence.cleanup.Verified
            $afterFirst = [IO.File]::ReadAllText([string]$installed.evidence.receiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            Assert-QvwEqual ([string]$afterFirst.state) 'rolled-back'
            Assert-QvwEqual ([string]$afterFirst.evidence.rollback) 'incomplete'
            Assert-QvwFalse $afterFirst.evidence.cleanup.Verified

            $second = Uninstall-QvwQwenMm -Hermes $fixture -ReceiptPath ([string]$installed.evidence.receiptPath)
            Assert-QvwEqual $second.status 'degraded'
            Assert-QvwEqual $second.code 'QVW-QMM-ROLLED-BACK'
            Assert-QvwTrue $second.evidence.cleanup.Verified
            Assert-QvwTrue ([int]$removeState['Calls'] -ge 2)
            $afterSecond = [IO.File]::ReadAllText([string]$installed.evidence.receiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            Assert-QvwEqual ([string]$afterSecond.evidence.rollback) 'complete'
            Assert-QvwTrue $afterSecond.evidence.cleanup.Verified
            Assert-QvwEqual @($afterSecond.evidence.cleanup.Failed).Count 0
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'redacts an arbitrary runtime credential from process output before returning it' {
        $module = Get-Module QwenMmAdapter
        $safe = & $module { Protect-QvwQwenMmProcessText -Text 'stdout fixture-qwen-mm-runtime-secret stderr' -Secrets @('fixture-qwen-mm-runtime-secret') }
        Assert-QvwNotMatch ([string]$safe) 'fixture-qwen-mm-runtime-secret'
        Assert-QvwMatch ([string]$safe) '\[REDACTED\]'
    }

    It-Qvw 'blocks before transaction when no secure inherited or persistent credential source exists' {
        $fixture = New-QvwQwenMmFixture
        try {
            $before = Get-QvwTreeHash $fixture.Home
            $result = Install-QvwQwenMm -Hermes $fixture
            Assert-QvwEqual $result.status 'blocked'
            Assert-QvwMatch $result.code 'CRED'
            Assert-QvwEqual (Get-QvwTreeHash $fixture.Home) $before
        }
        finally { & $fixture.Cleanup }
    }

    It-Qvw 'uninstalls strictly through the committed receipt' {
        $fixture = New-QvwQwenMmFixture
        try {
            $secret = ConvertTo-SecureString 'fixture-qwen-mm-uninstall-secret' -AsPlainText -Force
            $installed = Install-QvwQwenMm -Hermes $fixture -DashScopeKey $secret
            Assert-QvwEqual $installed.status 'installed'
            $uninstalled = Uninstall-QvwQwenMm -Hermes $fixture -ReceiptPath ([string]$installed.evidence.receiptPath)
            Assert-QvwEqual $uninstalled.status 'degraded'
            Assert-QvwEqual $uninstalled.code 'QVW-QMM-ROLLED-BACK'
            Assert-QvwMatch ([IO.File]::ReadAllText((Join-Path $fixture.QwenMmSkillPath 'SKILL.md'))) '# before'
        }
        finally { & $fixture.Cleanup }
    }
}
