param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$CodexPath = (Get-Command codex.exe -ErrorAction SilentlyContinue).Source,
    [switch]$UsePresetTitles
)
$ErrorActionPreference = 'Stop'
if (-not $CodexPath -or -not (Test-Path -LiteralPath $CodexPath -PathType Leaf)) {
    throw 'Pass the absolute path to an installed codex.exe that supports codex queue.'
}
$CodexPath = (Resolve-Path -LiteralPath $CodexPath).Path
$node = (Get-Command node.exe -ErrorAction Stop).Source
& $node -e 'process.exit(globalThis.WebSocket?0:1)'
if ($LASTEXITCODE -ne 0) { throw 'Install Node.js 22 or newer.' }
& $CodexPath queue --help | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'This Codex CLI does not support queue.' }

$name = 'SlackWorkBridge'
if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
    throw 'The receiver is already installed. Stop and unregister the existing task before reinstalling.'
}
$source = Join-Path $PSScriptRoot 'bridge.mjs'
if ($UsePresetTitles) {
    & (Join-Path $PSScriptRoot 'bind-windows-route.ps1') -ConfigPath $ConfigPath -UsePresetTitles
}
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$config.codex = $CodexPath
$config.credential = [pscustomobject]@{ kind = 'windows-dpapi' }
$dir = Join-Path $env:LOCALAPPDATA $name
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$script = Join-Path $dir 'bridge.mjs'
$settings = Join-Path $dir 'bridge.json'
Copy-Item -LiteralPath $source -Destination $script
$config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $settings -Encoding UTF8
& $node $script $settings --check-config
if ($LASTEXITCODE -ne 0) { throw 'Fill in the workspace, Slack app, channel, allowed senders and at least one real route before installing.' }

$tokenFile = Join-Path $dir 'slack-token.dpapi'
if (-not (Test-Path -LiteralPath $tokenFile)) {
    $secret = Read-Host 'Enter the Windows Slack app-level token (xapp)' -AsSecureString
    if ($secret.Length -eq 0) { throw 'No token entered.' }
    ConvertFrom-SecureString -SecureString $secret | Set-Content -LiteralPath $tokenFile -Encoding ASCII
    $secret.Dispose()
}

$account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$arguments = '"{0}" "{1}"' -f $script, $settings
$action = New-ScheduledTaskAction -Execute $node -Argument $arguments -WorkingDirectory $dir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $account
$principal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Limited
$options = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $options | Out-Null
Start-ScheduledTask -TaskName $name
Write-Host "Started $name. Check $dir\status.json for connected."
