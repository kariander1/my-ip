<#
.SYNOPSIS
  Publishes this network's public IP to ip.txt in a GitHub repo (only when it changes).

.DESCRIPTION
  Standalone: Windows PowerShell 5.1+, no git needed. Uses the GitHub REST API with a
  fine-grained token stored encrypted for the current Windows user (DPAPI).

  One-time setup (PowerShell, in the folder with this script):
    1. Create a token: GitHub > Settings > Developer settings > Fine-grained tokens
         Repository access: only kariander1/my-ip
         Permissions: Contents = Read and write
    2. .\update-ip.ps1 -SetToken      # paste the token; saved encrypted
    3. .\update-ip.ps1                # test run, see output
    4. .\update-ip.ps1 -Install       # run every 15 min + at logon (Task Scheduler)

  Uninstall: .\update-ip.ps1 -Uninstall
  If scripts are blocked: powershell -ExecutionPolicy Bypass -File .\update-ip.ps1 ...
#>
param(
    [string]$Owner = "kariander1",
    [string]$Repo = "my-ip",
    [string]$FilePath = "ip.txt",
    [string]$Branch = "main",
    [int]$EveryMinutes = 15,
    [switch]$SetToken,
    [switch]$Install,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Dir = Join-Path $env:LOCALAPPDATA "my-ip"
$TokenFile = Join-Path $Dir "token.xml"
$LogFile = Join-Path $Dir "log.txt"
$TaskName = "Publish public IP to GitHub"
New-Item -ItemType Directory -Force -Path $Dir | Out-Null

function Log($msg) {
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
    # keep the log small
    $lines = Get-Content $LogFile
    if ($lines.Count -gt 500) { $lines | Select-Object -Last 300 | Set-Content $LogFile }
}

if ($SetToken) {
    $secure = Read-Host "Paste GitHub fine-grained token" -AsSecureString
    $secure | Export-Clixml -Path $TokenFile   # encrypted with DPAPI, readable only by you on this PC
    Write-Host "Token saved to $TokenFile"
    exit 0
}

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Scheduled task removed. (Token still at $TokenFile - delete it if you want.)"
    exit 0
}

if ($Install) {
    $script = $MyInvocation.MyCommand.Path
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
    $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($repeat, $logon) `
        -Settings $settings -Description "Updates $Owner/$Repo/$FilePath with this network's public IP" -Force | Out-Null
    Write-Host "Installed: runs every $EveryMinutes min and at logon (while you're logged in)."
    exit 0
}

# --- main: get IP, compare, update ---------------------------------------
if (-not (Test-Path $TokenFile)) { Log "No token. Run: .\update-ip.ps1 -SetToken"; exit 1 }
$token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR((Import-Clixml $TokenFile)))

$ip = $null
foreach ($svc in "https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com") {
    try {
        $candidate = (Invoke-RestMethod -Uri $svc -TimeoutSec 10).ToString().Trim()
        if ($candidate -match '^\d{1,3}(\.\d{1,3}){3}$' -or $candidate -match '^[0-9a-fA-F:]+:[0-9a-fA-F:]+$') { $ip = $candidate; break }
    } catch { }
}
if (-not $ip) { Log "Could not determine public IP (offline?)"; exit 1 }

$headers = @{
    Authorization          = "Bearer $token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "my-ip-updater"
}
$url = "https://api.github.com/repos/$Owner/$Repo/contents/$FilePath"

$sha = $null
try {
    $current = Invoke-RestMethod -Uri "$url`?ref=$Branch" -Headers $headers
    $sha = $current.sha
    $old = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($current.content -replace '\s', '')))
    if ((($old -split "`n")[0]).Trim() -eq $ip) { Log "Unchanged: $ip"; exit 0 }
} catch {
    if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { $sha = $null }  # first run
    else { Log "GitHub read failed: $($_.Exception.Message)"; exit 1 }
}

$stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$body = @{
    message = "Update IP"
    content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$ip`n$stamp`n"))
    branch  = $Branch
    # keep commits on your GitHub no-reply identity (not your real email)
    committer = @{ name = $Owner; email = "34168638+kariander1@users.noreply.github.com" }
}
if ($sha) { $body.sha = $sha }

try {
    Invoke-RestMethod -Method Put -Uri $url -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json" | Out-Null
    Log "Updated: $ip"
} catch {
    Log "GitHub write failed: $($_.Exception.Message)"; exit 1
}
