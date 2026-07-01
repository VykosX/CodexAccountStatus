[CmdletBinding()]
param(
  [string]$AuthPath = (Join-Path $HOME ".codex\auth.json"),
  [string]$CacheDir = (Join-Path $PSScriptRoot ".codex-cache"),
  [string]$OutputPath = (Join-Path $PSScriptRoot "index.html"),
  [string]$LiveApiBase = "http://127.0.0.1:8787",
  [switch]$SkipSaveCurrent,
  [switch]$SkipFetch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function ConvertFrom-JsonWithStringDates {
  param([Parameter(Mandatory = $true)][string]$Json)

  if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey("DateKind")) {
    return $Json | ConvertFrom-Json -DateKind String
  }

  return $Json | ConvertFrom-Json
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  return ConvertFrom-JsonWithStringDates (Get-Content -LiteralPath $Path -Raw)
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)]$Value,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $jsonArgs = @{
    Depth = 100
  }
  if ((Get-Command ConvertTo-Json).Parameters.ContainsKey("EscapeHandling")) {
    $jsonArgs.EscapeHandling = "EscapeNonAscii"
  }

  $json = $Value | ConvertTo-Json @jsonArgs
  Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Get-PropertyValue {
  param(
    [Parameter(Mandatory = $false)]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $Object) {
    return $null
  }

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
  }

  return $property.Value
}

function First-NonEmpty {
  foreach ($value in $args) {
    if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
      return $value
    }
  }

  return $null
}

function ConvertFrom-Base64Url {
  param([Parameter(Mandatory = $true)][string]$Value)

  $padded = $Value.Replace("-", "+").Replace("_", "/")
  switch ($padded.Length % 4) {
    2 { $padded += "==" }
    3 { $padded += "=" }
    1 { throw "Invalid base64url value." }
  }

  return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($padded))
}

function Decode-JwtPayload {
  param([Parameter(Mandatory = $true)][string]$Token)

  $parts = $Token -split "\."
  if ($parts.Count -lt 2) {
    throw "Token is not a JWT."
  }

  return ConvertFrom-JsonWithStringDates (ConvertFrom-Base64Url $parts[1])
}

function Convert-ToLocalStamp {
  param([Parameter(Mandatory = $false)]$Value)

  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return $null
  }

  if ($Value -is [DateTime]) {
    $date = [DateTimeOffset]$Value
  } else {
    $date = [DateTimeOffset]::Parse(
      [string]$Value,
      [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::AssumeUniversal
    )
  }

  return $date.LocalDateTime.ToString("yyyy-MM-dd • HH:mm:ss")
}

function Convert-UnixSecondsToLocalStamp {
  param([Parameter(Mandatory = $false)]$Seconds)

  if ($null -eq $Seconds -or [string]::IsNullOrWhiteSpace([string]$Seconds)) {
    return $null
  }

  return ([DateTimeOffset]::FromUnixTimeSeconds([int64]$Seconds)).LocalDateTime.ToString("yyyy-MM-dd • HH:mm:ss")
}

function New-SafeFileStem {
  param([Parameter(Mandatory = $true)][string]$Value)

  $safe = $Value.ToLowerInvariant() -replace "[^a-z0-9._-]+", "-"
  $safe = $safe.Trim(".-")
  if ([string]::IsNullOrWhiteSpace($safe)) {
    return "account"
  }

  if ($safe.Length -gt 96) {
    return $safe.Substring(0, 96).Trim(".-")
  }

  return $safe
}

