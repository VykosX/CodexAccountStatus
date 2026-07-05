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

function Get-HistoryPath {
  param([Parameter(Mandatory = $true)]$Account)

  $historyDir = Join-Path $CacheDir "history"
  $identity = First-NonEmpty (Get-PropertyValue $Account "email") (Get-PropertyValue $Account "name") (Get-PropertyValue $Account "accountId")
  $accountId = [string](Get-PropertyValue $Account "accountId")
  if ([string]::IsNullOrWhiteSpace($accountId)) {
    return $null
  }

  $shortId = $accountId.Substring(0, [Math]::Min(8, $accountId.Length))
  return Join-Path $historyDir ("$(New-SafeFileStem "$identity-$shortId").history.json")
}

function Add-HistoryIfPresent {
  param([Parameter(Mandatory = $true)]$Account)

  $historyPath = Get-HistoryPath $Account
  if ($null -eq $historyPath -or -not (Test-Path -LiteralPath $historyPath)) {
    return
  }

  try {
    $Account | Add-Member -MemberType NoteProperty -Name "history" -Value (Read-JsonFile $historyPath) -Force
  } catch {
    Write-Warning "Skipping history $historyPath`: $($_.Exception.Message)"
  }
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
  $dailyUsageBuckets = @(Get-PropertyValue $stats "daily_usage_buckets")

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
    dailyUsageBuckets = @($dailyUsageBuckets | ForEach-Object {
      [pscustomobject]@{
        date = Get-PropertyValue $_ "start_date"
        tokens = Get-PropertyValue $_ "tokens"
      }
    })
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

    function escapeAttr(value) {
      return escapeHtml(value).replace(/`/g, "&#096;");
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
      width: min(1440px, calc(100% - 32px));
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
      grid-template-columns: 72px minmax(0, 1fr) minmax(180px, auto);
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

    .limit-value .used {
      color: #ff7777;
      margin-right: 8px;
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

    .history-grid {
      display: grid;
      gap: 16px;
      min-width: 0;
      overflow: hidden;
    }

    .history-grid > div {
      min-width: 0;
      overflow: hidden;
    }

    .history-summary {
      display: grid;
      grid-template-columns: repeat(6, minmax(0, 1fr));
      gap: 10px;
    }

    .mini-metric {
      align-items: center;
      background: #151716;
      border: 1px solid var(--line);
      border-radius: 8px;
      display: flex;
      flex-direction: column;
      justify-content: center;
      min-height: 82px;
      padding: 10px 12px;
      text-align: center;
    }

    .mini-metric span {
      color: var(--muted);
      display: block;
      font-size: 12px;
      margin-bottom: 4px;
    }

    .mini-metric strong {
      font-size: 20px;
      font-weight: 700;
      line-height: 1.15;
      overflow-wrap: anywhere;
    }

    .mini-metric strong.long-value {
      font-size: 15px;
    }

    .bar-chart {
      align-items: end;
      box-sizing: border-box;
      display: grid;
      gap: 6px;
      min-height: 224px;
      max-width: 100%;
      overflow: hidden;
      padding: 0;
      width: 100%;
    }

    .metric-chart {
      display: grid;
      gap: 10px;
      grid-template-columns: 56px minmax(0, 1fr);
      max-width: 100%;
      min-width: 0;
    }

    .metric-axis,
    .metric-plot {
      height: 242px;
      position: relative;
    }

    .metric-axis {
      border-right: 1px solid var(--line);
    }

    .axis-label {
      color: var(--dim);
      font-size: 10px;
      line-height: 1;
      position: absolute;
      right: 8px;
      transform: translateY(50%);
      white-space: nowrap;
    }

    .metric-plot {
      border-bottom: 1px solid var(--line);
      min-width: 0;
      overflow: hidden;
    }

    .metric-gridline {
      border-top: 1px solid rgba(255, 255, 255, 0.08);
      left: 0;
      position: absolute;
      right: 0;
    }

    .metric-plot .bar-chart,
    .metric-plot .area-chart {
      height: 242px;
      left: 0;
      position: absolute;
      right: 0;
      top: 0;
      z-index: 1;
    }

    .chart-header {
      align-items: center;
      display: flex;
      gap: 12px;
      justify-content: space-between;
      margin-bottom: 8px;
    }

    .chart-header h4 {
      margin: 0;
    }

    .chart-select {
      background: #151716;
      border: 1px solid var(--line);
      border-radius: 8px;
      color: var(--text);
      font: inherit;
      padding: 7px 10px;
    }

    .chart-box {
      display: grid;
      gap: 8px;
      max-width: 100%;
      min-width: 0;
      overflow: hidden;
    }

    .bar-column {
      align-items: stretch;
      display: grid;
      gap: 6px;
      grid-template-rows: 200px auto;
      min-width: 0;
    }

    .bar-stack {
      align-items: end;
      display: flex;
      height: 200px;
      justify-content: center;
      min-width: 0;
    }

    .bar {
      background: #e52727;
      border-radius: 5px 5px 0 0;
      min-height: 2px;
      position: relative;
      width: 100%;
    }

    .bar-label {
      color: var(--dim);
      font-size: 10px;
      line-height: 1.1;
      min-height: 22px;
      text-align: center;
    }

    .chart-legend {
      display: flex;
      flex-wrap: wrap;
      gap: 8px 14px;
      margin-top: 4px;
    }

    .legend-item {
      align-items: center;
      color: var(--muted);
      display: inline-flex;
      font-size: 12px;
      gap: 6px;
    }

    .legend-swatch {
      border-radius: 999px;
      display: inline-block;
      height: 9px;
      width: 9px;
    }

    .area-chart {
      border-bottom: 1px solid var(--line);
      box-sizing: border-box;
      display: grid;
      gap: 6px;
      max-width: 100%;
      min-height: 180px;
      overflow: hidden;
      padding-top: 14px;
      width: 100%;
    }

    .area-column {
      align-items: end;
      display: grid;
      gap: 5px;
      grid-template-rows: 200px auto;
      min-width: 0;
    }

    .area-stack {
      align-items: end;
      display: flex;
      flex-direction: column;
      height: 200px;
      justify-content: flex-end;
      overflow: hidden;
      width: 100%;
    }

    .area-segment {
      border-radius: 4px 4px 0 0;
      min-height: 1px;
      width: 100%;
    }

    .bar:hover::after {
      display: none;
    }

    .history-bars {
      display: grid;
      gap: 10px;
    }

    .table-scroll {
      max-width: 100%;
      overflow-x: auto;
    }

    .session-table {
      table-layout: auto;
      width: 100%;
      min-width: 100%;
    }

    .session-table th,
    .session-table td {
      white-space: nowrap;
    }

    .history-row {
      display: grid;
      gap: 10px;
      grid-template-columns: 110px 1fr 90px;
      align-items: center;
    }

    .breakdown {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
    }

    .chip {
      background: #202320;
      border: 1px solid var(--line);
      border-radius: 999px;
      color: var(--text);
      font-size: 12px;
      padding: 6px 10px;
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
    const historyMonths = {};
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

        <article class="panel" style="margin-top:16px">
          <h3>History</h3>
          <div class="panel-body">
            ${renderHistory(account)}
          </div>
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
        const used = clampPercent(window.usedPercent);
        return `
          <div class="limit-row">
            <div class="limit-label">${escapeHtml(window.label || window.kind || "limit")} limit:</div>
            <div class="track" aria-label="${escapeHtml(window.label || "limit")} remaining">
              <div class="fill" style="width:${remaining}%"></div>
            </div>
            <div class="limit-value">${remaining}% left <span class="separator">•</span> <span class="used">${used}% used</span> <span>(resets ${escapeHtml(window.resetAt || "")})</span></div>
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

    function renderHistory(account) {
      const history = account.history || {};
      const sessions = Array.isArray(history.sessions) ? history.sessions : [];
      const samples = Array.isArray(history.samples) ? history.samples : [];
      const rawDailyBuckets = Array.isArray(history.dailyUsageBuckets) && history.dailyUsageBuckets.length
        ? history.dailyUsageBuckets
        : (Array.isArray(account.profileStats?.dailyUsageBuckets) ? account.profileStats.dailyUsageBuckets : []);
      const dailyBuckets = withLiveTodayBucket(rawDailyBuckets, samples);
      const totalTokens = sessions.reduce((sum, session) => sum + Number(session.tokensUsed || 0), 0);
      const totalThreads = sessions.reduce((sum, session) => sum + Number(session.threadDelta || 0), 0);
      const analytics = history.analytics || {};
      const totals = analytics.totals || {};
      const latest = samples[samples.length - 1] || {};

      return `
        <div class="history-grid">
          <div class="history-summary">
            ${miniMetric("Samples", integer(samples.length))}
            ${miniMetric("Sessions", integer(sessions.length))}
            ${miniMetric("30d tokens", compactNumber(totals.textTotalTokens ?? totalTokens))}
            ${miniMetric("30d turns", integer(totals.turns ?? totalThreads))}
            ${miniMetric("30d credits", number(totals.credits, 2))}
            ${miniMetric("Analytics as of", analytics.fetchedAt || "--")}
          </div>
          <div>
            <div class="chart-header">
              <h4>Personal Usage (tokens/day)</h4>
              ${renderMonthSelect(account, dailyBuckets)}
            </div>
            ${renderDailyBars(account, dailyBuckets)}
          </div>
          <div>
            <h4>Usage by Model (turns)</h4>
            ${renderStackedUsageChart(account, dailyBuckets, "model")}
          </div>
          <div>
            <h4>Usage by Surface (turns)</h4>
            ${renderStackedUsageChart(account, dailyBuckets, "surface")}
          </div>
          <div>
            <h4>Working Sessions</h4>
            ${renderSessionTable(sessions, latest, dailyBuckets)}
          </div>
          <div>
            <h4>Daily Entries</h4>
            ${renderDailyTable(dailyBuckets)}
          </div>
        </div>
      `;
    }

    function miniMetric(label, value) {
      const text = String(value ?? "--");
      const longClass = text.length > 14 ? " long-value" : "";
      return `<div class="mini-metric"><span>${escapeHtml(label)}</span><strong class="${longClass.trim()}">${escapeHtml(text)}</strong></div>`;
    }

    function renderMonthSelect(account, buckets) {
      const months = availableMonths(buckets);
      if (months.length <= 1) return "";
      const selected = selectedHistoryMonth(account, buckets);
      return `
        <select class="chart-select" aria-label="Usage month" onchange="setHistoryMonth('${escapeAttr(account.accountId || "")}', this.value)">
          ${months.map((month) => `<option value="${escapeAttr(month)}"${month === selected ? " selected" : ""}>${escapeHtml(monthLabel(month))}</option>`).join("")}
        </select>
      `;
    }

    window.setHistoryMonth = function(accountId, month) {
      historyMonths[accountId || "active"] = month;
      renderAccount();
    };

    function selectedHistoryMonth(account, buckets) {
      const months = availableMonths(buckets);
      if (!months.length) return "";
      const key = account.accountId || "active";
      if (historyMonths[key] && months.includes(historyMonths[key])) return historyMonths[key];
      historyMonths[key] = months[months.length - 1];
      return historyMonths[key];
    }

    function availableMonths(buckets) {
      return [...new Set((Array.isArray(buckets) ? buckets : [])
        .map((bucket) => String(bucket.date || "").slice(0, 7))
        .filter(Boolean))]
        .sort();
    }

    function monthBuckets(account, buckets) {
      const selected = selectedHistoryMonth(account, buckets);
      return expandMonthBuckets(selected, buckets);
    }

    function monthLabel(month) {
      const [year, monthNumber] = String(month).split("-").map(Number);
      if (!year || !monthNumber) return month;
      return new Date(year, monthNumber - 1, 1).toLocaleDateString(undefined, { month: "long", year: "numeric" });
    }

    function expandMonthBuckets(month, buckets) {
      const [year, monthNumber] = String(month || "").split("-").map(Number);
      if (!year || !monthNumber) return [];
      const daysInMonth = new Date(year, monthNumber, 0).getDate();
      const byDate = new Map((Array.isArray(buckets) ? buckets : [])
        .filter((bucket) => String(bucket.date || "").startsWith(month))
        .map((bucket) => [bucket.date, bucket]));
      return Array.from({ length: daysInMonth }, (_, index) => {
        const date = `${year}-${String(monthNumber).padStart(2, "0")}-${String(index + 1).padStart(2, "0")}`;
        return byDate.get(date) || {
          date,
          users: 0,
          threads: 0,
          turns: 0,
          credits: 0,
          uncachedTextInputTokens: 0,
          cachedTextInputTokens: 0,
          textOutputTokens: 0,
          tokens: 0,
          clients: [],
          models: [],
          empty: true
        };
      });
    }

    function withLiveTodayBucket(buckets, samples) {
      const rows = Array.isArray(buckets) ? buckets.map((bucket) => ({ ...bucket })) : [];
      const latest = Array.isArray(samples) && samples.length ? samples[samples.length - 1] : null;
      if (!latest?.at) return rows;

      const today = String(latest.at).slice(0, 10);
      if (!today || rows.some((bucket) => bucket.date === today)) return rows;

      const todaySamples = (Array.isArray(samples) ? samples : []).filter((sample) => String(sample.at || "").startsWith(today));
      const first = todaySamples[0] || latest;
      const last = todaySamples[todaySamples.length - 1] || latest;
      const tokenDelta = Math.max(0, Number(last.lifetimeTokens || 0) - Number(first.lifetimeTokens || 0));
      const threadDelta = Math.max(0, Number(last.totalThreads || 0) - Number(first.totalThreads || 0));
      const primaryDelta = Math.max(0, Number(last.primaryUsedPercent || 0) - Number(first.primaryUsedPercent || 0));
      const secondaryDelta = Math.max(0, Number(last.secondaryUsedPercent || 0) - Number(first.secondaryUsedPercent || 0));
      const hasLiveActivity = tokenDelta > 0 || threadDelta > 0 || primaryDelta > 0 || secondaryDelta > 0;
      const inferredTurns = hasLiveActivity ? Math.max(1, threadDelta, Math.ceil(primaryDelta + secondaryDelta)) : 0;
      const averageTokensPerTurn = averageMetricPerTurn(rows, "tokens");
      const displayTokens = tokenDelta > 0 ? tokenDelta : (hasLiveActivity ? averageTokensPerTurn * inferredTurns : 0);
      rows.push({
        date: today,
        users: hasLiveActivity ? 1 : 0,
        threads: threadDelta,
        turns: inferredTurns,
        credits: 0,
        uncachedTextInputTokens: displayTokens,
        cachedTextInputTokens: 0,
        textOutputTokens: 0,
        tokens: displayTokens,
        clients: hasLiveActivity ? [{ client_id: "LOCAL_LIVE_SAMPLE", turns: inferredTurns, threads: threadDelta, text_total_tokens: displayTokens }] : [],
        models: hasLiveActivity ? [{ model: "N/A", turns: inferredTurns, threads: threadDelta, pending: true }] : [],
        estimated: true
      });
      return rows.sort((a, b) => String(a.date).localeCompare(String(b.date)));
    }

    function averageMetricPerTurn(rows, metric) {
      const totals = (Array.isArray(rows) ? rows : []).reduce((acc, row) => {
        acc.value += Number(row[metric] || 0);
        acc.turns += Number(row.turns || 0);
        return acc;
      }, { value: 0, turns: 0 });
      return totals.turns > 0 ? totals.value / totals.turns : 0;
    }

    function niceAxis(maxValue, targetTicks = 7) {
      const max = Math.max(1, Number(maxValue || 0));
      const rawStep = max / Math.max(1, targetTicks - 1);
      const magnitude = Math.pow(10, Math.floor(Math.log10(rawStep)));
      const normalized = rawStep / magnitude;
      const niceNormalized = normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 2.5 ? 2.5 : normalized <= 5 ? 5 : 10;
      const step = niceNormalized * magnitude;
      const axisMax = Math.ceil(max / step) * step;
      const tickCount = Math.floor(axisMax / step);
      return {
        step,
        max: axisMax,
        ticks: Array.from({ length: tickCount + 1 }, (_, index) => index * step)
      };
    }

    function renderDailyBars(account, buckets) {
      const recent = monthBuckets(account, buckets);
      if (!recent.length) return `<p class="note">No daily usage buckets have been recorded for this month.</p>`;
      const maxTokens = Math.max(...recent.map((bucket) => Number(bucket.tokens || 0)), 1);
      const axis = niceAxis(maxTokens, 7);
      const axisMax = axis.max;
      const ticks = axis.ticks;
      const plotHeight = 200;
      const labelSpace = 24;
      return `<div class="chart-box">
        <div class="metric-chart">
          <div class="metric-axis" aria-hidden="true">
            ${ticks.map((tick) => `<span class="axis-label" style="bottom:${labelSpace + ((tick / axisMax) * plotHeight)}px">${escapeHtml(compactNumber(tick))}</span>`).join("")}
          </div>
          <div class="metric-plot">
            ${ticks.map((tick) => `<span class="metric-gridline" style="bottom:${labelSpace + ((tick / axisMax) * plotHeight)}px"></span>`).join("")}
            <div class="bar-chart" style="grid-template-columns: repeat(${recent.length}, minmax(0, 1fr))">${recent.map((bucket) => {
        const tokens = Number(bucket.tokens || 0);
        const height = tokens > 0 ? Math.max(2, (tokens / axisMax) * 100) : 0;
        return `
          <div class="bar-column">
            <div class="bar-stack">${height > 0 ? `<div class="bar" style="height:${height}%" title="${escapeAttr(`${bucket.date || ""}: ${compactNumber(tokens)} tokens`)}"></div>` : ""}</div>
            <div class="bar-label">${escapeHtml(dayLabel(bucket.date))}</div>
          </div>
        `;
      }).join("")}</div>
          </div>
        </div>
        <div class="chart-legend"><span class="legend-item"><span class="legend-swatch" style="background:#e52727"></span>Daily tokens</span></div>
      </div>`;
    }

    function renderStackedUsageChart(account, buckets, kind) {
      const rows = monthBuckets(account, buckets);
      const sourceRows = rows.filter((row) => !row.empty);
      const seriesNames = usageSeriesNames(sourceRows, kind);
      if (!rows.length || !seriesNames.length) return `<p class="note">No ${escapeHtml(kind)} usage breakdown is available for this month.</p>`;
      const colors = chartColors(seriesNames.length);
      const maxTurns = Math.max(...rows.map((bucket) => Number(bucket.turns || 0)), 1);
      const axis = niceAxis(maxTurns, 7);
      const axisMax = axis.max;
      const ticks = axis.ticks;
      const plotHeight = 200;
      const labelSpace = 24;
      return `
        <div class="chart-box">
          <div class="metric-chart">
            <div class="metric-axis" aria-hidden="true">
              ${ticks.map((tick) => `<span class="axis-label" style="bottom:${labelSpace + ((tick / axisMax) * plotHeight)}px">${escapeHtml(integer(tick))}</span>`).join("")}
            </div>
            <div class="metric-plot">
              ${ticks.map((tick) => `<span class="metric-gridline" style="bottom:${labelSpace + ((tick / axisMax) * plotHeight)}px"></span>`).join("")}
              <div class="area-chart" style="grid-template-columns: repeat(${rows.length}, minmax(0, 1fr))">
                ${rows.map((bucket) => {
              const values = usageSeriesValues(bucket, kind, seriesNames);
              return `
                <div class="area-column">
                  <div class="area-stack" data-title="${escapeAttr(`${bucket.date}: ${integer(bucket.turns || 0)} turns`)}">
                    ${seriesNames.map((name, index) => {
                      const height = Math.max(0, (Number(values[name] || 0) / axisMax) * 100);
                      return height > 0 ? `<div class="area-segment" style="height:${height}%; background:${colors[index]}" title="${escapeAttr(`${name}: ${integer(values[name])} turns`)}"></div>` : "";
                    }).join("")}
                  </div>
                  <div class="bar-label">${escapeHtml(dayLabel(bucket.date))}</div>
                </div>
              `;
                }).join("")}
              </div>
            </div>
          </div>
          <div class="chart-legend">
            ${seriesNames.map((name, index) => `<span class="legend-item"><span class="legend-swatch" style="background:${colors[index]}"></span>${escapeHtml(surfaceLabel(name))}</span>`).join("")}
          </div>
        </div>
      `;
    }

    function renderSessionTable(sessions, latest, buckets) {
      const sessionEstimates = estimateSessionMetrics(sessions, buckets);
      const rows = sessions.slice(-12).reverse();
      if (!rows.length) {
        const sampleText = latest?.at ? ` Latest sample: ${escapeHtml(latest.at)}.` : "";
        return `<p class="note">No changing usage intervals have been recorded yet.${sampleText}</p>`;
      }

      return `
        <div class="table-scroll">
        <table class="session-table">
          <thead>
            <tr>
              <th>Session</th>
              <th>Duration</th>
              <th>Tokens</th>
              <th>Threads / turns</th>
              <th>5h</th>
              <th>7d</th>
              <th>Credits</th>
              <th>Samples</th>
              <th>Reasoning</th>
              <th>Model</th>
              <th>Surface</th>
            </tr>
          </thead>
          <tbody>
            ${rows.map((session) => `
              <tr>
                <td data-label="Session" class="stamp">${escapeHtml(sessionRange(session.base || session))}</td>
                <td data-label="Duration">${escapeHtml(sessionDuration(session.base || session))}</td>
                <td data-label="Tokens">${escapeHtml(sessionTokens(session, sessionEstimates))}</td>
                <td data-label="Threads / turns">${escapeHtml(sessionThreads(session, sessionEstimates))}</td>
                <td data-label="5h">${escapeHtml(percentDelta(session.primaryUsedPercentStart, session.primaryUsedPercentEnd))}</td>
                <td data-label="7d">${escapeHtml(percentDelta(session.secondaryUsedPercentStart, session.secondaryUsedPercentEnd))}</td>
                <td data-label="Credits">${escapeHtml(sessionCreditDelta(session))}</td>
                <td data-label="Samples">${escapeHtml(integer(session.sampleCount || 0))}</td>
                <td data-label="Reasoning">${escapeHtml(session.reasoning || "--")}</td>
                <td data-label="Model">${escapeHtml(sessionModelSummary(session, sessionEstimates))}</td>
                <td data-label="Surface">${escapeHtml(session.surface || "Unknown")}</td>
              </tr>
            `).join("")}
          </tbody>
        </table>
        </div>
      `;
    }

    function renderDailyTable(buckets) {
      const rows = dailyModelRows(buckets).slice(-80).reverse();
      if (!rows.length) return `<p class="note">No dated usage entries are available yet.</p>`;
      return `
        <table>
          <thead>
            <tr>
              <th>Date</th>
              <th>Model</th>
              <th>Tokens</th>
              <th>Est. API $</th>
              <th>Credits</th>
              <th>Turns</th>
              <th>Threads</th>
              <th>Input</th>
              <th>Cached</th>
              <th>Output</th>
            </tr>
          </thead>
          <tbody>
            ${rows.map((bucket) => `
              <tr>
                <td data-label="Date" class="stamp">${escapeHtml(bucket.date || "")}</td>
                <td data-label="Model">${escapeHtml(bucket.model || "Unknown")}</td>
                <td data-label="Tokens">${escapeHtml(bucket.tokens == null ? "--" : compactNumber(bucket.tokens))}</td>
                <td data-label="Est. API $">${escapeHtml(bucket.estimatedApiUsd == null ? "--" : formatUsd(bucket.estimatedApiUsd))}</td>
                <td data-label="Credits">${escapeHtml(bucket.credits == null ? "--" : number(bucket.credits, 2))}</td>
                <td data-label="Turns">${escapeHtml(integer(bucket.turns || 0))}</td>
                <td data-label="Threads">${escapeHtml(integer(bucket.threads || 0))}</td>
                <td data-label="Input">${escapeHtml(bucket.uncachedTextInputTokens == null ? "--" : compactNumber(bucket.uncachedTextInputTokens))}</td>
                <td data-label="Cached">${escapeHtml(bucket.cachedTextInputTokens == null ? "--" : compactNumber(bucket.cachedTextInputTokens))}</td>
                <td data-label="Output">${escapeHtml(bucket.textOutputTokens == null ? "--" : compactNumber(bucket.textOutputTokens))}</td>
              </tr>
            `).join("")}
          </tbody>
        </table>
      `;
    }

    function dayLabel(dateText) {
      const text = String(dateText || "");
      const day = text.slice(8, 10);
      return day || text;
    }

    function usageSeriesNames(rows, kind) {
      const names = new Set();
      for (const row of rows) {
        if (kind === "model") {
          for (const model of Array.isArray(row.models) ? row.models : []) {
            names.add(model.model || model.name || "Unknown");
          }
        } else {
          for (const client of Array.isArray(row.clients) ? row.clients : []) {
            names.add(client.client_id || client.name || "Unknown");
          }
        }
      }
      return [...names].sort();
    }

    function usageSeriesValues(row, kind, names) {
      const values = Object.fromEntries(names.map((name) => [name, 0]));
      if (kind === "model") {
        for (const model of Array.isArray(row.models) ? row.models : []) {
          const name = model.model || model.name || "Unknown";
          values[name] = (values[name] || 0) + Number(model.turns || 0);
        }
      } else {
        for (const client of Array.isArray(row.clients) ? row.clients : []) {
          const name = client.client_id || client.name || "Unknown";
          values[name] = (values[name] || 0) + Number(client.turns || 0);
        }
      }
      return values;
    }

    function dailyModelRows(buckets) {
      const rows = [];
      for (const bucket of Array.isArray(buckets) ? buckets : []) {
        const models = Array.isArray(bucket.models) && bucket.models.length ? bucket.models : [{ model: "Unknown", turns: bucket.turns || 0, threads: bucket.threads || 0 }];
        const totalTurns = models.reduce((sum, model) => sum + Number(model.turns || 0), 0) || 1;
        const duplicateShapes = duplicateModelShapes(models);
        const duplicateShares = duplicateModelShares(models);
        for (const model of models) {
          const shape = modelShape(model);
          const shareKey = modelShareShape(model);
          const duplicateShaped = duplicateShapes.has(shape) || duplicateShares.has(shareKey);
          const share = Number(model.turns || 0) / totalTurns;
          const allocated = !duplicateShaped;
          rows.push({
            date: bucket.date,
            model: model.model || model.name || "Unknown",
            tokens: allocated ? Number(bucket.tokens || 0) * share : null,
            credits: allocated ? Number(bucket.credits || 0) * share : Number(model.credits || 0),
            turns: Number(model.turns || 0),
            threads: Number(model.threads ?? bucket.threads ?? 0),
            uncachedTextInputTokens: allocated ? Number(bucket.uncachedTextInputTokens || 0) * share : null,
            cachedTextInputTokens: allocated ? Number(bucket.cachedTextInputTokens || 0) * share : null,
            textOutputTokens: allocated ? Number(bucket.textOutputTokens || 0) * share : null,
            estimatedApiUsd: null
          });
          rows[rows.length - 1].estimatedApiUsd = allocated
            ? estimateApiUsd(rows[rows.length - 1].model, rows[rows.length - 1].uncachedTextInputTokens, rows[rows.length - 1].cachedTextInputTokens, rows[rows.length - 1].textOutputTokens)
            : null;
        }
      }
      return rows;
    }

    function modelShape(model) {
      return [
        Number(model.turns || 0),
        Number(model.threads || 0),
        Number(model.users || 0),
        Number(model.credits || 0)
      ].join("|");
    }

    function duplicateModelShapes(models) {
      const counts = new Map();
      for (const model of Array.isArray(models) ? models : []) {
        const shape = modelShape(model);
        counts.set(shape, (counts.get(shape) || 0) + 1);
      }
      return new Set([...counts.entries()].filter(([, count]) => count > 1).map(([shape]) => shape));
    }

    function modelShareShape(model) {
      return String(Number(model.turns || 0));
    }

    function duplicateModelShares(models) {
      const counts = new Map();
      for (const model of Array.isArray(models) ? models : []) {
        const shape = modelShareShape(model);
        counts.set(shape, (counts.get(shape) || 0) + 1);
      }
      return new Set([...counts.entries()].filter(([, count]) => count > 1).map(([shape]) => shape));
    }

    function estimateApiUsd(model, uncachedInput, cachedInput, output) {
      const rates = apiRates(model);
      return ((Number(uncachedInput || 0) / 1_000_000) * rates.input) +
        ((Number(cachedInput || 0) / 1_000_000) * rates.cachedInput) +
        ((Number(output || 0) / 1_000_000) * rates.output);
    }

    function apiRates(model) {
      const key = String(model || "").toLowerCase();
      if (key.includes("5.5")) return { input: 5.00, cachedInput: 0.50, output: 30.00 };
      if (key.includes("5.4-mini")) return { input: 0.75, cachedInput: 0.075, output: 4.50 };
      if (key.includes("5.4")) return { input: 2.50, cachedInput: 0.25, output: 15.00 };
      return { input: 5.00, cachedInput: 0.50, output: 30.00 };
    }

    function chartColors(count) {
      const palette = ["#3b82f6", "#1d4ed8", "#c4b5fd", "#8b5cf6", "#f97316", "#14b8a6", "#facc15", "#fb7185"];
      return Array.from({ length: count }, (_, index) => palette[index % palette.length]);
    }

    function surfaceLabel(value) {
      return String(value || "Unknown")
        .replace(/^CODEX_/i, "")
        .replace(/_/g, " ")
        .toLowerCase()
        .replace(/\b\w/g, (letter) => letter.toUpperCase());
    }

    function formatUsd(value) {
      const n = Number(value);
      if (!Number.isFinite(n)) return "--";
      return n.toLocaleString(undefined, { style: "currency", currency: "USD", maximumFractionDigits: n >= 10 ? 2 : 4 });
    }

    function percentDelta(start, end) {
      if (start == null || end == null) return "--";
      const delta = Number(end) - Number(start);
      const sign = delta > 0 ? "+" : "";
      return `${Number(start).toFixed(0)}% → ${Number(end).toFixed(0)}% (${sign}${delta.toFixed(0)})`;
    }

    function sessionRange(session) {
      const start = String(session.start || "");
      const end = String(session.end || "");
      if (!start && !end) return "--";
      const endTime = end.includes(" • ") ? end.split(" • ").pop() : end;
      return `${start || "--"} → ${endTime || "--"}`;
    }

    function sessionDuration(session) {
      const start = parseLocalStamp(session.start);
      const end = parseLocalStamp(session.end);
      if (!start || !end) return "--";
      return duration(Math.max(0, Math.round((end - start) / 1000)));
    }

    function sessionUsageMoved(session) {
      return Math.abs(Number(session.primaryUsedPercentEnd || 0) - Number(session.primaryUsedPercentStart || 0)) > 0 ||
        Math.abs(Number(session.secondaryUsedPercentEnd || 0) - Number(session.secondaryUsedPercentStart || 0)) > 0;
    }

    function sessionMovement(session) {
      return Math.max(0,
        Math.abs(Number(session.primaryUsedPercentEnd || 0) - Number(session.primaryUsedPercentStart || 0)) +
        Math.abs(Number(session.secondaryUsedPercentEnd || 0) - Number(session.secondaryUsedPercentStart || 0))
      );
    }

    function sessionDate(session) {
      return String(session.start || session.end || "").slice(0, 10);
    }

    function estimateSessionMetrics(sessions, buckets) {
      const bucketByDate = new Map((Array.isArray(buckets) ? buckets : []).map((bucket) => [bucket.date, bucket]));
      const movementByDate = {};
      for (const session of Array.isArray(sessions) ? sessions : []) {
        const date = sessionDate(session);
        movementByDate[date] = (movementByDate[date] || 0) + sessionMovement(session);
      }
      const estimates = new Map();
      for (const session of Array.isArray(sessions) ? sessions : []) {
        const date = sessionDate(session);
        const bucket = bucketByDate.get(date);
        const movement = sessionMovement(session);
        const totalMovement = movementByDate[date] || 0;
        if (!bucket || !movement || !totalMovement) continue;
        const share = movement / totalMovement;
        const models = Array.isArray(bucket.models) && bucket.models.length
          ? bucket.models
          : [{ model: session.model || "Estimated", turns: bucket.turns || 0, threads: bucket.threads || 0 }];
        const modelTurnTotal = models.reduce((sum, model) => sum + Number(model.turns || 0), 0) || 1;
        estimates.set(sessionKey(session), {
          tokens: Number(bucket.tokens || 0) * share,
          threads: Number(bucket.threads || 0) * share,
          turns: Number(bucket.turns || 0) * share,
          models: models.map((model) => {
            const modelShare = Number(model.turns || 0) / modelTurnTotal;
            return {
              model: model.model || model.name || "Estimated",
              tokens: Number(bucket.tokens || 0) * share * modelShare,
              threads: Number(model.threads ?? bucket.threads ?? 0) * share,
              turns: Number(model.turns || 0) * share
            };
          }).filter((model) => model.turns > 0 || model.tokens > 0)
        });
      }
      return estimates;
    }

    function sessionKey(session) {
      return `${session.start || ""}|${session.end || ""}`;
    }

    function sessionTokens(session, estimates) {
      const tokens = Number(session.tokensUsed || 0);
      if (tokens > 0) return compactNumber(tokens);
      const estimate = estimates?.get(sessionKey(session));
      if (estimate?.tokens > 0) return `≈${compactNumber(estimate.tokens)}`;
      return sessionUsageMoved(session) ? "≈0" : "0";
    }

    function sessionThreads(session, estimates) {
      const threads = Number(session.threadDelta || 0);
      if (threads > 0) return integer(threads);
      const estimate = estimates?.get(sessionKey(session));
      if (estimate?.threads > 0) return `≈${number(estimate.threads, 1)}`;
      if (estimate?.turns > 0) return `≈${number(estimate.turns, 1)} turns`;
      return sessionUsageMoved(session) ? "≈0" : "0";
    }

    function sessionModelSummary(session, estimates) {
      const direct = session.model && session.model !== "Unknown" ? session.model : "";
      const estimate = estimates?.get(sessionKey(session));
      const models = Array.isArray(estimate?.models) ? estimate.models : [];
      if (!models.length) return direct || "Not exposed";
      const totalTurns = models.reduce((sum, model) => sum + Number(model.turns || 0), 0) || 1;
      return models
        .slice()
        .sort((a, b) => Number(b.turns || 0) - Number(a.turns || 0))
        .map((model) => `${model.model} ${Math.round((Number(model.turns || 0) / totalTurns) * 100)}%`)
        .join(" / ");
    }

    function sessionCreditDelta(session) {
      if (session.resetCreditsStart == null || session.resetCreditsEnd == null) return "--";
      const start = Number(session.resetCreditsStart);
      const end = Number(session.resetCreditsEnd);
      if (!Number.isFinite(start) || !Number.isFinite(end)) return "--";
      const delta = end - start;
      const sign = delta > 0 ? "+" : "";
      return `${start} → ${end} (${sign}${delta})`;
    }

    function parseLocalStamp(value) {
      if (!value) return null;
      const normalized = String(value).replace(" • ", "T");
      const date = new Date(normalized);
      return Number.isNaN(date.getTime()) ? null : date;
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

    function number(value, digits = 2) {
      const n = Number(value);
      return Number.isFinite(n) ? n.toLocaleString(undefined, { maximumFractionDigits: digits }) : "--";
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

    function escapeAttr(value) {
      return escapeHtml(value).replace(/`/g, "&#096;");
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
      Add-HistoryIfPresent $cached
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
    Add-HistoryIfPresent $liveRecord
    if ($SkipFetch -and $accountsById.ContainsKey($info.accountId)) {
      $cachedLive = $accountsById[$info.accountId]
      $cachedLive | Add-Member -MemberType NoteProperty -Name "isLive" -Value $true -Force
      $cachedLive | Add-Member -MemberType NoteProperty -Name "dataSource" -Value "cached snapshot for active account; fetching skipped" -Force
    } else {
      $accountsById[$info.accountId] = $liveRecord
    }

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
