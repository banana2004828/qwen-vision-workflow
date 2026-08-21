Set-StrictMode -Version 2.0

$script:QvwTestCases = @()
$script:QvwCurrentDescribe = ''
$script:QvwDescribeDepth = 0

function Get-QvwSafeDiagnostic {
    param($Value)

    if ($null -eq $Value) {
        return 'type=null'
    }

    try {
        if ($Value -is [string]) {
            return ("type=String,length={0}" -f $Value.Length)
        }
        if ($Value -is [System.Collections.IDictionary]) {
            return ("type={0},count={1}" -f $Value.GetType().Name, $Value.Count)
        }
        if ($Value -is [System.Collections.ICollection]) {
            return ("type={0},count={1}" -f $Value.GetType().Name, $Value.Count)
        }
        return ("type={0}" -f $Value.GetType().Name)
    }
    catch {
        return 'type=unknown'
    }
}

function Get-QvwComparableValue {
    param($Value)

    if ($null -eq $Value) {
        return '<null>'
    }

    if ($Value -is [string]) {
        return [string]$Value
    }
    if ($Value -is [bool] -or $Value -is [char] -or $Value -is [System.Enum] -or $Value -is [DateTime] -or $Value -is [DateTimeOffset] -or $Value -is [TimeSpan] -or $Value -is [Guid]) {
        return $Value
    }
    try {
        if ([Convert]::GetTypeCode($Value) -ne [TypeCode]::Object) {
            return $Value
        }
    }
    catch {
    }

    try {
        return ($Value | ConvertTo-Json -Depth 8 -Compress)
    }
    catch {
        return $Value.GetType().FullName
    }
}

function Write-QvwHarnessCaseLine {
    param($Case)

    $safeDescribe = Get-QvwSafeDiagnostic $Case.Describe
    $safeName = Get-QvwSafeDiagnostic $Case.Name
    if ($Case.Passed) {
        Write-Output ("PASS: describe={0}; name={1}" -f $safeDescribe, $safeName)
    }
    else {
        $safeError = Get-QvwSafeDiagnostic $Case.Error
        Write-Output ("FAIL: describe={0}; name={1}; error={2}" -f $safeDescribe, $safeName, $safeError)
    }
}

