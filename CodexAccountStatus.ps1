[CmdletBinding()]
param(
  [int]$Port = 8787,
  [string]$AuthPath = (Join-Path $HOME ".codex\auth.json"),
  [string]$Root,
  [string]$CacheDir,
  [switch]$Update,
  [switch]$SkipBrowser,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$RemainingArgs
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


function Write-Utf8NoBomFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Value
  )

  [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
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
      return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} \u2022 ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
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
            <div class="limit-value">${remaining}% left <span class="separator">&#8226;</span> <span class="used">${used}% used</span> <span>(resets ${escapeHtml(window.resetAt || "")})</span></div>
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
      return `${Number(start).toFixed(0)}% \u2192 ${Number(end).toFixed(0)}% (${sign}${delta.toFixed(0)})`;
    }

    function sessionRange(session) {
      const start = String(session.start || "");
      const end = String(session.end || "");
      if (!start && !end) return "--";
      const endTime = end.includes(" \u2022 ") ? end.split(" \u2022 ").pop() : end;
      return `${start || "--"} \u2192 ${endTime || "--"}`;
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
              pending: Boolean(model.pending),
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
      if (estimate?.tokens > 0) return `\u2248${compactNumber(estimate.tokens)}`;
      return sessionUsageMoved(session) ? "\u22480" : "0";
    }

    function sessionThreads(session, estimates) {
      const threads = Number(session.threadDelta || 0);
      if (threads > 0) return integer(threads);
      const estimate = estimates?.get(sessionKey(session));
      if (estimate?.threads > 0) return `\u2248${number(estimate.threads, 1)}`;
      if (estimate?.turns > 0) return `\u2248${number(estimate.turns, 1)} turns`;
      return sessionUsageMoved(session) ? "\u22480" : "0";
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
        .map((model) => {
          const label = model.model || "Estimated";
          const percent = Math.round((Number(model.turns || 0) / totalTurns) * 100);
          return percent === 100 ? label : `${label} ${percent}%`;
        })
        .join(" / ");
    }

    function sessionCreditDelta(session) {
      if (session.resetCreditsStart == null || session.resetCreditsEnd == null) return "--";
      const start = Number(session.resetCreditsStart);
      const end = Number(session.resetCreditsEnd);
      if (!Number.isFinite(start) || !Number.isFinite(end)) return "--";
      const delta = end - start;
      const sign = delta > 0 ? "+" : "";
      return `${start} \u2192 ${end} (${sign}${delta})`;
    }

    function parseLocalStamp(value) {
      if (!value) return null;
      const normalized = String(value).replace(" \u2022 ", "T");
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
  Write-Utf8NoBomFile -Path $OutputPath -Value $html
}


function Test-DashboardCachePresent {
  return [bool]@(Get-ChildItem -LiteralPath $CacheDir -Filter "*.snapshot.json" -File -ErrorAction SilentlyContinue).Count
}

function Update-CodexAccountStatusDashboard {
  param([switch]$ForceLiveRefresh)

  New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $CacheDir "history") | Out-Null

  if ($ForceLiveRefresh -or -not (Test-DashboardCachePresent)) {
    try {
      Write-Host "Refreshing live Codex account data..."
      Get-LiveAccountSnapshot | Out-Null
    } catch {
      Write-Warning "Could not refresh live account data: $($_.Exception.Message)"
    }
  }

  $indexPath = Join-Path $Root "index.html"
  Write-CodexDashboardHtml (Get-CachedDashboardSnapshot) (Get-LiveAuthPayload) $indexPath
  Write-Host "Wrote $indexPath"
}

function Start-CodexAccountStatusBrowser {
  param([Parameter(Mandatory = $true)][string]$Url)

  try {
    Start-Process $Url -WindowStyle Hidden | Out-Null
  } catch {
    Write-Warning "Could not open default browser for $Url`: $($_.Exception.Message)"
  }
}

foreach ($arg in @($RemainingArgs)) {
  if ([string]::IsNullOrWhiteSpace($arg)) {
    continue
  }
  switch -Regex ($arg) {
    default { throw "Unknown argument: $arg" }
  }
}

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

Update-CodexAccountStatusDashboard -ForceLiveRefresh:$Update
if ($Update) {
  return
}

$listener = [Net.HttpListener]::new()
$prefix = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()
$script:Stopping = $false
$cancelHandler = $null
try {
  Add-Type -TypeDefinition @"
using System;

public static class CodexAccountStatusCtrlC
{
    public static void Handler(object sender, ConsoleCancelEventArgs e)
    {
        try { Console.WriteLine("Abort requested, exiting."); } catch {}
        Environment.Exit(130);
    }
}
"@
  $cancelHandler = [ConsoleCancelEventHandler][CodexAccountStatusCtrlC]::Handler
  [Console]::add_CancelKeyPress($cancelHandler)
} catch {}

Write-Host "Codex Resets server running at $prefix"
Write-Host "Open ${prefix}index.html"
Write-Host "Press Ctrl+C to stop."

if (-not $SkipBrowser) {
  Start-CodexAccountStatusBrowser "${prefix}index.html"
}

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
          Update-CodexAccountStatusDashboard
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
  if ($null -ne $cancelHandler) {
    try { [Console]::remove_CancelKeyPress($cancelHandler) } catch {}
  }
  if ($listener.IsListening) {
    $listener.Stop()
  }
  $listener.Close()
  if ($script:Stopping) {
    Write-Host "Codex Resets server stopped."
  }
}
