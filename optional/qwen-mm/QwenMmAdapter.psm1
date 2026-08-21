Set-StrictMode -Version 2.0

$script:QvwQwenMmServerName = 'qwen-mm-api'
$script:QvwQwenMmLockPath = Join-Path $PSScriptRoot 'source-lock.json'

# PowerShell scriptblocks cannot safely run on a .NET worker thread without a
# Runspace (notably on Windows PowerShell 5.1).  This tiny managed reader keeps
# the interactive prompt path genuinely incremental on both PS5 and PS7.
if ($null -eq ('QvwQwenMmRuntime.PipeBuffer' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace QvwQwenMmRuntime {
    public sealed class PipeBuffer {
        internal readonly ConcurrentQueue<string> Queue = new ConcurrentQueue<string>();
        private readonly object Gate = new object();
        private int _characters;
        public bool Overflowed { get; private set; }

        public bool Enqueue(string value, int limit) {
            if (String.IsNullOrEmpty(value)) return true;
            lock (Gate) {
                if (_characters + value.Length > limit) { Overflowed = true; return false; }
                _characters += value.Length;
                Queue.Enqueue(value);
                return true;
            }
        }

        public bool TryDequeue(out string value) { return Queue.TryDequeue(out value); }
    }

    public static class PipeReader {
        public static Task Start(Stream stream, PipeBuffer buffer, int limit) {
            return Task.Factory.StartNew(() => Read(stream, buffer, limit), TaskCreationOptions.LongRunning);
        }

        private static void Read(Stream stream, PipeBuffer buffer, int limit) {
            try {
                using (stream) {
                    byte[] bytes = new byte[2048];
                    int count;
                    while ((count = stream.Read(bytes, 0, bytes.Length)) > 0) {
                        if (!buffer.Enqueue(Encoding.UTF8.GetString(bytes, 0, count), limit)) break;
                    }
                }
            } catch { }
        }
    }
}
'@ -ErrorAction Stop
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$dependencyMap = @{
    'Qvw.Result.psm1' = 'New-QvwResult'
    'Qvw.Process.psm1' = 'Invoke-QvwCommand'
    'Qvw.State.psm1' = 'Start-QvwTransaction'
}
foreach ($dependency in @('Qvw.Result.psm1', 'Qvw.Process.psm1', 'Qvw.State.psm1')) {
    $dependencyPath = Join-Path $repoRoot (Join-Path 'modules' $dependency)
    $commandName = [string]$dependencyMap[$dependency]
    if ((Test-Path -LiteralPath $dependencyPath -PathType Leaf) -and $null -eq (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
        Import-Module -Name $dependencyPath -Force -ErrorAction Stop
    }
}

function Get-QvwQwenMmProperty {
    param($Object, [string]$Name, $Default = $null)

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function ConvertFrom-QvwMcpTestOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [AllowNull()][AllowEmptyString()][string]$Text
    )

    $safeText = if ($null -eq $Text) { '' } else { [string]$Text }
    $toolCount = 0
    $countPatterns = @(
        '(?im)\btools?\s+discovered\s*:\s*(?<n>\d+)',
        '(?im)\bfound\s+(?<n>\d+)\s+(?:tools?|tool\(s\))\b',
        '(?im)\b(?<n>\d+)\s+(?:tools?|tool\(s\))\b',
        '(?im)\btools?\s*[:=]\s*(?<n>\d+)\b',
        '(?im)\btoolcount\s*[:=]\s*(?<n>\d+)\b'
    )
    foreach ($pattern in $countPatterns) {
        foreach ($match in @([regex]::Matches($safeText, $pattern))) {
            try {
                $candidate = [int]$match.Groups['n'].Value
                if ($candidate -gt $toolCount) { $toolCount = $candidate }
            }
            catch { }
        }
    }
    if ($toolCount -lt 0) { $toolCount = 0 }

    $hasConnected = [regex]::IsMatch($safeText, '(?im)(?<!not\s)(?<!failed\s)(?<!connection\s)\bconnected\b')
    $hasFailure = [regex]::IsMatch($safeText, '(?im)\b(?:connection\s+failed|failed\s+to\s+connect|not\s+connected|disconnected|cancelled|canceled|eof|aborted|error)\b')
    $connected = ($ExitCode -eq 0 -and $hasConnected -and -not $hasFailure -and $toolCount -gt 0)
    $reason = 'not-connected'
    if ($ExitCode -ne 0) { $reason = 'exit-code-{0}' -f $ExitCode }
    elseif ($hasFailure -and $safeText -match '(?im)\b(?:cancelled|canceled|eof|aborted)\b') { $reason = 'cancelled' }
    elseif ($hasFailure) { $reason = 'connection-failed' }
    elseif (-not $hasConnected) { $reason = 'connected-marker-missing' }
    elseif ($toolCount -le 0) { $reason = 'tool-count-missing-or-zero' }
    elseif ($connected) { $reason = 'connected' }

    return [pscustomobject][ordered]@{
        Connected = [bool]$connected
        ToolCount = [int]$toolCount
        Reason = $reason
    }
}

function Test-QvwQwenMmSafeRelativePath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ([IO.Path]::IsPathRooted($Path) -or $Path -match '^[\\/]' -or $Path -match ':') { return $false }
    if ($Path -match '(?i)(^|[\\/])\.\.([\\/]|$)') { return $false }
    return $true
}

function Get-QvwQwenMmSourceLock {
    param($Hermes = $null)

    $override = Get-QvwQwenMmProperty -Object $Hermes -Name 'SourceLock'
    $testMode = Get-QvwQwenMmProperty -Object $Hermes -Name 'TestMode'
    if ($null -ne $override -and [bool]$testMode) { return $override }
    if (-not (Test-Path -LiteralPath $script:QvwQwenMmLockPath -PathType Leaf)) {
        throw 'Qwen-MM source lock is missing.'
    }
    try {
        return [IO.File]::ReadAllText($script:QvwQwenMmLockPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw 'Qwen-MM source lock is invalid.'
    }
}

function Test-QvwQwenMmSourceLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Lock,
        [switch]$AllowTestOverride
    )

    $officialRepository = 'https://github.com/QwenLM/Qwen-MM-Plugins'
    $officialTag = 'qwen-mm-plugins-api-v1.0.1'
    $officialTagObject = '09fcc4e38ee1d359f714d17da7b4bb5acf61e9d7'
    $officialCommit = 'ef18102f374cf9465188081622222b284a823174'
    $rawPrefix = 'https://raw.githubusercontent.com/QwenLM/Qwen-MM-Plugins/' + $officialCommit + '/src/capabilities/api/skill/'
    $expectedHashes = @{
        'SKILL.md' = 'b5e7f27707f6d0221dbb705da9e4615079a2f90ae36dacf193cbf0d99a331967'
        'references/vision_chat.md' = 'f402c7e9955652217174427711e3806c715b6301f9196c1b87055194b185ed19'
        'references/launch_sam3_server.py' = '12bf2a6d8a6dff6220a9c8442428cb241f68a544650406059078241c256ecfb9'
    }
    $expectedFrom = 'qwen-mm-plugins[api] @ git+https://github.com/QwenLM/Qwen-MM-Plugins.git@' + $officialCommit

    foreach ($required in @('repository', 'tag', 'commit', 'capability', 'packageVersion', 'license', 'skillRawUrl', 'skillFiles', 'mcp')) {
        if ($null -eq $Lock.PSObject.Properties[$required]) { throw 'Source lock is incomplete.' }
    }
    if ([string]$Lock.repository -ne $officialRepository) { throw 'Source lock repository is not official.' }
    if ([string]$Lock.tag -ne $officialTag) { throw 'Source lock tag is mutable or unsupported.' }
    if ([string]$Lock.commit -ne $officialCommit) { throw 'Source lock commit is not the verified peeled tag commit.' }
    if ($null -eq $Lock.PSObject.Properties['tagObject'] -or [string]$Lock.tagObject -ne $officialTagObject) { throw 'Source lock tag object is not the verified annotated tag.' }
    if ([string]$Lock.capability -ne 'api' -or [string]$Lock.packageVersion -ne '1.0.1') { throw 'Source lock capability or package version is unsupported.' }
    if ([string]$Lock.license -ne 'Apache-2.0') { throw 'Source lock license is not Apache-2.0.' }
    if ([string]$Lock.skillRawUrl -ne ($rawPrefix + 'SKILL.md')) { throw 'Source lock Skill URL is mutable or does not match the verified commit.' }

    $files = @($Lock.skillFiles)
    if ($files.Count -ne 3) { throw 'Source lock must contain exactly three Skill files.' }
    $seenPaths = @{}
    $seenUrls = @{}
    $seenHashes = @{}
    foreach ($file in $files) {
        foreach ($required in @('path', 'rawUrl', 'sha256')) {
            if ($null -eq $file.PSObject.Properties[$required]) { throw 'Source lock Skill file entry is incomplete.' }
        }
        if (-not (Test-QvwQwenMmSafeRelativePath -Path ([string]$file.path))) { throw 'Source lock Skill path is unsafe.' }
        if ([string]$file.sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'Source lock Skill hash is invalid.' }
        $path = [string]$file.path
        $url = [string]$file.rawUrl
        $hash = ([string]$file.sha256).ToLowerInvariant()
        if (-not $expectedHashes.ContainsKey($path)) { throw 'Source lock must contain exactly the verified Skill paths.' }
        if ($seenPaths.ContainsKey($path) -or $seenUrls.ContainsKey($url) -or $seenHashes.ContainsKey($hash)) { throw 'Source lock Skill files contain duplicate path, URL, or hash.' }
        $seenPaths[$path] = $true
        $seenUrls[$url] = $true
        $seenHashes[$hash] = $true
        if ($url -ne ($rawPrefix + $path)) { throw 'Source lock Skill URL is mutable or does not match the verified commit.' }
        if (-not $AllowTestOverride -and $hash -ne $expectedHashes[$path]) { throw 'Source lock Skill hash does not match the verified official raw bytes.' }
    }
    foreach ($path in @($expectedHashes.Keys)) { if (-not $seenPaths.ContainsKey($path)) { throw 'Source lock is missing a verified Skill path.' } }

    $mcp = $Lock.mcp
    foreach ($required in @('serverName', 'command', 'from', 'args')) {
        if ($null -eq $mcp.PSObject.Properties[$required]) { throw 'Source lock MCP entry is incomplete.' }
    }
    if ([string]$mcp.serverName -ne $script:QvwQwenMmServerName -or [string]$mcp.command -ne 'uvx') { throw 'Source lock MCP identity is unsupported.' }
    if ([string]$mcp.from -ne $expectedFrom) { throw 'Source lock MCP source is mutable or not commit-pinned.' }
    $mcpArgs = @($mcp.args)
    if ($mcpArgs.Count -ne 3 -or $mcpArgs[0] -ne '--from' -or [string]$mcpArgs[1] -ne [string]$mcp.from -or [string]$mcpArgs[2] -ne 'qwen-mm-plugins-api') { throw 'Source lock MCP arguments are invalid.' }
    if ([string]::Join(' ', $mcpArgs) -match '(?i)--env|DASHSCOPE_API_KEY|=main\b') { throw 'Source lock MCP arguments contain an unsafe or mutable value.' }
    return $true
}

function Get-QvwQwenMmLockEvidence {
    param($Lock)

    return [ordered]@{
        tag = [string]$Lock.tag
        commit = [string]$Lock.commit
        capability = [string]$Lock.capability
        packageVersion = [string]$Lock.packageVersion
        license = [string]$Lock.license
    }
}

