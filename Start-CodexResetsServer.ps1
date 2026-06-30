[CmdletBinding()]
param(
  [int]$Port = 8787,
  [string]$AuthPath = (Join-Path $HOME ".codex\auth.json"),
  [string]$Root = $PSScriptRoot
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
  }
}

function Write-Response {
  param(
    [Parameter(Mandatory = $true)]$Context,
    [int]$StatusCode = 200,
    [string]$ContentType = "application/json; charset=utf-8",
    [string]$Body = ""
  )

  $response = $Context.Response
  $response.StatusCode = $StatusCode
  $response.ContentType = $ContentType
  $response.Headers["Access-Control-Allow-Origin"] = "*"
  $response.Headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
  $response.Headers["Access-Control-Allow-Headers"] = "Accept, Content-Type"
  $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
  $response.ContentLength64 = $bytes.Length
  $response.OutputStream.Write($bytes, 0, $bytes.Length)
  $response.OutputStream.Close()
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

$listener = [Net.HttpListener]::new()
$prefix = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()

Write-Host "Codex Resets server running at $prefix"
Write-Host "Open ${prefix}index.html"
Write-Host "Press Ctrl+C to stop."

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
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

        Write-Response $context 200 "text/html; charset=utf-8" (Get-Content -LiteralPath $indexPath -Raw)
        continue
      }

      if ($path -like "/backend-api/wham/*") {
        Write-Response $context 200 "application/json; charset=utf-8" (Invoke-CodexProxy $path)
        continue
      }

      Write-JsonError $context 404 "Unknown path: $path"
    } catch {
      Write-JsonError $context 500 $_.Exception.Message
    }
  }
} finally {
  if ($listener.IsListening) {
    $listener.Stop()
  }
  $listener.Close()
}
