[CmdletBinding()]
param(
  [int]$Port = 8787,
  [string]$AuthPath = (Join-Path $HOME ".codex\auth.json"),
  [string]$Root,
  [string]$CacheDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  $PSScriptRoot
} elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
  Split-Path -Parent $PSCommandPath
} else {
  (Get-Location).Path
}
if ([string]::IsNullOrWhiteSpace($Root)) {
  $Root = $ScriptRoot
}
if ([string]::IsNullOrWhiteSpace($CacheDir)) {
  $CacheDir = Join-Path $ScriptRoot ".codex-cache"
}

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

function ConvertTo-Number {
  param(
    [Parameter(Mandatory = $false)]$Value,
    [double]$Default = 0
  )

  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return $Default
  }

  try {
    return [double]$Value
  } catch {
    return $Default
  }
}

function Add-NumberProperty {
  param(
    [Parameter(Mandatory = $true)]$Target,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $false)]$Value
  )

  $Target.$Name = (ConvertTo-Number $Target.$Name) + (ConvertTo-Number $Value)
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

  return Format-LocalStamp $date.LocalDateTime
}

function Convert-UnixSecondsToLocalStamp {
  param([Parameter(Mandatory = $false)]$Seconds)

  if ($null -eq $Seconds -or [string]::IsNullOrWhiteSpace([string]$Seconds)) {
    return $null
  }

  return Format-LocalStamp ([DateTimeOffset]::FromUnixTimeSeconds([int64]$Seconds)).LocalDateTime
}

