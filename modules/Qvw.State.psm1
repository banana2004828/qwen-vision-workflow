Set-StrictMode -Version 2.0

function Protect-QvwStateText {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ($null -eq $Text) {
        return $null
    }
    $result = $Text
    $result = [regex]::Replace($result, '(?i)(authorization\s*:\s*bearer\s+)\S+', '$1[REDACTED]')
    $result = [regex]::Replace($result, '(?i)(\bbearer\s+token(?:\s*[:=]\s*|\s+))\S+', '$1[REDACTED]')
    $result = [regex]::Replace($result, '(?i)(\bbearer\s*[:=]\s*)\S+', '$1[REDACTED]')
    $result = [regex]::Replace($result, '(?i)((?:authorization|api[-_ ]?key|access[-_ ]?key|access[-_ ]?token|auth[-_ ]?token|refresh[-_ ]?token|session[-_ ]?token|token|secret|password|passwd|cookie)\s*[=:]\s*)\S+', '$1[REDACTED]')
    $redactor = Get-Command -Name Protect-QvwText -ErrorAction SilentlyContinue
    if ($redactor) {
        $result = Protect-QvwText -Text $result -Secrets @()
    }
    return $result
}

function Test-QvwStateCredentialShape {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $false }
    $redactor = Get-Command -Name Protect-QvwText -ErrorAction SilentlyContinue
    if ($redactor) {
        try {
            if ((Protect-QvwText -Text $Text -Secrets @()) -ne $Text) {
                return $true
            }
        }
        catch { }
    }
    return $Text -match '(?i)(?:\bauthorization\s*:\s*bearer\s+\S+|\bbearer\s+token(?:\s*[:=]\s*|\s+)\S+|\bbearer\s*[:=]\s*\S+|\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|AKIA[A-Z0-9]{16}|AIza[A-Za-z0-9_-]{30,})\b|\b(?:DASHSCOPE_API_KEY|DEEPSEEK_API_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY|authorization|api[-_ ]?key|access[-_ ]?key|access[-_ ]?token|auth[-_ ]?token|refresh[-_ ]?token|session[-_ ]?token|token|secret|password|passwd|cookie)\s*[=:]\s*\S+)'
}

function Test-QvwSafeRelativePath {
    param([AllowNull()][string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $false }
    if ([IO.Path]::IsPathRooted($RelativePath)) { return $false }
    if ($RelativePath -match '^[\\/]') { return $false }
    if ($RelativePath -match '(?i)(^|[\\/])\.\.([\\/]|$)') { return $false }
    if ($RelativePath -match ':') { return $false }
    return $true
}

function Test-QvwNoReparsePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $cursor = $fullPath
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            try {
                $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw 'Reparse point is not allowed.'
                }
            }
            catch {
                if ($_.Exception.Message -eq 'Reparse point is not allowed.') { throw }
                throw 'Unable to inspect the controlled path.'
            }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent -or $parent.FullName -eq $cursor) { break }
        $cursor = $parent.FullName
    }
    return $true
}

