Describe-Qvw 'New-QvwResult' {
    It-Qvw 'rejects an unknown status' {
        Assert-QvwThrows { New-QvwResult -Component hermes -Status done -Code X -Message x -Evidence @{} } '*Unknown status*'
    }
    It-Qvw 'rejects uppercase status values' {
        Assert-QvwThrows { New-QvwResult -Component hermes -Status INSTALLED -Code X -Message x -Evidence @{} } '*Unknown status*'
    }
    It-Qvw 'serializes without type metadata' {
        $r = New-QvwResult -Component hermes -Status installed -Code QVW-H-200 -Message ok -Evidence @{ model = 'qwen3.7-plus' }
        $json = $r | ConvertTo-Json -Depth 8
        Assert-QvwMatch $json '"status"\s*:\s*"installed"'
        Assert-QvwNotMatch $json 'PSComputerName|RunspaceId'
    }
    It-Qvw 'redacts sensitive evidence recursively' {
        $secret = 'fixture-secret'
        $r = New-QvwResult -Component hermes -Status installed -Code QVW-H-200 -Message ok -Evidence @{
            nested = @{
                apiKey = $secret
                detail = "Bearer $secret"
            }
            note = "token=$secret"
            session = $secret
            cookie = "session=$secret"
            password = $secret
            authorization = "Bearer $secret"
            safe = 'visible'
        }
        $json = Write-QvwResult $r -AsJson
        Assert-QvwNotMatch $json $secret
        Assert-QvwMatch $json '\[REDACTED\]'
        Assert-QvwMatch $json '"safe"\s*:\s*"visible"'
    }
    It-Qvw 'does not expose fixture secrets in assertion errors' {
        $message = $null
        try {
            Assert-QvwEqual 'fixture-secret' 'other-value'
        }
        catch {
            $message = $_.Exception.Message
        }
        Assert-QvwNotMatch $message 'fixture-secret|other-value'
    }
    It-Qvw 'redacts high-confidence credential shapes in ordinary evidence fields' {
        $secrets = @(
            'sk-proj-1234567890abcdef1234567890abcdef'
            'ghp_1234567890abcdefghij1234567890'
            'gho_1234567890abcdefghij1234567890'
            'ghu_1234567890abcdefghij1234567890'
            'ghs_1234567890abcdefghij1234567890'
            'ghr_1234567890abcdefghij1234567890'
            'github_pat_11AAAAAA000000000000000000000000000000000000000000'
            'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.signature1234567890'
            'AKIAIOSFODNN7EXAMPLE'
            'AIzaSyA-1234567890abcdefghijkl'
        )
        $r = New-QvwResult -Component hermes -Status installed -Code QVW-H-200 -Message ok -Evidence @{
            note = $secrets -join '|'
            model = 'qwen3.7-plus'
            digest = 'sha256:0123456789ab'
            path = 'C:\work\artifact.json'
        }
        $json = Write-QvwResult $r -AsJson
        foreach ($secret in $secrets) {
            Assert-QvwNotMatch $json ([regex]::Escape($secret))
        }
        Assert-QvwMatch $json 'qwen3\.7-plus'
        Assert-QvwMatch $json 'sha256:0123456789ab'
        Assert-QvwMatch $json 'artifact\.json'
    }
    It-Qvw 'compares raw file strings by value without deep serialization' {
        $root = New-QvwTempDirectory
        $file = Join-Path $root 'fixture.txt'
        [System.IO.File]::WriteAllText($file, 'fixture-secret-value')
        $raw = Get-Content -LiteralPath $file -Raw
        Assert-QvwEqual $raw 'fixture-secret-value'
    }
    It-Qvw 'redacts unknown credential objects and top-level result fields' {
        $secret = 'fixture-network-secret'
        $credential = [System.Net.NetworkCredential]::new('fixture-network-user', $secret)
        $r = New-QvwResult -Component 'sk-proj-1234567890abcdef1234567890abcdef' -Status installed -Code 'AKIAIOSFODNN7EXAMPLE' -Message "Bearer $secret" -Evidence @{
            payload = $credential
            safe = 'visible'
        }
        $json = $r | ConvertTo-Json -Depth 8
        Assert-QvwNotMatch $json 'fixture-network-secret|fixture-network-user|sk-proj-|AKIAIOSFODNN7EXAMPLE'
        Assert-QvwMatch $json '\[REDACTED\]'
        Assert-QvwMatch $json '"safe"\s*:\s*"visible"'
    }
    It-Qvw 'suppresses Assert-QvwThrows body output and nonterminating errors' {
        $captured = (& {
            Assert-QvwThrows {
                Write-Output 'fixture-success-secret'
                Write-Host 'fixture-host-secret'
                Write-Information 'fixture-information-secret' -InformationAction Continue
                Write-Error 'Bearer fixture-error-secret' -ErrorAction Continue
            } '*fixture-error-secret*'
        } *>&1 | Out-String)
        Assert-QvwNotMatch $captured 'fixture-success-secret|fixture-host-secret|fixture-information-secret|fixture-error-secret'
    }
    It-Qvw 'does not disclose an invalid status value' {
        $message = $null
        try {
            New-QvwResult -Component hermes -Status 'sk-proj-invalid-status-secret' -Code X -Message x -Evidence @{}
        }
        catch {
            $message = $_.Exception.Message
        }
        Assert-QvwMatch $message 'Unknown status'
        Assert-QvwNotMatch $message 'sk-proj-invalid-status-secret'
    }
    It-Qvw 'redacts credential-shaped dictionary and object property names without collisions' {
        $credentialKey = 'ghp_1234567890abcdefghij1234567890'
        $dictionary = [ordered]@{}
        $dictionary[$credentialKey] = 'first-value'
        $dictionary['[REDACTED_KEY]'] = 'second-value'
        $object = [pscustomobject]@{}
        $object | Add-Member -MemberType NoteProperty -Name $credentialKey -Value 'object-value'
        $r = New-QvwResult -Component hermes -Status installed -Code c -Message ok -Evidence @{
            dictionary = $dictionary
            object = $object
        }
        $json = $r | ConvertTo-Json -Depth 8
        Assert-QvwNotMatch $json $credentialKey
        Assert-QvwMatch $json 'first-value|second-value|object-value'
        Assert-QvwMatch $json '\[REDACTED_KEY\]'
    }
}
