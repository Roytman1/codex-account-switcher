param([switch]$Check)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AccountStore.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$script:authPath = Join-Path $script:codexHome 'auth.json'
$script:store = Join-Path $env:LOCALAPPDATA 'CodexAccountSwitcher'
$script:cli = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\*\codex.exe') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
if (!$script:cli) {
    $command = Get-Command codex.exe -ErrorAction SilentlyContinue
    if ($command) { $script:cli = $command.Source }
}
if ($Check) {
    [pscustomobject]@{CliFound=[bool]$script:cli; AuthCacheExists=(Test-Path -LiteralPath $script:authPath); StorePath=$script:store} | Format-List | Out-Host
    exit
}
New-Item -ItemType Directory -Path $script:store -Force | Out-Null
$mutex = New-Object Threading.Mutex($false, 'Local\CodexAccountSwitcher')
if (!$mutex.WaitOne(0)) { [Windows.Forms.MessageBox]::Show('The switcher is already open.') | Out-Null; exit }

function Assert-CodexClosed {
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(codex|chatgpt)([-.]|$)' })
    if ($running.Count) { throw 'Close Codex and any Codex terminal or IDE sessions first. The switcher never closes running tasks for you.' }
    $config = Join-Path $script:codexHome 'config.toml'
    if (Test-Path -LiteralPath $config) {
        if (Select-String -LiteralPath $config -Pattern '^\s*cli_auth_credentials_store\s*=\s*["''](keyring|auto|ephemeral)["'']' -Quiet) {
            throw 'This utility supports file-based login storage only. Your credential-store configuration is not changed.'
        }
    }
}
function Refresh-Accounts {
    $list.Items.Clear()
    foreach ($file in Get-ChildItem -LiteralPath $script:store -Filter 'account-*.bin') {
        try {
            $identity = Get-AccountIdentity (Read-EncryptedAccount $file.FullName)
            $null = $list.Items.Add([pscustomobject]@{Label=$identity.Email; Path=$file.FullName})
        } catch { $status.Text = 'A saved account could not be read by this Windows user.' }
    }
    if ($list.Items.Count) { $list.SelectedIndex = 0 }
}
function Capture-Account([string]$Json) {
    $identity = Get-AccountIdentity $Json
    $path = Join-Path $script:store "account-$([guid]::NewGuid().ToString('N')).bin"
    foreach ($file in Get-ChildItem -LiteralPath $script:store -Filter 'account-*.bin') {
        if ((Get-AccountIdentity (Read-EncryptedAccount $file.FullName)).Key -eq $identity.Key) { $path = $file.FullName; break }
    }
    Save-EncryptedAccount $path $Json
    Refresh-Accounts
    $status.Text = "Saved $($identity.Email)."
}
function Run-Action([scriptblock]$Action) {
    try { & $Action } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Codex account switcher') | Out-Null }
}
$form = New-Object Windows.Forms.Form
$form.Text = 'Codex account switcher - preview'
$form.ClientSize = New-Object Drawing.Size(570, 400)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$title = New-Object Windows.Forms.Label
$title.Text = 'Your saved ChatGPT accounts'
$title.Location = New-Object Drawing.Point(22, 18)
$title.Size = New-Object Drawing.Size(520, 30)
$title.Font = New-Object Drawing.Font('Segoe UI', 15, [Drawing.FontStyle]::Bold)
$form.Controls.Add($title)
$info = New-Object Windows.Forms.Label
$info.Text = "Save your current account, then add your second account.`nTo switch: close Codex, select an account, apply, and reopen Codex."
$info.Location = New-Object Drawing.Point(22, 56)
$info.Size = New-Object Drawing.Size(526, 50)
$form.Controls.Add($info)
$list = New-Object Windows.Forms.ListBox
$list.DisplayMember = 'Label'
$list.Location = New-Object Drawing.Point(22, 116)
$list.Size = New-Object Drawing.Size(526, 95)
$form.Controls.Add($list)
function Add-Button([string]$Text, [int]$X, [int]$Y, [int]$Width, [scriptblock]$Click) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object Drawing.Point($X, $Y)
    $button.Size = New-Object Drawing.Size($Width, 38)
    $button.Add_Click($Click)
    $form.Controls.Add($button)
}
Add-Button 'Save current account' 22 222 252 { Run-Action { Capture-Account ([IO.File]::ReadAllText($script:authPath)) } }
Add-Button 'Add account (browser sign-in)' 286 222 262 { Run-Action {
    if (!$script:cli) { throw 'Codex CLI was not found in the desktop installation.' }
    $status.Text = 'Complete browser sign-in in the window that opens. Select your other account.'
    $form.Refresh()
    $loginHome = Join-Path $script:store "login-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $loginHome | Out-Null
    # This child alone gets a separate CODEX_HOME. The active desktop cache is untouched.
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $script:cli
    $start.Arguments = '-c cli_auth_credentials_store=\"file\" login'
    $start.UseShellExecute = $false
    $start.EnvironmentVariables['CODEX_HOME'] = $loginHome
    $process = $null
    $form.Enabled = $false
    try {
        $process = [Diagnostics.Process]::Start($start)
        while (!$process.WaitForExit(100)) { [Windows.Forms.Application]::DoEvents() }
        if ($process.ExitCode -ne 0) { throw 'Sign-in did not finish. You can try Add account again.' }
        Capture-Account ([IO.File]::ReadAllText((Join-Path $loginHome 'auth.json')))
    } finally {
        $form.Enabled = $true
        if ($process) { $process.Dispose() }
        # Only the known temporary credential file is removed. Other login diagnostics stay local.
        $temporaryAuth = Join-Path $loginHome 'auth.json'
        if ([IO.File]::Exists($temporaryAuth)) { [IO.File]::Delete($temporaryAuth) }
    }
} }
Add-Button 'Apply selected account' 22 272 252 { Run-Action {
    Assert-CodexClosed
    if (!$list.SelectedItem) { throw 'Save or add an account first.' }
    Set-SavedAccount $list.SelectedItem.Path $script:authPath $script:store
    $status.Text = 'Login cache updated. Reopen Codex and check the account menu.'
} }
Add-Button 'Restore previous login' 286 272 262 { Run-Action {
    Assert-CodexClosed
    $previous = Join-Path $script:store 'previous-login.bin'
    if (!(Test-Path -LiteralPath $previous)) { throw 'No previous login has been saved yet.' }
    $json = Read-EncryptedAccount $previous
    $null = Get-AccountIdentity $json
    Write-AtomicBytes $script:authPath ([Text.Encoding]::UTF8.GetBytes($json))
    $status.Text = 'Previous login restored. Reopen Codex.'
} }
$status = New-Object Windows.Forms.Label
$status.Location = New-Object Drawing.Point(22, 325)
$status.Size = New-Object Drawing.Size(526, 65)
$status.Text = 'Preview: desktop account reload still needs verification on this installation.'
$form.Controls.Add($status)
try { Refresh-Accounts; $null = $form.ShowDialog() } finally { $mutex.ReleaseMutex(); $mutex.Dispose(); $form.Dispose() }
