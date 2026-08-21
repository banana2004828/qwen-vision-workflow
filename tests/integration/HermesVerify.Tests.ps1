Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$adapterPath = Join-Path $repoRoot 'adapters\hermes\HermesAdapter.psm1'
$fixtureModulePath = Join-Path $repoRoot 'modules\Qvw.ImageFixture.psm1'
Import-Module -Name $fixtureModulePath -Force -ErrorAction Stop
Import-Module -Name $adapterPath -Force -ErrorAction Stop

function New-QvwHermesVerifyFixture {
    param(
        [scriptblock]$Command,
        [scriptblock]$AcpProbe = $null,
        [switch]$Timeout
    )

    $root = New-QvwTempDirectory
    $fixture = New-QvwImageFixture -Path (Join-Path $root 'qvw.png')
    $record = New-Object System.Collections.ArrayList
    if ($null -eq $Command) {
        $Command = {
            param([string[]]$Arguments)
            [void]$record.Add(@($Arguments))
            [pscustomobject][ordered]@{
                ExitCode = if ($Timeout) { -1 } else { 0 }
                Succeeded = (-not $Timeout)
                TimedOut = [bool]$Timeout
                StdOut = if ($Timeout) { '' } else { 'Image text: QVW-7319; red circle is left of blue square; green triangle is below red circle and blue square.' }
                StdErr = ''
                Error = $null
            }
        }.GetNewClosure()
    }
    return [pscustomobject][ordered]@{
        Home = $root
        CliPath = Join-Path $root 'bin\hermes.cmd'
        Command = $Command
        AcpProbe = $AcpProbe
        ActiveMainModel = 'deepseek-v4-pro'
        ImageFixture = $fixture
        Arguments = $record
        Cleanup = ({ Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null }).GetNewClosure()
    }
}

function New-QvwAcceptedAcpRoute {
    return [pscustomobject][ordered]@{
        auxiliary = [pscustomobject][ordered]@{
            task = 'vision'
            provider = 'alibaba'
            model = 'qwen3.7-plus'
            request_has_image = $true
        }
        main = [pscustomobject][ordered]@{
            before_has_image = $true
            after_has_image = $false
            after_has_visual_text_note = $true
        }
    }
}

