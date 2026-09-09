$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AccountStore.ps1')
function Fake-Auth([string]$Subject, [string]$Refresh) {
    $claims = @{sub=$Subject; email="$Subject@example.invalid"} | ConvertTo-Json -Compress
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).TrimEnd('=').Replace('+','-').Replace('/','_')
    return (@{auth_mode='chatgpt';tokens=@{id_token="fake.$payload.fake";access_token='fake-access';refresh_token=$Refresh;account_id='fake-workspace'}} | ConvertTo-Json -Depth 4 -Compress)
}
function Assert([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
$testDir = Join-Path ([IO.Path]::GetTempPath()) "codex-switcher-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testDir | Out-Null
try {
    $a = Join-Path $testDir 'account-a.bin'
    $b = Join-Path $testDir 'account-b.bin'
    $active = Join-Path $testDir 'auth.json'
    $old = Fake-Auth 'a' 'old-refresh'
    $fresh = Fake-Auth 'a' 'refreshed-token'
    $other = Fake-Auth 'b' 'other-refresh'
    Save-EncryptedAccount $a $old
    Save-EncryptedAccount $b $other
    Assert ((Read-EncryptedAccount $a) -eq $old) 'DPAPI round trip failed'
    Assert (![Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($a)).Contains('old-refresh')) 'Plaintext token in encrypted storage'
    [IO.File]::WriteAllText($active, $fresh)
    Set-SavedAccount $b $active $testDir
    Assert ([IO.File]::ReadAllText($active) -eq $other) 'Target was not selected'
    Assert ((Read-EncryptedAccount $a) -eq $fresh) 'Refreshed tokens were lost'
    Assert ((Read-EncryptedAccount (Join-Path $testDir 'previous-login.bin')) -eq $fresh) 'Rollback missing'
    Set-SavedAccount $a $active $testDir
    Assert ([IO.File]::ReadAllText($active) -eq $fresh) 'Round-trip switch lost refreshed tokens'
    Set-SavedAccount $a $active $testDir
    Assert ([IO.File]::ReadAllText($active) -eq $fresh) 'Selecting active account changed credentials'
    $before = [IO.File]::ReadAllText($active)
    [IO.File]::WriteAllText($b, 'broken encrypted data')
    $rejected = $false
    try { Set-SavedAccount $b $active $testDir } catch { $rejected = $true }
    Assert $rejected 'Corrupt account accepted'
    Assert ([IO.File]::ReadAllText($active) -eq $before) 'Corrupt account changed active login'
    $rejected = $false
    try { $null = Get-AccountIdentity '{"auth_mode":"apikey"}' } catch { $rejected = $true }
    Assert $rejected 'API key mode accepted'
    'PASS: encryption, refreshed-token preservation, switching, rollback, repeated selection, corruption handling, unsupported mode.'
} finally {
    # Delete only individually enumerated files from this exact newly created test directory.
    foreach ($file in [IO.Directory]::GetFiles($testDir)) { [IO.File]::Delete($file) }
    [IO.Directory]::Delete($testDir)
}