function ConvertTo-QvwQwenMmBytes {
    param($Value)

    if ($Value -is [byte[]]) { return ,$Value }
    if ($Value -is [string]) { return ,([Text.Encoding]::UTF8.GetBytes([string]$Value)) }
    $items = @($Value)
    if ($items.Count -gt 0 -and @($items | Where-Object { $_ -isnot [byte] }).Count -eq 0) {
        return ,([byte[]]$items)
    }
    $bytesProperty = $Value.PSObject.Properties['Bytes']
    if ($null -ne $bytesProperty) { return (ConvertTo-QvwQwenMmBytes -Value $bytesProperty.Value) }
    throw 'Downloaded source was not bytes or text.'
}

function Get-QvwQwenMmSourceBytes {
    param($Hermes, [string]$Url)

    $download = Get-QvwQwenMmProperty -Object $Hermes -Name 'Download'
    if ($download -is [scriptblock]) {
        $raw = @(& $download $Url)
        if ($raw.Count -eq 1) { return (ConvertTo-QvwQwenMmBytes -Value $raw[0]) }
        return (ConvertTo-QvwQwenMmBytes -Value $raw)
    }
    $client = New-Object Net.WebClient
    try { return ,$client.DownloadData($Url) }
    finally { $client.Dispose() }
}

function Get-QvwQwenMmBytesSha256 {
    param([byte[]]$Bytes)

    $sha = $null
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { if ($sha) { $sha.Dispose() } }
}

function Invoke-QvwQwenMmCommand {
    param($Hermes, [string[]]$Arguments, [int]$TimeoutSeconds = 60)

    $command = Get-QvwQwenMmProperty -Object $Hermes -Name 'Command'
    if ($command -is [scriptblock]) {
        try {
            $raw = @(& $command -Arguments @($Arguments))
            if ($raw.Count -eq 0) { return [pscustomobject][ordered]@{ ExitCode = -1; Succeeded = $false; StdOut = ''; StdErr = ''; Error = 'No command result.' } }
            $last = $raw[$raw.Count - 1]
            if ($last.PSObject.Properties['ExitCode'] -and $last.PSObject.Properties['Succeeded']) { return $last }
            return [pscustomobject][ordered]@{ ExitCode = 0; Succeeded = $true; StdOut = [string]$last; StdErr = ''; Error = $null }
        }
        catch { return [pscustomobject][ordered]@{ ExitCode = -1; Succeeded = $false; StdOut = ''; StdErr = ''; Error = 'Hermes command failed.' } }
    }
    $cli = [string](Get-QvwQwenMmProperty -Object $Hermes -Name 'CliPath')
    $work = [string](Get-QvwQwenMmProperty -Object $Hermes -Name 'Home')
    if ([string]::IsNullOrWhiteSpace($cli)) { return [pscustomobject][ordered]@{ ExitCode = -1; Succeeded = $false; StdOut = ''; StdErr = ''; Error = 'Hermes CLI is unavailable.' } }
    return (Invoke-QvwCommand -FilePath $cli -ArgumentList $Arguments -WorkingDirectory $work -TimeoutSeconds $TimeoutSeconds -Secrets @())
}

function Protect-QvwQwenMmProcessText {
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [string[]]$Secrets = @()
    )

    if ($null -eq $Text) { return '' }
    $safe = [string]$Text
    # Use the repository-wide redactor when it is available, but also perform
    # an exact replacement here.  Qwen/DashScope credentials are not required
    # to match a provider-specific shape, so the exact secret is the security
    # boundary for this process output.
    $redactor = Get-Command -Name Protect-QvwText -ErrorAction SilentlyContinue
    if ($redactor) {
        try { $safe = Protect-QvwText -Text $safe -Secrets @($Secrets) } catch { }
    }
    foreach ($secret in @($Secrets)) {
        if (-not [string]::IsNullOrEmpty([string]$secret)) {
            $safe = $safe.Replace([string]$secret, '[REDACTED]')
        }
    }
    $safe = [regex]::Replace($safe, '(?im)(DASHSCOPE_API_KEY\s*[=:]\s*)\S+', '$1[REDACTED]')
    $safe = [regex]::Replace($safe, '(?im)(QWEN_MM_CONFIG\s*[=:]\s*)\S+', '$1[REDACTED]')
    $safe = [regex]::Replace($safe, '(?im)(authorization\s*:\s*bearer\s+)\S+', '$1[REDACTED]')
    return $safe
}