function Test-QvwPathWithinRoot {
    param([string]$Root,[string]$Path)

    $rootFull = ([IO.Path]::GetFullPath($Root)).TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
    $pathFull = [IO.Path]::GetFullPath($Path)
    return $pathFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-QvwStateSafeValue {
    param(
        $Value,
        [string]$KeyName,
        [int]$Depth = 0
    )

    if ($Depth -gt 8) {
        return '[REDACTED]'
    }
    if ($KeyName -match '(?i)(?:api|access|auth|private|encryption|signing)?key|token|secret|password|passwd|cookie|authorization') {
        return '[REDACTED]'
    }
    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [string]) {
        return Protect-QvwStateText -Text $Value
    }
    if (
        $Value -is [bool] -or
        $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal] -or
        $Value -is [datetime] -or $Value -is [datetimeoffset] -or
        $Value -is [timespan] -or $Value -is [guid] -or
        $Value.GetType().IsEnum
    ) {
        return $Value
    }
    if ($Value -is [System.Security.SecureString] -or $Value -is [System.Net.NetworkCredential]) {
        return '[REDACTED]'
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $safe = [ordered]@{}
        foreach ($entry in $Value.GetEnumerator()) {
            $name = [string]$entry.Key
            $safeName = Protect-QvwStateText -Text $name
            if ((Test-QvwStateCredentialShape -Text $name) -or $safeName -ne $name) {
                $safeName = '[REDACTED]'
            }
            $safe[$safeName] = ConvertTo-QvwStateSafeValue -Value $entry.Value -KeyName $name -Depth ($Depth + 1)
        }
        return $safe
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $safe = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $name = [string]$property.Name
            $safeName = Protect-QvwStateText -Text $name
            if ((Test-QvwStateCredentialShape -Text $name) -or $safeName -ne $name) {
                $safeName = '[REDACTED]'
            }
            $safe[$safeName] = ConvertTo-QvwStateSafeValue -Value $property.Value -KeyName $name -Depth ($Depth + 1)
        }
        return [pscustomobject]$safe
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        return @($Value | ForEach-Object { ConvertTo-QvwStateSafeValue -Value $_ -KeyName $null -Depth ($Depth + 1) })
    }
    return '[REDACTED]'
}

function Test-QvwStateEvidenceSafe {
    param(
        $Value,
        [int]$Depth = 0
    )

    if ($Depth -gt 8) { return $false }
    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) {
        return -not (Test-QvwStateCredentialShape -Text $Value)
    }
    if ($Value -is [bool] -or $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or
        $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal] -or
        $Value -is [datetime] -or $Value -is [datetimeoffset] -or
        $Value -is [timespan] -or $Value -is [guid] -or $Value.GetType().IsEnum) {
        return $true
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($entry in $Value.GetEnumerator()) {
            if (Test-QvwStateCredentialShape -Text ([string]$entry.Key)) { return $false }
            if (-not (Test-QvwStateEvidenceSafe -Value $entry.Value -Depth ($Depth + 1))) { return $false }
        }
        return $true
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if (Test-QvwStateCredentialShape -Text ([string]$property.Name)) { return $false }
            if (-not (Test-QvwStateEvidenceSafe -Value $property.Value -Depth ($Depth + 1))) { return $false }
        }
        return $true
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        foreach ($item in $Value) {
            if (-not (Test-QvwStateEvidenceSafe -Value $item -Depth ($Depth + 1))) { return $false }
        }
        return $true
    }
    return $false
}

function Get-QvwStateSha256 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $stream = $null
    $sha = $null
    $digest = $null
    try {
        $stream = [IO.File]::OpenRead($Path)
        $sha = [Security.Cryptography.SHA256]::Create()
        $digest = $sha.ComputeHash($stream)
        return ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        if ($digest -is [byte[]]) {
            [Array]::Clear($digest, 0, $digest.Length)
        }
        if ($stream) { $stream.Dispose() }
        if ($sha) { $sha.Dispose() }
        $digest = $null
    }
}

