[CmdletBinding(DefaultParameterSetName='Preset')]
param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'SlackWorkBridge\bridge.json'),
    [Parameter(ParameterSetName='Preset', Mandatory)][switch]$UsePresetTitles,
    [Parameter(ParameterSetName='Title', Mandatory)]
    [Parameter(ParameterSetName='Id', Mandatory)][string]$Label,
    [Parameter(ParameterSetName='Title', Mandatory)][string]$Title,
    [Parameter(ParameterSetName='Id', Mandatory)][guid]$SessionId
)
$ErrorActionPreference = 'Stop'
$ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$codexDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
if ($PSCmdlet.ParameterSetName -ne 'Id') {
    $index = Join-Path $codexDir 'session_index.jsonl'
    if (-not (Test-Path -LiteralPath $index -PathType Leaf)) {
        throw 'Local Codex session index not found. Use the session ID from the target chat with -SessionId.'
    }
    $localNames = @{}
    foreach ($line in Get-Content -LiteralPath $index -Encoding UTF8) {
        if (-not $line.Trim()) { continue }
        try { $record = ConvertFrom-Json -InputObject $line -ErrorAction Stop } catch { continue }
        if ($record.id -and $record.thread_name) { $localNames[[string]$record.id] = [string]$record.thread_name }
    }
}

function Resolve-LocalTitle([string]$Name) {
    $matches = @($localNames.Keys | Where-Object { $localNames[$_] -ceq $Name })
    if ($matches.Count -ne 1) { throw "Expected one local session named [$Name], found $($matches.Count). Supply the real session ID with -SessionId." }
    return [guid]$matches[0]
}
function Confirm-LocalSession([guid]$Id) {
    $sessions = Join-Path $codexDir 'sessions'
    $file = Get-ChildItem -LiteralPath $sessions -Recurse -File -Filter "*-$Id.jsonl" -ErrorAction Stop | Select-Object -First 1
    if (-not $file) { throw "Session [$Id] could not be verified in this Windows user's local sessions." }
}
$bound = @()
function Set-Route([string]$Name, [guid]$Id) {
    if ($Name -cnotmatch '^[\p{L}\p{N}_-]{1,40}$') { throw "Invalid route label [$Name]." }
    Confirm-LocalSession $Id
    if (-not $config.routes) { $config | Add-Member -NotePropertyName routes -NotePropertyValue ([pscustomobject]@{}) -Force }
    $config.routes | Add-Member -NotePropertyName $Name -NotePropertyValue ([string]$Id) -Force
    return "Bound $Name to $Id"
}

switch ($PSCmdlet.ParameterSetName) {
    'Preset' {
        $targets = @($config.routeTitles.PSObject.Properties | Where-Object Name)
        if (-not $targets.Count) { throw 'No preset route titles in this configuration.' }
        foreach ($entry in $targets) { $bound += Set-Route $entry.Name (Resolve-LocalTitle $entry.Value) }
    }
    'Title' { $bound += Set-Route $Label (Resolve-LocalTitle $Title) }
    'Id' { $bound += Set-Route $Label $SessionId }
}

$temp = "$ConfigPath.$([guid]::NewGuid()).tmp"
$backup = "$temp.bak"
try {
    $json = $config | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($temp, $json, [Text.UTF8Encoding]::new($false))
    [IO.File]::Replace($temp, $ConfigPath, $backup)
    $bound | Write-Host
    Remove-Item -LiteralPath $backup -ErrorAction SilentlyContinue
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp }
}