function Get-QvwQwenMmPromptDecision {
    param([AllowNull()][AllowEmptyString()][string]$Text)

    $safeText = if ($null -eq $Text) { '' } else { [string]$Text }
    # Hermes colours this prompt in the real CLI. Remove only ANSI control
    # sequences, then inspect the *last* non-empty output line. This prevents
    # a stale allowlisted prompt earlier in the stream from authorizing a
    # later overwrite/authentication/unknown prompt.
    $normalized = [regex]::Replace($safeText, ([string][char]27 + '\[[0-?]*[ -/]*[@-~]'), '')
    $lines = @($normalized -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($lines.Count -gt 0) {
        $tail = ([string]$lines[$lines.Count - 1]).Trim()
        $targetPattern = '(?i)^Enable\s+all\s+\d+\s+tools\?\s+\[Y/n/select\]\s*:?\s*$'
        # Do not let a stale allowlisted line authorize a dangerous prompt
        # elsewhere in the same output batch.
        foreach ($line in @($lines | Select-Object -SkipLast 1)) {
            $prior = ([string]$line).Trim()
            if ([string]::IsNullOrWhiteSpace($prior)) { continue }
            if ($prior -match '(?i)(?:overwrite|replace|authentication|\bauth\b|password|token|api[-_ ]?key|secret|credential|login|confirm|choose|select|continue|proceed|yes/no|y/n)' -or $prior -match '\?\s*$') {
                return [pscustomobject][ordered]@{ State = 'blocked'; Reason = 'unexpected-hermes-prompt' }
            }
        }
        # This is intentionally the only prompt which permits an automated
        # reply. Keep the tool count in the match and require the complete
        # prompt line (with Hermes' optional trailing colon). Test this before
        # the generic selection-word guard because the allowlist itself
        # contains the literal word `select`.
        if ($tail -match $targetPattern) {
            return [pscustomobject][ordered]@{ State = 'target'; Reason = 'qwen-mm-tool-consent' }
        }
        # Any question or credential/selection prompt which is not the exact
        # allowlisted form is a stop condition.  This includes overwrite,
        # authentication, and future/unknown prompts.
        if ($tail -match '(?i)(?:overwrite|replace|authentication|\bauth\b|password|token|api[-_ ]?key|secret|credential|login|confirm|choose|select|continue|proceed|yes/no|y/n)' -or
            $tail -match '\?\s*$') {
            return [pscustomobject][ordered]@{ State = 'blocked'; Reason = 'unexpected-hermes-prompt' }
        }
    }
    return [pscustomobject][ordered]@{ State = 'waiting'; Reason = 'prompt-not-seen' }
}

function ConvertTo-QvwQwenMmProcessArgument {
    param([AllowEmptyString()][string]$Argument)

    if ($null -eq $Argument -or $Argument.Length -eq 0) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) { $backslashes++; continue }
        if ($character -eq [char]34) {
            if ($backslashes -gt 0) { [void]$builder.Append((New-Object string ([char]92, ($backslashes * 2 + 1)))) }
            else { [void]$builder.Append([char]92) }
            [void]$builder.Append([char]34)
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) { [void]$builder.Append((New-Object string ([char]92, $backslashes))); $backslashes = 0 }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) { [void]$builder.Append((New-Object string ([char]92, ($backslashes * 2)))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-QvwQwenMmCommandWithInput {
    param(
        $Hermes,
        [string[]]$Arguments,
        [AllowNull()][AllowEmptyString()][string]$InputText,
        [int]$TimeoutSeconds = 90,
        [AllowNull()][string]$RuntimeConfigPath,
        [switch]$PromptRequired
    )

    $seam = Get-QvwQwenMmProperty -Object $Hermes -Name 'CommandWithInput'
    if ($seam -is [scriptblock]) {
        $first = $null
        $second = $null
        $runtimeCredential = $null
        try {
            if (-not [string]::IsNullOrWhiteSpace($RuntimeConfigPath)) {
                $runtimeCredential = Get-QvwQwenMmConfigCredentialPlaintext -Path $RuntimeConfigPath
            }
            # The seam mirrors the real process protocol: probe without stdin,
            # then send exactly one y only after the allowlisted prompt arrives.
            # Leave stdin unbound for the probe.  Passing an explicit null to
            # a typed PowerShell seam can be coerced to an empty string; an
            # unbound parameter preserves the no-input contract.
            $firstRaw = @(& $seam -Arguments @($Arguments))
            if ($firstRaw.Count -eq 0) { throw 'No command result.' }
            $first = $firstRaw[$firstRaw.Count - 1]
            $firstOut = [string](Get-QvwQwenMmProperty -Object $first -Name 'StdOut')
            $firstErr = [string](Get-QvwQwenMmProperty -Object $first -Name 'StdErr')
            if (-not $PromptRequired) {
                $firstExit = if ($first.PSObject.Properties['ExitCode']) { [int]$first.ExitCode } else { 0 }
                $firstSucceeded = if ($first.PSObject.Properties['Succeeded']) { [bool]$first.Succeeded } else { $firstExit -eq 0 }
                return [pscustomobject][ordered]@{
                    ExitCode = $firstExit; Succeeded = $firstSucceeded; TimedOut = [bool](Get-QvwQwenMmProperty -Object $first -Name 'TimedOut');
                    StdOut = Protect-QvwQwenMmProcessText -Text $firstOut -Secrets @($runtimeCredential)
                    StdErr = Protect-QvwQwenMmProcessText -Text $firstErr -Secrets @($runtimeCredential)
                    Error = Protect-QvwQwenMmProcessText -Text ([string](Get-QvwQwenMmProperty -Object $first -Name 'Error')) -Secrets @($runtimeCredential)
                    InputSent = $false; PromptState = 'not-required'
                }
            }
            $decision = Get-QvwQwenMmPromptDecision -Text ($firstOut + "`n" + $firstErr)
            if ([string]$decision.State -ne 'target') {
                return [pscustomobject][ordered]@{
                    ExitCode = if ($first.PSObject.Properties['ExitCode']) { [int]$first.ExitCode } else { 0 }
                    Succeeded = $false
                    TimedOut = [bool](Get-QvwQwenMmProperty -Object $first -Name 'TimedOut')
                    StdOut = Protect-QvwQwenMmProcessText -Text $firstOut -Secrets @($runtimeCredential)
                    StdErr = Protect-QvwQwenMmProcessText -Text $firstErr -Secrets @($runtimeCredential)
                    Error = Protect-QvwQwenMmProcessText -Text ([string]$decision.Reason) -Secrets @($runtimeCredential)
                    InputSent = $false; PromptState = [string]$decision.State
                }
            }

            # Deliberately ignore caller-provided InputText: the only permitted
            # response is this exact single y line after the prompt.
            $secondRaw = @(& $seam -Arguments @($Arguments) -InputText "y`r`n")
            if ($secondRaw.Count -eq 0) { throw 'No command result after the consent prompt.' }
            $second = $secondRaw[$secondRaw.Count - 1]
            $secondOut = [string](Get-QvwQwenMmProperty -Object $second -Name 'StdOut')
            $secondErr = [string](Get-QvwQwenMmProperty -Object $second -Name 'StdErr')
            $afterDecision = Get-QvwQwenMmPromptDecision -Text ($secondOut + "`n" + $secondErr)
            $secondExit = if ($second.PSObject.Properties['ExitCode']) { [int]$second.ExitCode } else { 0 }
            $secondSucceeded = if ($second.PSObject.Properties['Succeeded']) { [bool]$second.Succeeded } else { $secondExit -eq 0 }
            $blockedAfter = [string]$afterDecision.State -in @('blocked', 'target')
            return [pscustomobject][ordered]@{
                ExitCode = $secondExit
                Succeeded = ($secondSucceeded -and -not $blockedAfter)
                TimedOut = [bool](Get-QvwQwenMmProperty -Object $second -Name 'TimedOut')
                StdOut = Protect-QvwQwenMmProcessText -Text ($firstOut + $secondOut) -Secrets @($runtimeCredential)
                StdErr = Protect-QvwQwenMmProcessText -Text ($firstErr + $secondErr) -Secrets @($runtimeCredential)
                Error = if ($blockedAfter) { Protect-QvwQwenMmProcessText -Text ([string]$afterDecision.Reason) -Secrets @($runtimeCredential) } else { Protect-QvwQwenMmProcessText -Text ([string](Get-QvwQwenMmProperty -Object $second -Name 'Error')) -Secrets @($runtimeCredential) }
                InputSent = $true; PromptState = if ($blockedAfter) { 'blocked-after-consent' } else { 'accepted' }
            }
        }
        catch {
            return [pscustomobject][ordered]@{ ExitCode = -1; Succeeded = $false; StdOut = Protect-QvwQwenMmProcessText -Text ([string](Get-QvwQwenMmProperty -Object $first -Name 'StdOut')) -Secrets @($runtimeCredential); StdErr = Protect-QvwQwenMmProcessText -Text ([string](Get-QvwQwenMmProperty -Object $first -Name 'StdErr')) -Secrets @($runtimeCredential); Error = 'Hermes interactive command failed.'; InputSent = $false; PromptState = 'failed' }
        }
        finally {
            $runtimeCredential = $null
        }
    }

    $cli = [string](Get-QvwQwenMmProperty -Object $Hermes -Name 'CliPath')
    $work = [string](Get-QvwQwenMmProperty -Object $Hermes -Name 'Home')
    if ([string]::IsNullOrWhiteSpace($cli)) {
        return [pscustomobject][ordered]@{ ExitCode = -1; Succeeded = $false; StdOut = ''; StdErr = ''; Error = 'Hermes CLI is unavailable.'; InputSent = $false }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $cli
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    # Windows PowerShell's default redirected stdin encoding can emit a UTF-8
    # BOM before the first character. Hermes then receives "\uFEFFy" instead
    # of the single consent token. Use BOM-free UTF-8 when the runtime exposes
    # the encoding knobs (the guarded assignment keeps older .NET compatible).
    try {
        if ($null -ne $startInfo.PSObject.Properties['StandardInputEncoding']) { $startInfo.StandardInputEncoding = New-Object Text.UTF8Encoding($false) }
        if ($null -ne $startInfo.PSObject.Properties['StandardOutputEncoding']) { $startInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false) }
        if ($null -ne $startInfo.PSObject.Properties['StandardErrorEncoding']) { $startInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding($false) }
    }
    catch { }
    if (-not [string]::IsNullOrWhiteSpace($work)) { $startInfo.WorkingDirectory = $work }
    $runtimeCredential = $null
    if (-not [string]::IsNullOrWhiteSpace($RuntimeConfigPath)) {
        try { $startInfo.EnvironmentVariables['QWEN_MM_CONFIG'] = [string]$RuntimeConfigPath } catch { }
        $runtimeCredential = Get-QvwQwenMmConfigCredentialPlaintext -Path $RuntimeConfigPath
        if (-not [string]::IsNullOrWhiteSpace($runtimeCredential)) {
            try { $startInfo.EnvironmentVariables['DASHSCOPE_API_KEY'] = $runtimeCredential } catch { $runtimeCredential = $null }
        }
    }
    if ([string]::IsNullOrWhiteSpace($runtimeCredential)) {
        try { $runtimeCredential = [Environment]::GetEnvironmentVariable('DASHSCOPE_API_KEY', 'Process') } catch { $runtimeCredential = $null }
    }
    $argumentListProperty = $startInfo.PSObject.Properties['ArgumentList']
    if ($null -ne $argumentListProperty) {
        foreach ($argument in @($Arguments)) { [void]$startInfo.ArgumentList.Add([string]$argument) }
    }
    else {
        $encoded = @($Arguments | ForEach-Object { ConvertTo-QvwQwenMmProcessArgument -Argument ([string]$_) })
        $startInfo.Arguments = [string]::Join(' ', $encoded)
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $started = $false
    $timedOut = $false
    $overflowed = $false
    $inputSent = $false
    $promptState = if ($PromptRequired) { 'waiting' } else { 'not-required' }
    $stdout = ''
    $stderr = ''
    $errorText = $null
    $safeStdOut = ''
    $safeStdErr = ''
    $safeError = $null
    $exitCode = -1
    $maxOutputChars = 65536
    $stdoutBuffer = New-Object 'QvwQwenMmRuntime.PipeBuffer'
    $stderrBuffer = New-Object 'QvwQwenMmRuntime.PipeBuffer'
    $stdoutTask = $null
    $stderrTask = $null
    try {
        try {
            $started = $process.Start()
            if (-not $started) { throw 'Process did not start.' }
        }
        catch {
            $errorText = Protect-QvwQwenMmProcessText -Text $_.Exception.Message -Secrets @($runtimeCredential)
            return [pscustomobject][ordered]@{ ExitCode = -1; Succeeded = $false; TimedOut = $false; StdOut = ''; StdErr = ''; Error = $errorText; InputSent = $false; PromptState = 'failed' }
        }
        # Read both streams incrementally. ReadToEndAsync cannot expose a
        # prompt which has no newline, and waiting for process exit would make
        # an interactive Hermes process deadlock before the consent reply.
        $stdoutTask = [QvwQwenMmRuntime.PipeReader]::Start($process.StandardOutput.BaseStream, $stdoutBuffer, $maxOutputChars)
        $stderrTask = [QvwQwenMmRuntime.PipeReader]::Start($process.StandardError.BaseStream, $stderrBuffer, $maxOutputChars)
        $stdinClosed = $false
        $timeout = if ($TimeoutSeconds -le 0) { 90 } else { $TimeoutSeconds }
        $deadline = [DateTime]::UtcNow.AddSeconds($timeout)
        $killRequested = $false
        while ($true) {
            $chunk = $null
            while ($stdoutBuffer.TryDequeue([ref]$chunk)) {
                if ($stdout.Length + $chunk.Length -gt $maxOutputChars) { $overflowed = $true } else { $stdout += $chunk }
                $chunk = $null
            }
            while ($stderrBuffer.TryDequeue([ref]$chunk)) {
                if ($stderr.Length + $chunk.Length -gt $maxOutputChars) { $overflowed = $true } else { $stderr += $chunk }
                $chunk = $null
            }
            if ($stdoutBuffer.Overflowed -or $stderrBuffer.Overflowed) { $overflowed = $true }
            if ($overflowed) { $errorText = 'Hermes interactive output exceeded the safety limit.'; $killRequested = $true }
            if (-not $inputSent -and $PromptRequired) {
                $decision = Get-QvwQwenMmPromptDecision -Text ($stdout + "`n" + $stderr)
                if ([string]$decision.State -eq 'target') {
                    # Write the one permitted consent line as raw ASCII bytes;
                    # do not use StreamWriter.Write.  PS7 exposes
                    # StandardInputEncoding and has been verified BOM-free.
                    # Windows PowerShell 5.1's .NET Framework does not expose
                    # that property and can still emit its redirected UTF-8
                    # preamble even when BaseStream receives these bytes. The
                    # pinned Hermes v0.20.4 CLI strips/lowercases its choice
                    # input and therefore treats that compatibility case as
                    # enable-all; a future strict-token CLI requires a native
                    # raw-pipe executor before this path can claim PS5 exact
                    # byte compatibility.
                    $stdinWriter = $process.StandardInput
                    $consentBytes = [byte[]](0x79, 0x0d, 0x0a)
                    try {
                        $stdinWriter.BaseStream.Write($consentBytes, 0, $consentBytes.Length)
                        $stdinWriter.BaseStream.Flush()
                    }
                    finally { [Array]::Clear($consentBytes, 0, $consentBytes.Length) }
                    $inputSent = $true
                    $promptState = 'accepted'
                    $promptBoundary = $stdout.Length + $stderr.Length
                }
                elseif ([string]$decision.State -eq 'blocked') {
                    $promptState = 'blocked'
                    $errorText = [string]$decision.Reason
                    $killRequested = $true
                }
            }
            elseif (-not $stdinClosed -and -not $PromptRequired) {
                $process.StandardInput.Close()
                $stdinClosed = $true
            }
            if ($inputSent -and $promptState -eq 'accepted') {
                $after = $stdout + "`n" + $stderr
                if ($after.Length -gt $promptBoundary) {
                    $tail = $after.Substring([Math]::Min($promptBoundary, $after.Length))
                    $afterDecision = Get-QvwQwenMmPromptDecision -Text $tail
                    if ([string]$afterDecision.State -in @('blocked', 'target')) {
                        $promptState = 'blocked-after-consent'
                        $errorText = [string]$afterDecision.Reason
                        $killRequested = $true
                    }
                }
            }
            $hasExited = $false
            try { $hasExited = $process.HasExited } catch { $hasExited = $true }
            if ($killRequested) {
                try { $process.StandardInput.Close() } catch { }
                try { $process.Kill($true) } catch { try { $process.Kill() } catch { } }
                try { $process.WaitForExit() } catch { }
                break
            }
            if ($hasExited) {
                if (-not $stdinClosed) { try { $process.StandardInput.Close() } catch { }; $stdinClosed = $true }
                break
            }
            if ([DateTime]::UtcNow -gt $deadline) {
                $timedOut = $true
                $errorText = 'Hermes interactive command timed out.'
                try { $process.StandardInput.Close() } catch { }
                try { $process.Kill($true) } catch { try { $process.Kill() } catch { } }
                try { $process.WaitForExit() } catch { }
                break
            }
            Start-Sleep -Milliseconds 25
        }
        try { if ($stdoutTask) { [void]$stdoutTask.Wait(1000) } } catch { }
        try { if ($stderrTask) { [void]$stderrTask.Wait(1000) } } catch { }
        $chunk = $null
        while ($stdoutBuffer.TryDequeue([ref]$chunk)) { if ($stdout.Length + $chunk.Length -le $maxOutputChars) { $stdout += $chunk } else { $overflowed = $true }; $chunk = $null }
        while ($stderrBuffer.TryDequeue([ref]$chunk)) { if ($stderr.Length + $chunk.Length -le $maxOutputChars) { $stderr += $chunk } else { $overflowed = $true }; $chunk = $null }
        if ($stdoutBuffer.Overflowed -or $stderrBuffer.Overflowed) { $overflowed = $true }
        if ($process.HasExited) { $exitCode = $process.ExitCode }
    }
    catch { $errorText = Protect-QvwQwenMmProcessText -Text $_.Exception.Message -Secrets @($runtimeCredential) }
    finally {
        # Redact while the exact runtime credential is still available, then
        # clear it before returning or disposing the process.
        $safeStdOut = Protect-QvwQwenMmProcessText -Text $stdout -Secrets @($runtimeCredential)
        $safeStdErr = Protect-QvwQwenMmProcessText -Text $stderr -Secrets @($runtimeCredential)
        $safeError = Protect-QvwQwenMmProcessText -Text $errorText -Secrets @($runtimeCredential)
        if ($process) { $process.Dispose() }
        $runtimeCredential = $null
    }
    if ($PromptRequired -and -not $inputSent -and -not $timedOut -and -not $overflowed -and $promptState -eq 'waiting') {
        $promptState = 'prompt-missing'
        if ([string]::IsNullOrWhiteSpace($errorText)) { $errorText = 'The expected Hermes consent prompt was not observed.' }
        $safeError = Protect-QvwQwenMmProcessText -Text $errorText -Secrets @()
    }
    return [pscustomobject][ordered]@{
        ExitCode = $exitCode
        Succeeded = ($started -and -not $timedOut -and -not $overflowed -and $exitCode -eq 0 -and ((-not $PromptRequired) -or ($inputSent -and $promptState -eq 'accepted')))
        TimedOut = $timedOut
        StdOut = $safeStdOut
        StdErr = $safeStdErr
        Error = $safeError
        InputSent = $inputSent
        PromptState = $promptState
    }
}

function Invoke-QvwQwenMmNetworkCheck {
    param($Hermes, [string]$Url)

    $check = Get-QvwQwenMmProperty -Object $Hermes -Name 'NetworkCheck'
    if ($check -is [scriptblock]) {
        try {
            $raw = @(& $check $Url)
            if ($raw.Count -eq 0) { return $false }
            $last = $raw[$raw.Count - 1]
            if ($last -is [bool]) { return [bool]$last }
            if ($last.PSObject.Properties['Succeeded']) { return [bool]$last.Succeeded }
            return [bool]$last
        }
        catch { return $false }
    }
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $Url -TimeoutSec 20 -ErrorAction Stop
        return ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400)
    }
    catch { return $false }
}

function Test-QvwQwenMmPrerequisite {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Hermes)

    try {
        $lock = Get-QvwQwenMmSourceLock -Hermes $Hermes
        [void](Test-QvwQwenMmSourceLock -Lock $lock -AllowTestOverride:([bool](Get-QvwQwenMmProperty -Object $Hermes -Name 'TestMode')))
    }
    catch {
        return (New-QvwResult -Component 'qwen-mm' -Status 'blocked' -Code 'QVW-QMM-SOURCE-LOCK-INVALID' -Message 'The pinned Qwen-MM source lock is invalid; no files were changed.' -Evidence @{})
    }

    $uvxAvailableProperty = $Hermes.PSObject.Properties['UvxAvailable']
    if ($null -ne $uvxAvailableProperty) {
        $uvxAvailable = [bool]$uvxAvailableProperty.Value
    }
    else {
        $uvxAvailable = ($null -ne (Get-Command -Name 'uvx' -CommandType Application -ErrorAction SilentlyContinue))
    }
    if (-not $uvxAvailable) {
        return (New-QvwResult -Component 'qwen-mm' -Status 'blocked' -Code 'QVW-QMM-UVX-MISSING' -Message 'uvx is required for the pinned Qwen-MM MCP server.' -Evidence @{ uvx = $false })
    }

    $mcpSupportedProperty = $Hermes.PSObject.Properties['McpAddSupported']
    if ($null -ne $mcpSupportedProperty) {
        $mcpSupported = [bool]$mcpSupportedProperty.Value
    }
    else {
        $help = Invoke-QvwQwenMmCommand -Hermes $Hermes -Arguments @('mcp', 'add', '--help') -TimeoutSeconds 20
        $mcpSupported = ([bool]$help.Succeeded -and ([string]$help.StdOut -match '(?i)\bmcp\s+add|add an MCP server|server name'))
    }
    if (-not $mcpSupported) {
        return (New-QvwResult -Component 'qwen-mm' -Status 'blocked' -Code 'QVW-QMM-MCP-ADD-UNSUPPORTED' -Message 'The installed Hermes CLI does not expose mcp add; no files were changed.' -Evidence @{ uvx = $true; mcpAdd = $false })
    }

    $network = Invoke-QvwQwenMmNetworkCheck -Hermes $Hermes -Url ([string]$lock.skillRawUrl)
    if (-not $network) {
        return (New-QvwResult -Component 'qwen-mm' -Status 'blocked' -Code 'QVW-QMM-NETWORK-UNAVAILABLE' -Message 'The pinned Qwen-MM source could not be reached; no files were changed.' -Evidence @{ uvx = $true; mcpAdd = $true; network = $false })
    }
    return (New-QvwResult -Component 'qwen-mm' -Status 'discovered' -Code 'QVW-QMM-PREREQUISITES-OK' -Message 'Qwen-MM prerequisites are available; no files were changed.' -Evidence @{ uvx = $true; mcpAdd = $true; network = $true; source = (Get-QvwQwenMmLockEvidence -Lock $lock) })
}