function Write-QvwStateBytesAtomic {
    param(
        [string]$Path,
        [byte[]]$Bytes
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    $temp = "$Path.qvw-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllBytes($temp, $Bytes)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                [IO.File]::Replace($temp, $Path, [string]$null)
            }
            catch {
                # File.Replace is unavailable for a few mounted/virtualized
                # Windows paths; same-volume Move-Item is the safe fallback.
                Move-Item -LiteralPath $temp -Destination $Path -Force -ErrorAction Stop | Out-Null
            }
        }
        else {
            [IO.File]::Move($temp, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

function Write-QvwStateReceipt {
    param(
        $Transaction,
        [string]$State,
        [hashtable]$Evidence = @{}
    )

    if ((Test-QvwStateCredentialShape -Text ([string]$Transaction.ClientRoot)) -or
        (Test-QvwStateCredentialShape -Text ([string]$Transaction.Operation))) {
        throw 'Transaction metadata is not safe to record.'
    }
    foreach ($candidate in @($Transaction.Entries)) {
        if ((Test-QvwStateCredentialShape -Text ([string]$candidate.Path)) -or
            (Test-QvwStateCredentialShape -Text ([string]$candidate.LogicalName))) {
            throw 'Transaction metadata is not safe to record.'
        }
    }
    $safeEntries = @($Transaction.Entries | ForEach-Object {
        [ordered]@{
            path = $_.Path
            logicalName = $_.LogicalName
            beforeExists = [bool]$_.BeforeExists
            beforeSha256 = $_.BeforeSha256
            backupRelativePath = $_.BackupRelativePath
            afterSha256 = $_.AfterSha256
        }
    })
    $receipt = [ordered]@{
        schemaVersion = 1
        receiptId = $Transaction.ReceiptId
        toolVersion = 'qwen-vision-workflow-task2'
        createdUtc = $Transaction.CreatedUtc
        updatedUtc = [DateTime]::UtcNow.ToString('o')
        clientRoot = $Transaction.ClientRoot
        operation = (Protect-QvwStateText -Text ([string]$Transaction.Operation))
        state = $State
        entryMode = if (@($Transaction.Entries).Count -eq 0) { 'zero-files' } else { 'files' }
        entries = $safeEntries
        evidence = ConvertTo-QvwStateSafeValue -Value $Evidence -KeyName $null
    }
    if (-not (Test-QvwPathWithinRoot -Root $Transaction.ClientRoot -Path $Transaction.ReceiptPath)) {
        throw 'Receipt path is outside its client root.'
    }
    [void](Test-QvwNoReparsePath -Path $Transaction.ReceiptPath)
    $json = $receipt | ConvertTo-Json -Depth 16
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    Write-QvwStateBytesAtomic -Path $Transaction.ReceiptPath -Bytes $bytes
    return $receipt
}

function Start-QvwTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClientRoot,
        [Parameter(Mandatory = $true)]
        [string]$Operation
    )

    try {
        if ((Test-QvwStateCredentialShape -Text $ClientRoot) -or (Test-QvwStateCredentialShape -Text $Operation)) {
            throw 'Transaction metadata is not safe to record.'
        }
        if (-not (Test-Path -LiteralPath $ClientRoot -PathType Container)) {
            throw 'Client root is not a directory.'
        }
        # Inspect the caller-supplied path before Resolve-Path so a junction or
        # symlink is not silently normalized to its target and accepted.
        [void](Test-QvwNoReparsePath -Path $ClientRoot)
        $resolvedRoot = (Resolve-Path -LiteralPath $ClientRoot -ErrorAction Stop).Path
        [void](Test-QvwNoReparsePath -Path $resolvedRoot)
        $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 6).ToLowerInvariant()
        $receiptId = "qvw-$stamp-$suffix"
        $backupRoot = Join-Path $resolvedRoot (Join-Path 'backups\qwen-vision-workflow' $receiptId)
        [void](Test-QvwNoReparsePath -Path $backupRoot)
        [IO.Directory]::CreateDirectory((Join-Path $backupRoot 'files')) | Out-Null
        $transaction = [pscustomobject][ordered]@{
            ReceiptId = $receiptId
            ClientRoot = $resolvedRoot
            Operation = $Operation
            BackupRoot = $backupRoot
            ReceiptPath = Join-Path $backupRoot 'receipt.json'
            CreatedUtc = [DateTime]::UtcNow.ToString('o')
            State = 'started'
            Entries = (New-Object System.Collections.ArrayList)
        }
        [void](Write-QvwStateReceipt -Transaction $transaction -State 'started' -Evidence @{})
        return $transaction
    }
    catch {
        throw 'Unable to start the QVW transaction.'
    }
}

