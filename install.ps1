# =============================================================================
# BlockDAG Pool-Stack Installer - Windows
#
# What it does (mirrors install.sh):
#   1.  Repair %ProgramData% env so Docker Desktop launches cleanly
#   2.  Install Docker Desktop via winget if missing
#   3.  Start the engine and verify
#   4.  Check disk space and host ports
#   5.  Download the official BlockDAG pool-stack-docker release tarball,
#       SHA-256 verify, extract
#   6.  (Optional) Download a snapshot for fast bootstrap, SHA verify if known,
#       confirm the binary can read its manifest before committing to a build
#   7.  Prompt for: pool reward wallet, worker name, pool fee, strong RPC creds Y/N,
#       snapshot Y/N - validated, with retries
#   8.  Render .env + node.conf from templates (auto-generates a strong POSTGRES_PASSWORD)
#   9.  docker compose build - auto-retry once with --no-cache if the first attempt
#                              fails on apt-mirror flakiness (Bug 14)
#   10. docker compose up -d, wait for postgres healthcheck
#   11. Add a Windows Defender Firewall rule for inbound Stratum :3334
#   12. Send install-complete notification to dawie@dagminingtrust.com via webhook
#   13. Print a success summary
#
# Usage (right-click the .ps1 -> Run with PowerShell, or):
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
#
# Unattended install via env vars:
#   $env:POOL_WALLET = '0x6387C32ccDD60BfBa00EC70A67715Dcd52E8083f'
#   $env:WORKER_NAME = 'node-3'
#   $env:USE_SNAPSHOT = 'yes'
#   $env:SNAPSHOT_URL = 'https://example.com/latest.bdsnap'
#   $env:NOTIFY_OPT_OUT = 'false'
#   .\install.ps1 -Unattended
# =============================================================================
[CmdletBinding()]
param(
    [string]$ReleaseTag      = 'v1.3.21',
    [string]$ReleaseURLBase  = 'https://bdagstack.bdagdev.xyz',
    [string]$NotifyURL       = 'https://notify.dagminingtrust.com/install-complete',
    [string]$InstallDir      = "$env:USERPROFILE\bdag-pool-stack",
    [string]$InnerPrefix     = 'pool-stack-docker-pool-',
    [switch]$Unattended,
    [switch]$SkipDockerInstall,
    [switch]$NoFirewall
)

$ErrorActionPreference = 'Stop'
if (-not $env:ProgramData)     { $env:ProgramData     = 'C:\ProgramData' }
if (-not $env:ALLUSERSPROFILE) { $env:ALLUSERSPROFILE = 'C:\ProgramData' }

$LogDir = Join-Path $InstallDir 'logs'

# -----------------------------------------------------------------------------
# UI helpers
# -----------------------------------------------------------------------------
function Write-Banner($msg) {
    Write-Host ''
    Write-Host '=================================================================' -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host '=================================================================' -ForegroundColor Cyan
    Write-Host ''
}
function Write-Step($msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "    [OK]  $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    [!]   $msg" -ForegroundColor Yellow }
function Write-Err2($msg)  { Write-Host "    [X]   $msg" -ForegroundColor Red }
function Write-Note($msg)  { Write-Host "         $msg" -ForegroundColor DarkGray }

function Read-WithDefault($prompt, $default) {
    $r = Read-Host "$prompt [$default]"
    if ([string]::IsNullOrWhiteSpace($r)) { $default } else { $r.Trim() }
}
function Read-Validated($prompt, $regex, $default = $null, $maxRetries = 3) {
    for ($i = 1; $i -le $maxRetries; $i++) {
        $val = if ($default) { Read-WithDefault $prompt $default } else { (Read-Host $prompt).Trim() }
        if ($val -match $regex) { return $val }
        Write-Err2 "Value does not match expected pattern (try $i of $maxRetries)."
    }
    throw "Validation failed after $maxRetries attempts"
}
function New-StrongPassword($len = 28) {
    $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
    -join ((1..$len) | ForEach-Object { $chars | Get-Random })
}