function Test-QvwQwenMmSecureStringNonEmpty {
    param([AllowNull()][securestring]$Value)

    if ($null -eq $Value) { return $false }
    $bstr = [IntPtr]::Zero
    $plain = $null
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        return -not [string]::IsNullOrEmpty($plain)
    }
    catch { return $false }
    finally {
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        $plain = $null
    }
}

function Test-QvwQwenMmEnvironmentCredential {
    foreach ($scope in @('Process', 'Machine', 'User')) {
        $value = [Environment]::GetEnvironmentVariable('DASHSCOPE_API_KEY', $scope)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $value = $null
            return $true
        }
        $value = $null
    }
    return $false
}

function Test-QvwQwenMmDotEnvCredential {
    param($Hermes)

    $configured = [string](Get-QvwQwenMmProperty -Object $Hermes -Name 'EnvPath')
    if ([string]::IsNullOrWhiteSpace($configured)) { $configured = [string](Get-QvwQwenMmProperty -Object $Hermes -Name 'DotEnvPath') }
    if ([string]::IsNullOrWhiteSpace($configured)) {
        $home = [string](Get-QvwQwenMmProperty -Object $Hermes -Name 'Home')
        if (-not [string]::IsNullOrWhiteSpace($home)) { $configured = Join-Path $home '.env' }
    }
    if ([string]::IsNullOrWhiteSpace($configured) -or -not (Test-Path -LiteralPath $configured -PathType Leaf)) { return $false }
    try {
        $text = [IO.File]::ReadAllText($configured, [Text.Encoding]::UTF8)
        return [regex]::IsMatch($text, '(?im)^\s*DASHSCOPE_API_KEY\s*=\s*\S+\s*$')
    }
    catch { return $false }
}

function Get-QvwQwenMmSecurePlaintext {
    param([securestring]$Value)

    $bstr = [IntPtr]::Zero
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
}

function Get-QvwQwenMmSkillDirectory {
    param($Hermes)

    $configured = [string](Get-QvwQwenMmProperty -Object $Hermes -Name 'QwenMmSkillPath')
    if ([string]::IsNullOrWhiteSpace($configured)) { $configured = Join-Path ([string](Get-QvwQwenMmProperty -Object $Hermes -Name 'Home')) 'skills\qwen-mm-plugins-api' }
    return [IO.Path]::GetFullPath($configured)
}

function Get-QvwQwenMmConfigPath {
    param($Hermes)

    $configured = [string](Get-QvwQwenMmProperty -Object $Hermes -Name 'McpConfigPath')
    if ([string]::IsNullOrWhiteSpace($configured)) { $configured = [string](Get-QvwQwenMmProperty -Object $Hermes -Name 'ConfigPath') }
    if ([string]::IsNullOrWhiteSpace($configured)) { $configured = Join-Path ([string](Get-QvwQwenMmProperty -Object $Hermes -Name 'Home')) 'config.yaml' }
    return [IO.Path]::GetFullPath($configured)
}

function Get-QvwQwenMmCredentialConfigPath {
    param($Hermes)

    $configured = [string](Get-QvwQwenMmProperty -Object $Hermes -Name 'QwenMmConfigPath')
    if ([string]::IsNullOrWhiteSpace($configured)) {
        $home = [string](Get-QvwQwenMmProperty -Object $Hermes -Name 'Home')
        $configured = Join-Path $home 'qwen-mm-plugins\config'
    }
    return [IO.Path]::GetFullPath($configured)
}

function Test-QvwQwenMmWithinHome {
    param([string]$Home, [string]$Path)

    $root = ([IO.Path]::GetFullPath($Home)).TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath($Path)
    return $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
}

function Get-QvwQwenMmDirectoryPlan {
    param(
        [string[]]$Paths,
        [Parameter(Mandatory = $true)][string]$Home
    )

    $homeFull = [IO.Path]::GetFullPath($Home).TrimEnd([char]92, [char]47)
    $plan = New-Object System.Collections.ArrayList
    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $cursor = [IO.Path]::GetFullPath($path).TrimEnd([char]92, [char]47)
        if (-not $cursor.StartsWith(($homeFull + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Qwen-MM directory plan escaped Hermes root.'
        }

        # Record every directory that this transaction may create, walking
        # upward until an existing directory is reached or the Hermes root is
        # reached.  The root itself is an existing safety boundary and is not
        # part of the removable plan (an empty relative path is invalid in a
        # receipt).  This makes rollback able to remove a brand-new parent
        # chain, not only the leaf directory.
        while ($cursor.StartsWith(($homeFull + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
            $alreadyRecorded = @($plan | Where-Object { [string]$_.Path -eq $cursor }).Count -gt 0
            $exists = Test-Path -LiteralPath $cursor -PathType Container
            if (-not $alreadyRecorded) {
                if ($exists) {
                    try {
                        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'reparse-point' }
                    }
                    catch { throw 'Qwen-MM directory plan contains an unsafe existing directory.' }
                }
                [void]$plan.Add([pscustomobject][ordered]@{ Path = $cursor; Existed = [bool]$exists })
            }
            if ($exists) { break }
            $parent = [IO.Directory]::GetParent($cursor)
            if ($null -eq $parent) { break }
            $cursor = $parent.FullName.TrimEnd([char]92, [char]47)
        }
    }
    return @($plan)
}

function ConvertTo-QvwQwenMmDirectoryEvidence {
    param([string]$Home, [object[]]$Plan)

    $root = ([IO.Path]::GetFullPath($Home)).TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
    $evidence = New-Object System.Collections.ArrayList
    foreach ($entry in @($Plan)) {
        if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.Path)) { throw 'Qwen-MM directory plan is incomplete.' }
        $full = [IO.Path]::GetFullPath([string]$entry.Path)
        if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Qwen-MM directory plan escaped Hermes root.' }
        $relative = $full.Substring($root.Length).Replace([char]92, [char]47)
        if (-not (Test-QvwQwenMmSafeRelativePath -Path $relative)) { throw 'Qwen-MM directory plan contains an unsafe relative path.' }
        [void]$evidence.Add([ordered]@{ relativePath = $relative; existed = [bool]$entry.Existed })
    }
    if ($evidence.Count -eq 0) { throw 'Qwen-MM directory plan cannot be empty.' }
    return @($evidence)
}

