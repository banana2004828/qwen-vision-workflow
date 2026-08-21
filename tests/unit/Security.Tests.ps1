Describe-Qvw 'Qvw.Security' {
    It-Qvw 'redacts exact and bearer secrets' {
        $out = Protect-QvwText -Text 'Authorization: Bearer abc123; key=abc123' -Secrets @('abc123')
        Assert-QvwNotMatch $out 'abc123'
        Assert-QvwMatch $out '\[REDACTED\]'
    }

    It-Qvw 'returns a short lowercase sha256 fingerprint for a SecureString' {
        $secret = New-Object System.Security.SecureString
        foreach ($character in 'fingerprint-fixture-secret'.ToCharArray()) {
            [void]$secret.AppendChar($character)
        }
        $secret.MakeReadOnly()
        $fingerprint = Get-QvwSecretFingerprint -Secret $secret
        Assert-QvwMatch $fingerprint '^sha256:[0-9a-f]{12}$'
        Assert-QvwNotMatch $fingerprint 'fingerprint-fixture-secret'
    }

    It-Qvw 'rejects a sensitive artifact without disclosing its contents' {
        $root = New-QvwTempDirectory
        $path = Join-Path $root 'diagnostic.txt'
        Set-Content -LiteralPath $path -Value 'DASHSCOPE_API_KEY=fixture-artifact-secret' -NoNewline
        $scan = Assert-QvwArtifactSafe -Path $root
        Assert-QvwFalse $scan.Safe
        Assert-QvwTrue ($scan.FindingCount -gt 0)
        $json = $scan | ConvertTo-Json -Depth 8
        Assert-QvwNotMatch $json 'fixture-artifact-secret'
    }

    It-Qvw 'accepts a credential-free artifact' {
        $root = New-QvwTempDirectory
        $path = Join-Path $root 'safe.txt'
        Set-Content -LiteralPath $path -Value 'status=installed' -NoNewline
        $scan = Assert-QvwArtifactSafe -Path $root
        Assert-QvwTrue $scan.Safe
        Assert-QvwEqual $scan.FindingCount 0
    }

    It-Qvw 'detects high-confidence credential shapes in ordinary text' {
        $root = New-QvwTempDirectory
        $path = Join-Path $root 'notes.txt'
        $values = @(
            ('sk-' + ('A' * 40)),
            ('ghp_' + ('B' * 36)),
            ('eyJhbGciOiJIUzI1NiJ9.' + ('C' * 24) + '.' + ('D' * 24)),
            ('AKIA' + ('E' * 16)),
            ('AIza' + ('F' * 35))
        )
        Set-Content -LiteralPath $path -Value ($values -join "`n") -NoNewline
        $scan = Assert-QvwArtifactSafe -Path $root
        Assert-QvwFalse $scan.Safe
        Assert-QvwEqual $scan.FindingCount 5
        $json = $scan | ConvertTo-Json -Depth 8
        foreach ($value in $values) {
            Assert-QvwNotMatch $json ([regex]::Escape($value))
        }
    }

    It-Qvw 'decodes UTF-16 artifacts and allows only explicit safe placeholders' {
        $root = New-QvwTempDirectory
        $utf16Path = Join-Path $root 'utf16.env'
        $placeholderPath = Join-Path $root 'placeholder.env'
        $utf16Bytes = [Text.Encoding]::Unicode.GetBytes("DASHSCOPE_API_KEY=fixture-utf16-secret")
        [IO.File]::WriteAllBytes($utf16Path, $utf16Bytes)
        Set-Content -LiteralPath $placeholderPath -Value 'DASHSCOPE_API_KEY=your-key-here' -NoNewline

        $utf16Scan = Assert-QvwArtifactSafe -Path $utf16Path
        $placeholderScan = Assert-QvwArtifactSafe -Path $placeholderPath
        Assert-QvwFalse $utf16Scan.Safe
        Assert-QvwTrue $placeholderScan.Safe
    }

    It-Qvw 'fails closed for undecodable text candidates' {
        $root = New-QvwTempDirectory
        $path = Join-Path $root 'unknown.txt'
        [IO.File]::WriteAllBytes($path, [byte[]](0xFF, 0xFE, 0xFF, 0x00, 0x7F))
        $scan = Assert-QvwArtifactSafe -Path $path
        Assert-QvwFalse $scan.Safe
        Assert-QvwTrue ($scan.FindingCount -gt 0)
        $json = $scan | ConvertTo-Json -Depth 8
        Assert-QvwNotMatch $json 'FFFEFF'
    }

    It-Qvw 'detects UTF-32 without a BOM and does not decode NUL bytes as UTF-8' {
        $root = New-QvwTempDirectory
        $littlePath = Join-Path $root 'utf32-le.env'
        $bigPath = Join-Path $root 'utf32-be.env'
        $little = New-Object System.Text.UTF32Encoding($false, $false, $true)
        $big = New-Object System.Text.UTF32Encoding($true, $false, $true)
        [IO.File]::WriteAllBytes($littlePath, $little.GetBytes('DASHSCOPE_API_KEY=fixture-utf32-le'))
        [IO.File]::WriteAllBytes($bigPath, $big.GetBytes('DASHSCOPE_API_KEY=fixture-utf32-be'))

        $scan = Assert-QvwArtifactSafe -Path $root
        Assert-QvwFalse $scan.Safe
        Assert-QvwTrue ($scan.FindingCount -ge 2)
        $json = $scan | ConvertTo-Json -Depth 8
        Assert-QvwNotMatch $json 'fixture-utf32-(?:le|be)'
    }

    It-Qvw 'fails closed with a finding when an artifact tree contains a reparse point' {
        $root = New-QvwTempDirectory
        $target = New-QvwTempDirectory
        $junction = Join-Path $root 'linked-directory'
        $created = $false
        try {
            New-Item -ItemType Junction -Path $junction -Target $target -ErrorAction Stop | Out-Null
            $created = $true
        }
        catch {
            # Junction creation may be disabled by local Windows policy. The
            # path inventory guard is still covered by the implementation and
            # the integration fixture documents this environment limitation.
        }
        if ($created) {
            $scan = Assert-QvwArtifactSafe -Path $root
            Assert-QvwFalse $scan.Safe
            Assert-QvwContains (@($scan.Findings | ForEach-Object { $_.code })) 'reparse-point'
            $json = $scan | ConvertTo-Json -Depth 8
            Assert-QvwNotMatch $json ([regex]::Escape($target))
        }
        else {
            Assert-QvwTrue $true
        }
    }
}
