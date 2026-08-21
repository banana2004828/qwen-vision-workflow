Set-StrictMode -Version 2.0

$script:QvwRedactedMarker = '[REDACTED]'

function Protect-QvwText {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,
        [string[]]$Secrets = @()
    )

    if ($null -eq $Text) {
        return $null
    }

    $result = $Text
    foreach ($secret in @($Secrets)) {
        if (-not [string]::IsNullOrEmpty([string]$secret)) {
            $result = $result.Replace([string]$secret, $script:QvwRedactedMarker)
        }
    }

    # Keep the field name (which is useful for diagnosis) but never return its value.
    $result = [regex]::Replace(
        $result,
        '(?i)(authorization\s*:\s*bearer\s+)\S+',
        '$1[REDACTED]'
    )
    $result = [regex]::Replace(
        $result,
        '(?i)(\bbearer\s+token(?:\s*[:=]\s*|\s+))\S+',
        '$1[REDACTED]'
    )
    $result = [regex]::Replace(
        $result,
        '(?i)(\bbearer\s*[:=]\s*)\S+',
        '$1[REDACTED]'
    )
    $result = [regex]::Replace(
        $result,
        '(?i)((?:authorization|api[-_ ]?key|access[-_ ]?key|access[-_ ]?token|auth[-_ ]?token|refresh[-_ ]?token|session[-_ ]?token|token|secret|password|passwd|cookie)\s*[=:]\s*)\S+',
        '$1[REDACTED]'
    )
    $credentialShapes = @(
        '(?i)\bsk-[A-Za-z0-9_-]{16,}\b',
        '(?i)\bgh[pousr]_[A-Za-z0-9]{20,}\b',
        '(?i)\bgithub_pat_[A-Za-z0-9_]{20,}\b',
        '(?i)\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b',
        '\bAKIA[A-Z0-9]{16}\b',
        '\bAIza[A-Za-z0-9_-]{30,}\b'
    )
    foreach ($shape in $credentialShapes) {
        $result = [regex]::Replace($result, $shape, $script:QvwRedactedMarker)
    }
    return $result
}

function Get-QvwSecretFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.SecureString]$Secret
    )

    $bstr = [IntPtr]::Zero
    $plain = $null
    $bytes = $null
    $sha = $null
    $digest = $null
    $hex = $null
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $bytes = [Text.Encoding]::UTF8.GetBytes($plain)
        $sha = [Security.Cryptography.SHA256]::Create()
        $digest = $sha.ComputeHash($bytes)
        $hex = ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
        return 'sha256:' + $hex.Substring(0, 12)
    }
    catch {
        throw 'Unable to fingerprint the supplied secret.'
    }
    finally {
        if ($bytes -is [byte[]]) {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
        if ($sha) {
            $sha.Dispose()
        }
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        # The managed string cannot be reliably zeroed on all supported runtimes;
        # dropping it immediately keeps its lifetime limited to this try/finally.
        $plain = $null
        $digest = $null
        $hex = $null
    }
}

function Get-QvwArtifactFiles {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw 'Artifact not found.'
    }

    $files = New-Object System.Collections.ArrayList
    $findings = New-Object System.Collections.ArrayList
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $reparse = [IO.FileAttributes]::ReparsePoint
    if (($item.Attributes -band $reparse) -ne 0) {
        [void]$findings.Add([pscustomobject][ordered]@{
            file = $script:QvwRedactedMarker
            line = 0
            code = 'reparse-point'
            match = $script:QvwRedactedMarker
        })
        return [pscustomobject][ordered]@{ Files = @(); Findings = @($findings) }
    }
    if (-not $item.PSIsContainer) {
        [void]$files.Add($item)
        return [pscustomobject][ordered]@{ Files = @($files); Findings = @($findings) }
    }

    $pending = New-Object System.Collections.Stack
    $pending.Push($item.FullName)
    while ($pending.Count -gt 0) {
        $directory = [string]$pending.Pop()
        try {
            $children = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)
        }
        catch {
            [void]$findings.Add([pscustomobject][ordered]@{
                file = $script:QvwRedactedMarker
                line = 0
                code = 'artifact-enumeration'
                match = $script:QvwRedactedMarker
            })
            continue
        }
        foreach ($child in $children) {
            if (($child.Attributes -band $reparse) -ne 0) {
                [void]$findings.Add([pscustomobject][ordered]@{
                    file = $script:QvwRedactedMarker
                    line = 0
                    code = 'reparse-point'
                    match = $script:QvwRedactedMarker
                })
                continue
            }
            if ($child.PSIsContainer) {
                $pending.Push($child.FullName)
            }
            else {
                [void]$files.Add($child)
            }
        }
    }
    return [pscustomobject][ordered]@{ Files = @($files); Findings = @($findings) }
}

