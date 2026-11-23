$ErrorActionPreference = 'Stop'
$name = 'SlackWorkBridge'
$dir = Join-Path $env:LOCALAPPDATA $name
$source = Join-Path $PSScriptRoot 'bridge.mjs'
$installed = Join-Path $dir 'bridge.mjs'
$backup = Join-Path $dir "bridge.$([guid]::NewGuid()).bak"
$config = Join-Path $dir 'bridge.json'
$node = (Get-Command node.exe -ErrorAction Stop).Source
$task = Get-ScheduledTask -TaskName $name
if ($task.State -eq 'Disabled') { throw 'The receiver task is disabled. Enable it explicitly before updating.' }
& $node $source $config --check-config
if ($LASTEXITCODE -ne 0) { throw 'The installed receiver configuration did not pass validation.' }
if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName $name }
Copy-Item -LiteralPath $installed -Destination $backup
try {
    Copy-Item -LiteralPath $source -Destination $installed -Force
    Start-ScheduledTask -TaskName $name
} catch {
    Copy-Item -LiteralPath $backup -Destination $installed -Force
    Start-ScheduledTask -TaskName $name
    throw
}
Write-Host "Receiver updated. Verify $dir\status.json and test an actual Work message."
