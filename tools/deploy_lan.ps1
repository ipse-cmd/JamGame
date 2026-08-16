# deploy_lan.ps1 — export a real Windows build and push it to the LAN test PC.
# This tests "a game" every time: the packed artifact (exe + pck + native DLL),
# not source-in-editor. Usage:
#   .\tools\deploy_lan.ps1              # export + copy to remote
#   .\tools\deploy_lan.ps1 -Bot        # ...then launch a headless bass bot that
#                                       # joins this machine (host locally first!)
param(
    [switch]$Bot,
    [string]$RemoteHost = "192.168.1.105",
    [string]$RemoteUser = "ipse",
    [string]$RemoteDir = "C:/Users/ipse/JamGame_build",
    [string]$HostIp = "192.168.1.167"
)

$ErrorActionPreference = "Stop"
$proj = Split-Path $PSScriptRoot -Parent
$godot = "C:\Godot\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe"
$key = "$env:USERPROFILE\.ssh\id_ed25519_zforce"
$ssh = "$RemoteUser@$RemoteHost"

Write-Host "== Exporting Windows build =="
& $godot --headless --path $proj --export-release "Windows Desktop" "build/JamGame.exe"
if ($LASTEXITCODE -ne 0) { throw "Export failed ($LASTEXITCODE)" }
Get-ChildItem "$proj\build" | Format-Table Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } } -AutoSize

Write-Host "== Copying to $ssh`:$RemoteDir =="
ssh -i $key -o BatchMode=yes $ssh "if not exist $($RemoteDir.Replace('/','\')) mkdir $($RemoteDir.Replace('/','\'))"
scp -i $key "$proj\build\*" "$ssh`:$RemoteDir/"

if ($Bot) {
    Write-Host "== Launching remote bot (joins $HostIp — make sure you are hosting) =="
    ssh -i $key -o BatchMode=yes $ssh "$($RemoteDir.Replace('/','\'))\JamGame.console.exe --headless -- --join=$HostIp --bot"
}
