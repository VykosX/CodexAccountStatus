# Codex Account Status Dashboard

A self-contained local dashboard for checking Codex reset credits, current usage windows, and profile stats across one or more Codex accounts.

![Redacted dashboard screenshot](./dashboard-screenshot.png)

## Features

- Shows saved Codex accounts as tabs, with one account selected at a time.
- Displays available Codex reset credits across all saved accounts.
- Shows each reset credit with status, `granted_at`, and `expires_at` in `YYYY-MM-DD_HH:MM:SS` local-time format.
- Displays current 5-hour and 7-day Codex usage windows with remaining percentage and reset time.
- Displays profile-card stats similar to the Codex UI, including lifetime tokens, peak tokens, longest task, current streak, and longest streak.
- Captures multiple accounts by saving the active `~/.codex/auth.json` token bundle each time the update script runs.
- Generates a static `index.html` page that can be opened directly in a browser.
- Does not embed OAuth access or refresh tokens in `index.html`.

## Files

- `Update-CodexResets.ps1`: Captures the active Codex account token bundle, queries Codex backend endpoints, and regenerates `index.html`.
- `index.html`: The generated self-contained dashboard.
- `.codex-accounts/`: Local saved auth bundles for each captured account. This directory is ignored by git.
- `dashboard-screenshot.png`: Redacted screenshot for documentation.
- `.gitignore`: Prevents saved auth bundles from being committed.

## How It Works

Codex stores the currently active account auth data in:

```powershell
~/.codex/auth.json
```

That file normally contains only one active account at a time. To support multiple accounts, the update script copies the active `auth.json` into `.codex-accounts/` under an account-specific filename. After you switch Codex accounts and rerun the script, the new account is captured too.

For each saved account, the script uses the saved bearer token and account id to query:

- `GET https://chatgpt.com/backend-api/wham/usage`
- `GET https://chatgpt.com/backend-api/wham/profiles/me`
- `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`

The script sends the same auth pattern Codex uses: `Authorization: Bearer ...`, `ChatGPT-Account-ID`, `OpenAI-Beta: codex-1`, and `originator: Codex Desktop`.

## Usage

Run from this project directory:

```powershell
.\Update-CodexResets.ps1
```

Then open:

```text
index.html
```

The generated page is static. To refresh usage, reset credits, or profile stats, rerun the script.

## Adding Accounts

1. Sign into or switch to an account in Codex.
2. Run `.\Update-CodexResets.ps1`.
3. Repeat for each account you want included.

Each captured account appears as a tab in the dashboard after the script successfully saves and queries it.

## Script Options

```powershell
.\Update-CodexResets.ps1 `
  -AuthPath "$HOME\.codex\auth.json" `
  -AccountsDir ".\.codex-accounts" `
  -OutputPath ".\index.html"
```

- `-AuthPath`: Path to the active Codex auth file.
- `-AccountsDir`: Directory where saved account auth bundles are stored.
- `-OutputPath`: Destination for the generated HTML page.
- `-SkipSaveCurrent`: Query only already saved account bundles.
- `-SkipFetch`: Regenerate the page without querying the backend; useful for layout testing.

## Privacy And Security

The `.codex-accounts/` directory contains live auth token bundles. Keep it private and do not commit or share it.

`index.html` does not include OAuth tokens, but it does embed the generated account labels, account ids, usage data, reset-credit data, and profile stats. Treat it as personal account data unless you intentionally redact it first.

## Troubleshooting

If an account tab shows a query error, the saved token may have expired. Switch to that account in Codex and rerun `.\Update-CodexResets.ps1`.

If an account is missing, Codex probably has not been active on that account since this project started capturing bundles. Switch to that account and rerun the script.

If PowerShell blocks script execution, run the script from a PowerShell session that allows local scripts, or invoke it with an appropriate execution policy for your machine.