function Backup-QvwFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Transaction,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$LogicalName
    )

    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        if ((Test-QvwStateCredentialShape -Text $fullPath) -or (Test-QvwStateCredentialShape -Text $LogicalName)) {
            throw 'Controlled metadata is not safe to record.'
        }
        if (-not (Test-QvwPathWithinRoot -Root $Transaction.ClientRoot -Path $fullPath)) {
            throw 'Controlled file is outside the transaction client root.'
        }
        [void](Test-QvwNoReparsePath -Path $fullPath)
        $existing = @($Transaction.Entries | Where-Object { $_.Path -eq $fullPath })
        if ($existing.Count -gt 0) {
            return $existing[0]
        }
        $beforeExists = Test-Path -LiteralPath $fullPath -PathType Leaf
        $beforeSha = if ($beforeExists) { Get-QvwStateSha256 -Path $fullPath } else { $null }
        $safeName = ($LogicalName -replace '[^A-Za-z0-9_.-]', '_')
        if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = 'file' }
        $relative = Join-Path 'files' ("{0:D3}-{1}.bak" -f ($Transaction.Entries.Count + 1), $safeName)
        $backupPath = Join-Path $Transaction.BackupRoot $relative
        if ($beforeExists) {
            [IO.File]::Copy($fullPath, $backupPath, $true)
        }
        $entry = [pscustomobject][ordered]@{
            Path = $fullPath
            LogicalName = $LogicalName
            BeforeExists = [bool]$beforeExists
            BeforeSha256 = $beforeSha
            BackupRelativePath = if ($beforeExists) { $relative } else { $null }
            AfterSha256 = $null
        }
        [void]$Transaction.Entries.Add($entry)
        [void](Write-QvwStateReceipt -Transaction $Transaction -State $Transaction.State -Evidence @{})
        return $entry
    }
    catch {
        throw 'Unable to back up the controlled file.'
    }
}

function Set-QvwEnvValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Transaction,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [System.Security.SecureString]$Value
    )

    if ($Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw 'Environment variable name is invalid.'
    }
    $bstr = [IntPtr]::Zero
    $plain = $null
    $updated = $null
    $bytes = $null
    try {
        $entry = Backup-QvwFile -Transaction $Transaction -Path $Path -LogicalName ("env-$Name")
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        foreach ($character in $plain.ToCharArray()) {
            if ([Char]::IsControl($character)) {
                throw 'Environment value contains a control character.'
            }
        }
        $fullPath = [IO.Path]::GetFullPath($Path)
        $text = if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            [IO.File]::ReadAllText($fullPath, [Text.Encoding]::UTF8)
        }
        else { '' }
        $escapedName = [regex]::Escape($Name)
        $pattern = "(?m)^(?<prefix>[ \t]*$escapedName[ \t]*=[ \t]*).*$"
        if ([regex]::IsMatch($text, $pattern)) {
            $evaluator = [Text.RegularExpressions.MatchEvaluator]{
                param($match)
                return $match.Groups['prefix'].Value + $plain
            }
            $updated = [regex]::Replace($text, $pattern, $evaluator)
        }
        else {
            $lineEnding = if ($text -match "`r`n") { "`r`n" } else { "`n" }
            $separator = if ($text.Length -gt 0 -and -not ($text.EndsWith("`n") -or $text.EndsWith("`r"))) { $lineEnding } else { '' }
            $updated = $text + $separator + $Name + '=' + $plain
        }
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($updated)
        Write-QvwStateBytesAtomic -Path $fullPath -Bytes $bytes
        return $entry
    }
    catch {
        try { [void](Undo-QvwTransaction -ReceiptPath $Transaction.ReceiptPath) } catch { }
        throw 'Unable to update the environment file.'
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        if ($bytes -is [byte[]]) {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
        $plain = $null
        $updated = $null
    }
}