# -----------------------------------------------------------------------------
# Prereqs
# -----------------------------------------------------------------------------
function Test-DockerInstalled { try { docker --version | Out-Null; $true } catch { $false } }
function Test-DockerEngineUp  { try { docker info --format '{{.ServerVersion}}' 2>$null | Out-Null; ($LASTEXITCODE -eq 0) } catch { $false } }

function Install-DockerDesktop {
    if ($SkipDockerInstall) { Write-Warn2 'Skipping Docker install (-SkipDockerInstall set).'; return }
    Write-Step 'Installing Docker Desktop via winget'
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget not found. Install Docker Desktop manually from https://www.docker.com/products/docker-desktop/ then re-run."
    }
    winget install --id Docker.DockerDesktop --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget install failed (exit $LASTEXITCODE)" }
    Write-Ok 'Docker Desktop installed. You may need to log out and back in for PATH to update.'
}

function Start-DockerEngine {
    Write-Step 'Starting Docker engine'
    if (Test-DockerEngineUp) { Write-Ok 'Engine already up.'; return }
    $exe = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
    if (-not (Test-Path $exe)) { throw "Docker Desktop not found at $exe" }
    Start-Process $exe -UseNewEnvironment | Out-Null
    Write-Host '    Waiting up to 120 s for engine ' -NoNewline
    for ($i = 0; $i -lt 24; $i++) {
        Start-Sleep -Seconds 5
        Write-Host '.' -NoNewline
        if (Test-DockerEngineUp) { Write-Host ''; Write-Ok 'Engine up.'; return }
    }
    Write-Host ''
    throw 'Docker engine did not come up in 120 s.'
}

function Ensure-Docker {
    Write-Step 'Checking Docker'
    if (-not (Test-DockerInstalled)) {
        Write-Warn2 'Docker not installed. Installing now...'
        Install-DockerDesktop
    }
    Start-DockerEngine
    Write-Ok ("Docker engine: " + (docker --version))
    docker compose version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Docker Compose v2 plugin not available.' }
    Write-Ok ("Docker Compose v2: " + (docker compose version --short))
}

function Test-DiskSpace {
    param([int]$MinGB = 30)
    Write-Step "Checking disk space (need >= $MinGB GB)"
    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null }
    $drive = (Split-Path -Qualifier $InstallDir).TrimEnd(':')
    $vol = Get-Volume -DriveLetter $drive
    $free = [math]::Round($vol.SizeRemaining / 1GB, 1)
    if ($free -lt $MinGB) {
        Write-Warn2 "Only $free GB free on ${drive}: - recommend >= $MinGB GB."
        if (-not $Unattended) {
            $ans = Read-Host '    Continue anyway? (y/N)'
            if ($ans -ne 'y') { throw 'Aborted on insufficient disk.' }
        }
    } else { Write-Ok "Disk: $free GB free." }
}

function Test-PortsAvailable {
    Write-Step 'Checking required host ports'
    $ports = 8150, 38131, 18545, 18546, 6060, 3334, 8080, 9280
    $busy = @()
    foreach ($p in $ports) {
        $conn = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
        if ($conn) { $busy += $p }
    }
    if ($busy.Count -gt 0) {
        Write-Warn2 ("Ports already in use: " + ($busy -join ', '))
        if (-not $Unattended) {
            $ans = Read-Host '    Continue anyway? compose may fail to bind. (y/N)'
            if ($ans -ne 'y') { throw 'Aborted on port conflict.' }
        }
    } else { Write-Ok 'All required ports free.' }
}