function ConvertFrom-QvwQwenMmDirectoryEvidence {
    param([string]$Home, $Evidence)

    if ($null -eq $Evidence) { throw 'Qwen-MM receipt directory plan is missing.' }
    $root = ([IO.Path]::GetFullPath($Home)).TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
    $plan = New-Object System.Collections.ArrayList
    foreach ($entry in @($Evidence)) {
        if ($null -eq $entry -or $null -eq $entry.PSObject.Properties['relativePath'] -or $null -eq $entry.PSObject.Properties['existed']) { throw 'Qwen-MM receipt directory plan is invalid.' }
        $relative = [string]$entry.relativePath
        if (-not (Test-QvwQwenMmSafeRelativePath -Path $relative)) { throw 'Qwen-MM receipt directory plan contains an unsafe path.' }
        $full = [IO.Path]::GetFullPath((Join-Path $Home ($relative -replace '/', '\')))
        if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Qwen-MM receipt directory plan escaped Hermes root.' }
        if ($null -ne (@($plan | Where-Object { [string]$_.Path -eq $full }).Count) -and @($plan | Where-Object { [string]$_.Path -eq $full }).Count -gt 0) { throw 'Qwen-MM receipt directory plan contains duplicates.' }
        [void]$plan.Add([pscustomobject][ordered]@{ Path = $full; Existed = [bool]$entry.existed })
    }
    if ($plan.Count -eq 0) { throw 'Qwen-MM receipt directory plan is empty.' }
    return @($plan)
}

function Set-QvwQwenMmReceiptEvidence {
    param([string]$Home, [string]$ReceiptPath, [hashtable]$Evidence)

    if ([string]::IsNullOrWhiteSpace($ReceiptPath) -or -not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw 'Qwen-MM receipt is missing.' }
    if (-not (Test-QvwQwenMmWithinHome -Home $Home -Path $ReceiptPath)) { throw 'Qwen-MM receipt is outside Hermes root.' }
    $receipt = [IO.File]::ReadAllText($ReceiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    foreach ($required in @('schemaVersion', 'receiptId', 'clientRoot', 'operation', 'state', 'entryMode', 'entries', 'evidence')) { if ($null -eq $receipt.PSObject.Properties[$required]) { throw 'Qwen-MM receipt schema is incomplete.' } }
    if ([int]$receipt.schemaVersion -ne 1 -or [string]$receipt.operation -ne 'install-qwen-mm-api' -or [IO.Path]::GetFullPath([string]$receipt.clientRoot) -ne [IO.Path]::GetFullPath($Home)) { throw 'Qwen-MM receipt ownership is invalid.' }
    $merged = [ordered]@{}
    foreach ($property in @($receipt.evidence.PSObject.Properties)) { $merged[[string]$property.Name] = $property.Value }
    foreach ($key in @($Evidence.Keys)) { $merged[[string]$key] = $Evidence[$key] }
    $receipt.evidence = [pscustomobject]$merged
    $json = $receipt | ConvertTo-Json -Depth 20
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    try { Write-QvwQwenMmBytesAtomic -Path $ReceiptPath -Bytes $bytes }
    finally { if ($bytes -is [byte[]]) { [Array]::Clear($bytes, 0, $bytes.Length) } }
    return $receipt
}

function Get-QvwQwenMmValidatedReceipt {
    param($Hermes, [string]$ReceiptPath, [string[]]$ExpectedStates = @('committed'))

    $home = [string](Get-QvwQwenMmProperty -Object $Hermes -Name 'Home')
    if ([string]::IsNullOrWhiteSpace($home) -or -not (Test-Path -LiteralPath $home -PathType Container)) { throw 'Hermes root is unavailable.' }
    if ([string]::IsNullOrWhiteSpace($ReceiptPath) -or -not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw 'Qwen-MM receipt is missing.' }
    $fullReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
    if (-not (Test-QvwQwenMmWithinHome -Home $home -Path $fullReceiptPath)) { throw 'Qwen-MM receipt is outside the active Hermes root.' }
    $receipt = [IO.File]::ReadAllText($fullReceiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    foreach ($required in @('schemaVersion', 'receiptId', 'createdUtc', 'updatedUtc', 'clientRoot', 'operation', 'state', 'entryMode', 'entries', 'evidence')) {
        if ($null -eq $receipt.PSObject.Properties[$required]) { throw 'Qwen-MM receipt schema is incomplete.' }
    }
    if ([int]$receipt.schemaVersion -ne 1 -or [string]::IsNullOrWhiteSpace([string]$receipt.receiptId) -or [string]$receipt.operation -ne 'install-qwen-mm-api' -or @($ExpectedStates) -notcontains [string]$receipt.state) { throw 'Qwen-MM receipt schema or state is invalid.' }
    if ([IO.Path]::GetFullPath([string]$receipt.clientRoot) -ne [IO.Path]::GetFullPath($home)) { throw 'Qwen-MM receipt belongs to a different Hermes root.' }
    if ([string]$receipt.entryMode -notin @('files', 'zero-files') -or $receipt.entries -isnot [array]) { throw 'Qwen-MM receipt entry schema is invalid.' }
    foreach ($entry in @($receipt.entries)) {
        foreach ($required in @('path', 'logicalName', 'beforeExists')) { if ($null -eq $entry.PSObject.Properties[$required]) { throw 'Qwen-MM receipt entry schema is invalid.' } }
        if (-not (Test-QvwQwenMmWithinHome -Home $home -Path ([string]$entry.path))) { throw 'Qwen-MM receipt entry escaped Hermes root.' }
    }
    $evidence = $receipt.evidence
    foreach ($required in @('serverName', 'source', 'readback', 'directoryPlan')) { if ($null -eq $evidence.PSObject.Properties[$required]) { throw 'Qwen-MM receipt evidence is incomplete.' } }
    if ([string]$evidence.serverName -ne $script:QvwQwenMmServerName -or [string]$evidence.readback -ne 'unique-pinned') { throw 'Qwen-MM receipt server evidence is invalid.' }
    $lock = Get-QvwQwenMmSourceLock -Hermes $Hermes
    $source = $evidence.source
    foreach ($required in @('tag', 'commit', 'capability', 'packageVersion', 'license')) { if ($null -eq $source.PSObject.Properties[$required]) { throw 'Qwen-MM receipt source evidence is incomplete.' } }
    $expectedSource = Get-QvwQwenMmLockEvidence -Lock $lock
    foreach ($key in @($expectedSource.Keys)) { if ([string]$source.$key -ne [string]$expectedSource[$key]) { throw 'Qwen-MM receipt source evidence does not match the pinned lock.' } }
    $plan = ConvertFrom-QvwQwenMmDirectoryEvidence -Home $home -Evidence $evidence.directoryPlan
    return [pscustomobject][ordered]@{ Path = $fullReceiptPath; Receipt = $receipt; Home = [IO.Path]::GetFullPath($home); DirectoryPlan = $plan }
}

function Remove-QvwQwenMmNewEmptyDirectories {
    param($Hermes, [string]$Home, [object[]]$Plan)

    $removed = New-Object System.Collections.ArrayList
    $preservedExisting = New-Object System.Collections.ArrayList
    $preservedNonEmpty = New-Object System.Collections.ArrayList
    $failed = New-Object System.Collections.ArrayList
    if ($null -eq $Plan -or @($Plan).Count -eq 0) {
        [void]$failed.Add([pscustomobject][ordered]@{ Path = $Home; Reason = 'directory-plan-missing' })
        return [pscustomobject][ordered]@{ Verified = $false; Removed = @(); PreservedExisting = @(); PreservedNonEmpty = @(); Failed = @($failed) }
    }
    foreach ($entry in @($Plan | Sort-Object { $_.Path.Length } -Descending)) {
        $path = [string]$entry.Path
        if ([bool]$entry.Existed) {
            if (-not (Test-Path -LiteralPath $path -PathType Container)) {
                [void]$failed.Add([pscustomobject][ordered]@{ Path = $path; Reason = 'preexisting-directory-missing' })
            }
            else { [void]$preservedExisting.Add($path) }
            continue
        }
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
        if (-not (Test-QvwQwenMmWithinHome -Home $Home -Path $path)) { [void]$failed.Add([pscustomobject][ordered]@{ Path = $path; Reason = 'outside-home' }); continue }
        try {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'reparse-point' }
            $children = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop)
            if ($children.Count -gt 0) {
                [void]$preservedNonEmpty.Add($path)
                continue
            }
            $removeSeam = Get-QvwQwenMmProperty -Object $Hermes -Name 'RemoveDirectory'
            if ($removeSeam -is [scriptblock]) {
                $raw = @(& $removeSeam $path)
                if ($raw.Count -eq 0 -or -not [bool]$raw[$raw.Count - 1]) { throw 'directory-remove-seam-failed' }
            }
            else { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
            if (Test-Path -LiteralPath $path) { throw 'directory-still-exists' }
            [void]$removed.Add($path)
        }
        catch { [void]$failed.Add([pscustomobject][ordered]@{ Path = $path; Reason = [string]$_.Exception.Message }) }
    }
    return [pscustomobject][ordered]@{ Verified = (@($failed).Count -eq 0); Removed = @($removed); PreservedExisting = @($preservedExisting); PreservedNonEmpty = @($preservedNonEmpty); Failed = @($failed) }
}

function Write-QvwQwenMmBytesAtomic {
    param([string]$Path, [byte[]]$Bytes)

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $temp = "$Path.qvw-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllBytes($temp, $Bytes)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try { [IO.File]::Replace($temp, $Path, [string]$null) }
            catch { Move-Item -LiteralPath $temp -Destination $Path -Force -ErrorAction Stop | Out-Null }
        }
        else { [IO.File]::Move($temp, $Path) }
    }
    finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue | Out-Null }
    }
}

function Get-QvwQwenMmCredentialPlan {
    param($Hermes, [AllowNull()][securestring]$DashScopeKey)

    if ((Test-QvwQwenMmEnvironmentCredential) -or (Test-QvwQwenMmDotEnvCredential -Hermes $Hermes)) {
        return [pscustomobject][ordered]@{ Mode = 'inherited'; ConfigPath = $null }
    }
    if (-not (Test-QvwQwenMmSecureStringNonEmpty -Value $DashScopeKey)) { return $null }
    $path = Get-QvwQwenMmCredentialConfigPath -Hermes $Hermes
    return [pscustomobject][ordered]@{ Mode = 'acl-config'; ConfigPath = $path }
}

