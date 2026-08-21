Set-StrictMode -Version 2.0

$script:QvwRedactedValue = '[REDACTED]'
$script:QvwMaxEvidenceDepth = 8

function Test-QvwCredentialShape {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $false
    }

    $patterns = @(
        '(?i)\bsk-[A-Za-z0-9][A-Za-z0-9_-]{16,}\b',
        '(?i)\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}\b',
        '(?i)\bgithub_pat_[A-Za-z0-9_]{20,}\b',
        '(?i)\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b',
        '(?i)\bAKIA[0-9A-Z]{16}\b',
        '(?i)\bAIza[A-Za-z0-9_-]{20,}\b'
    )
    foreach ($pattern in $patterns) {
        if ($Text -match $pattern) {
            return $true
        }
    }
    return $false
}

function Test-QvwSensitiveKey {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    if (Test-QvwCredentialShape $Name) {
        return $true
    }

    $compactName = $Name -replace '[^A-Za-z0-9]', ''
    if ($compactName -match '(?i)^(?:api|access|auth|client|private|public|encryption|signing|session)?key$') {
        return $true
    }
    if ($compactName -match '(?i)(?:authorization|auth|bearer|token|secret|password|passwd|cookie|session|credential)') {
        return $true
    }
    return $false
}

function Test-QvwSensitiveText {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $false
    }

    if (Test-QvwCredentialShape $Text) {
        return $true
    }

    $patterns = @(
        '(?i)\bbearer\s+\S+',
        '(?i)\b(?:api[-_ ]?key|access[-_ ]?key|authorization|auth|token|cookie|password|passwd|secret|session|credential|key)\s*[:=]\s*\S+',
        '(?i)\b(?:bearer|token|cookie|password|passwd|secret|session|credential)\b'
    )
    foreach ($pattern in $patterns) {
        if ($Text -match $pattern) {
            return $true
        }
    }
    return $false
}

function Get-QvwSafePropertyName {
    param(
        [string]$Name,
        [hashtable]$UsedNames
    )

    $candidate = $Name
    if ([string]::IsNullOrEmpty($candidate) -or (Test-QvwCredentialShape $candidate)) {
        $candidate = '[REDACTED_KEY]'
    }

    $base = $candidate
    $suffix = 1
    while ($UsedNames.ContainsKey($candidate)) {
        $candidate = '{0}-{1}' -f $base, $suffix
        $suffix++
    }
    $UsedNames[$candidate] = $true
    return $candidate
}

function Test-QvwSafeScalar {
    param($Value)

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or $Value -is [char]) {
        return $true
    }
    if ($Value -is [System.Enum] -or $Value -is [DateTime] -or $Value -is [DateTimeOffset] -or $Value -is [TimeSpan] -or $Value -is [Guid]) {
        return $true
    }
    try {
        return ([Convert]::GetTypeCode($Value) -ne [TypeCode]::Object)
    }
    catch {
        return $false
    }
}

function Test-QvwExplicitCollection {
    param($Value)

    if ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Array] -or $Value -is [System.Collections.IList] -or $Value -is [System.Collections.ICollection]) {
        return $true
    }
    return ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string]))
}

function Protect-QvwEvidence {
    param(
        $Value,
        [string]$KeyName,
        [int]$Depth = 0,
        [System.Collections.Generic.HashSet[int]]$Visited = $null
    )

    if ($null -eq $Visited) {
        $Visited = New-Object 'System.Collections.Generic.HashSet[int]'
    }
    if (Test-QvwSensitiveKey $KeyName) {
        return $script:QvwRedactedValue
    }
    if ($null -eq $Value) {
        return $null
    }
    if ($Depth -gt $script:QvwMaxEvidenceDepth) {
        return $script:QvwRedactedValue
    }
    if ($Value -is [string]) {
        if (Test-QvwSensitiveText $Value) {
            return $script:QvwRedactedValue
        }
        return $Value
    }
    if (Test-QvwSafeScalar $Value) {
        return $Value
    }

    $isObjectGraph = ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Management.Automation.PSCustomObject] -or (Test-QvwExplicitCollection $Value))
    if (-not $isObjectGraph) {
        return $script:QvwRedactedValue
    }

    try {
        $referenceId = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Value)
        if (-not $Visited.Add($referenceId)) {
            return $script:QvwRedactedValue
        }
        try {
            if ($Value -is [System.Collections.IDictionary]) {
                $safeDictionary = [ordered]@{}
                $usedNames = @{}
                foreach ($entry in $Value.GetEnumerator()) {
                    if ($entry.Key -is [string]) {
                        $entryName = [string]$entry.Key
                    }
                    else {
                        $entryName = '[REDACTED_KEY]'
                    }
                    $safeName = Get-QvwSafePropertyName $entryName $usedNames
                    $valueKeyName = if (Test-QvwCredentialShape $entryName) { $safeName } else { $entryName }
                    $safeDictionary[$safeName] = Protect-QvwEvidence $entry.Value $valueKeyName ($Depth + 1) $Visited
                }
                return $safeDictionary
            }
            if ($Value -is [System.Management.Automation.PSCustomObject]) {
                $safeObject = [ordered]@{}
                $usedNames = @{}
                foreach ($property in $Value.PSObject.Properties) {
                    $propertyName = [string]$property.Name
                    $safeName = Get-QvwSafePropertyName $propertyName $usedNames
                    $valueKeyName = if (Test-QvwCredentialShape $propertyName) { $safeName } else { $propertyName }
                    $safeObject[$safeName] = Protect-QvwEvidence $property.Value $valueKeyName ($Depth + 1) $Visited
                }
                return [pscustomobject]$safeObject
            }
            if (Test-QvwExplicitCollection $Value) {
                $safeItems = @()
                foreach ($item in $Value) {
                    $safeItems += ,(Protect-QvwEvidence $item $null ($Depth + 1) $Visited)
                }
                return $safeItems
            }
            return $script:QvwRedactedValue
        }
        finally {
            [void]$Visited.Remove($referenceId)
        }
    }
    catch {
        return $script:QvwRedactedValue
    }
}

function New-QvwResult {
    [CmdletBinding()]
    param(
        [string]$Component,
        [string]$Status,
        [string]$Code,
        [string]$Message,
        [hashtable]$Evidence = @{}
    )

    $allowed = @(
        'discovered',
        'backed-up',
        'installed',
        'tests-passed',
        'target-accepted',
        'final-accepted',
        'degraded',
        'unverified',
        'failed',
        'blocked'
    )

    if (-not ($allowed -ccontains $Status)) {
        throw 'Unknown status'
    }

    [pscustomobject][ordered]@{
        schemaVersion = 1
        component = Protect-QvwEvidence $Component $null
        status = $Status
        code = Protect-QvwEvidence $Code $null
        message = Protect-QvwEvidence $Message $null
        evidence = Protect-QvwEvidence $Evidence $null
        timestampUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Write-QvwResult {
    [CmdletBinding()]
    param(
        $Result,
        [switch]$AsJson
    )

    $safeResult = Protect-QvwEvidence $Result $null
    if ($AsJson) {
        $safeResult | ConvertTo-Json -Depth 8
    }
    else {
        $safeResult
    }
}

Export-ModuleMember -Function New-QvwResult, Write-QvwResult
