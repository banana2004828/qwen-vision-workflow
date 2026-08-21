Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$fixtureModulePath = Join-Path $repoRoot 'modules\Qvw.ImageFixture.psm1'
Import-Module -Name $fixtureModulePath -Force -ErrorAction Stop

Describe-Qvw 'Deterministic Qwen vision image fixture' {
    It-Qvw 'creates a stable valid PNG without user data' {
        $root = New-QvwTempDirectory
        try {
            $firstPath = Join-Path $root 'qvw-first.png'
            $secondPath = Join-Path $root 'qvw-second.png'
            $first = New-QvwImageFixture -Path $firstPath
            $second = New-QvwImageFixture -Path $secondPath

            Assert-QvwTrue (Test-Path -LiteralPath $first.Path -PathType Leaf)
            $bytes = [IO.File]::ReadAllBytes($first.Path)
            Assert-QvwEqual ([BitConverter]::ToString($bytes[0..7])) '89-50-4E-47-0D-0A-1A-0A'
            Assert-QvwEqual $first.ExpectedText 'QVW-7319'
            Assert-QvwTrue ($first.ExpectedRelations.Count -ge 3)
            Assert-QvwEqual $first.Sha256 ((Get-FileHash -LiteralPath $first.Path -Algorithm SHA256).Hash.ToUpperInvariant())
            Assert-QvwEqual $first.Sha256 $second.Sha256
            Assert-QvwEqual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($first.Path))) ([Convert]::ToBase64String([IO.File]::ReadAllBytes($second.Path)))
            Assert-QvwNotMatch ([IO.File]::ReadAllText($first.Path, [Text.Encoding]::GetEncoding(28591))) 'Lenovo|Users|AppData|fixture-secret|DASHSCOPE'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }

    It-Qvw 'returns the fixed spatial facts needed by the verifier' {
        $root = New-QvwTempDirectory
        try {
            $fixture = New-QvwImageFixture -Path (Join-Path $root 'qvw.png')
            Assert-QvwEqual $fixture.ExpectedText 'QVW-7319'
            Assert-QvwContains $fixture.ExpectedRelations 'red circle left of blue square'
            Assert-QvwContains $fixture.ExpectedRelations 'green triangle below red circle'
            Assert-QvwContains $fixture.ExpectedRelations 'green triangle below blue square'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
}
