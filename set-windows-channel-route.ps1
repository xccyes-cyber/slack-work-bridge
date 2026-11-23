param(
    [Parameter(Mandatory)][ValidatePattern('^[CG][A-Z0-9]+$')][string]$ChannelId,
    [Parameter(Mandatory)][ValidatePattern('^[\p{L}\p{N}_-]{1,40}$')][string]$Label,
    [switch]$DisableLegacyChannel
)
$ErrorActionPreference = 'Stop'
$settings = Join-Path $env:LOCALAPPDATA 'SlackWorkBridge\bridge.json'
$config = Get-Content -LiteralPath $settings -Raw -Encoding UTF8 | ConvertFrom-Json
$route = $config.routes.PSObject.Properties | Where-Object { $_.Name -ceq $Label }
if (-not $route -or -not $route.Value) { throw "No configured Work route for [$Label]." }
if (-not $config.channelRoutes) {
    $config | Add-Member -NotePropertyName channelRoutes -NotePropertyValue ([pscustomobject]@{}) -Force
}
$existing = $config.channelRoutes.PSObject.Properties[$ChannelId]
if ($existing -and $existing.Value -cne $Label) {
    throw "This Slack channel is already assigned to [$($existing.Value)]."
}
$config.channelRoutes | Add-Member -NotePropertyName $ChannelId -NotePropertyValue $Label -Force
if ($DisableLegacyChannel) { $config.PSObject.Properties.Remove('channel') }
$temp = "$settings.$([guid]::NewGuid()).tmp"
$backup = "$temp.bak"
try {
    [IO.File]::WriteAllText($temp, ($config | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    [IO.File]::Replace($temp, $settings, $backup)
    Remove-Item -LiteralPath $backup -ErrorAction SilentlyContinue
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp }
}
Write-Host "Mapped Slack channel $ChannelId to [$Label]."