function Describe-Qvw {
    param(
        [string]$Name,
        [scriptblock]$Body
    )

    $previousDescribe = $script:QvwCurrentDescribe
    $caseCountBefore = @($script:QvwTestCases).Count
    $script:QvwDescribeDepth++
    $script:QvwCurrentDescribe = $Name
    try {
        $errorCountBefore = $Error.Count
        $bodyOutput = @()
        try {
            $bodyOutput = @(& $Body *>&1)
        }
        catch {
            throw 'Describe-Qvw body failed'
        }

        $capturedErrors = @($bodyOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        $newErrorCount = $Error.Count - $errorCountBefore
        if ($newErrorCount -lt 0) {
            $newErrorCount = 0
        }
        for ($index = 0; $index -lt $newErrorCount; $index++) {
            $Error.RemoveAt(0)
        }
        if ($capturedErrors.Count -gt 0 -or $newErrorCount -gt 0) {
            throw 'Describe-Qvw body emitted a non-terminating error'
        }

        if ($script:QvwDescribeDepth -eq 1) {
            for ($index = $caseCountBefore; $index -lt @($script:QvwTestCases).Count; $index++) {
                Write-QvwHarnessCaseLine $script:QvwTestCases[$index]
            }
        }
    }
    finally {
        $script:QvwDescribeDepth--
        $script:QvwCurrentDescribe = $previousDescribe
    }
}

function It-Qvw {
    param(
        [string]$Name,
        [scriptblock]$Body
    )

    $passed = $false
    $errorMessage = $null
    $errorCountBefore = $Error.Count
    $bodyOutput = @()
    try {
        $bodyOutput = @(& $Body *>&1)
        $passed = $true
    }
    catch {
        $errorMessage = Get-QvwSafeDiagnostic $_.Exception
    }

    $capturedErrors = @($bodyOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
    $newErrorCount = $Error.Count - $errorCountBefore
    if ($passed -and ($capturedErrors.Count -gt 0 -or $newErrorCount -gt 0)) {
        for ($index = 0; $index -lt $newErrorCount; $index++) {
            if ($Error[$index].Exception -is [Microsoft.PowerShell.Commands.WriteErrorException]) {
                $passed = $false
                $errorMessage = 'type=NonTerminatingError'
                break
            }
        }
        if ($passed -and $capturedErrors.Count -gt 0) {
            $passed = $false
            $errorMessage = 'type=NonTerminatingError'
        }
    }
    for ($index = 0; $index -lt $newErrorCount; $index++) {
        $Error.RemoveAt(0)
    }

    $case = [pscustomobject][ordered]@{
        Describe = $script:QvwCurrentDescribe
        Name = $Name
        Passed = $passed
        Error = $errorMessage
    }
    $script:QvwTestCases += $case

    if ($script:QvwDescribeDepth -eq 0) {
        Write-QvwHarnessCaseLine $case
    }
}

function Get-QvwTestCases {
    return @($script:QvwTestCases)
}

function Assert-QvwEqual {
    param($Actual, $Expected)

    $actualJson = Get-QvwComparableValue $Actual
    $expectedJson = Get-QvwComparableValue $Expected
    if ($actualJson -ne $expectedJson) {
        throw ("Assert-QvwEqual failed ({0} vs {1})" -f (Get-QvwSafeDiagnostic $Actual), (Get-QvwSafeDiagnostic $Expected))
    }
}

function Assert-QvwTrue {
    param($Actual)

    if (-not [bool]$Actual) {
        throw ("Assert-QvwTrue failed ({0})" -f (Get-QvwSafeDiagnostic $Actual))
    }
}

function Assert-QvwFalse {
    param($Actual)

    if ([bool]$Actual) {
        throw ("Assert-QvwFalse failed ({0})" -f (Get-QvwSafeDiagnostic $Actual))
    }
}

function Assert-QvwMatch {
    param(
        [string]$Actual,
        [string]$Pattern
    )

    if ($Actual -notmatch $Pattern) {
        throw 'Assert-QvwMatch failed'
    }
}

function Assert-QvwNotMatch {
    param(
        [string]$Actual,
        [string]$Pattern
    )

    if ($Actual -match $Pattern) {
        throw 'Assert-QvwNotMatch failed'
    }
}

function Assert-QvwContains {
    param($Collection, $Expected)

    if ($null -eq $Collection -or -not ($Collection -contains $Expected)) {
        throw ("Assert-QvwContains failed ({0})" -f (Get-QvwSafeDiagnostic $Collection))
    }
}

function Assert-QvwThrows {
    param(
        [scriptblock]$Body,
        [string]$Pattern
    )

    $thrown = $false
    $errorMessage = $null
    $errorCountBefore = $Error.Count
    $bodyOutput = @()
    try {
        $bodyOutput = @(& $Body *>&1)
        $bodyErrors = @($bodyOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        if ($bodyErrors.Count -gt 0) {
            $thrown = $true
            $errorMessage = $bodyErrors[0].Exception.Message
        }
    }
    catch {
        $thrown = $true
        $errorMessage = $_.Exception.Message
    }

    $newErrorCount = $Error.Count - $errorCountBefore
    for ($index = 0; $index -lt $newErrorCount; $index++) {
        $Error.RemoveAt(0)
    }

    if (-not $thrown) {
        throw 'Assert-QvwThrows failed: no error was thrown'
    }
    if ($errorMessage -notlike $Pattern) {
        throw 'Assert-QvwThrows failed: error pattern did not match'
    }
}

function New-QvwTempDirectory {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("qvw-" + [guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($path) | Out-Null
    return $path
}

function Get-QvwTreeHash {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Directory not found: $Path"
    }

    $root = (Resolve-Path -LiteralPath $Path).Path
    $files = @(Get-ChildItem -LiteralPath $root -File -Recurse | Sort-Object FullName)
    $lines = foreach ($file in $files) {
        $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/')
        $fileHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
        "{0}`t{1}" -f $relative, $fileHash
    }
    $manifest = [string]::Join("`n", @($lines))
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($manifest)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToUpperInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-QvwZipNames {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Zip file not found: $Path"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
    try {
        return @($archive.Entries | ForEach-Object { $_.FullName } | Sort-Object)
    }
    finally {
        $archive.Dispose()
    }
}