function Complete-QvwTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Transaction,
        [hashtable]$Evidence = @{}
    )

    try {
        foreach ($entry in @($Transaction.Entries)) {
            $entry.AfterSha256 = Get-QvwStateSha256 -Path $entry.Path
        }
        $Transaction.State = 'committed'
        [void](Write-QvwStateReceipt -Transaction $Transaction -State 'committed' -Evidence $Evidence)
        return [pscustomobject][ordered]@{
            ReceiptId = $Transaction.ReceiptId
            ReceiptPath = $Transaction.ReceiptPath
            State = 'committed'
        }
    }
    catch {
        throw 'Unable to commit the QVW transaction.'
    }
}

function Get-QvwReceipt {
    param([string]$ReceiptPath)

    if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
        throw 'Receipt not found.'
    }
    try {
        return [IO.File]::ReadAllText($ReceiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw 'Receipt is invalid.'
    }
}

function Test-QvwReceiptSchema {
    param($Receipt,[string]$ReceiptPath)

    if ($null -eq $Receipt -or $Receipt -isnot [System.Management.Automation.PSCustomObject]) {
        throw 'Receipt schema is invalid.'
    }
    foreach ($required in @('schemaVersion', 'receiptId', 'toolVersion', 'createdUtc', 'updatedUtc', 'clientRoot', 'operation', 'state', 'entryMode', 'entries')) {
        if ($null -eq $Receipt.PSObject.Properties[$required]) { throw 'Receipt schema is invalid.' }
    }
    if (-not ($Receipt.schemaVersion -is [byte] -or $Receipt.schemaVersion -is [int16] -or
            $Receipt.schemaVersion -is [int32] -or $Receipt.schemaVersion -is [int64]) -or
        [int]$Receipt.schemaVersion -ne 1) {
        throw 'Receipt schema is invalid.'
    }
    foreach ($textField in @('receiptId', 'toolVersion', 'clientRoot', 'operation', 'state', 'entryMode')) {
        $property = $Receipt.PSObject.Properties[$textField]
        if ($null -eq $property -or $property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            throw 'Receipt schema is invalid.'
        }
    }
    foreach ($dateField in @('createdUtc', 'updatedUtc')) {
        $dateProperty = $Receipt.PSObject.Properties[$dateField]
        if ($null -eq $dateProperty -or ($dateProperty.Value -isnot [string] -and
                $dateProperty.Value -isnot [datetime] -and $dateProperty.Value -isnot [datetimeoffset])) {
            throw 'Receipt schema is invalid.'
        }
    }
    $evidenceProperty = $Receipt.PSObject.Properties['evidence']
    if ($null -eq $evidenceProperty -or -not (Test-QvwStateEvidenceSafe -Value $evidenceProperty.Value)) {
        throw 'Receipt schema is invalid.'
    }
    if ([string]$Receipt.receiptId -notmatch '^qvw-\d{8}-\d{6}-[a-f0-9]{6}$') {
        throw 'Receipt schema is invalid.'
    }
    if ($Receipt.entries -isnot [array]) { throw 'Receipt schema is invalid.' }
    if ([string]$Receipt.state -notin @('started', 'committed', 'rollback-failed', 'rolled-back')) {
        throw 'Receipt schema is invalid.'
    }
    if ([string]$Receipt.entryMode -notin @('files', 'zero-files')) { throw 'Receipt schema is invalid.' }
    try {
        [void][DateTime]::Parse([string]$Receipt.createdUtc)
        [void][DateTime]::Parse([string]$Receipt.updatedUtc)
    }
    catch { throw 'Receipt schema is invalid.' }

    $root = [string]$Receipt.clientRoot
    if ([string]::IsNullOrWhiteSpace($root) -or (Test-QvwStateCredentialShape -Text $root)) { throw 'Receipt schema is invalid.' }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Receipt schema is invalid.' }
    [void](Test-QvwNoReparsePath -Path $root)
    $receiptRoot = Split-Path -Parent $ReceiptPath
    if (-not (Test-QvwPathWithinRoot -Root $root -Path $receiptRoot)) { throw 'Receipt schema is invalid.' }
    [void](Test-QvwNoReparsePath -Path $receiptRoot)
    [void](Test-QvwNoReparsePath -Path $ReceiptPath)

    $entries = @($Receipt.entries)
    if ($entries.Count -eq 0) {
        if ([string]$Receipt.entryMode -ne 'zero-files') { throw 'Receipt schema is invalid.' }
        return $true
    }
    if ([string]$Receipt.entryMode -ne 'files') { throw 'Receipt schema is invalid.' }
    foreach ($entry in $entries) {
        if ($null -eq $entry -or $entry -isnot [System.Management.Automation.PSCustomObject]) { throw 'Receipt schema is invalid.' }
        foreach ($required in @('path', 'logicalName', 'beforeExists', 'beforeSha256', 'backupRelativePath', 'afterSha256')) {
            if ($null -eq $entry.PSObject.Properties[$required]) { throw 'Receipt schema is invalid.' }
        }
        foreach ($textField in @('path', 'logicalName', 'beforeSha256', 'backupRelativePath', 'afterSha256')) {
            $property = $entry.PSObject.Properties[$textField]
            if ($null -eq $property -or ($null -ne $property.Value -and $property.Value -isnot [string])) {
                throw 'Receipt schema is invalid.'
            }
        }
        if ($entry.beforeExists -isnot [bool]) { throw 'Receipt schema is invalid.' }
        $target = [string]$entry.path
        if ([string]::IsNullOrWhiteSpace($target) -or (Test-QvwStateCredentialShape -Text $target) -or
            -not (Test-QvwPathWithinRoot -Root $root -Path $target)) { throw 'Receipt schema is invalid.' }
        [void](Test-QvwNoReparsePath -Path $target)
        if ([string]::IsNullOrWhiteSpace([string]$entry.logicalName) -or (Test-QvwStateCredentialShape -Text ([string]$entry.logicalName))) {
            throw 'Receipt schema is invalid.'
        }
        if ([bool]$entry.beforeExists) {
            if ([string]$entry.beforeSha256 -notmatch '^[0-9a-fA-F]{64}$' -or
                -not (Test-QvwSafeRelativePath -RelativePath ([string]$entry.backupRelativePath))) { throw 'Receipt schema is invalid.' }
            $backup = [IO.Path]::GetFullPath((Join-Path $receiptRoot ([string]$entry.backupRelativePath)))
            if (-not (Test-QvwPathWithinRoot -Root $receiptRoot -Path $backup)) { throw 'Receipt schema is invalid.' }
            [void](Test-QvwNoReparsePath -Path $backup)
        }
        else {
            if (-not [string]::IsNullOrEmpty([string]$entry.beforeSha256) -or -not [string]::IsNullOrEmpty([string]$entry.backupRelativePath)) {
                throw 'Receipt schema is invalid.'
            }
        }
        if (-not [string]::IsNullOrEmpty([string]$entry.afterSha256) -and [string]$entry.afterSha256 -notmatch '^[0-9a-fA-F]{64}$') {
            throw 'Receipt schema is invalid.'
        }
    }
    return $true
}

