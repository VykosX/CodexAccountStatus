[CmdletBinding()]
param(
  [int]$Port = 8787,
  [string]$AuthPath = (Join-Path $HOME ".codex\auth.json"),
  [string]$Root = $PSScriptRoot,
  [string]$CacheDir = (Join-Path $PSScriptRoot ".codex-cache")
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

function Convert-ToLocalStamp {
  param([Parameter(Mandatory = $false)]$Value)

  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return $null
  }

  if ($Value -is [DateTime]) {
    $date = [DateTimeOffset]$Value
  } elseif ([string]$Value -match "^\d+$") {
    $date = [DateTimeOffset]::FromUnixTimeSeconds([int64]$Value)
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

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)]$Value,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $jsonArgs = @{ Depth = 100 }
  if ((Get-Command ConvertTo-Json).Parameters.ContainsKey("EscapeHandling")) {
    $jsonArgs.EscapeHandling = "EscapeNonAscii"
  }

  $json = $Value | ConvertTo-Json @jsonArgs
  Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function ConvertTo-HtmlJson {
  param([Parameter(Mandatory = $true)]$Value)

  $jsonArgs = @{ Depth = 100; Compress = $true }
  if ((Get-Command ConvertTo-Json).Parameters.ContainsKey("EscapeHandling")) {
    $jsonArgs.EscapeHandling = "EscapeHtml"
  }

  return $Value | ConvertTo-Json @jsonArgs
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

function Get-ActiveCodexAuth {
  if (-not (Test-Path -LiteralPath $AuthPath)) {
    throw "Auth file not found: $AuthPath"
  }

  $auth = ConvertFrom-JsonWithStringDates (Get-Content -LiteralPath $AuthPath -Raw)
  $tokens = Get-PropertyValue $auth "tokens"
  $accessToken = Get-PropertyValue $tokens "access_token"
  if ([string]::IsNullOrWhiteSpace($accessToken)) {
    throw "Missing access_token in $AuthPath."
  }

  $accessPayload = Decode-JwtPayload $accessToken
  $accessAuth = Get-PropertyValue $accessPayload "https://api.openai.com/auth"
  $idToken = Get-PropertyValue $tokens "id_token"
  $idPayload = if ($idToken) { Decode-JwtPayload $idToken } else { $null }
  $profile = Get-PropertyValue $accessPayload "https://api.openai.com/profile"
  $accountId = Get-PropertyValue $tokens "account_id"
  if ([string]::IsNullOrWhiteSpace($accountId)) {
    $accountId = Get-PropertyValue $accessAuth "chatgpt_account_id"
  }
  if ([string]::IsNullOrWhiteSpace($accountId)) {
    throw "Could not determine account id in $AuthPath."
  }

  return [pscustomobject]@{
    accessToken = $accessToken
    accountId = $accountId
    email = First-NonEmpty (Get-PropertyValue $profile "email") (Get-PropertyValue $idPayload "email")
    name = Get-PropertyValue $idPayload "name"
    plan = First-NonEmpty (Get-PropertyValue $accessAuth "chatgpt_plan_type") (Get-PropertyValue $idPayload "chatgpt_plan_type")
    accessTokenExpiresAt = Convert-UnixSecondsToLocalStamp (Get-PropertyValue $accessPayload "exp")
  }
}

function Write-Response {
  param(
    [Parameter(Mandatory = $true)]$Context,
    [int]$StatusCode = 200,
    [string]$ContentType = "application/json; charset=utf-8",
    [string]$Body = ""
  )

  try {
    $response = $Context.Response
    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $response.StatusCode = $StatusCode
    $response.ContentType = $ContentType
    $response.Headers["Access-Control-Allow-Origin"] = "*"
    $response.Headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
    $response.Headers["Access-Control-Allow-Headers"] = "Accept, Content-Type"
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
  } catch [InvalidOperationException] {
    return
  } finally {
    try { $Context.Response.OutputStream.Close() } catch {}
  }
}

function Write-JsonError {
  param(
    [Parameter(Mandatory = $true)]$Context,
    [int]$StatusCode,
    [string]$Message
  )

  $body = @{ error = $Message; status = $StatusCode } | ConvertTo-Json -Depth 4
  Write-Response $Context $StatusCode "application/json; charset=utf-8" $body
}

function Invoke-CodexProxy {
  param(
    [Parameter(Mandatory = $true)][string]$BackendPath
  )

  $active = Get-ActiveCodexAuth
  $headers = @{
    Authorization = "Bearer $($active.accessToken)"
    "ChatGPT-Account-ID" = $active.accountId
    "OpenAI-Beta" = "codex-1"
    originator = "Codex Desktop"
    Accept = "application/json"
    "User-Agent" = "codex-resets-local-proxy/1.0"
  }

  $response = Invoke-WebRequest `
    -Uri "https://chatgpt.com$BackendPath" `
    -Headers $headers `
    -Method Get `
    -TimeoutSec 30

  return $response.Content
}

function Convert-UsageWindow {
  param(
    [Parameter(Mandatory = $true)]$Window,
    [Parameter(Mandatory = $true)][string]$Kind
  )

  $usedPercent = [int](First-NonEmpty (Get-PropertyValue $Window "used_percent") 0)
  $windowSeconds = Get-PropertyValue $Window "limit_window_seconds"

  return [pscustomobject]@{
    kind = $Kind
    label = if ([int64]$windowSeconds -eq 18000) { "5h" } elseif ([int64]$windowSeconds -eq 604800) { "7d" } else { "limit" }
    usedPercent = $usedPercent
    remainingPercent = [Math]::Max(0, 100 - $usedPercent)
    limitWindowSeconds = $windowSeconds
    resetAfterSeconds = Get-PropertyValue $Window "reset_after_seconds"
    resetAt = Convert-UnixSecondsToLocalStamp (Get-PropertyValue $Window "reset_at")
  }
}

function Convert-UsageStatus {
  param([Parameter(Mandatory = $true)]$Json)

  $rateLimit = Get-PropertyValue $Json "rate_limit"
  $primaryWindow = Get-PropertyValue $rateLimit "primary_window"
  $secondaryWindow = Get-PropertyValue $rateLimit "secondary_window"
  $windows = @()
  if ($null -ne $primaryWindow) { $windows += Convert-UsageWindow $primaryWindow "primary" }
  if ($null -ne $secondaryWindow) { $windows += Convert-UsageWindow $secondaryWindow "secondary" }

  $credits = Get-PropertyValue $Json "credits"
  $spendControl = Get-PropertyValue $Json "spend_control"
  $resetCredits = Get-PropertyValue $Json "rate_limit_reset_credits"

  return [pscustomobject]@{
    allowed = Get-PropertyValue $rateLimit "allowed"
    limitReached = Get-PropertyValue $rateLimit "limit_reached"
    rateLimitReachedType = Get-PropertyValue $Json "rate_limit_reached_type"
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

function Convert-ProfileStats {
  param([Parameter(Mandatory = $true)]$Json)

  $profile = Get-PropertyValue $Json "profile"
  $stats = Get-PropertyValue $Json "stats"
  $metadata = Get-PropertyValue $Json "metadata"
  $dailyUsageBuckets = @(Get-PropertyValue $stats "daily_usage_buckets")
  $statsAsOf = First-NonEmpty (Get-PropertyValue $metadata "stats_as_of") (Get-PropertyValue $Json "stats_as_of")
  if ([string]::IsNullOrWhiteSpace([string]$statsAsOf) -and $dailyUsageBuckets.Count -gt 0) {
    $statsAsOf = ($dailyUsageBuckets | ForEach-Object { Get-PropertyValue $_ "start_date" } | Sort-Object | Select-Object -Last 1)
  }

  return [pscustomobject]@{
    username = Get-PropertyValue $profile "username"
    displayName = Get-PropertyValue $profile "display_name"
    statsAsOf = $statsAsOf
    generatedAt = (Get-Date).ToString("yyyy-MM-dd • HH:mm:ss")
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

function Convert-ResetCredits {
  param([Parameter(Mandatory = $true)]$Json)

  $credits = @(Get-PropertyValue $Json "credits") | ForEach-Object {
    [pscustomobject]@{
      id = Get-PropertyValue $_ "id"
      resetType = Get-PropertyValue $_ "reset_type"
      status = Get-PropertyValue $_ "status"
      grantedAt = Convert-ToLocalStamp (Get-PropertyValue $_ "granted_at")
      expiresAt = Convert-ToLocalStamp (Get-PropertyValue $_ "expires_at")
      title = Get-PropertyValue $_ "title"
      description = Get-PropertyValue $_ "description"
    }
  }

  return [pscustomobject]@{
    availableCount = [int](First-NonEmpty (Get-PropertyValue $Json "available_count") 0)
    credits = @($credits)
  }
}

function Get-LiveAccountSnapshot {
  $active = Get-ActiveCodexAuth
  $usage = Convert-UsageStatus (ConvertFrom-JsonWithStringDates (Invoke-CodexProxy "/backend-api/wham/usage"))
  $profile = Convert-ProfileStats (ConvertFrom-JsonWithStringDates (Invoke-CodexProxy "/backend-api/wham/profiles/me"))
  $resetCredits = Convert-ResetCredits (ConvertFrom-JsonWithStringDates (Invoke-CodexProxy "/backend-api/wham/rate-limit-reset-credits"))

  $record = [pscustomobject]@{
    email = $active.email
    name = First-NonEmpty $active.name $profile.displayName
    plan = $active.plan
    accountId = $active.accountId
    tokenSource = "~/.codex/auth.json"
    dataSource = "live local proxy"
    isLive = $true
    lastPolledAt = (Get-Date).ToString("yyyy-MM-dd • HH:mm:ss")
    accessTokenExpiresAt = $active.accessTokenExpiresAt
    availableCount = $resetCredits.availableCount
    credits = $resetCredits.credits
    usageStatus = $usage
    profileStats = $profile
    resetCreditsError = $null
    usageError = $null
    profileError = $null
    error = $null
  }

  New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
  $identity = First-NonEmpty $record.email $record.name $record.accountId
  $shortId = $record.accountId.Substring(0, [Math]::Min(8, $record.accountId.Length))
  $cacheFile = Join-Path $CacheDir ("$(New-SafeFileStem "$identity-$shortId").snapshot.json")
  $cacheRecord = $record.PSObject.Copy()
  $cacheRecord.isLive = $false
  $cacheRecord.dataSource = "cached snapshot from local proxy"
  Write-JsonFile $cacheRecord $cacheFile

  return [pscustomobject]@{
    account = $record
    cacheFile = Split-Path -Leaf $cacheFile
  }
}

function Get-CachedDashboardSnapshot {
  New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
  $accounts = @()
  foreach ($file in @(Get-ChildItem -LiteralPath $CacheDir -Filter "*.snapshot.json" -File -ErrorAction SilentlyContinue)) {
    try {
      $cached = ConvertFrom-JsonWithStringDates (Get-Content -LiteralPath $file.FullName -Raw)
      if (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $cached "accountId"))) {
        $cached | Add-Member -MemberType NoteProperty -Name "isLive" -Value $false -Force
        $cached | Add-Member -MemberType NoteProperty -Name "dataSource" -Value "cached snapshot from $($file.Name)" -Force
        $accounts += $cached
      }
    } catch {
      Write-Warning "Skipping cached snapshot $($file.Name): $($_.Exception.Message)"
    }
  }

  $active = $null
  try { $active = Get-ActiveCodexAuth } catch {}
  if ($null -ne $active) {
    foreach ($account in $accounts) {
      if ($account.accountId -eq $active.accountId) {
        $account.isLive = $true
        $account.dataSource = "cached snapshot for active account"
      }
    }
  }

  $totalAvailable = 0
  foreach ($account in $accounts) {
    $totalAvailable += [int](First-NonEmpty (Get-PropertyValue $account "availableCount") 0)
  }

  return [ordered]@{
    generatedAt = (Get-Date).ToString("yyyy-MM-dd • HH:mm:ss")
    timeZone = (Get-TimeZone).Id
    source = "Live data for the active ~/.codex/auth.json account plus cached snapshots for other accounts."
    accountsDir = ".codex-cache"
    totalAvailable = $totalAvailable
    accounts = @($accounts | Sort-Object { -not $_.isLive }, { $_.email }, { $_.accountId })
  }
}

function Get-LiveAuthPayload {
  $active = $null
  try { $active = Get-ActiveCodexAuth } catch {}

  return [ordered]@{
    accountId = if ($null -ne $active) { $active.accountId } else { $null }
    apiBase = "http://127.0.0.1:$Port"
  }
}

function Get-ServedIndexHtml {
  param([Parameter(Mandatory = $true)][string]$IndexPath)

  $html = Get-Content -LiteralPath $IndexPath -Raw
  $snapshotJson = ConvertTo-HtmlJson (Get-CachedDashboardSnapshot)
  $liveAuthJson = ConvertTo-HtmlJson (Get-LiveAuthPayload)
  $html = [Text.RegularExpressions.Regex]::Replace(
    $html,
    '<script id="reset-data" type="application/json">.*?</script>',
    [Text.RegularExpressions.MatchEvaluator]{ param($Match) "<script id=`"reset-data`" type=`"application/json`">$snapshotJson</script>" },
    [Text.RegularExpressions.RegexOptions]::Singleline
  )
  $html = [Text.RegularExpressions.Regex]::Replace(
    $html,
    '<script id="live-auth" type="application/json">.*?</script>',
    [Text.RegularExpressions.MatchEvaluator]{ param($Match) "<script id=`"live-auth`" type=`"application/json`">$liveAuthJson</script>" },
    [Text.RegularExpressions.RegexOptions]::Singleline
  )

  return $html
}

$listener = [Net.HttpListener]::new()
$prefix = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()
$script:Stopping = $false
$cancelHandler = [ConsoleCancelEventHandler]{
  param($Sender, $EventArgs)
  $script:Stopping = $true
  try { $listener.Stop() } catch {}
  $EventArgs.Cancel = $false
}
[Console]::add_CancelKeyPress($cancelHandler)

Write-Host "Codex Resets server running at $prefix"
Write-Host "Open ${prefix}index.html"
Write-Host "Press Ctrl+C to stop."

try {
  while ($listener.IsListening -and -not $script:Stopping) {
    $async = $listener.BeginGetContext($null, $null)
    while (-not $async.AsyncWaitHandle.WaitOne(200)) {
      if ($script:Stopping -or -not $listener.IsListening) {
        break
      }
    }

    if ($script:Stopping -or -not $listener.IsListening) {
      break
    }

    $context = $null
    try {
      $context = $listener.EndGetContext($async)
      if ($context.Request.HttpMethod -eq "OPTIONS") {
        Write-Response $context 204 "text/plain; charset=utf-8" ""
        continue
      }

      $path = $context.Request.Url.AbsolutePath
      if ($path -eq "/" -or $path -eq "/index.html") {
        $indexPath = Join-Path $Root "index.html"
        if (-not (Test-Path -LiteralPath $indexPath)) {
          Write-JsonError $context 404 "index.html not found. Run .\Update-CodexResets.ps1 first."
          continue
        }

        Write-Response $context 200 "text/html; charset=utf-8" (Get-ServedIndexHtml $indexPath)
        continue
      }

      if ($path -like "/backend-api/wham/*") {
        Write-Response $context 200 "application/json; charset=utf-8" (Invoke-CodexProxy $path)
        continue
      }

      if ($path -eq "/codex-resets/live") {
        Write-Response $context 200 "application/json; charset=utf-8" ((Get-LiveAccountSnapshot) | ConvertTo-Json -Depth 100)
        continue
      }

      Write-JsonError $context 404 "Unknown path: $path"
    } catch {
      if ($null -ne $context) {
        Write-JsonError $context 500 $_.Exception.Message
      } elseif (-not $script:Stopping) {
        Write-Warning $_.Exception.Message
      }
    }
  }
} finally {
  [Console]::remove_CancelKeyPress($cancelHandler)
  if ($listener.IsListening) {
    $listener.Stop()
  }
  $listener.Close()
}
