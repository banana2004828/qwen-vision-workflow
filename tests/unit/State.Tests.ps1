Describe-Qvw 'Qvw.State' {
    It-Qvw 'creates a receipt and records hashes without secret evidence' {
        $root = New-QvwTempDirectory
        $path = Join-Path $root 'config.yaml'
        Set-Content -LiteralPath $path -Value 'before' -NoNewline
        $tx = Start-QvwTransaction -ClientRoot $root -Operation install
        Backup-QvwFile -Transaction $tx -Path $path -LogicalName config
        Set-Content -LiteralPath $path -Value 'after' -NoNewline
        $completed = Complete-QvwTransaction -Transaction $tx -Evidence @{ note = 'safe'; apiKey = 'fixture-receipt-secret' }
        Assert-QvwEqual $completed.State 'committed'
        Assert-QvwTrue (Test-Path -LiteralPath $tx.ReceiptPath -PathType Leaf)
        $json = [IO.File]::ReadAllText($tx.ReceiptPath, [Text.Encoding]::UTF8)
        Assert-QvwNotMatch $json 'fixture-receipt-secret'
        Assert-QvwMatch $json '"afterSha256"'
    }

    It-Qvw 'updates only the exact env key and preserves unrelated values' {
        $root = New-QvwTempDirectory
        $envPath = Join-Path $root '.env'
        Set-Content -LiteralPath $envPath -Value "OTHER=value`nDASHSCOPE_API_KEY_OLD=keep`nDASHSCOPE_API_KEY=old" -NoNewline
        $tx = Start-QvwTransaction -ClientRoot $root -Operation env
        $secret = New-Object System.Security.SecureString
        foreach ($character in 'fixture-env-secret'.ToCharArray()) {
            [void]$secret.AppendChar($character)
        }
        $secret.MakeReadOnly()
        Set-QvwEnvValue -Transaction $tx -Path $envPath -Name 'DASHSCOPE_API_KEY' -Value $secret
        $text = [IO.File]::ReadAllText($envPath, [Text.Encoding]::UTF8)
        Assert-QvwMatch $text 'OTHER=value'
        Assert-QvwMatch $text 'DASHSCOPE_API_KEY_OLD=keep'
        Assert-QvwMatch $text 'DASHSCOPE_API_KEY=fixture-env-secret'
        Undo-QvwTransaction -ReceiptPath $tx.ReceiptPath | Out-Null
        Assert-QvwMatch ([IO.File]::ReadAllText($envPath, [Text.Encoding]::UTF8)) 'DASHSCOPE_API_KEY=old'
    }

    It-Qvw 'does not mark a transaction rolled back before restoration finishes' {
        $root = New-QvwTempDirectory
        $path = Join-Path $root 'config.ini'
        Set-Content -LiteralPath $path -Value 'before' -NoNewline
        $tx = Start-QvwTransaction -ClientRoot $root -Operation test
        Backup-QvwFile -Transaction $tx -Path $path -LogicalName config
        Set-Content -LiteralPath $path -Value 'after' -NoNewline
        $result = Undo-QvwTransaction -ReceiptPath $tx.ReceiptPath
        Assert-QvwFalse ($result -is [array])
        Assert-QvwEqual $result.GetType().Name 'PSCustomObject'
        Assert-QvwEqual $result.State 'rolled-back'
        $restored = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        Assert-QvwEqual $restored 'before'
    }

    It-Qvw 'redacts credential-shaped and unknown evidence objects' {
        $root = New-QvwTempDirectory
        $tx = Start-QvwTransaction -ClientRoot $root -Operation test
        $secretValue = 'sk-' + ('A' * 40)
        $credential = New-Object Net.NetworkCredential ('user', $secretValue)
        Complete-QvwTransaction -Transaction $tx -Evidence @{ note = $secretValue; opaque = $credential } | Out-Null
        $json = [IO.File]::ReadAllText($tx.ReceiptPath, [Text.Encoding]::UTF8)
        Assert-QvwNotMatch $json ([regex]::Escape($secretValue))
        Assert-QvwMatch $json '\[REDACTED\]'
    }

    It-Qvw 'refuses to control a file outside the client root' {
        $root = New-QvwTempDirectory
        $outsideRoot = New-QvwTempDirectory
        $outside = Join-Path $outsideRoot 'outside.txt'
        Set-Content -LiteralPath $outside -Value 'safe' -NoNewline
        $tx = Start-QvwTransaction -ClientRoot $root -Operation test
        Assert-QvwThrows { Backup-QvwFile -Transaction $tx -Path $outside -LogicalName outside } '*'
        Assert-QvwEqual $tx.Entries.Count 0
    }

    It-Qvw 'does not write credential-shaped evidence keys or metadata' {
        $root = New-QvwTempDirectory
        $credentialKey = 'sk-' + ('A' * 40)
        $tx = Start-QvwTransaction -ClientRoot $root -Operation test
        Complete-QvwTransaction -Transaction $tx -Evidence @{ $credentialKey = 'safe-value' } | Out-Null
        $json = [IO.File]::ReadAllText($tx.ReceiptPath, [Text.Encoding]::UTF8)
        Assert-QvwNotMatch $json ([regex]::Escape($credentialKey))

        $path = Join-Path $root 'config.yaml'
        Set-Content -LiteralPath $path -Value 'safe' -NoNewline
        $tx2 = Start-QvwTransaction -ClientRoot $root -Operation test
        Assert-QvwThrows { Backup-QvwFile -Transaction $tx2 -Path $path -LogicalName $credentialKey } '*'
        $json2 = [IO.File]::ReadAllText($tx2.ReceiptPath, [Text.Encoding]::UTF8)
        Assert-QvwNotMatch $json2 ([regex]::Escape($credentialKey))
    }

    It-Qvw 'rejects dangerous control characters in secure environment values' {
        $root = New-QvwTempDirectory
        $envPath = Join-Path $root '.env'
        Set-Content -LiteralPath $envPath -Value 'DASHSCOPE_API_KEY=old' -NoNewline
        $tx = Start-QvwTransaction -ClientRoot $root -Operation env
        $secret = New-Object System.Security.SecureString
        foreach ($character in ('fixture' + [char]0 + 'secret').ToCharArray()) {
            [void]$secret.AppendChar($character)
        }
        $secret.MakeReadOnly()
        Assert-QvwThrows { Set-QvwEnvValue -Transaction $tx -Path $envPath -Name 'DASHSCOPE_API_KEY' -Value $secret } '*'
        Assert-QvwMatch ([IO.File]::ReadAllText($envPath, [Text.Encoding]::UTF8)) 'DASHSCOPE_API_KEY=old'
    }

    It-Qvw 'rejects a receipt with empty entries unless explicitly marked zero-files' {
        $root = New-QvwTempDirectory
        $tx = Start-QvwTransaction -ClientRoot $root -Operation test
        Complete-QvwTransaction -Transaction $tx -Evidence @{} | Out-Null
        $receipt = [IO.File]::ReadAllText($tx.ReceiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $receipt | Add-Member -NotePropertyName entryMode -NotePropertyValue 'files' -Force
        $receipt.state = 'committed'
        $json = $receipt | ConvertTo-Json -Depth 16
        [IO.File]::WriteAllText($tx.ReceiptPath, $json, (New-Object Text.UTF8Encoding($false)))
        Assert-QvwThrows { Undo-QvwTransaction -ReceiptPath $tx.ReceiptPath } '*'
        $after = [IO.File]::ReadAllText($tx.ReceiptPath, [Text.Encoding]::UTF8)
        Assert-QvwNotMatch $after '"state"\s*:\s*"rolled-back"'
    }

    It-Qvw 'rejects malformed receipt types and credential-shaped evidence' {
        $root = New-QvwTempDirectory
        $tx = Start-QvwTransaction -ClientRoot $root -Operation test
        Complete-QvwTransaction -Transaction $tx -Evidence @{} | Out-Null
        $receipt = [IO.File]::ReadAllText($tx.ReceiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $receipt.evidence = [pscustomobject]@{ note = ('sk-' + ('A' * 40)) }
        $json = $receipt | ConvertTo-Json -Depth 16
        [IO.File]::WriteAllText($tx.ReceiptPath, $json, (New-Object Text.UTF8Encoding($false)))
        Assert-QvwThrows { Undo-QvwTransaction -ReceiptPath $tx.ReceiptPath } '*'
        $after = [IO.File]::ReadAllText($tx.ReceiptPath, [Text.Encoding]::UTF8)
        Assert-QvwNotMatch $after '"state"\s*:\s*"rolled-back"'
    }

    It-Qvw 'rejects null entries and non-boolean entry flags' {
        $root = New-QvwTempDirectory
        $tx = Start-QvwTransaction -ClientRoot $root -Operation test
        Complete-QvwTransaction -Transaction $tx -Evidence @{} | Out-Null
        $receipt = [IO.File]::ReadAllText($tx.ReceiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $receipt.entries = $null
        $json = $receipt | ConvertTo-Json -Depth 16
        [IO.File]::WriteAllText($tx.ReceiptPath, $json, (New-Object Text.UTF8Encoding($false)))
        Assert-QvwThrows { Undo-QvwTransaction -ReceiptPath $tx.ReceiptPath } '*'
        Assert-QvwNotMatch ([IO.File]::ReadAllText($tx.ReceiptPath, [Text.Encoding]::UTF8)) '"state"\s*:\s*"rolled-back"'

        $path = Join-Path $root 'config.yaml'
        Set-Content -LiteralPath $path -Value 'before' -NoNewline
        $tx2 = Start-QvwTransaction -ClientRoot $root -Operation test
        Backup-QvwFile -Transaction $tx2 -Path $path -LogicalName config | Out-Null
        Complete-QvwTransaction -Transaction $tx2 -Evidence @{} | Out-Null
        $receipt2 = [IO.File]::ReadAllText($tx2.ReceiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $receipt2.entries[0].beforeExists = 'true'
        $json2 = $receipt2 | ConvertTo-Json -Depth 16
        [IO.File]::WriteAllText($tx2.ReceiptPath, $json2, (New-Object Text.UTF8Encoding($false)))
        Assert-QvwThrows { Undo-QvwTransaction -ReceiptPath $tx2.ReceiptPath } '*'
        Assert-QvwNotMatch ([IO.File]::ReadAllText($tx2.ReceiptPath, [Text.Encoding]::UTF8)) '"state"\s*:\s*"rolled-back"'
    }

    It-Qvw 'redacts or rejects complete bearer and token metadata shapes' {
        $root = New-QvwTempDirectory
        $shapes = @(
            'Authorization: Bearer fixture-auth-token',
            'bearer token=fixture-bearer-token',
            'session_token=fixture-session-underscore',
            'session-token=fixture-session-dash',
            'sessionToken=fixture-session-camel',
            'refresh_token=fixture-refresh',
            'auth_token=fixture-auth',
            'access_token=fixture-access'
        )

        foreach ($shape in $shapes) {
            $tx = Start-QvwTransaction -ClientRoot $root -Operation test
            Complete-QvwTransaction -Transaction $tx -Evidence @{ $shape = $shape } | Out-Null
            $json = [IO.File]::ReadAllText($tx.ReceiptPath, [Text.Encoding]::UTF8)
            Assert-QvwNotMatch $json ([regex]::Escape($shape))
        }

        foreach ($shape in $shapes) {
            Assert-QvwThrows { Start-QvwTransaction -ClientRoot $root -Operation $shape } '*'
        }

        $path = Join-Path $root 'controlled.txt'
        Set-Content -LiteralPath $path -Value 'safe' -NoNewline
        $tx2 = Start-QvwTransaction -ClientRoot $root -Operation test
        foreach ($shape in $shapes) {
            Assert-QvwThrows { Backup-QvwFile -Transaction $tx2 -Path $path -LogicalName $shape } '*'
        }
        $receiptJson = [IO.File]::ReadAllText($tx2.ReceiptPath, [Text.Encoding]::UTF8)
        foreach ($shape in $shapes) {
            Assert-QvwNotMatch $receiptJson ([regex]::Escape($shape))
        }

        $sensitiveDirectory = Join-Path $root 'sessionToken=fixture-client-root'
        [IO.Directory]::CreateDirectory($sensitiveDirectory) | Out-Null
        Assert-QvwThrows { Start-QvwTransaction -ClientRoot $sensitiveDirectory -Operation test } '*'
        $sensitivePath = Join-Path $root 'sessionToken=fixture-controlled-path.txt'
        Set-Content -LiteralPath $sensitivePath -Value 'safe' -NoNewline
        $tx3 = Start-QvwTransaction -ClientRoot $root -Operation test
        Assert-QvwThrows { Backup-QvwFile -Transaction $tx3 -Path $sensitivePath -LogicalName safe } '*'
        $receiptJson3 = [IO.File]::ReadAllText($tx3.ReceiptPath, [Text.Encoding]::UTF8)
        Assert-QvwNotMatch $receiptJson3 'sessionToken=fixture-(?:client-root|controlled-path)'
    }
}
