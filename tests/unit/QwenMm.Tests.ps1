Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$adapterPath = Join-Path $repoRoot 'optional\qwen-mm\QwenMmAdapter.psm1'
Import-Module -Name $adapterPath -Force -ErrorAction Stop

Describe-Qvw 'Optional Qwen-MM parser and immutable source lock' {
    It-Qvw 'rejects exit zero when MCP is not connected' {
        $result = ConvertFrom-QvwMcpTestOutput -ExitCode 0 -Text 'Connection failed; 0 tools'
        Assert-QvwFalse $result.Connected
        Assert-QvwEqual $result.ToolCount 0
    }

    It-Qvw 'requires Connected and a positive tool count' {
        $result = ConvertFrom-QvwMcpTestOutput -ExitCode 0 -Text "Connected`nTools: 3"
        Assert-QvwTrue $result.Connected
        Assert-QvwEqual $result.ToolCount 3
        Assert-QvwEqual $result.Reason 'connected'
    }

    It-Qvw 'parses every supported Hermes v0.20.4 positive tool-count format' {
        $variants = @(
            "Connected (123ms)`nTools discovered: 5",
            'Connected! Found 5 tools',
            'Connected! Found 5 tool(s)',
            "Connected`n5 tools",
            "Connected`nTools: 5"
        )
        foreach ($text in $variants) {
            $result = ConvertFrom-QvwMcpTestOutput -ExitCode 0 -Text $text
            Assert-QvwTrue $result.Connected
            Assert-QvwEqual $result.ToolCount 5
        }
    }

    It-Qvw 'rejects cancelled exit-zero MCP tests and zero tool counts' {
        $result = ConvertFrom-QvwMcpTestOutput -ExitCode 0 -Text 'Cancelled by user; Connected! Found 5 tools'
        Assert-QvwFalse $result.Connected
        Assert-QvwEqual $result.ToolCount 5
        Assert-QvwMatch $result.Reason 'cancel'
    }

    It-Qvw 'does not accept a positive count without a connected marker or a non-zero exit' {
        $notConnected = ConvertFrom-QvwMcpTestOutput -ExitCode 0 -Text 'Tools: 3; connection failed'
        Assert-QvwFalse $notConnected.Connected
        $badExit = ConvertFrom-QvwMcpTestOutput -ExitCode 1 -Text 'Connected`nTools: 3'
        Assert-QvwFalse $badExit.Connected
        Assert-QvwMatch $badExit.Reason 'exit'
    }

    It-Qvw 'loads a fixed upstream commit, raw Skill files, license and pinned MCP args' {
        $lockPath = Join-Path $repoRoot 'optional\qwen-mm\source-lock.json'
        $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        Assert-QvwEqual $lock.repository 'https://github.com/QwenLM/Qwen-MM-Plugins'
        Assert-QvwEqual $lock.tag 'qwen-mm-plugins-api-v1.0.1'
        Assert-QvwEqual $lock.tagObject '09fcc4e38ee1d359f714d17da7b4bb5acf61e9d7'
        Assert-QvwEqual $lock.commit 'ef18102f374cf9465188081622222b284a823174'
        Assert-QvwEqual $lock.capability 'api'
        Assert-QvwEqual $lock.packageVersion '1.0.1'
        Assert-QvwEqual $lock.license 'Apache-2.0'
        Assert-QvwEqual $lock.skillRawUrl 'https://raw.githubusercontent.com/QwenLM/Qwen-MM-Plugins/ef18102f374cf9465188081622222b284a823174/src/capabilities/api/skill/SKILL.md'
        Assert-QvwEqual (@($lock.skillFiles).Count) 3
        $expected = @{
            'SKILL.md' = 'b5e7f27707f6d0221dbb705da9e4615079a2f90ae36dacf193cbf0d99a331967'
            'references/vision_chat.md' = 'f402c7e9955652217174427711e3806c715b6301f9196c1b87055194b185ed19'
            'references/launch_sam3_server.py' = '12bf2a6d8a6dff6220a9c8442428cb241f68a544650406059078241c256ecfb9'
        }
        foreach ($file in @($lock.skillFiles)) {
            Assert-QvwEqual $file.rawUrl ('https://raw.githubusercontent.com/QwenLM/Qwen-MM-Plugins/ef18102f374cf9465188081622222b284a823174/src/capabilities/api/skill/' + $file.path)
            Assert-QvwEqual $file.sha256 $expected[[string]$file.path]
        }
        Assert-QvwEqual ([string]$lock.mcp.from) 'qwen-mm-plugins[api] @ git+https://github.com/QwenLM/Qwen-MM-Plugins.git@ef18102f374cf9465188081622222b284a823174'
        Assert-QvwEqual (@($lock.mcp.args).Count) 3
        Assert-QvwNotMatch (($lock | ConvertTo-Json -Depth 12)) '(?i)@(?:main|master|develop)'
    }

    It-Qvw 'refuses mutable source locks and invalid hashes before installation' {
        $lock = Get-Content -LiteralPath (Join-Path $repoRoot 'optional\qwen-mm\source-lock.json') -Raw | ConvertFrom-Json
        $mutable = $lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $mutable.skillFiles[0].rawUrl = $mutable.skillFiles[0].rawUrl -replace '/ef18102f374cf9465188081622222b284a823174/', '/main/'
        Assert-QvwThrows { Test-QvwQwenMmSourceLock -Lock $mutable } '*mutable*'

        $fakeCommit = $lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $fakeCommit.commit = ('a' * 40)
        Assert-QvwThrows { Test-QvwQwenMmSourceLock -Lock $fakeCommit } '*commit*'

        $duplicate = $lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $duplicate.skillFiles = @($duplicate.skillFiles) + $duplicate.skillFiles[0]
        Assert-QvwThrows { Test-QvwQwenMmSourceLock -Lock $duplicate } '*exactly*'

        $extra = $lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $extra.skillFiles[0].path = 'references/extra.md'
        Assert-QvwThrows { Test-QvwQwenMmSourceLock -Lock $extra } '*exactly*'
    }

    It-Qvw 'keeps a prerequisite check read-only and requires uvx, mcp add and network' {
        $root = New-QvwTempDirectory
        try {
            $before = Get-QvwTreeHash $root
            $hermes = [pscustomobject][ordered]@{
                Home = $root
                UvxAvailable = $true
                McpAddSupported = $true
                NetworkCheck = { param($Url) return $true }
            }
            $result = Test-QvwQwenMmPrerequisite -Hermes $hermes
            Assert-QvwEqual $result.status 'discovered'
            Assert-QvwEqual $before (Get-QvwTreeHash $root)

            $blocked = Test-QvwQwenMmPrerequisite -Hermes ([pscustomobject]@{ Home = $root; UvxAvailable = $false; McpAddSupported = $true; NetworkCheck = { $true } })
            Assert-QvwEqual $blocked.status 'blocked'
            Assert-QvwMatch $blocked.code 'UVX'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
}