Describe-Qvw 'Hermes headless image verification' {
    It-Qvw 'refuses paid verification without explicit confirmation' {
        $fixture = New-QvwHermesVerifyFixture
        try {
            $result = Invoke-QvwHermesLiveVerify -Hermes $fixture -ImagePath $fixture.ImageFixture.Path
            Assert-QvwEqual $result.status 'blocked'
            Assert-QvwEqual $result.code 'QVW-H-PAID-CONFIRMATION-REQUIRED'
            Assert-QvwEqual $fixture.Arguments.Count 0
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'passes the image invocation as an argument array and accepts only complete route evidence' {
        $fixture = New-QvwHermesVerifyFixture -AcpProbe {
            param([string]$ImagePath, [int]$TimeoutSeconds)
            return (New-QvwAcceptedAcpRoute)
        }
        try {
            $result = Invoke-QvwHermesLiveVerify -Hermes $fixture -ImagePath $fixture.ImageFixture.Path -ConfirmPaidCalls -TimeoutSeconds 9
            Assert-QvwEqual $result.status 'target-accepted'
            Assert-QvwEqual $result.code 'QVW-H-TARGET-ACCEPTED'
            Assert-QvwEqual $fixture.Arguments.Count 1
            $arguments = @($fixture.Arguments[0])
            Assert-QvwEqual $arguments[0] 'chat'
            Assert-QvwEqual $arguments[1] '-q'
            Assert-QvwEqual $arguments[3] '--image'
            Assert-QvwEqual $arguments[4] $fixture.ImageFixture.Path
            Assert-QvwEqual $arguments[5] '-Q'
            Assert-QvwEqual $arguments[6] '--ignore-rules'
            Assert-QvwEqual $arguments[7] '--source'
            Assert-QvwEqual $arguments[8] 'tool'
            Assert-QvwEqual $arguments[9] '--max-turns'
            Assert-QvwEqual $arguments[10] '1'
            Assert-QvwEqual $arguments[11] '--run-budget'
            Assert-QvwEqual $arguments[12] '9'
            Assert-QvwNotMatch ($result | ConvertTo-Json -Depth 8) 'data:image|DASHSCOPE_API_KEY|Authorization|red circle|green triangle'
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'does not accept a correct final answer when ACP route evidence is missing' {
        $fixture = New-QvwHermesVerifyFixture
        try {
            $result = Invoke-QvwHermesLiveVerify -Hermes $fixture -ImagePath $fixture.ImageFixture.Path -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'unverified'
            Assert-QvwEqual $result.code 'QVW-H-ROUTE-EVIDENCE-MISSING'
            Assert-QvwMatch ([string]$result.message) '(?i)auxiliary|main|route|boundary'
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'returns timeout failure without treating an interrupted command as acceptance' {
        $fixture = New-QvwHermesVerifyFixture -Timeout
        try {
            $result = Invoke-QvwHermesLiveVerify -Hermes $fixture -ImagePath $fixture.ImageFixture.Path -ConfirmPaidCalls -TimeoutSeconds 2
            Assert-QvwEqual $result.status 'failed'
            Assert-QvwEqual $result.code 'QVW-H-VERIFY-TIMEOUT'
            Assert-QvwEqual $fixture.Arguments.Count 1
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'does not accept route metadata with a changed main model' {
        $fixture = New-QvwHermesVerifyFixture -AcpProbe {
            param([string]$ImagePath, [int]$TimeoutSeconds)
            return (New-QvwAcceptedAcpRoute)
        }
        $fixture.ActiveMainModel = 'deepseek-v4-pro'
        $fixture.Command = {
            param([string[]]$Arguments)
            [void]$fixture.Arguments.Add(@($Arguments))
            $fixture.ActiveMainModel = 'different-model'
            return [pscustomobject][ordered]@{ ExitCode = 0; Succeeded = $true; TimedOut = $false; StdOut = 'QVW-7319 red circle left of blue square green triangle below'; StdErr = ''; Error = $null }
        }.GetNewClosure()
        try {
            $result = Invoke-QvwHermesLiveVerify -Hermes $fixture -ImagePath $fixture.ImageFixture.Path -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'unverified'
            Assert-QvwMatch ([string]$result.message) '(?i)main.*model|primary.*model'
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'does not accept a green triangle that is only below the red circle' {
        $fixture = New-QvwHermesVerifyFixture -AcpProbe {
            param([string]$ImagePath, [int]$TimeoutSeconds)
            return (New-QvwAcceptedAcpRoute)
        }
        $fixture.Command = {
            param([string[]]$Arguments)
            [void]$fixture.Arguments.Add(@($Arguments))
            return [pscustomobject][ordered]@{
                ExitCode = 0
                Succeeded = $true
                TimedOut = $false
                StdOut = 'QVW-7319; red circle is left of blue square; green triangle is below red circle.'
                StdErr = ''
                Error = $null
            }
        }.GetNewClosure()
        try {
            $result = Invoke-QvwHermesLiveVerify -Hermes $fixture -ImagePath $fixture.ImageFixture.Path -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'unverified' 'single-relation status'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowRedCircle $true 'red relation fact'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowBlueSquare $false 'blue relation fact'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowBoth $false 'both relation fact'
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'does not accept a green triangle that is only below the blue square' {
        $fixture = New-QvwHermesVerifyFixture -AcpProbe {
            param([string]$ImagePath, [int]$TimeoutSeconds)
            return (New-QvwAcceptedAcpRoute)
        }
        $fixture.Command = {
            param([string[]]$Arguments)
            [void]$fixture.Arguments.Add(@($Arguments))
            return [pscustomobject][ordered]@{
                ExitCode = 0
                Succeeded = $true
                TimedOut = $false
                StdOut = 'QVW-7319; red circle is left of blue square; green triangle is below blue square.'
                StdErr = ''
                Error = $null
            }
        }.GetNewClosure()
        try {
            $result = Invoke-QvwHermesLiveVerify -Hermes $fixture -ImagePath $fixture.ImageFixture.Path -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'unverified' 'single-relation status'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowRedCircle $false 'red relation fact'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowBlueSquare $true 'blue relation fact'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowBoth $false 'both relation fact'
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'rejects external PYTHONPATH route functions for an empty Hermes home' {
        $fixture = New-QvwHermesVerifyFixture
        $fakeRoot = Join-Path $fixture.Home 'external-pythonpath'
        $fakePackage = Join-Path $fakeRoot 'agent'
        $oldPythonPath = [Environment]::GetEnvironmentVariable('PYTHONPATH', 'Process')
        try {
            [IO.Directory]::CreateDirectory($fakePackage) | Out-Null
            [IO.File]::WriteAllText((Join-Path $fakePackage '__init__.py'), '')
            [IO.File]::WriteAllText((Join-Path $fakePackage 'image_routing.py'), @"
def probe_image_route(*args, **kwargs):
    return {'instrumentation_available': True, 'auxiliary': {'task': 'vision', 'provider': 'alibaba', 'model': 'qwen3.7-plus', 'request_has_image': True}, 'main': {'before_has_image': True, 'after_has_image': False, 'after_has_visual_text_note': True}}
"@)
            $emptyHermes = Join-Path $fixture.Home 'empty-hermes'
            [IO.Directory]::CreateDirectory($emptyHermes) | Out-Null
            $python = @(Get-Command python.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)[0]
            if ($null -eq $python) {
                $python = @(Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)[0]
            }
            if ($null -eq $python) {
                throw 'python executable is required for the external PYTHONPATH regression test'
            }

            [Environment]::SetEnvironmentVariable('PYTHONPATH', $fakeRoot, 'Process')
            $probeScript = Join-Path $repoRoot 'adapters\hermes\verify_acp_route.py'
            $raw = & $python.Source $probeScript --hermes-home $emptyHermes --image $fixture.ImageFixture.Path --timeout 2 2>$null
            $json = [string]::Join('', @($raw))
            $route = $json | ConvertFrom-Json

            Assert-QvwEqual $route.instrumentation_available $false 'external PYTHONPATH must not provide instrumentation'
        }
        finally {
            [Environment]::SetEnvironmentVariable('PYTHONPATH', $oldPythonPath, 'Process')
            & $fixture.Cleanup
        }
    }

    It-Qvw 'rejects below red but above blue as a contradictory relation' {
        $fixture = New-QvwHermesVerifyFixture -AcpProbe {
            param([string]$ImagePath, [int]$TimeoutSeconds)
            return (New-QvwAcceptedAcpRoute)
        }
        $fixture.Command = {
            param([string[]]$Arguments)
            [void]$fixture.Arguments.Add(@($Arguments))
            return [pscustomobject][ordered]@{
                ExitCode = 0
                Succeeded = $true
                TimedOut = $false
                StdOut = 'QVW-7319; red circle is left of blue square; green triangle is below red circle but above blue square.'
                StdErr = ''
                Error = $null
            }
        }.GetNewClosure()
        try {
            $result = Invoke-QvwHermesLiveVerify -Hermes $fixture -ImagePath $fixture.ImageFixture.Path -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'unverified' 'contradictory relation status'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowRedCircle $true 'red relation fact'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowBlueSquare $false 'blue contradiction fact'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowBoth $false 'both contradiction fact'
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'rejects below blue but above red as a contradictory relation' {
        $fixture = New-QvwHermesVerifyFixture -AcpProbe {
            param([string]$ImagePath, [int]$TimeoutSeconds)
            return (New-QvwAcceptedAcpRoute)
        }
        $fixture.Command = {
            param([string[]]$Arguments)
            [void]$fixture.Arguments.Add(@($Arguments))
            return [pscustomobject][ordered]@{
                ExitCode = 0
                Succeeded = $true
                TimedOut = $false
                StdOut = 'QVW-7319; red circle is left of blue square; green triangle is below blue square but above red circle.'
                StdErr = ''
                Error = $null
            }
        }.GetNewClosure()
        try {
            $result = Invoke-QvwHermesLiveVerify -Hermes $fixture -ImagePath $fixture.ImageFixture.Path -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'unverified' 'contradictory relation status'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowRedCircle $false 'red contradiction fact'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowBlueSquare $true 'blue relation fact'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowBoth $false 'both contradiction fact'
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'rejects an explicit not-below relation even with the other relation present' {
        $fixture = New-QvwHermesVerifyFixture -AcpProbe {
            param([string]$ImagePath, [int]$TimeoutSeconds)
            return (New-QvwAcceptedAcpRoute)
        }
        $fixture.Command = {
            param([string[]]$Arguments)
            [void]$fixture.Arguments.Add(@($Arguments))
            return [pscustomobject][ordered]@{
                ExitCode = 0
                Succeeded = $true
                TimedOut = $false
                StdOut = 'QVW-7319; red circle is left of blue square; green triangle is below red circle and is not below blue square.'
                StdErr = ''
                Error = $null
            }
        }.GetNewClosure()
        try {
            $result = Invoke-QvwHermesLiveVerify -Hermes $fixture -ImagePath $fixture.ImageFixture.Path -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'unverified' 'negative relation status'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowRedCircle $true 'red relation fact'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowBlueSquare $false 'blue negative fact'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowBoth $false 'both negative fact'
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'accepts two independent non-contradictory relation sentences' {
        $fixture = New-QvwHermesVerifyFixture -AcpProbe {
            param([string]$ImagePath, [int]$TimeoutSeconds)
            return (New-QvwAcceptedAcpRoute)
        }
        $fixture.Command = {
            param([string[]]$Arguments)
            [void]$fixture.Arguments.Add(@($Arguments))
            return [pscustomobject][ordered]@{
                ExitCode = 0
                Succeeded = $true
                TimedOut = $false
                StdOut = 'QVW-7319. The red circle is left of the blue square. The green triangle is below the red circle. The green triangle is below the blue square.'
                StdErr = ''
                Error = $null
            }
        }.GetNewClosure()
        try {
            $result = Invoke-QvwHermesLiveVerify -Hermes $fixture -ImagePath $fixture.ImageFixture.Path -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'target-accepted' 'independent relation status'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowBoth $true 'both independent relations'
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'accepts an explicit below-both clause' {
        $fixture = New-QvwHermesVerifyFixture -AcpProbe {
            param([string]$ImagePath, [int]$TimeoutSeconds)
            return (New-QvwAcceptedAcpRoute)
        }
        $fixture.Command = {
            param([string[]]$Arguments)
            [void]$fixture.Arguments.Add(@($Arguments))
            return [pscustomobject][ordered]@{
                ExitCode = 0
                Succeeded = $true
                TimedOut = $false
                StdOut = 'QVW-7319; red circle is left of blue square; green triangle is below both red circle and blue square.'
                StdErr = ''
                Error = $null
            }
        }.GetNewClosure()
        try {
            $result = Invoke-QvwHermesLiveVerify -Hermes $fixture -ImagePath $fixture.ImageFixture.Path -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'target-accepted' 'below-both status'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowBoth $true 'below-both fact'
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'accepts a strict dual below relation with a shared subject' {
        $fixture = New-QvwHermesVerifyFixture -AcpProbe {
            param([string]$ImagePath, [int]$TimeoutSeconds)
            return (New-QvwAcceptedAcpRoute)
        }
        $fixture.Command = {
            param([string[]]$Arguments)
            [void]$fixture.Arguments.Add(@($Arguments))
            return [pscustomobject][ordered]@{
                ExitCode = 0
                Succeeded = $true
                TimedOut = $false
                StdOut = 'QVW-7319; red circle is left of blue square; green triangle is below red circle and below blue square.'
                StdErr = ''
                Error = $null
            }
        }.GetNewClosure()
        try {
            $result = Invoke-QvwHermesLiveVerify -Hermes $fixture -ImagePath $fixture.ImageFixture.Path -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'target-accepted' 'strict-dual status'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowBoth $true 'strict-dual fact'
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'lets a suffix not-below contradiction override a positive relation' {
        $fixture = New-QvwHermesVerifyFixture -AcpProbe {
            param([string]$ImagePath, [int]$TimeoutSeconds)
            return (New-QvwAcceptedAcpRoute)
        }
        $fixture.Command = {
            param([string[]]$Arguments)
            [void]$fixture.Arguments.Add(@($Arguments))
            return [pscustomobject][ordered]@{
                ExitCode = 0
                Succeeded = $true
                TimedOut = $false
                StdOut = 'QVW-7319; red circle is left of blue square; green triangle is below red circle and is below blue square but is not below blue square.'
                StdErr = ''
                Error = $null
            }
        }.GetNewClosure()
        try {
            $result = Invoke-QvwHermesLiveVerify -Hermes $fixture -ImagePath $fixture.ImageFixture.Path -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'unverified' 'suffix contradiction status'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowRedCircle $true 'suffix red fact'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowBlueSquare $false 'suffix blue fact'
            Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowBoth $false 'suffix both fact'
        }
        finally {
            & $fixture.Cleanup
        }
    }

    It-Qvw 'rejects contradictions that appear after an explicit below-both claim' {
        $contradictoryTexts = @(
            'QVW-7319. Red circle is left of blue square. Green triangle is below both red circle and blue square but not below blue square.',
            'QVW-7319. Red circle is left of blue square. Green triangle is below both red circle and blue square but above blue square.',
            'QVW-7319. Red circle is left of blue square. Green triangle is below red circle and below blue square. It is above blue square.'
        )
        foreach ($text in $contradictoryTexts) {
            $fixture = New-QvwHermesVerifyFixture -AcpProbe {
                param([string]$ImagePath, [int]$TimeoutSeconds)
                return (New-QvwAcceptedAcpRoute)
            }
            $currentText = $text
            $fixture.Command = {
                param([string[]]$Arguments)
                [void]$fixture.Arguments.Add(@($Arguments))
                return [pscustomobject][ordered]@{
                    ExitCode = 0
                    Succeeded = $true
                    TimedOut = $false
                    StdOut = $currentText
                    StdErr = ''
                    Error = $null
                }
            }.GetNewClosure()
            try {
                $result = Invoke-QvwHermesLiveVerify -Hermes $fixture -ImagePath $fixture.ImageFixture.Path -ConfirmPaidCalls
                Assert-QvwEqual $result.status 'unverified' 'post-claim contradiction status'
                Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowBlueSquare $false 'post-claim blue contradiction fact'
                Assert-QvwEqual $result.evidence.responseFacts.GreenTriangleBelowBoth $false 'post-claim both contradiction fact'
            }
            finally {
                & $fixture.Cleanup
            }
        }
    }

    It-Qvw 'does not accept configured Alibaba when the observed route is another provider' {
        $fixture = New-QvwHermesVerifyFixture -AcpProbe {
            param([string]$ImagePath, [int]$TimeoutSeconds)
            $route = New-QvwAcceptedAcpRoute
            $route.auxiliary.provider = 'openrouter'
            return $route
        }
        try {
            $result = Invoke-QvwHermesLiveVerify -Hermes $fixture -ImagePath $fixture.ImageFixture.Path -ConfirmPaidCalls
            Assert-QvwEqual $result.status 'unverified' 'observed provider status'
            Assert-QvwContains $result.evidence.missingBoundaries 'auxiliary-provider-alibaba'
        }
        finally {
            & $fixture.Cleanup
        }
    }
}
