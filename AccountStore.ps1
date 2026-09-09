Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security

function Get-AccountIdentity([string]$Json) {
    try {
        $auth = $Json | ConvertFrom-Json
        if ($auth.auth_mode -ne 'chatgpt') { throw 'Unsupported login mode.' }
        if (!$auth.tokens.access_token -or !$auth.tokens.refresh_token) { throw 'Missing tokens.' }
        $part = $auth.tokens.id_token.Split('.')[1].Replace('-', '+').Replace('_', '/')
        $part = $part.PadRight($part.Length + ((4 - $part.Length % 4) % 4), '=')
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
        if (!$claims.sub -or !$auth.tokens.account_id) { throw 'Missing identity.' }
        $email = if ($claims.PSObject.Properties['email']) { [string]$claims.email } else { 'ChatGPT account' }
        # Used only to label and match a local cache, never as proof of authentication.
        return [pscustomobject]@{ Key = "$($claims.sub)|$($auth.tokens.account_id)"; Email = $email }
    } catch { throw 'This is not a supported ChatGPT login cache. Sign in with ChatGPT first.' }
}

function Write-AtomicBytes([string]$Path, [byte[]]$Bytes) {
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllBytes($temp, $Bytes)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Save-EncryptedAccount([string]$Path, [string]$Json) {
    $null = Get-AccountIdentity $Json
    $bytes = [Text.Encoding]::UTF8.GetBytes($Json)
    try {
        $encrypted = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        Write-AtomicBytes $Path $encrypted
    } finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Read-EncryptedAccount([string]$Path) {
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($Path), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { return [Text.Encoding]::UTF8.GetString($bytes) }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Set-SavedAccount([string]$ProfilePath, [string]$AuthPath, [string]$StorePath) {
    $target = Read-EncryptedAccount $ProfilePath
    $null = Get-AccountIdentity $target
    if ([IO.File]::Exists($AuthPath)) {
        $current = [IO.File]::ReadAllText($AuthPath)
        $identity = Get-AccountIdentity $current
        # Keep refreshed credentials before replacing the active cache.
        foreach ($file in Get-ChildItem -LiteralPath $StorePath -Filter 'account-*.bin') {
            $saved = Get-AccountIdentity (Read-EncryptedAccount $file.FullName)
            if ($saved.Key -eq $identity.Key) { Save-EncryptedAccount $file.FullName $current }
        }
        Save-EncryptedAccount (Join-Path $StorePath 'previous-login.bin') $current
        # The target may have just been updated with its latest refresh token.
        $target = Read-EncryptedAccount $ProfilePath
    }
    Write-AtomicBytes $AuthPath ([Text.Encoding]::UTF8.GetBytes($target))
}
