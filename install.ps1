<#
  install.ps1 — Windows installer for muse-bridge (Windows 10/11).
  The Windows equivalent of install.sh.

  Run as Administrator (it self-elevates if you forget):
    powershell -ExecutionPolicy Bypass -File install.ps1

  What it does:
    - finds Python 3 (or installs it via winget)
    - installs the bridge to C:\muse-bridge (+ queue dir)
    - sets BRIDGE_QUEUE persistently (User env var)
    - generates the user + worker API keys (printed once)
    - installs cloudflared (via winget) for the quick public tunnel
    - registers a Scheduled Task "muse-bridge" (starts at logon, auto-restart)
#>
#Requires -Version 5.1
$ErrorActionPreference = "Stop"

# --- self-elevate -----------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal]`
  [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host "[install] re-launching as Administrator..."
  Start-Process powershell.exe -Verb RunAs -ArgumentList `
    "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
  exit
}

# --- python ------------------------------------------------------------------
function Find-PythonExe {
  # returns the exe path of a working console python, or $null
  foreach ($name in @("python.exe", "py.exe")) {
    $p = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $p) { continue }
    $pre = @()
    if ($name -eq "py.exe") { $pre = @("-3") }
    $ver = & $p.Source @pre --version 2>&1
    if ($LASTEXITCODE -eq 0 -and "$ver" -match "Python 3") {
      return @{ Exe = $p.Source; PreArgs = $pre }
    }
  }
  return $null
}

$python = Find-PythonExe
if (-not $python) {
  Write-Host "[install] Python 3 not found — trying winget..."
  if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
    winget install -e --id Python.Python.3 `
      --accept-package-agreements --accept-source-agreements
    # refresh PATH for this session
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + `
                [Environment]::GetEnvironmentVariable("Path", "User")
    $python = Find-PythonExe
  }
}
if (-not $python) {
  Write-Error "[install] Python 3 is required: install it from python.org (tick 'Add python.exe to PATH'), then re-run install.ps1."
  exit 1
}
# prefer pythonw (no console window) for the background task
$taskExe = (Get-Command pythonw.exe -ErrorAction SilentlyContinue).Source
if (-not $taskExe) { $taskExe = $python.Exe }
Write-Host "[install] python: $($python.Exe)"

# --- files -------------------------------------------------------------------
$DEST  = "C:\muse-bridge"
$QUEUE = Join-Path $DEST "queue"
$SRC   = Split-Path -Parent $PSCommandPath
New-Item -ItemType Directory -Force -Path $QUEUE | Out-Null
Copy-Item (Join-Path $SRC "bridge.py")         $DEST -Force
Copy-Item (Join-Path $SRC "worker_example.py") $DEST -Force

# persist BRIDGE_QUEUE for the user (scheduled task + future terminals see it)
[Environment]::SetEnvironmentVariable("BRIDGE_QUEUE", $QUEUE, "User")
$env:BRIDGE_QUEUE = $QUEUE

# --- keys --------------------------------------------------------------------
$bridge = Join-Path $DEST "bridge.py"
if (-not (Test-Path (Join-Path $DEST "keys.json"))) {
  Write-Host "[install] generating API keys (shown once — save them now)..."
  Write-Host "--- user key (for 9Router / OpenAI clients) ---"
  & $python.Exe @($python.PreArgs) $bridge keygen --role user --label 9router
  Write-Host "--- worker key (for your worker) ---"
  & $python.Exe @($python.PreArgs) $bridge keygen --role worker --label worker-1
  Write-Host "--- copy both keys somewhere safe before continuing ---"
} else {
  Write-Host "[install] keys.json already exists — keeping existing keys"
}

# --- cloudflared (quick public tunnel) -----------------------------------------
if (-not (Get-Command cloudflared.exe -ErrorAction SilentlyContinue)) {
  Write-Host "[install] installing cloudflared via winget..."
  if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
    winget install -e --id Cloudflare.cloudflared `
      --accept-package-agreements --accept-source-agreements
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + `
                [Environment]::GetEnvironmentVariable("Path", "User")
  } else {
    Write-Host "[install] winget not found — install cloudflared manually (see README)"
  }
}

# --- scheduled task (the Windows answer to systemd) ---------------------------
$taskArgs = (($python.PreArgs + @($bridge)) -join " ")
$action   = New-ScheduledTaskAction -Execute $taskExe -Argument $taskArgs `
              -WorkingDirectory $DEST
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
              -DontStopIfGoingOnBatteries -StartWhenAvailable `
              -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName "muse-bridge" -Action $action `
  -Trigger $trigger -Settings $settings `
  -Description "muse-bridge OpenAI-compatible server (127.0.0.1:8765)" -Force | Out-Null
Start-ScheduledTask -TaskName "muse-bridge"
Write-Host "[install] scheduled task 'muse-bridge' registered and started"

# --- health check --------------------------------------------------------------
Write-Host "[install] health check:"
$ok = $false
for ($i = 0; $i -lt 10; $i++) {
  Start-Sleep -Seconds 1
  try {
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:8765/health" -TimeoutSec 3
    if ($r.ok) { $ok = $true; break }
  } catch { }
}
if ($ok) { Write-Host '{"ok": true}' }
else {
  Write-Host "[install] not responding yet — it will retry at logon; check Task Scheduler > muse-bridge"
}

Write-Host ""
Write-Host "[install] done. Expose the bridge with cloudflared (already installed):"
Write-Host "  cloudflared tunnel --url http://127.0.0.1:8765"
Write-Host "Then run a worker: see README.md (worker_example.py)."