function Add-FirewallRule {
    if ($NoFirewall) { return }
    Write-Step 'Adding Windows Defender Firewall rule for inbound Stratum :3334'
    $existing = Get-NetFirewallRule -DisplayName 'BDAG-Pool-Stratum-3334' -ErrorAction SilentlyContinue
    if ($existing) { Write-Ok 'Rule already exists.'; return }
    try {
        New-NetFirewallRule -DisplayName 'BDAG-Pool-Stratum-3334' `
                            -Direction Inbound -Protocol TCP -LocalPort 3334 -Action Allow | Out-Null
        Write-Ok 'Firewall rule added.'
    } catch {
        Write-Warn2 "Could not add firewall rule (need Administrator?): $($_.Exception.Message)"
        Write-Note 'External miners on your LAN/internet will not be able to reach :3334 until this is allowed.'
    }
}

# -----------------------------------------------------------------------------
# Download + verify release tarball
# -----------------------------------------------------------------------------
function Get-Sha256($Path) { (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower() }

function Get-Release {
    Write-Step "Fetching release $ReleaseTag"
    $tarball = "pool-stack-docker-$ReleaseTag.tar.gz"
    $local   = Join-Path $InstallDir $tarball
    if (-not (Test-Path $local)) {
        $url = "$ReleaseURLBase/$tarball"
        Write-Note "Downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $local -UseBasicParsing
    } else { Write-Ok "Tarball already on disk: $local" }

    $checksumsPath = Join-Path $PSScriptRoot 'checksums.json'
    if (Test-Path $checksumsPath) {
        $j = Get-Content $checksumsPath -Raw | ConvertFrom-Json
        $expected = $j.$ReleaseTag.tarball
        if ($expected) {
            $actual = Get-Sha256 $local
            if ($actual -ne $expected) {
                throw "SHA-256 mismatch on $tarball - got $actual, expected $expected"
            }
            Write-Ok 'Tarball SHA-256 verified.'
        } else {
            Write-Warn2 "No published SHA for $ReleaseTag in checksums.json - skipping verify."
        }
    }
    Write-Note 'Extracting...'
    tar -xzf $local -C $InstallDir
    if ($LASTEXITCODE -ne 0) { throw 'tar extract failed' }
    Write-Ok "Extracted to $InstallDir"
}

function Locate-ReleaseRoot {
    $candidate = Get-ChildItem $InstallDir -Directory -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -like "$InnerPrefix$ReleaseTag*" } |
                 Select-Object -First 1
    if (-not $candidate) {
        # Try one level deeper
        $candidate = Get-ChildItem $InstallDir -Directory -Recurse -Depth 1 -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -like "$InnerPrefix$ReleaseTag*" } |
                     Select-Object -First 1
    }
    if (-not $candidate) { throw "Could not locate extracted release dir under $InstallDir" }
    Write-Ok ("Release root: " + $candidate.FullName)
    return $candidate.FullName
}

# -----------------------------------------------------------------------------
# Snapshot handling
# -----------------------------------------------------------------------------
function Stage-Snapshot {
    param([string]$ReleaseRoot, [string]$UseSnapshot, [string]$SnapshotFile, [string]$SnapshotURL)
    if ($UseSnapshot -ne 'yes') {
        Write-Ok 'Skipping snapshot - node will sync from genesis via P2P.'
        return 'docker/no-snapshot.marker'
    }
    Write-Step 'Staging snapshot'
    $target = Join-Path $ReleaseRoot 'latest.bdsnap'
    if ($SnapshotFile -and (Test-Path $SnapshotFile)) {
        Copy-Item -Path $SnapshotFile -Destination $target -Force
        Write-Ok "Copied $SnapshotFile -> $target"
    } elseif ($SnapshotURL) {
        Write-Note "Downloading snapshot from $SnapshotURL"
        Invoke-WebRequest -Uri $SnapshotURL -OutFile $target -UseBasicParsing
    } elseif (Test-Path $target) {
        Write-Ok "Snapshot already in place at $target"
    } else {
        throw 'Snapshot enabled but no SNAPSHOT_FILE or SNAPSHOT_URL provided, and no snapshot found.'
    }
    # Verify the binary can read it before we waste time on a build
    $binDir = Join-Path $ReleaseRoot 'bin'
    $cmd = "cp /bin-host/blockdag-node /tmp/bn && chmod +x /tmp/bn && /tmp/bn snap info --path /snap-host/latest.bdsnap"
    $info = docker run --rm -v "${binDir}:/bin-host:ro" -v "${ReleaseRoot}:/snap-host:ro" ubuntu:24.04 sh -c $cmd 2>&1
    if ($info -match '"format_version"') {
        Write-Ok 'Snapshot manifest readable by shipped blockdag-node binary.'
        return './latest.bdsnap'
    } else {
        Write-Warn2 'Snapshot manifest could NOT be read by the shipped binary - likely format mismatch.'
        Write-Warn2 'Falling back to no-snapshot path. Node will sync from genesis.'
        Remove-Item $target -Force -ErrorAction SilentlyContinue
        return 'docker/no-snapshot.marker'
    }
}

# -----------------------------------------------------------------------------
# Interactive configuration
# -----------------------------------------------------------------------------
function Get-UserConfig {
    Write-Step 'Configuration'
    $cfg = @{}

    $cfg.POOL_WALLET = if ($env:POOL_WALLET) { $env:POOL_WALLET } else {
        Read-Validated 'Pool reward / dashboard wallet (0x + 40 hex)' '^0x[a-fA-F0-9]{40}$'
    }
    $cfg.WORKER_NAME = if ($env:WORKER_NAME) { $env:WORKER_NAME } else {
        Read-Validated 'Worker / node name' '^[A-Za-z0-9_-]{1,32}$' $env:COMPUTERNAME
    }

    $strong = if ($env:STRONG_RPC) { $env:STRONG_RPC } elseif ($Unattended) { 'n' } else {
        Read-WithDefault 'Use strong (non-test/test) RPC creds? y/n' 'n'
    }
    if ($strong -eq 'y' -or $strong -eq 'yes') {
        $cfg.NODE_RPC_USER = Read-Validated 'RPC user (3-32 alphanumeric/underscore)' `
                                            '^[A-Za-z0-9_]{3,32}$' "bdag_$((New-StrongPassword 4).ToLower())"
        $cfg.NODE_RPC_PASS = if ($env:NODE_RPC_PASS) { $env:NODE_RPC_PASS } else { New-StrongPassword 28 }
    } else {
        $cfg.NODE_RPC_USER = 'test'
        $cfg.NODE_RPC_PASS = 'test'
        Write-Warn2 'Using default test/test RPC credentials. Fine for local; rotate before exposing the node to the internet.'
    }

    # PostgreSQL password — strict precedence:
    #   1. $env:POSTGRES_PASSWORD if explicitly set (unattended override)
    #   2. Existing .env in the release dir (preserves password across re-runs
    #      so a re-installed stack can still authenticate to the existing
    #      postgres-data volume)
    #   3. Auto-generate a strong 28-char password
    $existingEnv = Join-Path $releaseRoot '.env'
    $cfg.POSTGRES_PASSWORD = if ($env:POSTGRES_PASSWORD) {
        $env:POSTGRES_PASSWORD
    } elseif (Test-Path $existingEnv) {
        $line = (Get-Content $existingEnv -ErrorAction SilentlyContinue | Select-String '^POSTGRES_PASSWORD=(.*)$' | Select-Object -First 1)
        if ($line -and $line.Matches[0].Groups[1].Value -and $line.Matches[0].Groups[1].Value -ne 'change_me_to_a_strong_secret') {
            Write-Note 'Preserving POSTGRES_PASSWORD from existing .env (so re-installs still authenticate to the existing postgres volume).'
            $line.Matches[0].Groups[1].Value
        } else { New-StrongPassword 28 }
    } else { New-StrongPassword 28 }
    $cfg.POOL_FEE_PERCENTAGE = if ($env:POOL_FEE_PERCENTAGE) {
        # Validate env-var input (fail-fast in unattended mode)
        if ($env:POOL_FEE_PERCENTAGE -match '^[0-9]+(\.[0-9]+)?$' -and ([double]$env:POOL_FEE_PERCENTAGE) -ge 0.0 -and ([double]$env:POOL_FEE_PERCENTAGE) -le 10.0) {
            $env:POOL_FEE_PERCENTAGE
        } else {
            throw "POOL_FEE_PERCENTAGE not in 0.0-10.0: $($env:POOL_FEE_PERCENTAGE)"
        }
    } else {
        # Interactive: validate with retry
        $fee = $null
        for ($i = 1; $i -le 3; $i++) {
            $raw = Read-WithDefault 'Pool fee % (0.0-10.0)' '1.0'
            if ($raw -match '^[0-9]+(\.[0-9]+)?$' -and ([double]$raw) -ge 0.0 -and ([double]$raw) -le 10.0) { $fee = $raw; break }
            Write-Err2 "Fee must be a number between 0.0 and 10.0 (try $i of 3)."
        }
        if (-not $fee) { throw 'Pool fee validation failed.' }
        $fee
    }

    $cfg.USE_SNAPSHOT = if ($env:USE_SNAPSHOT) { $env:USE_SNAPSHOT } else {
        $a = Read-WithDefault 'Use snapshot for fast bootstrap? y/n (downloads ~4 GB)' 'n'
        if ($a -eq 'y') { 'yes' } else { 'no' }
    }
    if ($cfg.USE_SNAPSHOT -eq 'yes' -and -not $env:SNAPSHOT_FILE -and -not $env:SNAPSHOT_URL) {
        $a = Read-WithDefault 'Local snapshot file or URL? f/u' 'u'
        if ($a -eq 'f') {
            $env:SNAPSHOT_FILE = Read-Host '    Path to local .bdsnap'
        } else {
            $env:SNAPSHOT_URL = Read-Host '    Snapshot URL'
        }
    }
    $cfg.SNAPSHOT_FILE = $env:SNAPSHOT_FILE
    $cfg.SNAPSHOT_URL  = $env:SNAPSHOT_URL

    Write-Step 'Summary'
    foreach ($k in 'POOL_WALLET','WORKER_NAME','NODE_RPC_USER','POOL_FEE_PERCENTAGE','USE_SNAPSHOT' | Sort-Object) {
        Write-Host ("    {0,-22} = {1}" -f $k, $cfg.$k)
    }
    Write-Host ("    {0,-22} = <{1} chars>" -f 'NODE_RPC_PASS', $cfg.NODE_RPC_PASS.Length)
    Write-Host ("    {0,-22} = <{1} chars (auto-generated)>" -f 'POSTGRES_PASSWORD', $cfg.POSTGRES_PASSWORD.Length)

    if (-not $Unattended) {
        $ok = Read-Host '    Proceed? (y/N)'
        if ($ok -ne 'y') { throw 'Cancelled at summary.' }
    }
    return $cfg
}