function Get-QvwArtifactText {
    param([System.IO.FileInfo]$File)

    try {
        $bytes = [IO.File]::ReadAllBytes($File.FullName)
        if ($bytes.Length -eq 0) {
            return [pscustomobject][ordered]@{ Kind = 'text'; Text = '' }
        }

        $knownBinary = @('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.zip', '.gz', '.7z', '.exe', '.dll', '.ico') -contains $File.Extension.ToLowerInvariant()
        $encoding = $null
        $offset = 0
        if ($bytes.Length -ge 4 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
            $encoding = New-Object System.Text.UTF32Encoding($true, $true, $true)
            $offset = 4
        }
        elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) {
            $encoding = New-Object System.Text.UTF32Encoding($false, $true, $true)
            $offset = 4
        }
        elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $encoding = New-Object System.Text.UTF8Encoding($true, $true)
            $offset = 3
        }
        elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $encoding = New-Object System.Text.UnicodeEncoding($false, $true, $true)
            $offset = 2
        }
        elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            $encoding = New-Object System.Text.UnicodeEncoding($true, $true, $true)
            $offset = 2
        }
        else {
            $unitCount = [Math]::Floor($bytes.Length / 4)
            $little32Score = 0
            $big32Score = 0
            for ($unit = 0; $unit -lt $unitCount; $unit++) {
                $index = $unit * 4
                if ($bytes[$index + 1] -eq 0 -and $bytes[$index + 2] -eq 0 -and $bytes[$index + 3] -eq 0) {
                    $little32Score++
                }
                if ($bytes[$index] -eq 0 -and $bytes[$index + 1] -eq 0 -and $bytes[$index + 2] -eq 0) {
                    $big32Score++
                }
            }
            $utf32Threshold = [Math]::Max(1, [Math]::Ceiling($unitCount * 0.5))
            if ($bytes.Length % 4 -eq 0 -and $unitCount -gt 0 -and $little32Score -ge $utf32Threshold) {
                $encoding = New-Object System.Text.UTF32Encoding($false, $false, $true)
            }
            elseif ($bytes.Length % 4 -eq 0 -and $unitCount -gt 0 -and $big32Score -ge $utf32Threshold) {
                $encoding = New-Object System.Text.UTF32Encoding($true, $false, $true)
            }
            else {
                $evenNulls = 0
                $oddNulls = 0
                for ($index = 0; $index -lt $bytes.Length; $index++) {
                    if ($bytes[$index] -eq 0) {
                        if (($index % 2) -eq 0) { $evenNulls++ } else { $oddNulls++ }
                    }
                }
                $pairCount = [Math]::Floor($bytes.Length / 2)
                $utf16Threshold = [Math]::Max(1, [Math]::Ceiling($pairCount * 0.5))
                if ($bytes.Length % 2 -eq 0 -and $oddNulls -ge $utf16Threshold -and $evenNulls -lt $utf16Threshold) {
                    $encoding = New-Object System.Text.UnicodeEncoding($false, $false, $true)
                }
                elseif ($bytes.Length % 2 -eq 0 -and $evenNulls -ge $utf16Threshold -and $oddNulls -lt $utf16Threshold) {
                    $encoding = New-Object System.Text.UnicodeEncoding($true, $false, $true)
                }
                elseif (($evenNulls + $oddNulls) -gt 0) {
                    if ($knownBinary) {
                        return [pscustomobject][ordered]@{ Kind = 'binary'; Text = $null }
                    }
                    return [pscustomobject][ordered]@{ Kind = 'undecodable'; Text = $null }
                }
                else {
                    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
                }
            }
        }

        try {
            $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
            return [pscustomobject][ordered]@{ Kind = 'text'; Text = $text }
        }
        catch {
            if ($knownBinary) {
                return [pscustomobject][ordered]@{ Kind = 'binary'; Text = $null }
            }
            return [pscustomobject][ordered]@{ Kind = 'undecodable'; Text = $null }
        }
    }
    catch {
        return [pscustomobject][ordered]@{ Kind = 'undecodable'; Text = $null }
    }
}