function Set-QvwQwenMmConfigAcl {
    param($Hermes, [string]$Path)

    $seam = Get-QvwQwenMmProperty -Object $Hermes -Name 'ApplyConfigAcl'
    if ($seam -is [scriptblock]) {
        try {
            $raw = @(& $seam $Path)
            if ($raw.Count -gt 0) { return [bool]$raw[$raw.Count - 1] }
        }
        catch { return $false }
        return $false
    }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return $false }
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($existing in @($acl.Access)) { [void]$acl.RemoveAccessRule($existing) }
        $identity = if (-not [string]::IsNullOrWhiteSpace($env:USERDOMAIN)) { "$env:USERDOMAIN\$env:USERNAME" } else { [string]$env:USERNAME }
        foreach ($principal in @($identity, 'SYSTEM', 'BUILTIN\Administrators')) {
            if ([string]::IsNullOrWhiteSpace($principal)) { continue }
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($principal, 'FullControl', 'Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

function Write-QvwQwenMmCredentialConfig {
    param($Hermes, [string]$Path, [securestring]$DashScopeKey)

    $plain = $null
    $bytes = $null
    try {
        $plain = Get-QvwQwenMmSecurePlaintext -Value $DashScopeKey
        if ([string]::IsNullOrWhiteSpace($plain) -or $plain -match '[\r\n\x00-\x1f\x7f]') { throw 'Credential contains invalid control characters.' }
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(('DASHSCOPE_API_KEY=' + $plain + "`n"))
        Write-QvwQwenMmBytesAtomic -Path $Path -Bytes $bytes
        if (-not (Set-QvwQwenMmConfigAcl -Hermes $Hermes -Path $Path)) { throw 'Unable to apply ACL protection to Qwen-MM credential config.' }
    }
    finally {
        if ($bytes -is [byte[]]) { [Array]::Clear($bytes, 0, $bytes.Length) }
        $plain = $null
    }
}

function Get-QvwQwenMmConfigCredentialPlaintext {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        $match = [regex]::Match($text, '(?im)^\s*DASHSCOPE_API_KEY\s*=\s*(?<value>[^\r\n]+)\s*$')
        if ($match.Success -and -not [string]::IsNullOrWhiteSpace($match.Groups['value'].Value)) { return $match.Groups['value'].Value.Trim() }
    }
    catch { }
    return $null
}

function Invoke-QvwQwenMmRuntimeCommand {
    param($Hermes, [string[]]$Arguments, [int]$TimeoutSeconds = 90, [AllowNull()][string]$RuntimeConfigPath)

    if ([string]::IsNullOrWhiteSpace($RuntimeConfigPath)) { return (Invoke-QvwQwenMmCommand -Hermes $Hermes -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds) }
    $runtimeSeam = Get-QvwQwenMmProperty -Object $Hermes -Name 'CommandWithRuntimeConfig'
    if ($runtimeSeam -is [scriptblock]) {
        try {
            $raw = @(& $runtimeSeam -Arguments @($Arguments) -RuntimeConfigPath $RuntimeConfigPath)
            if ($raw.Count -gt 0) { return $raw[$raw.Count - 1] }
        }
        catch { return [pscustomobject][ordered]@{ ExitCode = -1; Succeeded = $false; StdOut = ''; StdErr = ''; Error = 'Hermes runtime command failed.' } }
    }
    return (Invoke-QvwQwenMmCommandWithInput -Hermes $Hermes -Arguments $Arguments -InputText $null -TimeoutSeconds $TimeoutSeconds -RuntimeConfigPath $RuntimeConfigPath)
}

function ConvertFrom-QvwQwenMmInlineArgs {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $trimmed = $Text.Trim()
    if ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']')) { $trimmed = $trimmed.Substring(1, $trimmed.Length - 2) }
    $parts = @()
    foreach ($part in ($trimmed -split ',|\s{2,}')) {
        $value = ([string]$part).Trim().Trim('''').Trim('"')
        if (-not [string]::IsNullOrWhiteSpace($value)) { $parts += $value }
    }
    return @($parts)
}

function Get-QvwQwenMmMcpReadback {
    param($Hermes, $Lock)

    $expectedArgs = @($Lock.mcp.args | ForEach-Object { [string]$_ })
    $seam = Get-QvwQwenMmProperty -Object $Hermes -Name 'McpReadback'
    if ($seam -is [scriptblock]) {
        try {
            $raw = @(& $seam $script:QvwQwenMmServerName)
            $candidate = if ($raw.Count -gt 0) { $raw[$raw.Count - 1] } else { $null }
            if ($null -eq $candidate) { throw 'MCP readback is empty.' }
            $count = if ($candidate.PSObject.Properties['Count']) { [int]$candidate.Count } elseif ($candidate.PSObject.Properties['UniqueCount']) { [int]$candidate.UniqueCount } else { 1 }
            $name = [string](Get-QvwQwenMmProperty -Object $candidate -Name 'ServerName')
            $command = [string](Get-QvwQwenMmProperty -Object $candidate -Name 'Command')
            $args = @((Get-QvwQwenMmProperty -Object $candidate -Name 'Args') | ForEach-Object { [string]$_ })
            if ($count -ne 1 -or $name -ne $script:QvwQwenMmServerName -or $command -ne [string]$Lock.mcp.command -or [string]::Join("`n", $args) -ne [string]::Join("`n", $expectedArgs)) { throw 'MCP readback did not match the unique pinned Qwen-MM server.' }
            return [pscustomobject][ordered]@{ Unique = $true; ServerName = $name; Command = $command; Args = $args; Source = 'seam' }
        }
        catch { throw 'Qwen-MM MCP readback failed.' }
    }

    $configPath = Get-QvwQwenMmConfigPath -Hermes $Hermes
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'Qwen-MM MCP configuration readback is missing.' }
    $lines = @([IO.File]::ReadAllLines($configPath, [Text.Encoding]::UTF8))
    $serverLineIndexes = @()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^\s{2}qwen-mm-api\s*:') { $serverLineIndexes += $index }
    }
    if ($serverLineIndexes.Count -ne 1) { throw 'Qwen-MM MCP server name is not unique in config readback.' }
    $start = [int]$serverLineIndexes[0]
    $end = $lines.Count
    for ($index = $start + 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^\s{2}\S[^:]*\s*:') { $end = $index; break }
    }
    $command = $null
    $args = New-Object System.Collections.ArrayList
    $collectList = $false
    for ($index = $start + 1; $index -lt $end; $index++) {
        $line = [string]$lines[$index]
        if ($line -match '^\s{4}command\s*:\s*(?<value>.+?)\s*$') { $command = $matches['value'].Trim().Trim('''').Trim('"'); $collectList = $false; continue }
        if ($line -match '^\s{4}args\s*:\s*(?<value>.*)$') {
            $inline = $matches['value'].Trim()
            if (-not [string]::IsNullOrWhiteSpace($inline)) { foreach ($value in @(ConvertFrom-QvwQwenMmInlineArgs -Text $inline)) { [void]$args.Add($value) }; $collectList = $false }
            else { $collectList = $true }
            continue
        }
        if ($collectList -and $line -match '^\s{6}-\s*(?<value>.+?)\s*$') { [void]$args.Add($matches['value'].Trim().Trim('''').Trim('"')); continue }
        if ($line -notmatch '^\s{6}-') { $collectList = $false }
    }
    if ($command -ne [string]$Lock.mcp.command -or [string]::Join("`n", @($args)) -ne [string]::Join("`n", $expectedArgs)) { throw 'Qwen-MM MCP readback command or args did not match the pinned source lock.' }
    return [pscustomobject][ordered]@{ Unique = $true; ServerName = $script:QvwQwenMmServerName; Command = $command; Args = @($args); Source = 'config' }
}

function Get-QvwQwenMmMcpAddInteraction {
    param($Hermes)

    $configured = [string](Get-QvwQwenMmProperty -Object $Hermes -Name 'McpAddNonInteractiveFlag')
    if (-not [string]::IsNullOrWhiteSpace($configured) -and $configured -match '^--(?:non-interactive|no-prompt|yes|assume-yes)$') {
        return [pscustomobject][ordered]@{ Flag = $configured; InputText = $null; Source = 'official-flag' }
    }
    $helpText = [string](Get-QvwQwenMmProperty -Object $Hermes -Name 'McpAddHelpText')
    if ([string]::IsNullOrWhiteSpace($helpText)) {
        $help = Invoke-QvwQwenMmCommand -Hermes $Hermes -Arguments @('mcp', 'add', '--help') -TimeoutSeconds 20
        $helpText = ([string]$help.StdOut) + "`n" + ([string]$help.StdErr)
    }
    $match = [regex]::Match($helpText, '(?im)(--(?:non-interactive|no-prompt|yes|assume-yes))\b')
    if ($match.Success) { return [pscustomobject][ordered]@{ Flag = $match.Groups[1].Value; InputText = $null; Source = 'official-flag' } }
    return [pscustomobject][ordered]@{ Flag = $null; InputText = "y`r`n"; Source = 'controlled-stdin' }
}

function Test-QvwQwenMmCredentialPresent {
    param($Hermes, [AllowNull()][securestring]$DashScopeKey)

    return ($null -ne (Get-QvwQwenMmCredentialPlan -Hermes $Hermes -DashScopeKey $DashScopeKey))
}

function Invoke-QvwQwenMmRollback {
    param($Hermes, [string]$Home, [string]$ReceiptPath)

    $validated = $null
    $plan = $null
    try {
        $validated = Get-QvwQwenMmValidatedReceipt -Hermes $Hermes -ReceiptPath $ReceiptPath -ExpectedStates @('committed', 'started')
        $plan = @($validated.DirectoryPlan)
        if ($plan.Count -eq 0) { throw 'Qwen-MM receipt directory plan is empty.' }
        $undo = Get-QvwQwenMmProperty -Object $Hermes -Name 'Undo'
        if ($undo -is [scriptblock]) { $rollback = & $undo $ReceiptPath }
        else { $rollback = Undo-QvwTransaction -ReceiptPath $ReceiptPath }
        if ($null -eq $rollback -or [string]$rollback.State -ne 'rolled-back') { throw 'Qwen-MM receipt rollback was not verified.' }
        $receipt = [IO.File]::ReadAllText($ReceiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        if ([string]$receipt.state -ne 'rolled-back' -or [string]$receipt.operation -ne 'install-qwen-mm-api' -or [IO.Path]::GetFullPath([string]$receipt.clientRoot) -ne [IO.Path]::GetFullPath([string]$validated.Home)) { throw 'Qwen-MM receipt state readback was not rolled-back.' }
        # Undo-QvwTransaction rewrites evidence. Restore the receipt-backed
        # plan before directory cleanup so future uninstall/live operations
        # never need to guess a directory list from timestamps.  Mark cleanup
        # incomplete until the directory pass itself has been verified; a
        # rolled-back file state is not, by itself, a complete uninstall.
        $lock = Get-QvwQwenMmSourceLock -Hermes $Hermes
        $receiptSource = Get-QvwQwenMmLockEvidence -Lock $lock
        $receiptPlan = ConvertTo-QvwQwenMmDirectoryEvidence -Home ([string]$validated.Home) -Plan $plan
        [void](Set-QvwQwenMmReceiptEvidence -Home ([string]$validated.Home) -ReceiptPath $ReceiptPath -Evidence @{ serverName = $script:QvwQwenMmServerName; source = $receiptSource; readback = 'unique-pinned'; directoryPlan = $receiptPlan; rollback = 'incomplete' })
        $cleanup = Remove-QvwQwenMmNewEmptyDirectories -Hermes $Hermes -Home ([string]$validated.Home) -Plan $plan
        if (-not $cleanup.Verified) {
            try { [void](Set-QvwQwenMmReceiptEvidence -Home ([string]$validated.Home) -ReceiptPath $ReceiptPath -Evidence @{ serverName = $script:QvwQwenMmServerName; source = $receiptSource; readback = 'unique-pinned'; rollback = 'incomplete'; directoryPlan = $receiptPlan; cleanup = $cleanup }) } catch { }
            return [pscustomobject][ordered]@{ Verified = $false; State = 'manual-recovery-required'; RemovedDirectories = @($cleanup.Removed); Cleanup = $cleanup }
        }
        try { [void](Set-QvwQwenMmReceiptEvidence -Home ([string]$validated.Home) -ReceiptPath $ReceiptPath -Evidence @{ serverName = $script:QvwQwenMmServerName; source = $receiptSource; readback = 'unique-pinned'; rollback = 'complete'; directoryPlan = $receiptPlan; cleanup = $cleanup }) }
        catch { return [pscustomobject][ordered]@{ Verified = $false; State = 'manual-recovery-required'; RemovedDirectories = @($cleanup.Removed); Cleanup = $cleanup } }
        return [pscustomobject][ordered]@{ Verified = $true; State = 'rolled-back'; RemovedDirectories = @($cleanup.Removed); Cleanup = $cleanup }
    }
    catch {
        return [pscustomobject][ordered]@{ Verified = $false; State = 'manual-recovery-required'; RemovedDirectories = @(); Cleanup = $null }
    }
}

function Invoke-QvwQwenMmRolledBackCleanup {
    param($Hermes, $Validated)

    $cleanup = $null
    try {
        $home = [string]$Validated.Home
        $plan = @($Validated.DirectoryPlan)
        if ($plan.Count -eq 0) { throw 'Qwen-MM receipt directory plan is empty.' }
        $cleanup = Remove-QvwQwenMmNewEmptyDirectories -Hermes $Hermes -Home $home -Plan $plan
        $lock = Get-QvwQwenMmSourceLock -Hermes $Hermes
        $receiptSource = Get-QvwQwenMmLockEvidence -Lock $lock
        $receiptPlan = ConvertTo-QvwQwenMmDirectoryEvidence -Home $home -Plan $plan
        $rollbackState = if ($cleanup.Verified) { 'complete' } else { 'incomplete' }
        [void](Set-QvwQwenMmReceiptEvidence -Home $home -ReceiptPath ([string]$Validated.Path) -Evidence @{ serverName = $script:QvwQwenMmServerName; source = $receiptSource; readback = 'unique-pinned'; rollback = $rollbackState; directoryPlan = $receiptPlan; cleanup = $cleanup })
        return [pscustomobject][ordered]@{
            Verified = [bool]$cleanup.Verified
            State = if ($cleanup.Verified) { 'rolled-back' } else { 'manual-recovery-required' }
            RemovedDirectories = @($cleanup.Removed)
            Cleanup = $cleanup
        }
    }
    catch {
        return [pscustomobject][ordered]@{ Verified = $false; State = 'manual-recovery-required'; RemovedDirectories = if ($null -ne $cleanup) { @($cleanup.Removed) } else { @() }; Cleanup = $cleanup }
    }
}

function Test-QvwQwenMmConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Hermes,
        [AllowNull()][string]$RuntimeConfigPath
    )

    $result = Invoke-QvwQwenMmRuntimeCommand -Hermes $Hermes -Arguments @('mcp', 'test', $script:QvwQwenMmServerName) -TimeoutSeconds 90 -RuntimeConfigPath $RuntimeConfigPath
    $text = ([string]$result.StdOut) + "`n" + ([string]$result.StdErr)
    $parsed = ConvertFrom-QvwMcpTestOutput -ExitCode ([int]$result.ExitCode) -Text $text
    if ($parsed.Connected) {
        return (New-QvwResult -Component 'qwen-mm' -Status 'tests-passed' -Code 'QVW-QMM-CONNECTED' -Message 'Qwen-MM MCP is connected and exposed tools.' -Evidence @{ connected = $true; toolCount = [int]$parsed.ToolCount })
    }
    return (New-QvwResult -Component 'qwen-mm' -Status 'degraded' -Code 'QVW-QMM-CONNECTION-FAILED' -Message 'Qwen-MM MCP did not pass the connected and positive-tool-count contract.' -Evidence @{ connected = $false; toolCount = [int]$parsed.ToolCount; reason = [string]$parsed.Reason })
}

function Install-QvwQwenMm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Hermes,
        [AllowNull()][securestring]$DashScopeKey
    )

    $lock = $null
    try {
        $lock = Get-QvwQwenMmSourceLock -Hermes $Hermes
        [void](Test-QvwQwenMmSourceLock -Lock $lock -AllowTestOverride:([bool](Get-QvwQwenMmProperty -Object $Hermes -Name 'TestMode')))
    }
    catch {
        return (New-QvwResult -Component 'qwen-mm' -Status 'blocked' -Code 'QVW-QMM-SOURCE-LOCK-INVALID' -Message 'The pinned Qwen-MM source lock is invalid; no files were changed.' -Evidence @{})
    }

    $preflight = Test-QvwQwenMmPrerequisite -Hermes $Hermes
    if ([string]$preflight.status -ne 'discovered') { return $preflight }
    $credentialPlan = Get-QvwQwenMmCredentialPlan -Hermes $Hermes -DashScopeKey $DashScopeKey
    if ($null -eq $credentialPlan) {
        return (New-QvwResult -Component 'qwen-mm' -Status 'blocked' -Code 'QVW-QMM-CRED-REQUIRED' -Message 'A persistent DASHSCOPE_API_KEY source is required: inherit Hermes secure .env/environment or provide a SecureString that can be stored in an ACL-protected Qwen-MM config.' -Evidence @{})
    }

    $downloaded = New-Object System.Collections.ArrayList
    try {
        foreach ($sourceFile in @($lock.skillFiles)) {
            $bytes = Get-QvwQwenMmSourceBytes -Hermes $Hermes -Url ([string]$sourceFile.rawUrl)
            $actual = Get-QvwQwenMmBytesSha256 -Bytes ([byte[]]$bytes)
            if ($actual -ne ([string]$sourceFile.sha256).ToLowerInvariant()) { throw 'Qwen-MM source hash mismatch.' }
            [void]$downloaded.Add([pscustomobject][ordered]@{ Path = [string]$sourceFile.path; Bytes = [byte[]]$bytes; Sha256 = $actual })
        }
    }
    catch {
        $code = if ($_.Exception.Message -match '(?i)hash') { 'QVW-QMM-HASH-MISMATCH' } else { 'QVW-QMM-SOURCE-DOWNLOAD-FAILED' }
        return (New-QvwResult -Component 'qwen-mm' -Status 'blocked' -Code $code -Message 'Pinned Qwen-MM Skill download or verification failed; no files were changed.' -Evidence @{})
    }

    $home = [string](Get-QvwQwenMmProperty -Object $Hermes -Name 'Home')
    $skillDir = Get-QvwQwenMmSkillDirectory -Hermes $Hermes
    $configPath = Get-QvwQwenMmConfigPath -Hermes $Hermes
    $credentialConfigPath = if ([string]$credentialPlan.Mode -eq 'acl-config') { [string]$credentialPlan.ConfigPath } else { $null }
    if ([string]::IsNullOrWhiteSpace($home) -or -not (Test-Path -LiteralPath $home -PathType Container) -or
        -not (Test-QvwQwenMmWithinHome -Home $home -Path $skillDir) -or -not (Test-QvwQwenMmWithinHome -Home $home -Path $configPath) -or
        (-not [string]::IsNullOrWhiteSpace($credentialConfigPath) -and (-not (Test-QvwQwenMmWithinHome -Home $home -Path $credentialConfigPath) -or [IO.Path]::GetFullPath($credentialConfigPath) -eq [IO.Path]::GetFullPath($configPath)))) {
        return (New-QvwResult -Component 'qwen-mm' -Status 'blocked' -Code 'QVW-QMM-PATH-INVALID' -Message 'Qwen-MM Skill, MCP, or credential configuration path is outside the active Hermes root or collides with MCP config.' -Evidence @{})
    }

    $directoryPaths = @($skillDir, (Join-Path $skillDir 'references'))
    if (-not [string]::IsNullOrWhiteSpace($credentialConfigPath)) { $directoryPaths += (Split-Path -Parent $credentialConfigPath) }
    $directoryPlan = Get-QvwQwenMmDirectoryPlan -Paths $directoryPaths -Home $home
    $directoryEvidence = ConvertTo-QvwQwenMmDirectoryEvidence -Home $home -Plan $directoryPlan
    $transaction = $null
    $receiptPath = $null
    try {
        $transaction = Start-QvwTransaction -ClientRoot $home -Operation 'install-qwen-mm-api'
        $receiptPath = [string]$transaction.ReceiptPath
        [void](Set-QvwQwenMmReceiptEvidence -Home $home -ReceiptPath $receiptPath -Evidence @{ serverName = $script:QvwQwenMmServerName; source = (Get-QvwQwenMmLockEvidence -Lock $lock); readback = 'unique-pinned'; directoryPlan = $directoryEvidence })
        [void](Backup-QvwFile -Transaction $transaction -Path $configPath -LogicalName 'qwen-mm-mcp-config')
        [void](Set-QvwQwenMmReceiptEvidence -Home $home -ReceiptPath $receiptPath -Evidence @{ serverName = $script:QvwQwenMmServerName; source = (Get-QvwQwenMmLockEvidence -Lock $lock); readback = 'unique-pinned'; directoryPlan = $directoryEvidence })
        if (-not [string]::IsNullOrWhiteSpace($credentialConfigPath)) {
            [void](Backup-QvwFile -Transaction $transaction -Path $credentialConfigPath -LogicalName 'qwen-mm-secure-config')
            [void](Set-QvwQwenMmReceiptEvidence -Home $home -ReceiptPath $receiptPath -Evidence @{ serverName = $script:QvwQwenMmServerName; source = (Get-QvwQwenMmLockEvidence -Lock $lock); readback = 'unique-pinned'; directoryPlan = $directoryEvidence })
            Write-QvwQwenMmCredentialConfig -Hermes $Hermes -Path $credentialConfigPath -DashScopeKey $DashScopeKey
        }
        if (Test-Path -LiteralPath $skillDir -PathType Container) {
            foreach ($existing in @(Get-ChildItem -LiteralPath $skillDir -Recurse -File -Force -ErrorAction Stop)) {
                [void](Backup-QvwFile -Transaction $transaction -Path $existing.FullName -LogicalName ('qwen-mm-skill-' + $existing.Name))
            }
            [void](Set-QvwQwenMmReceiptEvidence -Home $home -ReceiptPath $receiptPath -Evidence @{ serverName = $script:QvwQwenMmServerName; source = (Get-QvwQwenMmLockEvidence -Lock $lock); readback = 'unique-pinned'; directoryPlan = $directoryEvidence })
        }
        foreach ($sourceFile in @($downloaded)) {
            $target = [IO.Path]::GetFullPath((Join-Path $skillDir ([string]$sourceFile.Path)))
            if (-not (Test-QvwQwenMmWithinHome -Home $home -Path $target)) { throw 'Qwen-MM Skill target escaped Hermes root.' }
            [void](Backup-QvwFile -Transaction $transaction -Path $target -LogicalName ('qwen-mm-skill-' + ([string]$sourceFile.Path -replace '[\\/]', '-')))
            [void](Set-QvwQwenMmReceiptEvidence -Home $home -ReceiptPath $receiptPath -Evidence @{ serverName = $script:QvwQwenMmServerName; source = (Get-QvwQwenMmLockEvidence -Lock $lock); readback = 'unique-pinned'; directoryPlan = $directoryEvidence })
            Write-QvwQwenMmBytesAtomic -Path $target -Bytes ([byte[]]$sourceFile.Bytes)
        }

        $interaction = Get-QvwQwenMmMcpAddInteraction -Hermes $Hermes
        # Hermes parses --args as a remainder.  Any official noninteractive
        # flag must therefore precede --args, never follow it.
        $addInvocationArgs = @('mcp', 'add', $script:QvwQwenMmServerName)
        if (-not [string]::IsNullOrWhiteSpace([string]$interaction.Flag)) { $addInvocationArgs += [string]$interaction.Flag }
        $addInvocationArgs += @('--command', [string]$lock.mcp.command, '--args') + @($lock.mcp.args)
        if ([string]::Join(' ', $addInvocationArgs) -match '(?i)--env|DASHSCOPE_API_KEY|fixture-') { throw 'Qwen-MM MCP arguments contain a credential or forbidden env flag.' }
        $addResult = Invoke-QvwQwenMmCommandWithInput -Hermes $Hermes -Arguments $addInvocationArgs -InputText $interaction.InputText -PromptRequired:([string]$interaction.Source -eq 'controlled-stdin') -TimeoutSeconds 90 -RuntimeConfigPath $credentialConfigPath
        $addText = (Protect-QvwQwenMmProcessText (([string]$addResult.StdOut) + "`n" + ([string]$addResult.StdErr) + "`n" + ([string]$addResult.Error)))
        $inputRequirementMet = if ([string]$interaction.Source -eq 'official-flag') { -not [bool](Get-QvwQwenMmProperty -Object $addResult -Name 'InputSent') } else { [bool](Get-QvwQwenMmProperty -Object $addResult -Name 'InputSent') -and [string](Get-QvwQwenMmProperty -Object $addResult -Name 'PromptState') -eq 'accepted' }
        if (-not [bool]$addResult.Succeeded -or -not $inputRequirementMet -or $addText -match '(?im)\b(?:cancelled|canceled|eof|aborted|not\s+added|failed)\b') { throw 'Hermes MCP registration was cancelled or failed.' }
        $readback = Get-QvwQwenMmMcpReadback -Hermes $Hermes -Lock $lock
        $connection = Test-QvwQwenMmConnection -Hermes $Hermes -RuntimeConfigPath $credentialConfigPath
        if ([string]$connection.status -ne 'tests-passed') {
            $rollback = Invoke-QvwQwenMmRollback -Hermes $Hermes -Home $home -ReceiptPath $receiptPath
            $rollbackEvidence = if ($rollback.Verified) { 'verified' } else { 'manual-recovery-required' }
            $status = if ($rollback.Verified) { 'degraded' } else { 'failed' }
            $code = if ($rollback.Verified) { 'QVW-QMM-CONNECTION-FAILED' } else { 'QVW-QMM-ROLLBACK-FAILED' }
            $nativePreserved = if ($rollback.Verified) { $true } else { 'unknown' }
            $message = if ($rollback.Verified) { 'Qwen-MM MCP was not connected; the optional receipt was rolled back and Hermes native vision remains preserved.' } else { 'Qwen-MM MCP was not connected; optional rollback could not be verified, so Hermes native vision state is unknown and manual recovery is required.' }
            return (New-QvwResult -Component 'qwen-mm' -Status $status -Code $code -Message $message -Evidence @{ receiptPath = $receiptPath; rollback = $rollbackEvidence; hermesNativePreserved = $nativePreserved; connected = $false; toolCount = $connection.evidence.toolCount; reason = $connection.evidence.reason })
        }
        $commit = Complete-QvwTransaction -Transaction $transaction -Evidence @{ serverName = $script:QvwQwenMmServerName; source = (Get-QvwQwenMmLockEvidence -Lock $lock); toolCount = [int]$connection.evidence.toolCount; credentialMode = [string]$credentialPlan.Mode; readback = 'unique-pinned'; mcpAddInteraction = [string]$interaction.Source; directoryPlan = $directoryEvidence }
        return (New-QvwResult -Component 'qwen-mm' -Status 'installed' -Code 'QVW-QMM-INSTALLED' -Message 'Pinned Qwen-MM API Skill and MCP were installed, read back uniquely, and connected.' -Evidence @{ receiptPath = $commit.ReceiptPath; serverName = $script:QvwQwenMmServerName; toolCount = [int]$connection.evidence.toolCount; source = (Get-QvwQwenMmLockEvidence -Lock $lock); hermesNativePreserved = $true; readback = 'unique-pinned'; credentialMode = [string]$credentialPlan.Mode; mcpAddInteraction = [string]$interaction.Source; directoryPlan = $directoryEvidence })
    }
    catch {
        $rollback = Invoke-QvwQwenMmRollback -Hermes $Hermes -Home $home -ReceiptPath $receiptPath
        $rollbackEvidence = if ($rollback.Verified) { 'verified' } else { 'manual-recovery-required' }
        $status = if ($rollback.Verified) { 'degraded' } else { 'failed' }
        $code = if ($rollback.Verified) { 'QVW-QMM-INSTALL-ROLLED-BACK' } else { 'QVW-QMM-ROLLBACK-FAILED' }
        $nativePreserved = if ($rollback.Verified) { $true } else { 'unknown' }
        $message = if ($rollback.Verified) { 'Qwen-MM installation failed; only the optional transaction was targeted, and Hermes native vision remains preserved.' } else { 'Qwen-MM installation failed and optional rollback could not be verified; Hermes native vision state is unknown and manual recovery is required.' }
        return (New-QvwResult -Component 'qwen-mm' -Status $status -Code $code -Message $message -Evidence @{ receiptPath = $receiptPath; rollback = $rollbackEvidence; hermesNativePreserved = $nativePreserved })
    }
}

function Get-QvwQwenMmLiveReceipt {
    param($Hermes, [AllowNull()][string]$ReceiptPath)

    $home = [string](Get-QvwQwenMmProperty -Object $Hermes -Name 'Home')
    if ([string]::IsNullOrWhiteSpace($home) -or -not (Test-Path -LiteralPath $home -PathType Container)) { return $null }
    $configured = if (-not [string]::IsNullOrWhiteSpace($ReceiptPath)) { $ReceiptPath } else { [string](Get-QvwQwenMmProperty -Object $Hermes -Name 'QwenMmReceiptPath') }
    if ([string]::IsNullOrWhiteSpace($configured)) { return $null }
    try { return (Get-QvwQwenMmValidatedReceipt -Hermes $Hermes -ReceiptPath $configured -ExpectedStates @('committed')) }
    catch { return $null }
}

function Invoke-QvwQwenMmLiveFailureRollback {
    param($Hermes, $LiveReceipt, [string]$Reason)

    if ($null -eq $LiveReceipt) {
        return (New-QvwResult -Component 'qwen-mm' -Status 'failed' -Code 'QVW-QMM-RECEIPT-REQUIRED' -Message 'Confirmed live verification failed before a valid committed Qwen-MM receipt was supplied; manual recovery is required and Hermes native vision state is unknown.' -Evidence @{ rollback = 'manual-recovery-required'; failure = $Reason; hermesNativePreserved = 'unknown' })
    }
    $rollback = Invoke-QvwQwenMmRollback -Hermes $Hermes -Home ([string]$LiveReceipt.Home) -ReceiptPath ([string]$LiveReceipt.Path)
    if ($rollback.Verified) {
        return (New-QvwResult -Component 'qwen-mm' -Status 'degraded' -Code 'QVW-QMM-LIVE-ROLLBACK-DEGRADED' -Message 'Confirmed Qwen-MM live verification failed; only the validated Qwen-MM receipt was rolled back, and Hermes native vision remains preserved.' -Evidence @{ receiptPath = [string]$LiveReceipt.Path; rollback = 'verified'; failure = $Reason; hermesNativePreserved = $true; nativeVisionRoute = 'preserved'; cleanup = $rollback.Cleanup })
    }
    return (New-QvwResult -Component 'qwen-mm' -Status 'failed' -Code 'QVW-QMM-LIVE-ROLLBACK-FAILED' -Message 'Confirmed Qwen-MM live verification failed and its receipt rollback could not be verified; manual recovery is required. Hermes native vision state is unknown.' -Evidence @{ receiptPath = [string]$LiveReceipt.Path; rollback = 'manual-recovery-required'; failure = $Reason; hermesNativePreserved = 'unknown'; nativeVisionRoute = 'unknown' })
}

function Invoke-QvwQwenMmLiveVerify {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Hermes,
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [AllowNull()][string]$ReceiptPath,
        [switch]$ConfirmPaidCalls
    )

    if (-not $ConfirmPaidCalls) {
        return (New-QvwResult -Component 'qwen-mm' -Status 'blocked' -Code 'QVW-QMM-PAID-CONFIRMATION-REQUIRED' -Message 'Live Qwen-MM verification may call a paid API and requires explicit confirmation.' -Evidence @{})
    }
    $liveReceipt = Get-QvwQwenMmLiveReceipt -Hermes $Hermes -ReceiptPath $ReceiptPath
    if ($null -eq $liveReceipt) { return (Invoke-QvwQwenMmLiveFailureRollback -Hermes $Hermes -LiveReceipt $liveReceipt -Reason 'committed-qwen-mm-receipt-missing') }
    if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) { return (Invoke-QvwQwenMmLiveFailureRollback -Hermes $Hermes -LiveReceipt $liveReceipt -Reason 'image-missing') }
    $callback = Get-QvwQwenMmProperty -Object $Hermes -Name 'QwenMmLiveVerify'
    if ($callback -isnot [scriptblock]) { return (Invoke-QvwQwenMmLiveFailureRollback -Hermes $Hermes -LiveReceipt $liveReceipt -Reason 'live-verifier-unavailable') }
    try {
        $raw = @(& $callback $ImagePath)
        $candidate = if ($raw.Count -gt 0) { $raw[$raw.Count - 1] } else { $null }
        $accepted = ($null -ne $candidate -and $candidate.PSObject.Properties['Accepted'] -and [bool]$candidate.Accepted -and $candidate.PSObject.Properties['Text'] -and ([string]$candidate.Text -match 'QVW-7319'))
        if ($accepted) {
            return (New-QvwResult -Component 'qwen-mm' -Status 'target-accepted' -Code 'QVW-QMM-LIVE-ACCEPTED' -Message 'Qwen-MM returned the expected fixture OCR; Hermes native vision remains preserved.' -Evidence @{ receiptPath = if ($null -ne $liveReceipt) { [string]$liveReceipt.Path } else { $null }; image = 'present'; tool = if ($candidate.PSObject.Properties['Tool']) { [string]$candidate.Tool } else { 'vision_chat' }; expectedText = 'QVW-7319'; hermesNativePreserved = $true; nativeVisionRoute = 'preserved' })
        }
        return (Invoke-QvwQwenMmLiveFailureRollback -Hermes $Hermes -LiveReceipt $liveReceipt -Reason 'expected-evidence-missing')
    }
    catch { return (Invoke-QvwQwenMmLiveFailureRollback -Hermes $Hermes -LiveReceipt $liveReceipt -Reason 'live-verifier-failed') }
}

function Uninstall-QvwQwenMm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Hermes,
        [Parameter(Mandatory = $true)][string]$ReceiptPath
    )

    $rollback = $null
    try {
        $home = [IO.Path]::GetFullPath([string](Get-QvwQwenMmProperty -Object $Hermes -Name 'Home'))
        if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw 'Receipt not found.' }
        $receipt = [IO.File]::ReadAllText($ReceiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        if ([string]$receipt.state -eq 'rolled-back') {
            $validatedRolledBack = Get-QvwQwenMmValidatedReceipt -Hermes $Hermes -ReceiptPath $ReceiptPath -ExpectedStates @('rolled-back')
            $receiptEvidence = $validatedRolledBack.Receipt.evidence
            $cleanupEvidence = Get-QvwQwenMmProperty -Object $receiptEvidence -Name 'cleanup'
            $cleanupComplete = ($null -ne $cleanupEvidence -and
                $null -ne $cleanupEvidence.PSObject.Properties['Verified'] -and [bool]$cleanupEvidence.Verified -and
                $null -ne $cleanupEvidence.PSObject.Properties['Failed'] -and @($cleanupEvidence.Failed).Count -eq 0 -and
                [string](Get-QvwQwenMmProperty -Object $receiptEvidence -Name 'rollback') -eq 'complete')
            if ($cleanupComplete) {
                return (New-QvwResult -Component 'qwen-mm' -Status 'degraded' -Code 'QVW-QMM-ROLLED-BACK' -Message 'The Qwen-MM receipt and its directory cleanup were already verified.' -Evidence @{ receiptPath = $ReceiptPath; rollback = 'verified'; hermesNativePreserved = $true; cleanup = $cleanupEvidence })
            }

            # A prior uninstall can have restored every file but failed while
            # removing a newly-created empty directory.  The receipt remains
            # rolled-back, but it is not complete until this receipt-backed
            # directory plan is safely retried and recorded.
            $retry = Invoke-QvwQwenMmRolledBackCleanup -Hermes $Hermes -Validated $validatedRolledBack
            $rollback = $retry
            if (-not $retry.Verified) { throw 'Receipt cleanup was not verified after retry.' }
            return (New-QvwResult -Component 'qwen-mm' -Status 'degraded' -Code 'QVW-QMM-ROLLED-BACK' -Message 'The Qwen-MM receipt was already rolled back; its pending directory cleanup was retried and verified.' -Evidence @{ receiptPath = $ReceiptPath; rollback = 'verified'; hermesNativePreserved = $true; cleanup = $retry.Cleanup })
        }
        [void](Get-QvwQwenMmValidatedReceipt -Hermes $Hermes -ReceiptPath $ReceiptPath -ExpectedStates @('committed'))
        $rollback = Invoke-QvwQwenMmRollback -Hermes $Hermes -Home $home -ReceiptPath $ReceiptPath
        if (-not $rollback.Verified) { throw 'Receipt rollback was not verified.' }
        return (New-QvwResult -Component 'qwen-mm' -Status 'degraded' -Code 'QVW-QMM-ROLLED-BACK' -Message 'The optional Qwen-MM layer was restored from its receipt; Hermes native vision remains preserved.' -Evidence @{ receiptPath = $ReceiptPath; rollback = 'verified'; hermesNativePreserved = $true; cleanup = $rollback.Cleanup })
    }
    catch {
        return (New-QvwResult -Component 'qwen-mm' -Status 'failed' -Code 'QVW-QMM-ROLLBACK-FAILED' -Message 'The Qwen-MM receipt could not be safely rolled back; Hermes native vision state is unknown and manual recovery is required.' -Evidence @{ receiptPath = $ReceiptPath; rollback = 'manual-recovery-required'; hermesNativePreserved = 'unknown'; cleanup = if ($null -ne $rollback) { $rollback.Cleanup } else { $null } })
    }
}

Export-ModuleMember -Function ConvertFrom-QvwMcpTestOutput, Test-QvwQwenMmSourceLock, Test-QvwQwenMmPrerequisite, Install-QvwQwenMm, Test-QvwQwenMmConnection, Invoke-QvwQwenMmLiveVerify, Uninstall-QvwQwenMm