function Undo-QvwTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReceiptPath
    )

    $receipt = $null
    $receiptValid = $false
    try {
        $receipt = Get-QvwReceipt -ReceiptPath $ReceiptPath
        [void](Test-QvwReceiptSchema -Receipt $receipt -ReceiptPath $ReceiptPath)
        $receiptValid = $true
        if ([string]$receipt.state -eq 'rolled-back') {
            return [pscustomobject][ordered]@{
                ReceiptId = [string]$receipt.receiptId
                ReceiptPath = $ReceiptPath
                State = 'rolled-back'
            }
        }
        $root = [string]$receipt.clientRoot
        $receiptRoot = Split-Path -Parent $ReceiptPath
        foreach ($entry in @($receipt.entries)) {
            $target = [string]$entry.path
            if (-not (Test-QvwPathWithinRoot -Root $root -Path $target)) {
                throw 'Receipt target is outside its client root.'
            }
            [void](Test-QvwNoReparsePath -Path $target)
            $beforeExists = [bool]$entry.beforeExists
            if ($beforeExists) {
                $relative = [string]$entry.backupRelativePath
                if (-not (Test-QvwSafeRelativePath -RelativePath $relative)) {
                    throw 'Receipt backup path is invalid.'
                }
                $backup = [IO.Path]::GetFullPath((Join-Path $receiptRoot $relative))
                if (-not (Test-QvwPathWithinRoot -Root $receiptRoot -Path $backup)) {
                    throw 'Receipt backup path is outside its receipt root.'
                }
                [void](Test-QvwNoReparsePath -Path $backup)
                if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
                    throw 'Receipt backup is missing.'
                }
                $bytes = [IO.File]::ReadAllBytes($backup)
                Write-QvwStateBytesAtomic -Path $target -Bytes $bytes
                if ((Get-QvwStateSha256 -Path $target) -ne ([string]$entry.beforeSha256).ToLowerInvariant()) {
                    throw 'Restored file hash did not match the receipt.'
                }
            }
            else {
                if (Test-Path -LiteralPath $target -PathType Leaf) {
                    Remove-Item -LiteralPath $target -Force -ErrorAction Stop | Out-Null
                }
                if (Test-Path -LiteralPath $target) {
                    throw 'New controlled path could not be removed.'
                }
            }
        }

        $tx = [pscustomobject][ordered]@{
            ReceiptId = [string]$receipt.receiptId
            ClientRoot = $root
            Operation = [string]$receipt.operation
            BackupRoot = $receiptRoot
            ReceiptPath = $ReceiptPath
            CreatedUtc = [string]$receipt.createdUtc
            State = 'rolled-back'
            Entries = (New-Object System.Collections.ArrayList)
        }
        foreach ($entry in @($receipt.entries)) {
            [void]$tx.Entries.Add([pscustomobject][ordered]@{
                Path = [string]$entry.path
                LogicalName = [string]$entry.logicalName
                BeforeExists = [bool]$entry.beforeExists
                BeforeSha256 = [string]$entry.beforeSha256
                BackupRelativePath = [string]$entry.backupRelativePath
                AfterSha256 = [string]$entry.afterSha256
            })
        }
        [void](Write-QvwStateReceipt -Transaction $tx -State 'rolled-back' -Evidence @{ rollback = 'complete' })
        return [pscustomobject][ordered]@{
            ReceiptId = [string]$receipt.receiptId
            ReceiptPath = $ReceiptPath
            State = 'rolled-back'
        }
    }
    catch {
        if ($null -ne $receipt -and $receiptValid) {
            try {
                $root = [string]$receipt.clientRoot
                $tx = [pscustomobject][ordered]@{
                    ReceiptId = [string]$receipt.receiptId
                    ClientRoot = $root
                    Operation = [string]$receipt.operation
                    BackupRoot = Split-Path -Parent $ReceiptPath
                    ReceiptPath = $ReceiptPath
                    CreatedUtc = [string]$receipt.createdUtc
                    State = 'rollback-failed'
                    Entries = (New-Object System.Collections.ArrayList)
                }
                foreach ($entry in @($receipt.entries)) {
                    [void]$tx.Entries.Add([pscustomobject][ordered]@{
                        Path = [string]$entry.path
                        LogicalName = [string]$entry.logicalName
                        BeforeExists = [bool]$entry.beforeExists
                        BeforeSha256 = [string]$entry.beforeSha256
                        BackupRelativePath = [string]$entry.backupRelativePath
                        AfterSha256 = [string]$entry.afterSha256
                    })
                }
                [void](Write-QvwStateReceipt -Transaction $tx -State 'rollback-failed' -Evidence @{ rollback = 'incomplete' })
            }
            catch { }
        }
        throw 'Unable to complete transaction rollback.'
    }
}

Export-ModuleMember -Function Start-QvwTransaction, Backup-QvwFile, Set-QvwEnvValue, Complete-QvwTransaction, Undo-QvwTransaction