function Get-AuthAccountInfo {
  param(
    [Parameter(Mandatory = $true)]$Auth,
    [Parameter(Mandatory = $true)][string]$SourcePath
  )

  $tokens = Get-PropertyValue $Auth "tokens"
  $idToken = Get-PropertyValue $tokens "id_token"
  $accessToken = Get-PropertyValue $tokens "access_token"
  if ([string]::IsNullOrWhiteSpace($accessToken)) {
    throw "Missing access_token in $SourcePath."
  }

  $idPayload = if ($idToken) { Decode-JwtPayload $idToken } else { $null }
  $accessPayload = Decode-JwtPayload $accessToken
  $idAuth = Get-PropertyValue $idPayload "https://api.openai.com/auth"
  $accessAuth = Get-PropertyValue $accessPayload "https://api.openai.com/auth"
  $profile = Get-PropertyValue $accessPayload "https://api.openai.com/profile"
  $accountId = First-NonEmpty `
    (Get-PropertyValue $tokens "account_id") `
    (Get-PropertyValue $accessAuth "chatgpt_account_id") `
    (Get-PropertyValue $idAuth "chatgpt_account_id")

  if ([string]::IsNullOrWhiteSpace($accountId)) {
    throw "Could not determine account id in $SourcePath."
  }

  return [pscustomobject]@{
    accountId = $accountId
    email = First-NonEmpty (Get-PropertyValue $profile "email") (Get-PropertyValue $idPayload "email")
    name = Get-PropertyValue $idPayload "name"
    plan = First-NonEmpty (Get-PropertyValue $accessAuth "chatgpt_plan_type") (Get-PropertyValue $idAuth "chatgpt_plan_type")
    accessToken = $accessToken
    refreshToken = Get-PropertyValue $tokens "refresh_token"
    accessTokenExpiresAt = Convert-UnixSecondsToLocalStamp (Get-PropertyValue $accessPayload "exp")
    sourcePath = $SourcePath
  }
}

function Invoke-CodexApi {
  param(
    [Parameter(Mandatory = $true)]$Account,
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$RetriedAfterRefresh
  )

  $headers = @{
    Authorization = "Bearer $($Account.accessToken)"
    "ChatGPT-Account-ID" = $Account.accountId
    "OpenAI-Beta" = "codex-1"
    originator = "Codex Desktop"
    Accept = "application/json"
    "User-Agent" = "codex-resets-page/1.0"
  }

  try {
    $response = Invoke-WebRequest `
      -Uri "https://chatgpt.com/backend-api$Path" `
      -Headers $headers `
      -Method Get `
      -TimeoutSec 30
  } catch {
    $statusCode = $null
    if ($_.Exception.Response) {
      $statusCode = [int]$_.Exception.Response.StatusCode
    }

    if ($statusCode -eq 401 -and -not $RetriedAfterRefresh -and -not (Get-PropertyValue $Account "tokenRefreshAttempted")) {
      $Account | Add-Member -MemberType NoteProperty -Name "tokenRefreshAttempted" -Value $true -Force
      Refresh-SavedAccountToken $Account
      return Invoke-CodexApi $Account $Path -RetriedAfterRefresh
    }

    if ($statusCode -eq 401) {
      throw "Saved credentials for $(First-NonEmpty $Account.email $Account.accountId) were rejected by Codex after a refresh attempt. Switch Codex to this account and rerun .\Update-CodexResets.ps1 so the project can re-capture the current auth bundle."
    }

    throw
  }

  return ConvertFrom-JsonWithStringDates $response.Content
}

function Refresh-SavedAccountToken {
  param([Parameter(Mandatory = $true)]$Account)

  if ([string]::IsNullOrWhiteSpace([string]$Account.refreshToken)) {
    throw "Saved token for $(First-NonEmpty $Account.email $Account.accountId) was rejected and no refresh_token is available."
  }
  if ([string]::IsNullOrWhiteSpace([string]$Account.sourcePath)) {
    throw "Saved token for $(First-NonEmpty $Account.email $Account.accountId) was rejected and has no source file to update."
  }

  Write-Host "Refreshing saved token for $(First-NonEmpty $Account.email $Account.accountId)..."

  $body = @{
    client_id = "app_EMoamEEZ73f0CkXaXp7hrann"
    grant_type = "refresh_token"
    refresh_token = $Account.refreshToken
    scope = "openid profile email offline_access"
  }

  $response = Invoke-WebRequest `
    -Uri "https://auth.openai.com/oauth/token" `
    -Method Post `
    -Body $body `
    -ContentType "application/x-www-form-urlencoded" `
    -Headers @{ Accept = "application/json" } `
    -TimeoutSec 30

  $tokens = ConvertFrom-JsonWithStringDates $response.Content
  $accessToken = Get-PropertyValue $tokens "access_token"
  if ([string]::IsNullOrWhiteSpace([string]$accessToken)) {
    throw "Token refresh did not return an access_token."
  }

  $newRefreshToken = First-NonEmpty (Get-PropertyValue $tokens "refresh_token") $Account.refreshToken
  $auth = Read-JsonFile $Account.sourcePath
  if ($null -eq (Get-PropertyValue $auth "tokens")) {
    $auth | Add-Member -MemberType NoteProperty -Name "tokens" -Value ([pscustomobject]@{}) -Force
  }

  $auth.tokens | Add-Member -MemberType NoteProperty -Name "access_token" -Value $accessToken -Force
  $auth.tokens | Add-Member -MemberType NoteProperty -Name "refresh_token" -Value $newRefreshToken -Force
  $idToken = Get-PropertyValue $tokens "id_token"
  if (-not [string]::IsNullOrWhiteSpace([string]$idToken)) {
    $auth.tokens | Add-Member -MemberType NoteProperty -Name "id_token" -Value $idToken -Force
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$Account.accountId)) {
    $auth.tokens | Add-Member -MemberType NoteProperty -Name "account_id" -Value $Account.accountId -Force
  }
  $auth | Add-Member -MemberType NoteProperty -Name "last_refresh" -Value ([DateTimeOffset]::UtcNow.ToString("o")) -Force

  Write-JsonFile $auth $Account.sourcePath

  $updated = Get-AuthAccountInfo $auth $Account.sourcePath
  if ($updated.accountId -ne $Account.accountId) {
    throw "Refreshed token account id changed from $($Account.accountId) to $($updated.accountId); refusing to retry with mismatched credentials."
  }

  $Account.accessToken = $updated.accessToken
  $Account.refreshToken = $updated.refreshToken
  $Account.accessTokenExpiresAt = $updated.accessTokenExpiresAt
}

function Get-FriendlyAccountError {
  param(
    [Parameter(Mandatory = $true)]$Account,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if ($Message -match "401|Unauthorized") {
    return "Saved credentials for $(First-NonEmpty $Account.email $Account.accountId) were rejected by Codex. Switch Codex to this account and rerun .\Update-CodexResets.ps1 so the project can re-capture the current auth bundle."
  }

  return $Message
}

function Convert-WindowLabel {
  param([Parameter(Mandatory = $false)]$Seconds)

  if ($null -eq $Seconds -or [string]::IsNullOrWhiteSpace([string]$Seconds)) {
    return "limit"
  }

  $value = [int64]$Seconds
  switch ($value) {
    18000 { return "5h" }
    604800 { return "7d" }
  }

  if ($value % 86400 -eq 0) {
    return "$([int]($value / 86400))d"
  }

  if ($value % 3600 -eq 0) {
    return "$([int]($value / 3600))h"
  }

  return "$value sec"
}

function Convert-UsageWindow {
  param(
    [Parameter(Mandatory = $true)]$Window,
    [Parameter(Mandatory = $true)][string]$Kind
  )

  $usedPercent = [int](First-NonEmpty (Get-PropertyValue $Window "used_percent") 0)
  $remainingPercent = [Math]::Max(0, [Math]::Min(100, 100 - $usedPercent))
  $windowSeconds = Get-PropertyValue $Window "limit_window_seconds"

  return [pscustomobject]@{
    kind = $Kind
    label = Convert-WindowLabel $windowSeconds
    usedPercent = $usedPercent
    remainingPercent = $remainingPercent
    limitWindowSeconds = $windowSeconds
    resetAfterSeconds = Get-PropertyValue $Window "reset_after_seconds"
    resetAt = Convert-UnixSecondsToLocalStamp (Get-PropertyValue $Window "reset_at")
  }
}

function Get-UsageStatus {
  param(
    [Parameter(Mandatory = $true)]$Account
  )

  $json = Invoke-CodexApi $Account "/wham/usage"
  $rateLimit = Get-PropertyValue $json "rate_limit"
  $primaryWindow = Get-PropertyValue $rateLimit "primary_window"
  $secondaryWindow = Get-PropertyValue $rateLimit "secondary_window"
  $windows = @()

  if ($null -ne $primaryWindow) {
    $windows += Convert-UsageWindow $primaryWindow "primary"
  }

  if ($null -ne $secondaryWindow) {
    $windows += Convert-UsageWindow $secondaryWindow "secondary"
  }

  $credits = Get-PropertyValue $json "credits"
  $spendControl = Get-PropertyValue $json "spend_control"
  $resetCredits = Get-PropertyValue $json "rate_limit_reset_credits"

  return [pscustomobject]@{
    allowed = Get-PropertyValue $rateLimit "allowed"
    limitReached = Get-PropertyValue $rateLimit "limit_reached"
    rateLimitReachedType = Get-PropertyValue $json "rate_limit_reached_type"
    windows = $windows
    credits = [pscustomobject]@{
      hasCredits = Get-PropertyValue $credits "has_credits"
      unlimited = Get-PropertyValue $credits "unlimited"
      overageLimitReached = Get-PropertyValue $credits "overage_limit_reached"
      balance = Get-PropertyValue $credits "balance"
    }
    spendControl = [pscustomobject]@{
      reached = Get-PropertyValue $spendControl "reached"
      individualLimit = Get-PropertyValue $spendControl "individual_limit"
    }
    rateLimitResetCredits = [pscustomobject]@{
      availableCount = Get-PropertyValue $resetCredits "available_count"
    }
  }
}

function Get-ProfileStats {
  param(
    [Parameter(Mandatory = $true)]$Account
  )

  $json = Invoke-CodexApi $Account "/wham/profiles/me"
  $profile = Get-PropertyValue $json "profile"
  $stats = Get-PropertyValue $json "stats"
  $metadata = Get-PropertyValue $json "metadata"

  return [pscustomobject]@{
    username = Get-PropertyValue $profile "username"
    displayName = Get-PropertyValue $profile "display_name"
    statsAsOf = Get-PropertyValue $metadata "stats_as_of"
    generatedAt = Convert-ToLocalStamp (Get-PropertyValue $metadata "generated_at")
    lifetimeTokens = Get-PropertyValue $stats "lifetime_tokens"
    peakDailyTokens = Get-PropertyValue $stats "peak_daily_tokens"
    currentStreakDays = Get-PropertyValue $stats "current_streak_days"
    longestStreakDays = Get-PropertyValue $stats "longest_streak_days"
    totalThreads = Get-PropertyValue $stats "total_threads"
    longestRunningTurnSec = Get-PropertyValue $stats "longest_running_turn_sec"
    fastModeUsagePercentage = Get-PropertyValue $stats "fast_mode_usage_percentage"
    mostUsedReasoningEffort = Get-PropertyValue $stats "most_used_reasoning_effort"
    mostUsedReasoningEffortPercentage = Get-PropertyValue $stats "most_used_reasoning_effort_percentage"
  }
}

function Get-ResetCredits {
  param(
    [Parameter(Mandatory = $true)]$Account
  )

  $json = Invoke-CodexApi $Account "/wham/rate-limit-reset-credits"
  $rawCredits = Get-PropertyValue $json "credits"
  $creditItems = if ($null -eq $rawCredits) { @() } else { @($rawCredits) }
  $credits = @($creditItems | ForEach-Object {
    [pscustomobject]@{
      id = Get-PropertyValue $_ "id"
      resetType = Get-PropertyValue $_ "reset_type"
      status = Get-PropertyValue $_ "status"
      grantedAt = Convert-ToLocalStamp (Get-PropertyValue $_ "granted_at")
      expiresAt = Convert-ToLocalStamp (Get-PropertyValue $_ "expires_at")
      title = Get-PropertyValue $_ "title"
      description = Get-PropertyValue $_ "description"
    }
  })

  return [pscustomobject]@{
    availableCount = [int](First-NonEmpty (Get-PropertyValue $json "available_count") 0)
    credits = $credits
  }
}

function ConvertTo-HtmlJson {
  param([Parameter(Mandatory = $true)]$Value)

  $convertToJsonCommand = Get-Command ConvertTo-Json
  if ($convertToJsonCommand.Parameters.ContainsKey("EscapeHandling")) {
    return $Value | ConvertTo-Json -Depth 20 -Compress -EscapeHandling EscapeHtml
  }

  $json = $Value | ConvertTo-Json -Depth 20 -Compress
  return $json.
    Replace("&", "\u0026").
    Replace("<", "\u003c").
    Replace(">", "\u003e").
    Replace([char]0x2028, "\u2028").
    Replace([char]0x2029, "\u2029")
}

function Write-ResetHtml {
  param(
    [Parameter(Mandatory = $true)]$Snapshot,
    [Parameter(Mandatory = $true)][string]$OutputPath
  )

  $json = ConvertTo-HtmlJson $Snapshot
  $template = @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Codex Reset Credits</title>
  <style>
    :root {
      color-scheme: light;
      --ink: #18201d;
      --muted: #65716b;
      --line: #d9e0dc;
      --panel: #ffffff;
      --surface: #f3f6f4;
      --accent: #0b6f4d;
      --accent-soft: #dcefe7;
      --warning: #946200;
      --error: #a12828;
    }

    * {
      box-sizing: border-box;
    }

    body {
      margin: 0;
      min-height: 100vh;
      color: var(--ink);
      background:
        linear-gradient(135deg, rgba(11, 111, 77, 0.11), transparent 36rem),
        linear-gradient(315deg, rgba(195, 115, 20, 0.10), transparent 30rem),
        var(--surface);
      font-family: ui-sans-serif, "Segoe UI", Tahoma, Geneva, Verdana, sans-serif;
    }

    main {
      width: min(1100px, calc(100% - 32px));
      margin: 0 auto;
      padding: 48px 0;
    }

    header {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 24px;
      align-items: end;
      margin-bottom: 24px;
    }

    h1,
    p {
      margin: 0;
    }

    h1 {
      font-size: 32px;
      line-height: 1.1;
      font-weight: 750;
    }

    .subhead {
      margin-top: 10px;
      color: var(--muted);
      font-size: 14px;
      line-height: 1.5;
    }

    .total {
      min-width: 180px;
      padding: 18px 20px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--panel);
      box-shadow: 0 16px 42px rgba(24, 32, 29, 0.08);
      text-align: right;
    }

    .total span {
      display: block;
      color: var(--muted);
      font-size: 12px;
      font-weight: 700;
      text-transform: uppercase;
    }

    .total strong {
      display: block;
      margin-top: 6px;
      color: var(--accent);
      font-size: 44px;
      line-height: 1;
    }

    .account {
      overflow: hidden;
      margin-top: 16px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--panel);
      box-shadow: 0 16px 42px rgba(24, 32, 29, 0.08);
    }

    .account-head {
      display: flex;
      gap: 16px;
      align-items: center;
      justify-content: space-between;
      padding: 20px;
      border-bottom: 1px solid var(--line);
      background: rgba(255, 255, 255, 0.72);
    }

    .identity {
      min-width: 0;
    }

    .identity strong,
    .identity span {
      display: block;
      overflow-wrap: anywhere;
    }

    .identity strong {
      font-size: 18px;
    }

    .identity span {
      margin-top: 4px;
      color: var(--muted);
      font-size: 13px;
    }

    .badges {
      display: flex;
      flex: 0 0 auto;
      flex-wrap: wrap;
      gap: 8px;
      justify-content: flex-end;
    }

    .badge {
      padding: 7px 10px;
      border-radius: 999px;
      background: var(--accent-soft);
      color: var(--accent);
      font-size: 12px;
      font-weight: 750;
      text-transform: uppercase;
      white-space: nowrap;
    }

    .badge.error {
      background: #f8dfdf;
      color: var(--error);
    }

    table {
      width: 100%;
      border-collapse: collapse;
    }

    th,
    td {
      padding: 14px 20px;
      border-bottom: 1px solid var(--line);
      text-align: left;
      vertical-align: top;
      font-size: 14px;
    }

    th {
      color: var(--muted);
      font-size: 12px;
      font-weight: 750;
      text-transform: uppercase;
      background: #f8faf9;
    }

    tr:last-child td {
      border-bottom: 0;
    }

    .stamp {
      font-family: ui-monospace, "Cascadia Code", Consolas, monospace;
      white-space: nowrap;
    }

    .empty,
    .error-note {
      padding: 28px 20px;
      color: var(--muted);
      font-size: 14px;
      line-height: 1.45;
    }

    .error-note {
      color: var(--error);
    }

    footer {
      margin-top: 16px;
      color: var(--muted);
      font-size: 12px;
      line-height: 1.5;
    }

    code {
      font-family: ui-monospace, "Cascadia Code", Consolas, monospace;
      font-size: 0.95em;
    }

    @media (max-width: 760px) {
      main {
        width: min(100% - 24px, 1100px);
        padding: 28px 0;
      }

      header {
        grid-template-columns: 1fr;
      }

      .total {
        text-align: left;
      }

      .account-head {
        align-items: flex-start;
        flex-direction: column;
      }

      .badges {
        justify-content: flex-start;
      }

      table,
      thead,
      tbody,
      tr,
      th,
      td {
        display: block;
      }

      thead {
        display: none;
      }

      tr {
        border-bottom: 1px solid var(--line);
      }

      tr:last-child {
        border-bottom: 0;
      }

      td {
        border-bottom: 0;
        padding: 8px 20px;
      }

      td:first-child {
        padding-top: 16px;
      }

      td:last-child {
        padding-bottom: 16px;
      }

      td::before {
        content: attr(data-label);
        display: block;
        margin-bottom: 4px;
        color: var(--muted);
        font-size: 11px;
        font-weight: 750;
        text-transform: uppercase;
      }

      .stamp {
        white-space: normal;
      }
    }
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>Codex Reset Credits</h1>
        <p class="subhead" id="summary"></p>
      </div>
      <div class="total" aria-live="polite">
        <span>Available</span>
        <strong id="total">0</strong>
      </div>
    </header>

    <section id="accounts" aria-label="Codex reset accounts"></section>

    <footer id="source"></footer>
  </main>

  <script id="reset-data" type="application/json">__RESET_DATA_JSON__</script>
  <script>
    const resetData = JSON.parse(document.getElementById("reset-data").textContent);
    const total = Number(resetData.totalAvailable || 0);
    const accounts = Array.isArray(resetData.accounts) ? resetData.accounts : [];
    const localTimeZone = Intl.DateTimeFormat().resolvedOptions().timeZone || resetData.timeZone || "local";

    document.getElementById("total").textContent = String(total);
    document.getElementById("summary").textContent =
      `${total} reset ${total === 1 ? "credit is" : "credits are"} available across ${accounts.length} saved account${accounts.length === 1 ? "" : "s"}.`;
    document.getElementById("source").innerHTML =
      `Generated at <code>${escapeHtml(resetData.generatedAt || "")}</code>. ` +
      `Source: saved auth bundles in <code>${escapeHtml(resetData.accountsDir || "")}</code> plus the reset-credit API. ` +
      `Local timezone: <code>${escapeHtml(localTimeZone)}</code>.`;

    const accountsRoot = document.getElementById("accounts");

    if (!accounts.length) {
      accountsRoot.innerHTML = `<article class="account"><p class="empty">No saved accounts were found.</p></article>`;
    }

    for (const account of accounts) {
      const section = document.createElement("article");
      section.className = "account";

      const credits = Array.isArray(account.credits) ? account.credits : [];
      const rows = credits.length
        ? credits.map((credit) => `
            <tr>
              <td data-label="Reset">${escapeHtml(credit.title || credit.resetType || "Codex reset")}</td>
              <td data-label="Status">${escapeHtml(credit.status || "unknown")}</td>
              <td data-label="Granted at" class="stamp">${escapeHtml(credit.grantedAt || "")}</td>
              <td data-label="Expires at" class="stamp">${escapeHtml(credit.expiresAt || "")}</td>
            </tr>
          `).join("")
        : `<tr><td colspan="4" class="empty">No reset credits are currently available for this account.</td></tr>`;

      const errorHtml = account.error
        ? `<p class="error-note">${escapeHtml(account.error)}</p>`
        : `<table>
            <thead>
              <tr>
                <th>Reset</th>
                <th>Status</th>
                <th>Granted at</th>
                <th>Expires at</th>
              </tr>
            </thead>
            <tbody>${rows}</tbody>
          </table>`;

      section.innerHTML = `
        <div class="account-head">
          <div class="identity">
            <strong>${escapeHtml(account.email || account.name || "Unknown account")}</strong>
            <span>${escapeHtml(account.name || "")}${account.plan ? ` - ${escapeHtml(account.plan)}` : ""}${account.accountId ? ` - ${escapeHtml(account.accountId)}` : ""}</span>
          </div>
          <div class="badges">
            <div class="badge">${Number(account.availableCount || 0)} available</div>
            ${account.error ? `<div class="badge error">query failed</div>` : ""}
          </div>
        </div>
        ${errorHtml}
      `;

      accountsRoot.appendChild(section);
    }

    function escapeHtml(value) {
      return String(value)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#039;");
    }
  </script>
</body>
</html>
'@

  $html = $template.Replace("__RESET_DATA_JSON__", $json)
  Set-Content -LiteralPath $OutputPath -Value $html -Encoding utf8NoBOM
}

function Write-CodexDashboardHtml {
  param(
    [Parameter(Mandatory = $true)]$Snapshot,
    [Parameter(Mandatory = $true)]$LiveAuth,
    [Parameter(Mandatory = $true)][string]$OutputPath
  )

  $json = ConvertTo-HtmlJson $Snapshot
  $template = @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Codex Account Status</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #111312;
      --panel: #171918;
      --panel-2: #1c1f1d;
      --line: #2a2e2b;
      --text: #f4f4f1;
      --muted: #a6aaa5;
      --dim: #777d78;
      --accent: #ff9a87;
      --green: #8de6bd;
      --amber: #f4c86a;
      --error: #ff8d8d;
      --bar: #ecece8;
      --track: #303431;
    }

    * {
      box-sizing: border-box;
    }

    body {
      margin: 0;
      min-height: 100vh;
      color: var(--text);
      background:
        radial-gradient(circle at top left, rgba(255, 154, 135, 0.10), transparent 28rem),
        linear-gradient(180deg, #151716 0%, var(--bg) 46%, #0e100f 100%);
      font-family: ui-sans-serif, "Segoe UI", Tahoma, Geneva, Verdana, sans-serif;
    }

    main {
      width: min(1120px, calc(100% - 32px));
      margin: 0 auto;
      padding: 34px 0 42px;
    }

    .topline {
      display: flex;
      align-items: flex-end;
      justify-content: space-between;
      gap: 20px;
      margin-bottom: 18px;
    }

    h1,
    h2,
    h3,
    p {
      margin: 0;
    }

    h1 {
      font-size: 22px;
      font-weight: 650;
      line-height: 1.1;
    }

    .summary {
      margin-top: 7px;
      color: var(--muted);
      font-size: 13px;
    }

    .total-pill {
      min-width: 150px;
      padding: 12px 14px;
      border: 1px solid var(--line);
      border-radius: 10px;
      background: rgba(28, 31, 29, 0.82);
      text-align: right;
    }

    .total-pill span {
      display: block;
      color: var(--muted);
      font-size: 11px;
      font-weight: 700;
      text-transform: uppercase;
    }

    .total-pill strong {
      display: block;
      color: var(--green);
      font-size: 30px;
      line-height: 1;
      margin-top: 4px;
    }

    .tabs {
      display: flex;
      gap: 8px;
      overflow-x: auto;
      padding: 8px;
      margin-bottom: 28px;
      border: 1px solid var(--line);
      border-radius: 12px;
      background: rgba(23, 25, 24, 0.82);
    }

    .tab {
      appearance: none;
      display: flex;
      align-items: center;
      gap: 10px;
      min-width: 190px;
      max-width: 280px;
      padding: 10px 12px;
      border: 1px solid transparent;
      border-radius: 9px;
      color: var(--muted);
      background: transparent;
      font: inherit;
      text-align: left;
      cursor: pointer;
    }

    .tab[aria-selected="true"] {
      color: var(--text);
      border-color: #3a3f3b;
      background: #202421;
    }

    .tab-avatar,
    .hero-avatar {
      display: grid;
      place-items: center;
      flex: 0 0 auto;
      border-radius: 999px;
      background: var(--accent);
      color: white;
      font-weight: 650;
    }

    .tab-avatar {
      width: 28px;
      height: 28px;
      font-size: 12px;
    }

    .tab-text {
      min-width: 0;
    }

    .tab-text strong,
    .tab-text span {
      display: block;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .tab-text strong {
      font-size: 13px;
      font-weight: 650;
    }

    .tab-text span {
      margin-top: 2px;
      font-size: 12px;
      color: var(--dim);
    }

    .hero {
      display: grid;
      justify-items: center;
      gap: 10px;
      margin-bottom: 28px;
      text-align: center;
    }

    .hero-avatar {
      width: 80px;
      height: 80px;
      font-size: 30px;
    }

    .hero h2 {
      font-size: 25px;
      font-weight: 560;
    }

    .identity-line {
      color: var(--dim);
      font-size: 13px;
    }

    .identity-line .plan {
      display: inline-flex;
      align-items: center;
      margin-left: 6px;
      padding: 2px 7px;
      border: 1px solid var(--line);
      border-radius: 999px;
      color: var(--muted);
      font-size: 12px;
    }

    .profile-stats {
      display: grid;
      grid-template-columns: repeat(5, minmax(120px, 1fr));
      max-width: 920px;
      width: 100%;
      margin: 16px auto 0;
      border: 1px solid var(--line);
      border-radius: 14px;
      background: rgba(23, 25, 24, 0.72);
    }

    .profile-stat {
      min-width: 0;
      padding: 14px 18px;
      border-right: 1px solid var(--line);
    }

    .profile-stat:last-child {
      border-right: 0;
    }

    .profile-stat strong,
    .profile-stat span {
      display: block;
    }

    .profile-stat strong {
      font-size: 14px;
      line-height: 1.25;
    }

    .profile-stat span {
      margin-top: 5px;
      color: var(--muted);
      font-size: 13px;
    }

    .grid {
      display: grid;
      grid-template-columns: minmax(0, 1.1fr) minmax(320px, 0.9fr);
      gap: 16px;
    }

    .panel {
      border: 1px solid var(--line);
      border-radius: 12px;
      background: rgba(23, 25, 24, 0.86);
      box-shadow: 0 20px 50px rgba(0, 0, 0, 0.24);
      overflow: hidden;
    }

    .panel h3 {
      padding: 14px 16px 0;
      font-size: 13px;
      font-weight: 700;
    }

    .panel-body {
      padding: 16px;
    }

    .status-meta {
      display: grid;
      gap: 6px;
      margin-bottom: 16px;
      color: var(--muted);
      font-size: 12px;
    }

    .status-meta code {
      color: var(--text);
    }

    .limit-row {
      display: grid;
      grid-template-columns: 72px minmax(0, 1fr) auto;
      gap: 12px;
      align-items: center;
      margin-top: 12px;
    }

    .limit-label {
      color: var(--muted);
      font-size: 13px;
    }

    .track {
      height: 14px;
      overflow: hidden;
      border-radius: 2px;
      background: var(--track);
      box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.04);
    }

    .fill {
      height: 100%;
      min-width: 2px;
      background: var(--bar);
    }

    .limit-value {
      color: var(--text);
      font-size: 12px;
      white-space: nowrap;
    }

    .limit-value span {
      color: var(--muted);
    }

    .detail-grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 8px;
      margin-top: 16px;
    }

    .detail {
      padding: 10px 12px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--panel-2);
    }

    .detail span {
      display: block;
      color: var(--dim);
      font-size: 11px;
      text-transform: uppercase;
    }

    .detail strong {
      display: block;
      margin-top: 5px;
      overflow-wrap: anywhere;
      font-size: 13px;
      font-weight: 600;
    }

    table {
      width: 100%;
      border-collapse: collapse;
    }

    th,
    td {
      padding: 12px 14px;
      border-bottom: 1px solid var(--line);
      text-align: left;
      vertical-align: top;
      font-size: 13px;
    }

    th {
      color: var(--dim);
      font-size: 11px;
      font-weight: 700;
      text-transform: uppercase;
      background: #151716;
    }

    tr:last-child td {
      border-bottom: 0;
    }

    .stamp,
    code {
      font-family: ui-monospace, "Cascadia Code", Consolas, monospace;
    }

    .stamp {
      white-space: nowrap;
    }

    .live-note {
      color: var(--dim);
      font-size: 12px;
      margin-top: 10px;
    }

    .note,
    .error-note {
      color: var(--muted);
      font-size: 13px;
      line-height: 1.45;
    }

    .error-note {
      color: var(--error);
    }

    footer {
      margin-top: 18px;
      color: var(--dim);
      font-size: 12px;
      line-height: 1.5;
    }

    @media (max-width: 880px) {
      main {
        width: min(100% - 24px, 1120px);
        padding-top: 22px;
      }

      .topline,
      .grid {
        grid-template-columns: 1fr;
      }

      .topline {
        display: grid;
      }

      .total-pill {
        text-align: left;
      }

      .profile-stats {
        grid-template-columns: repeat(2, minmax(0, 1fr));
      }

      .profile-stat {
        border-right: 0;
        border-bottom: 1px solid var(--line);
      }

      .profile-stat:nth-last-child(-n + 1) {
        border-bottom: 0;
      }

      .limit-row {
        grid-template-columns: 58px minmax(0, 1fr);
      }

      .limit-value {
        grid-column: 2;
        white-space: normal;
      }

      .detail-grid {
        grid-template-columns: 1fr;
      }

      table,
      thead,
      tbody,
      tr,
      th,
      td {
        display: block;
      }

      thead {
        display: none;
      }

      tr {
        border-bottom: 1px solid var(--line);
      }

      tr:last-child {
        border-bottom: 0;
      }

      td {
        border-bottom: 0;
        padding: 8px 14px;
      }

      td:first-child {
        padding-top: 14px;
      }

      td:last-child {
        padding-bottom: 14px;
      }

      td::before {
        content: attr(data-label);
        display: block;
        margin-bottom: 4px;
        color: var(--dim);
        font-size: 11px;
        font-weight: 700;
        text-transform: uppercase;
      }

      .stamp {
        white-space: normal;
      }
    }
  </style>
</head>
<body>
  <main>
    <section class="topline">
      <div>
        <h1>Codex Account Status</h1>
        <p class="summary" id="summary"></p>
      </div>
      <div class="total-pill">
        <span>Reset credits</span>
        <strong id="total">0</strong>
      </div>
    </section>

    <nav class="tabs" id="tabs" role="tablist" aria-label="Saved Codex accounts"></nav>
    <section id="account-view" aria-live="polite"></section>
    <footer id="source"></footer>
  </main>

  <script id="reset-data" type="application/json">__RESET_DATA_JSON__</script>
  <script id="live-auth" type="application/json">__LIVE_AUTH_JSON__</script>
  <script>
    const resetData = JSON.parse(document.getElementById("reset-data").textContent);
    const liveAuth = JSON.parse(document.getElementById("live-auth").textContent);
    const accounts = Array.isArray(resetData.accounts) ? resetData.accounts : [];
    const localTimeZone = Intl.DateTimeFormat().resolvedOptions().timeZone || resetData.timeZone || "local";
    let activeIndex = 0;

    updateChromeText();
    document.getElementById("source").innerHTML =
      `Generated at <code>${escapeHtml(resetData.generatedAt || "")}</code>. ` +
      `Live refresh uses <code>${escapeHtml(liveAuth.apiBase || "")}</code>; other tabs use <code>${escapeHtml(resetData.accountsDir || "")}</code>. ` +
      `<code>/backend-api/wham/usage</code>, <code>/backend-api/wham/profiles/me</code>, and <code>/backend-api/wham/rate-limit-reset-credits</code>. ` +
      `Local timezone: <code>${escapeHtml(localTimeZone)}</code>.`;

    renderTabs();
    renderAccount();
    refreshLiveAccount();
    setInterval(refreshLiveAccount, 30000);

    function updateChromeText() {
      const total = accounts.reduce((sum, account) => sum + Number(account.availableCount || 0), 0);
      const account = accounts[activeIndex] || accounts[0] || {};
      const accountTotal = Number(account.availableCount || 0);
      document.getElementById("total").textContent = String(accountTotal);
      document.getElementById("summary").textContent =
        `${accountTotal} reset ${accountTotal === 1 ? "credit" : "credits"} on selected account - ${total} total across ${accounts.length} account snapshot${accounts.length === 1 ? "" : "s"}.`;
    }

    async function refreshLiveAccount() {
      if (!liveAuth || !liveAuth.apiBase) return;
      const previousLiveIndex = accounts.findIndex((account) => account.accountId === liveAuth.accountId);
      const account = previousLiveIndex >= 0 ? accounts[previousLiveIndex] : accounts[activeIndex];
      if (account) account.liveRefreshState = "refreshing";
      if (previousLiveIndex === activeIndex) renderAccount();

      try {
        const live = await fetchCodexJson("/codex-resets/live");
        const liveAccount = live.account || live;
        if (!liveAccount.accountId) throw new Error("Live response did not include accountId.");

        const index = upsertAccount(liveAccount);
        liveAuth.accountId = liveAccount.accountId;
        accounts.forEach((entry, entryIndex) => {
          entry.isLive = entryIndex === index;
          if (entryIndex !== index && entry.dataSource === "live local proxy") {
            entry.dataSource = "cached snapshot";
          }
        });
        accounts[index].liveRefreshState = "ok";
        accounts[index].liveRefreshError = null;
      } catch (error) {
        const failedIndex = accounts.findIndex((entry) => entry.accountId === liveAuth.accountId);
        const failedAccount = failedIndex >= 0 ? accounts[failedIndex] : accounts[activeIndex];
        if (failedAccount) {
          failedAccount.liveRefreshState = "failed";
          failedAccount.liveRefreshError = `Live browser refresh failed; showing cached data. ${error.message || error}`;
        }
      }

      updateChromeText();
      renderTabs();
      renderAccount();
    }

    function upsertAccount(nextAccount) {
      const index = accounts.findIndex((account) => account.accountId === nextAccount.accountId);
      if (index >= 0) {
        accounts[index] = { ...accounts[index], ...nextAccount };
        return index;
      }

      accounts.push(nextAccount);
      return accounts.length - 1;
    }

    async function fetchCodexJson(path) {
      const response = await fetch(`${liveAuth.apiBase}${path}`, {
        method: "GET",
        headers: {
          Accept: "application/json"
        },
        cache: "no-store"
      });
      if (!response.ok) throw new Error(`${response.status} ${response.statusText}`.trim());
      return response.json();
    }

    function applyLiveCredits(account, payload) {
      const rawCredits = Array.isArray(payload) ? payload : (Array.isArray(payload?.credits) ? payload.credits : []);
      const credits = rawCredits.map((credit) => ({
        id: credit.id || credit.credit_id || "",
        resetType: credit.reset_type || credit.resetType || "",
        status: credit.status || "",
        grantedAt: localStamp(credit.granted_at || credit.grantedAt || credit.created_at || credit.createdAt),
        expiresAt: localStamp(credit.expires_at || credit.expiresAt || credit.expiration_time || credit.expirationTime),
        title: credit.title || credit.name || "Codex reset",
        description: credit.description || ""
      })).filter((credit) => (credit.status || "").toLowerCase() !== "used");

      account.credits = credits;
      account.availableCount = credits.filter((credit) => (credit.status || "").toLowerCase() === "available").length;
    }

    function normalizeUsageStatus(payload) {
      const usage = payload || {};
      const rateLimit = usage.rate_limit || usage.rateLimit || usage;
      const windows = Array.isArray(usage.windows)
        ? usage.windows
        : [
            rateLimit.primary_window ? { kind: "primary", ...rateLimit.primary_window } : null,
            rateLimit.secondary_window ? { kind: "secondary", ...rateLimit.secondary_window } : null,
            usage.primary ? { kind: "primary", ...usage.primary } : null,
            usage.secondary ? { kind: "secondary", ...usage.secondary } : null
          ].filter(Boolean);
      return {
        allowed: rateLimit.allowed,
        limitReached: rateLimit.limit_reached ?? rateLimit.limitReached,
        rateLimitReachedType: usage.rate_limit_reached_type ?? usage.rateLimitReachedType,
        windows: windows.map((window) => normalizeUsageWindow(window)),
        credits: usage.credits || usage.credit_grants || {},
        spendControl: usage.spend_control || usage.spendControl || {},
        rateLimitResetCredits: usage.rate_limit_reset_credits || usage.rateLimitResetCredits || {}
      };
    }

    function normalizeUsageWindow(window) {
      const limitWindowSeconds = Number(window.limit_window_seconds ?? window.limitWindowSeconds ?? window.window_seconds ?? 0);
      const usedPercentRaw = Number(window.used_percent ?? window.usedPercent ?? window.percent_used ?? 0);
      const remainingRaw = window.remaining_percent ?? window.remainingPercent;
      const remainingPercent = remainingRaw == null ? 100 - usedPercentRaw : Number(remainingRaw);
      const resetAfterSeconds = window.reset_after_seconds ?? window.resetAfterSeconds;
      const resetAtRaw = window.reset_at || window.resetAt || window.resets_at || window.resetsAt;
      const resetAt = resetAtRaw
        ? localStamp(typeof resetAtRaw === "number" ? new Date(resetAtRaw * 1000) : resetAtRaw)
        : (resetAfterSeconds == null ? "" : localStamp(new Date(Date.now() + Number(resetAfterSeconds) * 1000)));
      return {
        kind: window.kind || "",
        label: window.label || labelForWindow(limitWindowSeconds),
        usedPercent: Math.round(clampPercent(usedPercentRaw)),
        remainingPercent: Math.round(clampPercent(remainingPercent)),
        limitWindowSeconds,
        resetAfterSeconds,
        resetAt
      };
    }

    function normalizeProfileStats(payload) {
      const source = payload?.stats || payload?.profile_stats || payload || {};
      return {
        username: payload?.username || source.username || "",
        displayName: payload?.display_name || payload?.displayName || source.display_name || source.displayName || "",
        statsAsOf: source.stats_as_of || source.statsAsOf || "",
        generatedAt: localStamp(new Date()),
        lifetimeTokens: source.lifetime_tokens ?? source.lifetimeTokens,
        peakDailyTokens: source.peak_daily_tokens ?? source.peakDailyTokens,
        currentStreakDays: source.current_streak_days ?? source.currentStreakDays,
        longestStreakDays: source.longest_streak_days ?? source.longestStreakDays,
        totalThreads: source.total_threads ?? source.totalThreads,
        longestRunningTurnSec: source.longest_running_turn_sec ?? source.longestRunningTurnSec,
        fastModeUsagePercentage: source.fast_mode_usage_percentage ?? source.fastModeUsagePercentage,
        mostUsedReasoningEffort: source.most_used_reasoning_effort ?? source.mostUsedReasoningEffort,
        mostUsedReasoningEffortPercentage: source.most_used_reasoning_effort_percentage ?? source.mostUsedReasoningEffortPercentage
      };
    }

    function labelForWindow(seconds) {
      if (seconds === 18000) return "5h";
      if (seconds === 604800) return "7d";
      return seconds ? `${Math.round(seconds / 3600)}h` : "limit";
    }

    function localStamp(value) {
      if (!value) return "";
      const date = value instanceof Date ? value : new Date(value);
      if (Number.isNaN(date.getTime())) return String(value);
      const pad = (n) => String(n).padStart(2, "0");
      return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} • ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
    }

    function renderTabs() {
      const root = document.getElementById("tabs");
      if (!accounts.length) {
        root.innerHTML = "";
        return;
      }

      root.innerHTML = accounts.map((account, index) => {
        const profile = account.profileStats || {};
        const label = accountLabel(account);
        const sublabel = profile.username ? `@${profile.username}` : (account.email || account.accountId || "");
        return `
          <button class="tab" role="tab" aria-selected="${index === activeIndex ? "true" : "false"}" data-index="${index}">
            <span class="tab-avatar">${escapeHtml(initials(label))}</span>
            <span class="tab-text">
              <strong>${escapeHtml(label)}</strong>
              <span>${escapeHtml(sublabel)}</span>
            </span>
          </button>
        `;
      }).join("");

      for (const button of root.querySelectorAll(".tab")) {
        button.addEventListener("click", () => {
          activeIndex = Number(button.dataset.index || 0);
          updateChromeText();
          renderTabs();
          renderAccount();
        });
      }
    }

    function renderAccount() {
      const root = document.getElementById("account-view");
      if (!accounts.length) {
        root.innerHTML = `<article class="panel"><div class="panel-body"><p class="note">No saved accounts were found. Run the update script after signing in to Codex.</p></div></article>`;
        return;
      }

      const account = accounts[activeIndex] || accounts[0];
      const profile = account.profileStats || {};
      const usage = account.usageStatus || {};
      const label = accountLabel(account);
      const handle = profile.username ? `@${profile.username}` : account.email || "";
      const plan = account.plan || "";

      root.innerHTML = `
        <section class="hero">
          <div class="hero-avatar">${escapeHtml(initials(label))}</div>
          <div>
            <h2>${escapeHtml(label)}</h2>
            <p class="identity-line">${escapeHtml(handle)}${plan ? `<span class="plan">${escapeHtml(plan)}</span>` : ""}</p>
            ${renderLiveNote(account)}
          </div>
          <div class="profile-stats">
            ${profileStat("Lifetime tokens", compactNumber(profile.lifetimeTokens))}
            ${profileStat("Peak tokens", compactNumber(profile.peakDailyTokens))}
            ${profileStat("Longest task", duration(profile.longestRunningTurnSec))}
            ${profileStat("Current streak", days(profile.currentStreakDays))}
            ${profileStat("Longest streak", days(profile.longestStreakDays))}
          </div>
        </section>

        <section class="grid">
          <article class="panel">
            <h3>Status</h3>
            <div class="panel-body">
              ${renderUsage(account, usage)}
            </div>
          </article>
          <article class="panel">
            <h3>Profile</h3>
            <div class="panel-body">
              ${renderProfileDetails(account, profile)}
            </div>
          </article>
        </section>

        <article class="panel" style="margin-top:16px">
          <h3>Reset Credits</h3>
          ${renderCredits(account)}
        </article>
      `;
    }

    function renderUsage(account, usage) {
      if (account.usageError) {
        return `<p class="error-note">${escapeHtml(account.usageError)}</p>`;
      }

      const windows = Array.isArray(usage.windows) ? usage.windows : [];
      if (!windows.length) {
        return `<p class="note">No usage-window data was returned for this account.</p>`;
      }

      const meta = `
        <div class="status-meta">
          <div>Account: <code>${escapeHtml(account.accountId || "")}</code></div>
          <div>Data source: <code>${escapeHtml(account.dataSource || account.tokenSource || "")}</code></div>
        </div>
      `;

      const rows = windows.map((window) => {
        const remaining = clampPercent(window.remainingPercent);
        return `
          <div class="limit-row">
            <div class="limit-label">${escapeHtml(window.label || window.kind || "limit")} limit:</div>
            <div class="track" aria-label="${escapeHtml(window.label || "limit")} remaining">
              <div class="fill" style="width:${remaining}%"></div>
            </div>
            <div class="limit-value">${remaining}% left <span>(resets ${escapeHtml(window.resetAt || "")})</span></div>
          </div>
        `;
      }).join("");

      const allowed = usage.allowed === false ? "Blocked" : "Allowed";
      const reached = usage.limitReached === true ? "Limit reached" : "Within limits";
      const credits = usage.credits || {};
      const spend = usage.spendControl || {};
      const resetBalance = usage.rateLimitResetCredits?.availableCount ?? account.availableCount ?? "--";

      return `
        ${meta}
        ${rows}
        <div class="detail-grid">
          ${detail("Access", allowed)}
          ${detail("Limit state", reached)}
          ${detail("Reset balance", resetBalance)}
          ${detail("Spend cap", spend.reached === true ? "Reached" : "Not reached")}
        </div>
      `;
    }

    function renderLiveNote(account) {
      const suffix = account.lastPolledAt ? ` Last updated ${escapeHtml(account.lastPolledAt)}.` : "";
      if (account.accountId === liveAuth.accountId) {
        if (account.liveRefreshState === "refreshing") {
          return `<p class="live-note">Refreshing live account data...${suffix}</p>`;
        }
        if (account.liveRefreshState === "failed") {
          return `<p class="live-note">${escapeHtml(account.liveRefreshError || "Live refresh failed; showing cached data.")}${suffix}</p>`;
        }
        return `<p class="live-note">Live account. Refreshes every 30 seconds.${suffix}</p>`;
      }

      return `<p class="live-note">Cached account snapshot.${suffix}</p>`;
    }

    function renderProfileDetails(account, profile) {
      if (account.profileError) {
        return `<p class="error-note">${escapeHtml(account.profileError)}</p>`;
      }

      if (!profile || !Object.keys(profile).length) {
        return `<p class="note">No profile stats were returned for this account.</p>`;
      }

      return `
        <div class="detail-grid">
          ${detail("Stats as of", profile.statsAsOf || "--")}
          ${detail("Total threads", integer(profile.totalThreads))}
          ${detail("Fast mode", percent(profile.fastModeUsagePercentage))}
          ${detail("Reasoning", `${profile.mostUsedReasoningEffort || "--"} (${percent(profile.mostUsedReasoningEffortPercentage)})`)}
          ${detail("Token expires", account.accessTokenExpiresAt || "--")}
          ${detail("Profile generated", profile.generatedAt || "--")}
        </div>
      `;
    }

    function renderCredits(account) {
      if (account.resetCreditsError) {
        return `<div class="panel-body"><p class="error-note">${escapeHtml(account.resetCreditsError)}</p></div>`;
      }

      const credits = Array.isArray(account.credits) ? account.credits : [];
      if (!credits.length) {
        return `<div class="panel-body"><p class="note">No reset credits are currently available for this account.</p></div>`;
      }

      const rows = credits.map((credit) => `
        <tr>
          <td data-label="Reset">${escapeHtml(credit.title || credit.resetType || "Codex reset")}</td>
          <td data-label="Status">${escapeHtml(credit.status || "unknown")}</td>
          <td data-label="Granted at" class="stamp">${escapeHtml(credit.grantedAt || "")}</td>
          <td data-label="Expires at" class="stamp">${escapeHtml(credit.expiresAt || "")}</td>
        </tr>
      `).join("");

      return `
        <table>
          <thead>
            <tr>
              <th>Reset</th>
              <th>Status</th>
              <th>Granted at</th>
              <th>Expires at</th>
            </tr>
          </thead>
          <tbody>${rows}</tbody>
        </table>
      `;
    }

    function accountLabel(account) {
      const profile = account.profileStats || {};
      return profile.displayName || account.name || account.email || account.accountId || "Unknown account";
    }

    function profileStat(label, value) {
      return `<div class="profile-stat"><strong>${escapeHtml(value || "--")}</strong><span>${escapeHtml(label)}</span></div>`;
    }

    function detail(label, value) {
      return `<div class="detail"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value ?? "--")}</strong></div>`;
    }

    function compactNumber(value) {
      const n = Number(value);
      if (!Number.isFinite(n)) return "--";
      if (Math.abs(n) >= 1e9) return `${trimNumber(n / 1e9)}B`;
      if (Math.abs(n) >= 1e6) return `${trimNumber(n / 1e6)}M`;
      if (Math.abs(n) >= 1e3) return `${trimNumber(n / 1e3)}K`;
      return String(n);
    }

    function trimNumber(value) {
      return value.toFixed(value >= 10 ? 1 : 2).replace(/\.0+$|(\.\d*[1-9])0+$/, "$1");
    }

    function duration(seconds) {
      const total = Number(seconds);
      if (!Number.isFinite(total)) return "--";
      const daysCount = Math.floor(total / 86400);
      const hours = Math.floor((total % 86400) / 3600);
      const minutes = Math.floor((total % 3600) / 60);
      if (daysCount > 0) return `${daysCount}d ${hours}h`;
      if (hours > 0) return `${hours}h ${minutes}m`;
      return `${minutes}m`;
    }

    function days(value) {
      const n = Number(value);
      if (!Number.isFinite(n)) return "--";
      return `${n} ${n === 1 ? "day" : "days"}`;
    }

    function integer(value) {
      const n = Number(value);
      return Number.isFinite(n) ? n.toLocaleString() : "--";
    }

    function percent(value) {
      const n = Number(value);
      return Number.isFinite(n) ? `${trimNumber(n)}%` : "--";
    }

    function clampPercent(value) {
      const n = Number(value);
      if (!Number.isFinite(n)) return 0;
      return Math.max(0, Math.min(100, Math.round(n)));
    }

    function initials(value) {
      const parts = String(value || "?")
        .replace(/@.*/, "")
        .split(/[^A-Za-z0-9]+/)
        .filter(Boolean);
      if (!parts.length) return "?";
      return parts.slice(0, 2).map((part) => part[0]).join("").toUpperCase();
    }

    function escapeHtml(value) {
      return String(value)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#039;");
    }
  </script>
</body>
</html>
'@

  $liveAuthJson = ConvertTo-HtmlJson $LiveAuth
  $html = $template.Replace("__RESET_DATA_JSON__", $json).Replace("__LIVE_AUTH_JSON__", $liveAuthJson)
  Set-Content -LiteralPath $OutputPath -Value $html -Encoding utf8NoBOM
}

New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null

$liveAuth = [ordered]@{
  accountId = $null
  apiBase = $LiveApiBase.TrimEnd("/")
}
$accountsById = @{}
$cachedFiles = @(Get-ChildItem -LiteralPath $CacheDir -Filter "*.snapshot.json" -File -ErrorAction SilentlyContinue)
foreach ($file in $cachedFiles) {
  try {
    $cached = Read-JsonFile $file.FullName
    if (-not [string]::IsNullOrWhiteSpace([string]$cached.accountId)) {
      $cached | Add-Member -MemberType NoteProperty -Name "isLive" -Value $false -Force
      $cached | Add-Member -MemberType NoteProperty -Name "dataSource" -Value "cached snapshot from $($file.Name)" -Force
      $accountsById[$cached.accountId] = $cached
    }
  } catch {
    Write-Warning "Skipping cached snapshot $($file.Name): $($_.Exception.Message)"
  }
}

if (-not $SkipSaveCurrent) {
  try {
    $activeAuth = Read-JsonFile $AuthPath
    $info = Get-AuthAccountInfo $activeAuth $AuthPath
    $liveAuth.accountId = $info.accountId
    Write-Host "Querying live Codex account data for $(First-NonEmpty $info.email $info.accountId)..."

    $record = [ordered]@{
      email = $info.email
      name = $info.name
      plan = $info.plan
      accountId = $info.accountId
      tokenSource = "~/.codex/auth.json"
      dataSource = "live ~/.codex/auth.json"
      isLive = $true
      lastPolledAt = (Get-Date).ToString("yyyy-MM-dd • HH:mm:ss")
      accessTokenExpiresAt = $info.accessTokenExpiresAt
      availableCount = 0
      credits = @()
      usageStatus = $null
      profileStats = $null
      resetCreditsError = $null
      usageError = $null
      profileError = $null
      error = $null
    }

    if ($SkipFetch) {
      $record.error = "Fetching was skipped."
      $record.resetCreditsError = "Fetching was skipped."
      $record.usageError = "Fetching was skipped."
      $record.profileError = "Fetching was skipped."
    } else {
      try {
        $resetCredits = Get-ResetCredits $info
        $record.availableCount = $resetCredits.availableCount
        $record.credits = $resetCredits.credits
      } catch {
        $record.resetCreditsError = Get-FriendlyAccountError $info $_.Exception.Message
      }

      try {
        $usageStatus = Get-UsageStatus $info
        $record.usageStatus = $usageStatus
        if ($record.availableCount -eq 0) {
          $usageResetCredits = Get-PropertyValue (Get-PropertyValue $usageStatus "rateLimitResetCredits") "availableCount"
          if ($null -ne $usageResetCredits) {
            $record.availableCount = [int]$usageResetCredits
          }
        }
      } catch {
        $record.usageError = Get-FriendlyAccountError $info $_.Exception.Message
      }

      try {
        $profileStats = Get-ProfileStats $info
        $record.profileStats = $profileStats
        if ([string]::IsNullOrWhiteSpace([string]$record.name)) {
          $record.name = $profileStats.displayName
        }
      } catch {
        $record.profileError = Get-FriendlyAccountError $info $_.Exception.Message
      }
    }

    $liveRecord = [pscustomobject]$record
    $accountsById[$info.accountId] = $liveRecord

    $hasUsableLiveData = $null -ne $liveRecord.usageStatus -or $null -ne $liveRecord.profileStats -or $null -ne $liveRecord.credits
    if ($hasUsableLiveData -and -not $SkipFetch) {
      $identity = First-NonEmpty $liveRecord.email $liveRecord.name $liveRecord.accountId
      $shortId = $liveRecord.accountId.Substring(0, [Math]::Min(8, $liveRecord.accountId.Length))
      $cacheFile = Join-Path $CacheDir ("$(New-SafeFileStem "$identity-$shortId").snapshot.json")
      $cacheRecord = [pscustomobject]$record
      $cacheRecord | Add-Member -MemberType NoteProperty -Name "isLive" -Value $false -Force
      $cacheRecord | Add-Member -MemberType NoteProperty -Name "dataSource" -Value "cached snapshot from last successful live poll" -Force
      Write-JsonFile $cacheRecord $cacheFile
      Write-Host "Updated cached snapshot for $(First-NonEmpty $liveRecord.email $liveRecord.accountId) at $cacheFile"
    }
  } catch {
    Write-Warning "Could not poll active auth file $AuthPath`: $($_.Exception.Message)"
  }
}

$accounts = @($accountsById.Values | Sort-Object { -not $_.isLive }, { $_.email }, { $_.accountId })

$totalAvailable = 0
foreach ($account in $accounts) {
  $totalAvailable += [int]$account.availableCount
}

$snapshot = [ordered]@{
  generatedAt = (Get-Date).ToString("yyyy-MM-dd • HH:mm:ss")
  timeZone = (Get-TimeZone).Id
  source = "Live data for the active ~/.codex/auth.json account plus cached snapshots for other accounts."
  accountsDir = ".codex-cache"
  totalAvailable = $totalAvailable
  accounts = $accounts
}

Write-CodexDashboardHtml $snapshot $liveAuth $OutputPath
Write-Host "Wrote $OutputPath with $totalAvailable available reset credit(s) across $($accounts.Count) account snapshot(s)."