function Test-QvwSafePlaceholder {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $candidate = $Value.Trim().Trim('"', "'")
    return $candidate -match '(?i)^(?:your[-_ ]?(?:api[-_ ]?)?key(?:[-_ ]?here)?|your[-_ ]?token|replace[-_ ]?me|change[-_ ]?me|changeme|placeholder|example|<[^>\r\n]+>|\$\{[A-Za-z_][A-Za-z0-9_]*\})$'
}

function Assert-QvwArtifactSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $findings = New-Object System.Collections.ArrayList
    $patterns = @(
        @{ Code = 'authorization-bearer'; Pattern = '(?i)\bauthorization\s*:\s*bearer\s+\S+' },
        @{ Code = 'bearer-token'; Pattern = '(?i)\bbearer\s+token(?:\s*[:=]\s*|\s+)\S+' },
        @{ Code = 'bearer-assignment'; Pattern = '(?i)\bbearer\s*[:=]\s*\S+' },
        @{ Code = 'credential-assignment'; Pattern = '(?i)\b(?:DASHSCOPE_API_KEY|DEEPSEEK_API_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY|authorization|api[-_ ]?key|access[-_ ]?key|access[-_ ]?token|auth[-_ ]?token|refresh[-_ ]?token|session[-_ ]?token|token|secret|password|passwd|cookie)\s*[=:]\s*(?<value>\S+)' },
        @{ Code = 'credential-sk'; Pattern = '(?i)\bsk-[A-Za-z0-9_-]{16,}\b' },
        @{ Code = 'credential-github'; Pattern = '(?i)\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b' },
        @{ Code = 'credential-jwt'; Pattern = '(?i)\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b' },
        @{ Code = 'credential-aws'; Pattern = '\bAKIA[A-Z0-9]{16}\b' },
        @{ Code = 'credential-google'; Pattern = '\bAIza[A-Za-z0-9_-]{30,}\b' }
    )

    $inventory = Get-QvwArtifactFiles -Path $Path
    foreach ($inventoryFinding in @($inventory.Findings)) {
        [void]$findings.Add($inventoryFinding)
    }
    foreach ($file in @($inventory.Files)) {
        $decoded = Get-QvwArtifactText -File $file
        if ($decoded.Kind -eq 'binary') {
            continue
        }
        if ($decoded.Kind -eq 'undecodable') {
            [void]$findings.Add([pscustomobject][ordered]@{
                file = $script:QvwRedactedMarker
                line = 0
                code = 'undecodable-text'
                match = $script:QvwRedactedMarker
            })
            continue
        }
        $text = $decoded.Text
        $lineNumber = 0
        foreach ($line in ($text -split "`r?`n")) {
            $lineNumber++
            foreach ($rule in $patterns) {
                $match = [regex]::Match($line, $rule.Pattern)
                if ($match.Success) {
                    if ($rule.Code -eq 'credential-assignment' -and (Test-QvwSafePlaceholder -Value $match.Groups['value'].Value)) {
                        continue
                    }
                    [void]$findings.Add([pscustomobject][ordered]@{
                        file = $script:QvwRedactedMarker
                        line = $lineNumber
                        code = $rule.Code
                        match = $script:QvwRedactedMarker
                    })
                    break
                }
            }
        }
    }

    return [pscustomobject][ordered]@{
        Safe = (@($findings).Count -eq 0)
        FindingCount = @($findings).Count
        Findings = @($findings)
    }
}

Export-ModuleMember -Function Protect-QvwText, Get-QvwSecretFingerprint, Assert-QvwArtifactSafe