function Format-LocalStamp {
  param([Parameter(Mandatory = $true)][DateTime]$Date)

  return "{0} {1} {2}" -f $Date.ToString("yyyy-MM-dd"), [char]0x2022, $Date.ToString("HH:mm:ss")
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

  $json = $Value | ConvertTo-Json @jsonArgs
  if ($jsonArgs.ContainsKey("EscapeHandling")) {
    return $json
  }

  return $json.
    Replace("&", "\u0026").
    Replace("<", "\u003c").
    Replace(">", "\u003e").
    Replace([string][char]0x2028, "\u2028").
    Replace([string][char]0x2029, "\u2029")
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
    generatedAt = Format-LocalStamp (Get-Date)
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

function Get-CodexAnalyticsUsage {
  param(
    [int]$Days = 30,
    [string]$GroupBy = "day"
  )

  $end = (Get-Date).Date.AddDays(1)
  $start = $end.AddDays(-[Math]::Max(1, $Days))
  $path = "/backend-api/wham/analytics/daily-workspace-usage-counts?start_date=$($start.ToString("yyyy-MM-dd"))&end_date=$($end.ToString("yyyy-MM-dd"))&group_by=$GroupBy"

  try {
    return Convert-CodexAnalyticsUsage (ConvertFrom-JsonWithStringDates (Invoke-CodexProxy $path)) $path
  } catch {
    return [pscustomobject]@{
      fetchedAt = Format-LocalStamp (Get-Date)
      path = $path
      groupBy = $GroupBy
      rows = @()
      modelBreakdown = @()
      surfaceBreakdown = @()
      totals = [pscustomobject]@{}
      error = $_.Exception.Message
    }
  }
}

function Convert-CodexAnalyticsUsage {
  param(
    [Parameter(Mandatory = $true)]$Json,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $modelTotals = @{}
  $surfaceTotals = @{}
  $summary = [ordered]@{
    users = 0
    threads = 0
    turns = 0
    credits = 0
    uncachedTextInputTokens = 0
    cachedTextInputTokens = 0
    textOutputTokens = 0
    textTotalTokens = 0
  }

  $rows = @(Get-PropertyValue $Json "data") | ForEach-Object {
    $totals = Get-PropertyValue $_ "totals"
    foreach ($pair in @(
      @("users", "users"),
      @("threads", "threads"),
      @("turns", "turns"),
      @("credits", "credits"),
      @("uncachedTextInputTokens", "uncached_text_input_tokens"),
      @("cachedTextInputTokens", "cached_text_input_tokens"),
      @("textOutputTokens", "text_output_tokens"),
      @("textTotalTokens", "text_total_tokens")
    )) {
      Add-NumberProperty $summary $pair[0] (Get-PropertyValue $totals $pair[1])
    }

    foreach ($client in @(Get-PropertyValue $_ "clients")) {
      $name = First-NonEmpty (Get-PropertyValue $client "client_id") "Unknown"
      if (-not $surfaceTotals.ContainsKey($name)) {
        $surfaceTotals[$name] = [ordered]@{ name = $name; users = 0; threads = 0; turns = 0; credits = 0; tokens = 0 }
      }
      Add-NumberProperty $surfaceTotals[$name] "users" (Get-PropertyValue $client "users")
      Add-NumberProperty $surfaceTotals[$name] "threads" (Get-PropertyValue $client "threads")
      Add-NumberProperty $surfaceTotals[$name] "turns" (Get-PropertyValue $client "turns")
      Add-NumberProperty $surfaceTotals[$name] "credits" (Get-PropertyValue $client "credits")
      Add-NumberProperty $surfaceTotals[$name] "tokens" (Get-PropertyValue $client "text_total_tokens")
    }

    foreach ($model in @(Get-PropertyValue $_ "models")) {
      $name = First-NonEmpty (Get-PropertyValue $model "model") "Unknown"
      if (-not $modelTotals.ContainsKey($name)) {
        $modelTotals[$name] = [ordered]@{ name = $name; users = 0; threads = 0; turns = 0; credits = 0; tokens = 0 }
      }
      Add-NumberProperty $modelTotals[$name] "users" (Get-PropertyValue $model "users")
      Add-NumberProperty $modelTotals[$name] "threads" (Get-PropertyValue $model "threads")
      Add-NumberProperty $modelTotals[$name] "turns" (Get-PropertyValue $model "turns")
      Add-NumberProperty $modelTotals[$name] "credits" (Get-PropertyValue $model "credits")
    }

    [pscustomobject]@{
      date = Get-PropertyValue $_ "date"
      users = ConvertTo-Number (Get-PropertyValue $totals "users")
      threads = ConvertTo-Number (Get-PropertyValue $totals "threads")
      turns = ConvertTo-Number (Get-PropertyValue $totals "turns")
      credits = ConvertTo-Number (Get-PropertyValue $totals "credits")
      uncachedTextInputTokens = ConvertTo-Number (Get-PropertyValue $totals "uncached_text_input_tokens")
      cachedTextInputTokens = ConvertTo-Number (Get-PropertyValue $totals "cached_text_input_tokens")
      textOutputTokens = ConvertTo-Number (Get-PropertyValue $totals "text_output_tokens")
      tokens = ConvertTo-Number (Get-PropertyValue $totals "text_total_tokens")
      clients = @(Get-PropertyValue $_ "clients")
      models = @(Get-PropertyValue $_ "models")
    }
  }

  return [pscustomobject]@{
    fetchedAt = Format-LocalStamp (Get-Date)
    path = $Path
    groupBy = First-NonEmpty (Get-PropertyValue $Json "group_by") "day"
    rows = @($rows)
    modelBreakdown = @($modelTotals.Values | Sort-Object { -1 * (ConvertTo-Number $_.turns) }, { $_.name })
    surfaceBreakdown = @($surfaceTotals.Values | Sort-Object { -1 * (ConvertTo-Number $_.turns) }, { $_.name })
    totals = [pscustomobject]$summary
    error = $null
  }
}

function Get-LiveAccountSnapshot {
  $active = Get-ActiveCodexAuth
  $usage = Convert-UsageStatus (ConvertFrom-JsonWithStringDates (Invoke-CodexProxy "/backend-api/wham/usage"))
  $profile = Convert-ProfileStats (ConvertFrom-JsonWithStringDates (Invoke-CodexProxy "/backend-api/wham/profiles/me"))
  $resetCredits = Convert-ResetCredits (ConvertFrom-JsonWithStringDates (Invoke-CodexProxy "/backend-api/wham/rate-limit-reset-credits"))
  $analytics = Get-CodexAnalyticsUsage 30 "day"

  $record = [pscustomobject]@{
    email = $active.email
    name = First-NonEmpty $active.name $profile.displayName
    plan = $active.plan
    accountId = $active.accountId
    tokenSource = "~/.codex/auth.json"
    dataSource = "live local proxy"
    isLive = $true
    lastPolledAt = Format-LocalStamp (Get-Date)
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

  $record | Add-Member -MemberType NoteProperty -Name "history" -Value (Update-AccountHistory $record $analytics) -Force

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

function Get-HistoryPath {
  param([Parameter(Mandatory = $true)]$Account)

  $historyDir = Join-Path $CacheDir "history"
  New-Item -ItemType Directory -Force -Path $historyDir | Out-Null
  $identity = First-NonEmpty $Account.email $Account.name $Account.accountId
  $shortId = $Account.accountId.Substring(0, [Math]::Min(8, $Account.accountId.Length))
  return Join-Path $historyDir ("$(New-SafeFileStem "$identity-$shortId").history.json")
}

function Convert-HistoryStampToDateTime {
  param([Parameter(Mandatory = $false)]$Value)

  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return $null
  }

  $text = ([string]$Value).Replace((" {0} " -f [char]0x2022), " ")
  $styles = [Globalization.DateTimeStyles]::AssumeLocal
  $parsed = [DateTime]::MinValue
  if ([DateTime]::TryParseExact($text, "yyyy-MM-dd HH:mm:ss", [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
    return $parsed
  }

  if ([DateTime]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
    return $parsed
  }

  return $null
}

function Convert-SamplesToSessions {
  param([Parameter(Mandatory = $true)]$Samples)

  $sessions = @()
  $current = $null
  $idleLimitMinutes = 5
  $orderedSamples = @($Samples | Sort-Object { Convert-HistoryStampToDateTime (Get-PropertyValue $_ "at") })
  for ($i = 1; $i -lt $orderedSamples.Count; $i++) {
    $previous = $orderedSamples[$i - 1]
    $sample = $orderedSamples[$i]
    $previousAt = Convert-HistoryStampToDateTime (Get-PropertyValue $previous "at")
    $sampleAt = Convert-HistoryStampToDateTime (Get-PropertyValue $sample "at")
    if ($null -eq $previousAt -or $null -eq $sampleAt) {
      continue
    }

    $minutesSinceLastSample = ($sampleAt - $previousAt).TotalMinutes
    $tokenDelta = [int64](First-NonEmpty (Get-PropertyValue $sample "lifetimeTokens") 0) - [int64](First-NonEmpty (Get-PropertyValue $previous "lifetimeTokens") 0)
    $threadDelta = [int64](First-NonEmpty (Get-PropertyValue $sample "totalThreads") 0) - [int64](First-NonEmpty (Get-PropertyValue $previous "totalThreads") 0)
    $primaryDelta = [double](First-NonEmpty (Get-PropertyValue $sample "primaryUsedPercent") 0) - [double](First-NonEmpty (Get-PropertyValue $previous "primaryUsedPercent") 0)
    $secondaryDelta = [double](First-NonEmpty (Get-PropertyValue $sample "secondaryUsedPercent") 0) - [double](First-NonEmpty (Get-PropertyValue $previous "secondaryUsedPercent") 0)
    $usageReduced = $tokenDelta -lt 0 -or $threadDelta -lt 0 -or $primaryDelta -lt 0 -or $secondaryDelta -lt 0
    $hasWork = -not $usageReduced -and ($tokenDelta -gt 0 -or $threadDelta -gt 0 -or $primaryDelta -gt 0 -or $secondaryDelta -gt 0)

    if ($usageReduced -or $minutesSinceLastSample -gt $idleLimitMinutes) {
      if ($null -ne $current) {
        $sessions += [pscustomobject]$current
        $current = $null
      }
      continue
    }

    if (-not $hasWork) {
      continue
    }

    if ($null -eq $current) {
      $current = [ordered]@{
        start = Get-PropertyValue $previous "at"
        end = Get-PropertyValue $sample "at"
        tokensUsed = 0
        threadDelta = 0
        primaryUsedPercentStart = Get-PropertyValue $previous "primaryUsedPercent"
        primaryUsedPercentEnd = Get-PropertyValue $sample "primaryUsedPercent"
        secondaryUsedPercentStart = Get-PropertyValue $previous "secondaryUsedPercent"
        secondaryUsedPercentEnd = Get-PropertyValue $sample "secondaryUsedPercent"
        resetCreditsStart = Get-PropertyValue $previous "availableResetCredits"
        resetCreditsEnd = Get-PropertyValue $sample "availableResetCredits"
        model = First-NonEmpty (Get-PropertyValue $sample "model") "Unknown"
        surface = First-NonEmpty (Get-PropertyValue $sample "surface") "Local proxy"
        reasoning = Get-PropertyValue $sample "mostUsedReasoningEffort"
        sampleCount = 1
      }
    }

    $current.end = Get-PropertyValue $sample "at"
    $current.tokensUsed += [Math]::Max(0, $tokenDelta)
    $current.threadDelta += [Math]::Max(0, $threadDelta)
    $current.primaryUsedPercentEnd = Get-PropertyValue $sample "primaryUsedPercent"
    $current.secondaryUsedPercentEnd = Get-PropertyValue $sample "secondaryUsedPercent"
    $current.resetCreditsEnd = Get-PropertyValue $sample "availableResetCredits"
    $current.reasoning = First-NonEmpty (Get-PropertyValue $sample "mostUsedReasoningEffort") $current.reasoning
    $current.sampleCount += 1
  }

  if ($null -ne $current) {
    $sessions += [pscustomobject]$current
  }

  return @($sessions)
}

function Update-AccountHistory {
  param(
    [Parameter(Mandatory = $true)]$Account,
    [Parameter(Mandatory = $false)]$Analytics
  )

  $historyPath = Get-HistoryPath $Account
  $history = $null
  if (Test-Path -LiteralPath $historyPath) {
    try {
      $history = ConvertFrom-JsonWithStringDates (Get-Content -LiteralPath $historyPath -Raw)
    } catch {
      $history = $null
    }
  }

  if ($null -eq $history) {
    $history = [pscustomobject]@{
      accountId = $Account.accountId
      email = $Account.email
      createdAt = Format-LocalStamp (Get-Date)
      updatedAt = $null
      samples = @()
      sessions = @()
      analytics = $null
    }
  }

  $primary = @($Account.usageStatus.windows | Where-Object { $_.kind -eq "primary" } | Select-Object -First 1)
  $secondary = @($Account.usageStatus.windows | Where-Object { $_.kind -eq "secondary" } | Select-Object -First 1)
  $sample = [pscustomobject]@{
    at = $Account.lastPolledAt
    availableResetCredits = $Account.availableCount
    lifetimeTokens = $Account.profileStats.lifetimeTokens
    totalThreads = $Account.profileStats.totalThreads
    primaryUsedPercent = if ($primary.Count) { $primary[0].usedPercent } else { $null }
    secondaryUsedPercent = if ($secondary.Count) { $secondary[0].usedPercent } else { $null }
    primaryResetAt = if ($primary.Count) { $primary[0].resetAt } else { $null }
    secondaryResetAt = if ($secondary.Count) { $secondary[0].resetAt } else { $null }
    mostUsedReasoningEffort = $Account.profileStats.mostUsedReasoningEffort
    surface = "Local proxy"
    model = "Unknown"
  }

  $samples = @($history.samples)
  $last = if ($samples.Count -gt 0) { $samples[-1] } else { $null }
  if ($null -eq $last -or $last.at -ne $sample.at) {
    $samples += $sample
  }

  $sessions = Convert-SamplesToSessions $samples

  $maxSamples = 2000
  $maxSessions = 1000
  $history.accountId = $Account.accountId
  $history.email = $Account.email
  $history.updatedAt = $sample.at
  $history.samples = @($samples | Select-Object -Last $maxSamples)
  $history.sessions = @($sessions | Select-Object -Last $maxSessions)
  if ($null -ne $Analytics -and $null -eq (Get-PropertyValue $Analytics "error")) {
    $history | Add-Member -MemberType NoteProperty -Name "analytics" -Value $Analytics -Force
    $history | Add-Member -MemberType NoteProperty -Name "dailyUsageBuckets" -Value @($Analytics.rows) -Force
    $history | Add-Member -MemberType NoteProperty -Name "modelBreakdown" -Value @($Analytics.modelBreakdown) -Force
    $history | Add-Member -MemberType NoteProperty -Name "surfaceBreakdown" -Value @($Analytics.surfaceBreakdown) -Force
  } else {
    $existingAnalytics = Get-PropertyValue $history "analytics"
    if ($null -ne $existingAnalytics) {
      $history | Add-Member -MemberType NoteProperty -Name "analytics" -Value $existingAnalytics -Force
      $history | Add-Member -MemberType NoteProperty -Name "dailyUsageBuckets" -Value @($existingAnalytics.rows) -Force
      $history | Add-Member -MemberType NoteProperty -Name "modelBreakdown" -Value @($existingAnalytics.modelBreakdown) -Force
      $history | Add-Member -MemberType NoteProperty -Name "surfaceBreakdown" -Value @($existingAnalytics.surfaceBreakdown) -Force
    } else {
      $history | Add-Member -MemberType NoteProperty -Name "dailyUsageBuckets" -Value $Account.profileStats.dailyUsageBuckets -Force
      $history | Add-Member -MemberType NoteProperty -Name "modelBreakdown" -Value @() -Force
      $history | Add-Member -MemberType NoteProperty -Name "surfaceBreakdown" -Value @([pscustomobject]@{ name = "Local proxy"; tokens = 0; turns = @($history.sessions).Count }) -Force
    }
  }

  Write-JsonFile $history $historyPath
  return $history
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
        $historyPath = Get-HistoryPath $cached
        if (Test-Path -LiteralPath $historyPath) {
          $cached | Add-Member -MemberType NoteProperty -Name "history" -Value (ConvertFrom-JsonWithStringDates (Get-Content -LiteralPath $historyPath -Raw)) -Force
        }
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
    generatedAt = Format-LocalStamp (Get-Date)
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
try {
  Add-Type -TypeDefinition @"
using System;

public static class CodexResetsCtrlC
{
    public static void Handler(object sender, ConsoleCancelEventArgs e)
    {
        try { Console.WriteLine("Abort requested, exiting."); } catch {}
        Environment.Exit(130);
    }
}
"@
} catch {}
$cancelHandler = [ConsoleCancelEventHandler][CodexResetsCtrlC]::Handler
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
      $pathAndQuery = $context.Request.Url.PathAndQuery
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
        Write-Response $context 200 "application/json; charset=utf-8" (Invoke-CodexProxy $pathAndQuery)
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
  try { [Console]::remove_CancelKeyPress($cancelHandler) } catch {}
  if ($listener.IsListening) {
    $listener.Stop()
  }
  $listener.Close()
  if ($script:Stopping) {
    Write-Host "Codex Resets server stopped."
  }
}
