Describe-Qvw 'Transaction rollback integration' {
    It-Qvw 'restores every controlled file after a mid-transaction failure' {
        $root = New-QvwTempDirectory
        $configPath = Join-Path $root 'config.yaml'
        $envPath = Join-Path $root '.env'
        Set-Content -LiteralPath $configPath -Value 'config-before' -NoNewline
        Set-Content -LiteralPath $envPath -Value 'DASHSCOPE_API_KEY=before' -NoNewline

        $tx = Start-QvwTransaction -ClientRoot $root -Operation install
        Backup-QvwFile -Transaction $tx -Path $configPath -LogicalName config
        Backup-QvwFile -Transaction $tx -Path $envPath -LogicalName env
        Set-Content -LiteralPath $configPath -Value 'config-after' -NoNewline
        Set-Content -LiteralPath $envPath -Value 'DASHSCOPE_API_KEY=after' -NoNewline

        $result = Undo-QvwTransaction -ReceiptPath $tx.ReceiptPath
        Assert-QvwFalse ($result -is [array])
        Assert-QvwEqual $result.GetType().Name 'PSCustomObject'
        Assert-QvwEqual $result.State 'rolled-back'
        Assert-QvwEqual ([IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8)) 'config-before'
        Assert-QvwEqual ([IO.File]::ReadAllText($envPath, [Text.Encoding]::UTF8)) 'DASHSCOPE_API_KEY=before'
    }

    It-Qvw 'restores a file that did not exist before the transaction by removing it' {
        $root = New-QvwTempDirectory
        $path = Join-Path $root 'new.txt'
        $tx = Start-QvwTransaction -ClientRoot $root -Operation install
        Backup-QvwFile -Transaction $tx -Path $path -LogicalName new
        Set-Content -LiteralPath $path -Value 'created-by-install' -NoNewline
        Undo-QvwTransaction -ReceiptPath $tx.ReceiptPath | Out-Null
        Assert-QvwFalse (Test-Path -LiteralPath $path)
    }

    It-Qvw 'rejects absolute and parent-traversing backup paths in a receipt' {
        $root = New-QvwTempDirectory
        $path = Join-Path $root 'config.yaml'
        Set-Content -LiteralPath $path -Value 'before' -NoNewline
        $tx = Start-QvwTransaction -ClientRoot $root -Operation install
        Backup-QvwFile -Transaction $tx -Path $path -LogicalName config | Out-Null
        Set-Content -LiteralPath $path -Value 'after' -NoNewline

        foreach ($badRelative in @('..\outside.bak', (Join-Path $root 'outside.bak'))) {
            $receipt = [IO.File]::ReadAllText($tx.ReceiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $receipt.entries[0].backupRelativePath = $badRelative
            $receipt.state = 'committed'
            $json = $receipt | ConvertTo-Json -Depth 16
            [IO.File]::WriteAllText($tx.ReceiptPath, $json, (New-Object Text.UTF8Encoding($false)))
            Assert-QvwThrows { Undo-QvwTransaction -ReceiptPath $tx.ReceiptPath } '*'
            $after = [IO.File]::ReadAllText($tx.ReceiptPath, [Text.Encoding]::UTF8)
            Assert-QvwNotMatch $after '"state"\s*:\s*"rolled-back"'
        }
    }

    It-Qvw 'rejects a reparse-point root when Windows permits a junction fixture' {
        $target = New-QvwTempDirectory
        $parent = New-QvwTempDirectory
        $junction = Join-Path $parent 'junction-root'
        $created = $false
        try {
            New-Item -ItemType Junction -Path $junction -Target $target -ErrorAction Stop | Out-Null
            $created = $true
        }
        catch {
            # Junction creation can be disabled by a non-admin Windows policy;
            # implementation coverage remains in the path guard and this case
            # is a documented environment skip rather than a false acceptance.
        }
        if ($created) {
            Assert-QvwThrows { Start-QvwTransaction -ClientRoot $junction -Operation test } '*'
        }
        else {
            Assert-QvwTrue $true
        }
    }
}
