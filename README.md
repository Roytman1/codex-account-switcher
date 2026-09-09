# Codex Account Switcher for Windows

A small Windows utility for keeping two ChatGPT sign-ins available for Codex local work. It stores each saved login encrypted with Windows DPAPI and lets you select which saved cache Codex should read after Codex is closed.

## Use

1. Double-click `Start Switcher.cmd`.
2. Choose **Save current account**.
3. Choose **Add account (browser sign-in)** and complete the OpenAI sign-in for the other account.
4. Close Codex and any Codex CLI or IDE sessions.
5. Select an account, choose **Apply selected account**, and reopen Codex.
6. Verify the account menu before starting work.

The browser flow is used only to add an account. Later switches use the encrypted local cache. A browser sign-in may still be required if OpenAI expires or revokes a saved session.

## Privacy and security

This repository contains only source code and synthetic test fixtures. The fixtures use fake credentials and `example.invalid` addresses; no real login credentials, personal email addresses, account IDs, screenshots, or user-specific paths are included. Saved credentials are written at runtime to the current Windows user's `%LOCALAPPDATA%\CodexAccountSwitcher` directory, outside this repository, and are protected with Windows DPAPI. The temporary plaintext login file used while adding an account is deleted after capture. The Git ignore rules allow only the seven reviewed source files.

The utility refuses to apply a selection while Codex is running and keeps a rollback copy of the previous cache. It does not upload credentials, access cloud tasks, or transfer connector authorizations.

This is an unofficial utility. The Codex desktop app's behavior when reloading a swapped cache must be verified on the installed version. If the selected account does not appear after reopening Codex, use **Restore previous login** in the local utility.

## Checks

Run the local test fixture with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-AccountStore.ps1
```

The test covers DPAPI round trips, token refresh preservation, switching, rollback, repeated selection, corruption rejection, and unsupported authentication modes.

## Official background

OpenAI documents Codex login caching and automatic token refresh at <https://learn.chatgpt.com/docs/auth>.
