param(
    [string]$Platform = 'desktop'
)

$ErrorActionPreference = 'Stop'

if (-not $env:TELEGRAM_BOT_TOKEN) {
    throw 'TELEGRAM_BOT_TOKEN is required'
}

if (-not $env:TELEGRAM_CHAT_ID) {
    throw 'TELEGRAM_CHAT_ID is required'
}

$version = 'unknown'
if (Test-Path 'pubspec.yaml') {
    $versionLine = Select-String -Path 'pubspec.yaml' -Pattern '^version:\s+(.+)$' | Select-Object -First 1
    if ($versionLine) {
        $version = $versionLine.Matches[0].Groups[1].Value.Trim()
    }
}

$status = if ($env:CM_BUILD_STATUS) { $env:CM_BUILD_STATUS } elseif ($env:CM_BUILD_STEP_STATUS) { $env:CM_BUILD_STEP_STATUS } else { 'finished' }
$workflow = if ($env:CM_WORKFLOW_NAME) { $env:CM_WORKFLOW_NAME } elseif ($env:CM_WORKFLOW_ID) { $env:CM_WORKFLOW_ID } else { 'unknown' }
$branch = if ($env:CM_BRANCH) { $env:CM_BRANCH } else { 'unknown' }
$commit = if ($env:CM_COMMIT) { $env:CM_COMMIT } else { 'unknown' }
$shortCommit = if ($commit.Length -gt 8) { $commit.Substring(0, 8) } else { $commit }
$buildId = if ($env:CM_BUILD_ID) { $env:CM_BUILD_ID } else { 'unknown' }

$message = @"
ChessEver desktop $Platform release $status
Version: $version
Workflow: $workflow
Branch: $branch
Commit: $shortCommit
Build: $buildId
"@

$payload = @{
    chat_id = $env:TELEGRAM_CHAT_ID
    text = $message
    link_preview_options = @{
        is_disabled = $true
    }
} | ConvertTo-Json -Depth 4

Invoke-RestMethod `
    -Method Post `
    -Uri "https://api.telegram.org/bot$($env:TELEGRAM_BOT_TOKEN)/sendMessage" `
    -ContentType 'application/json; charset=utf-8' `
    -Body $payload | Out-Null

Write-Host 'Telegram notification sent'