# -----------------------------------------------------------------------------
# Render templates
# -----------------------------------------------------------------------------
function Render-Template {
    param([string]$TemplatePath, [string]$OutPath, [hashtable]$Subs)
    if (-not (Test-Path $TemplatePath)) { throw "Missing template: $TemplatePath" }
    $content = Get-Content $TemplatePath -Raw
    foreach ($k in $Subs.Keys) {
        $content = $content.Replace("{{$k}}", [string]$Subs[$k])
    }
    [IO.File]::WriteAllText($OutPath, $content)
}

# -----------------------------------------------------------------------------
# Build override (Bug 14 workaround)
# -----------------------------------------------------------------------------
function Write-BuildOverride {
    param([string]$ReleaseRoot)
    $content = @"
# Auto-generated by the BlockDAG installer. Forces builds onto the host network
# stack to avoid archive.ubuntu.com / security.ubuntu.com flakiness inside the
# default Docker bridge. Runtime networking is unchanged. Safe to delete after
# the first successful build if you prefer the upstream layout.
services:
  node:
    build:
      network: host
  pool:
    build:
      network: host
  dashboard:
    build:
      network: host
"@
    [IO.File]::WriteAllText((Join-Path $ReleaseRoot 'docker-compose.override.yml'), $content)
}

function Build-WithRetry {
    param([string]$ReleaseRoot)
    Write-Step 'docker compose build (this can take 5-15 min on first run)'
    New-Item -ItemType Directory -Force $LogDir | Out-Null
    Write-BuildOverride -ReleaseRoot $ReleaseRoot

    $log = Join-Path $LogDir ("build-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    Push-Location $ReleaseRoot
    try {
        docker compose build 2>&1 | Tee-Object -FilePath $log
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Build succeeded.'; return }
        Write-Warn2 'Build failed on first attempt. Most often apt-mirror flakiness.'
        Write-Warn2 'Retrying once with --no-cache (this WILL re-download base images)...'
        $log = Join-Path $LogDir ("build-retry-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
        docker compose build --no-cache 2>&1 | Tee-Object -FilePath $log
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Build succeeded on retry.'; return }
        throw "Build failed on retry. See $log for details."
    } finally { Pop-Location }
}

# -----------------------------------------------------------------------------
# Up + healthcheck
# -----------------------------------------------------------------------------
function Compose-Up {
    param([string]$ReleaseRoot)
    Write-Step 'docker compose up -d'
    Push-Location $ReleaseRoot
    try {
        docker compose up -d
        if ($LASTEXITCODE -ne 0) { throw 'compose up -d failed' }
        Write-Ok 'All services started.'
        Write-Host '    Waiting for postgres healthcheck ' -NoNewline
        for ($i = 0; $i -lt 18; $i++) {
            Start-Sleep -Seconds 5
            Write-Host '.' -NoNewline
            $h = docker compose ps postgres --format '{{.Health}}' 2>$null
            if ($h -match 'healthy') { Write-Host ''; Write-Ok 'Postgres healthy.'; return }
        }
        Write-Host ''
        Write-Warn2 'Postgres did not flip healthy in 90 s. Continuing - check "docker compose logs postgres" if anything looks off.'
    } finally { Pop-Location }
}

# -----------------------------------------------------------------------------
# Notification
# -----------------------------------------------------------------------------
function Send-InstallNotification {
    param([hashtable]$Cfg, [datetime]$StartedAt, [int]$DurationSec)
    if ($env:NOTIFY_OPT_OUT -eq 'true' -or [string]::IsNullOrWhiteSpace($NotifyURL)) {
        Write-Warn2 'Notification opt-out (or NOTIFY_URL empty); skipping.'
        return
    }
    Write-Step 'Sending install-complete notification'
    $payload = @{
        version          = "pool-stack-docker-$ReleaseTag"
        hostname         = $env:COMPUTERNAME
        os               = 'windows'
        wallet           = $Cfg.POOL_WALLET
        worker_name      = $Cfg.WORKER_NAME
        started_at       = $StartedAt.ToString('o')
        duration_seconds = $DurationSec
        use_snapshot     = $Cfg.USE_SNAPSHOT
        status           = 'running'
    } | ConvertTo-Json -Compress
    for ($i = 1; $i -le 3; $i++) {
        try {
            Invoke-WebRequest -Uri $NotifyURL -Method POST -Body $payload `
                              -ContentType 'application/json' -UseBasicParsing -TimeoutSec 10 | Out-Null
            Write-Ok 'Notification sent.'
            return
        } catch {
            Write-Warn2 "Notify attempt $i/3 failed: $($_.Exception.Message)"
            Start-Sleep -Seconds (2 * $i)
        }
    }
    Write-Warn2 'Notification failed after 3 attempts. Install is fine; just no email landed.'
}

# -----------------------------------------------------------------------------
# Success summary
# -----------------------------------------------------------------------------
function Show-SuccessSummary {
    param([string]$ReleaseRoot, [hashtable]$Cfg, [int]$DurationSec)
    Write-Banner 'Install complete'
    Write-Host "   Stack root     : " -NoNewline; Write-Host $ReleaseRoot -ForegroundColor White
    Write-Host "   Wallet         : " -NoNewline; Write-Host $Cfg.POOL_WALLET -ForegroundColor White
    Write-Host "   Worker         : " -NoNewline; Write-Host $Cfg.WORKER_NAME -ForegroundColor White
    Write-Host "   Snapshot       : " -NoNewline; Write-Host $Cfg.USE_SNAPSHOT -ForegroundColor White
    Write-Host "   Build duration : " -NoNewline; Write-Host "${DurationSec}s" -ForegroundColor White
    Write-Host ''
    Write-Host "   Endpoints:" -ForegroundColor Cyan
    Write-Host "     Dashboard         : http://localhost:9280"
    Write-Host "     Mining pool       : stratum+tcp://localhost:3334"
    Write-Host "     DAG JSON-RPC      : http://localhost:38131  (Basic auth: $($Cfg.NODE_RPC_USER):[redacted])"
    Write-Host "     EVM JSON-RPC      : http://localhost:18545"
    Write-Host "     Node metrics      : http://localhost:6060/metrics"
    Write-Host ''
    Write-Host "   Useful commands:" -ForegroundColor Cyan
    Write-Host "     cd `"$ReleaseRoot`""
    Write-Host "     docker compose ps"
    Write-Host "     docker compose logs -f node"
    Write-Host "     docker compose down              # stop, keep chain data"
    Write-Host "     docker compose down -v           # stop, wipe chain data"
    Write-Host ''
}

# =============================================================================
# main
# =============================================================================
$started = Get-Date
try {
    Write-Banner "BlockDAG Pool-Stack Installer (Windows) - release $ReleaseTag"
    Test-DiskSpace -MinGB 30
    Ensure-Docker
    Test-PortsAvailable
    Get-Release
    $releaseRoot = Locate-ReleaseRoot
    $cfg = Get-UserConfig
    $cfg.SNAPSHOT_PATH_VAL = Stage-Snapshot -ReleaseRoot $releaseRoot `
                                            -UseSnapshot $cfg.USE_SNAPSHOT `
                                            -SnapshotFile $cfg.SNAPSHOT_FILE `
                                            -SnapshotURL  $cfg.SNAPSHOT_URL
    Render-Template -TemplatePath (Join-Path $PSScriptRoot 'templates\env.template') `
                    -OutPath      (Join-Path $releaseRoot '.env') `
                    -Subs $cfg
    Render-Template -TemplatePath (Join-Path $PSScriptRoot 'templates\node.conf.template') `
                    -OutPath      (Join-Path $releaseRoot 'node.conf') `
                    -Subs $cfg
    Write-Ok '.env and node.conf rendered.'
    Build-WithRetry -ReleaseRoot $releaseRoot
    Compose-Up      -ReleaseRoot $releaseRoot
    Add-FirewallRule
    $duration = [int]((Get-Date) - $started).TotalSeconds
    Send-InstallNotification -Cfg $cfg -StartedAt $started -DurationSec $duration
    Show-SuccessSummary      -ReleaseRoot $releaseRoot -Cfg $cfg -DurationSec $duration
    exit 0
} catch {
    Write-Err2 "Install failed: $($_.Exception.Message)"
    Write-Host "    Logs at: $LogDir" -ForegroundColor Yellow
    exit 1
}
