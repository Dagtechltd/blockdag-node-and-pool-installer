# Tier 7 - real end-to-end on Windows.
# Mirrors real install: down -v at start (fresh), render templates ONCE with a
# stable POSTGRES_PASSWORD, then up/down cycles using that fixed password
# (matching how a real operator re-ups their stack without re-running the installer).

[CmdletBinding()]
param(
    [string]$InstallerDir    = "",
    [string]$ExistingRelease = "",
    [string]$ResultsPath     = "",
    [int]$Cycles = 3
)

# Resolve defaults relative to this script (empty -> use script-relative path)
if (-not $InstallerDir) { $InstallerDir = Split-Path $PSScriptRoot -Parent }
if (-not $ResultsPath)  { $ResultsPath  = Join-Path $PSScriptRoot 'results-e2e.md' }
if (-not $ExistingRelease) { $ExistingRelease = "$env:USERPROFILE\bdag-pool-stack\pool-stack-docker-pool-v1.3.23" }

$script:Results = New-Object System.Collections.ArrayList
function Add-Result($Tier, $Name, $Status, $Detail = '') {
    $null = $script:Results.Add([PSCustomObject]@{ Tier=$Tier; Name=$Name; Status=$Status; Detail=$Detail })
    $col = switch ($Status) { 'PASS' {'Green'} 'FAIL' {'Red'} default {'Yellow'} }
    Write-Host ("  [{0,-4}] {1,-15} {2,-32} {3}" -f $Status, $Tier, $Name, $Detail) -ForegroundColor $col
}
function Banner($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

if (-not (Test-Path "$ExistingRelease\docker-compose.yml")) {
    Add-Result 'pre' 'release tree present' FAIL "no docker-compose.yml at $ExistingRelease"
    exit 1
}
Add-Result 'pre' 'release tree present' PASS

# 1. Tear everything down with -v so postgres-data starts empty
#    (ensures POSTGRES_PASSWORD we render below is the one postgres uses)
Push-Location $ExistingRelease
try {
    docker compose down -v 2>&1 | Out-Null
    Add-Result 'pre' 'compose down -v (clean slate)' PASS
} finally { Pop-Location }

# 2. Render templates ONCE - same password across all cycles
$pgPw = -join ((1..28) | ForEach-Object { [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789' | Get-Random })
$subs = @{
    POOL_WALLET            = '0x6387C32ccDD60BfBa00EC70A67715Dcd52E8083f'
    WORKER_NAME            = 'e2e-test'
    NODE_RPC_USER          = 'test'
    NODE_RPC_PASS          = 'test'
    POSTGRES_PASSWORD      = $pgPw
    POOL_FEE_PERCENTAGE    = '1.0'
    SNAPSHOT_PATH_VAL      = if (Test-Path "$ExistingRelease\latest.bdsnap") { './latest.bdsnap' } else { 'docker/no-snapshot.marker' }
}
function Render-Template-E2E($tpl, $out, $hash) {
    $c = Get-Content $tpl -Raw
    foreach ($k in $hash.Keys) { $c = $c.Replace("{{$k}}", [string]$hash[$k]) }
    [IO.File]::WriteAllText($out, $c)
}
try {
    Render-Template-E2E "$InstallerDir\templates\env.template"       "$ExistingRelease\.env"      $subs
    Render-Template-E2E "$InstallerDir\templates\node.conf.template" "$ExistingRelease\node.conf" $subs
    Add-Result 'pre' 'render templates (stable pwd)' PASS
} catch { Add-Result 'pre' 'render templates (stable pwd)' FAIL $_.Exception.Message; exit 1 }

# 3. Compose config validate
Push-Location $ExistingRelease
try {
    docker compose config | Out-Null
    if ($LASTEXITCODE -eq 0) { Add-Result 'pre' 'compose config valid' PASS }
    else { Add-Result 'pre' 'compose config valid' FAIL ; exit 1 }
} finally { Pop-Location }

# 4. Cycles of up + verify + down
for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
    $tier = "cycle$cycle"
    Banner "Cycle $cycle of $Cycles"
    Push-Location $ExistingRelease
    try {
        # Remove orphans (containers from previous run if any)
        docker ps -a --format '{{.Names}}' 2>$null | Where-Object { $_ -like 'pool-stack-docker-pool-v1321-*' } |
            ForEach-Object { docker rm -f $_ 2>&1 | Out-Null }

        $up = docker compose up -d 2>&1
        if ($LASTEXITCODE -ne 0) {
            Add-Result $tier 'compose up' FAIL (($up | Out-String).Substring(0, [Math]::Min(200, ($up | Out-String).Length)))
            continue
        }
        Add-Result $tier 'compose up' PASS

        # Wait for postgres healthy (max 90 s)
        $healthy = $false
        for ($i = 0; $i -lt 18; $i++) {
            Start-Sleep -Seconds 5
            $h = docker compose ps postgres --format '{{.Health}}' 2>$null
            if ($h -match 'healthy') { $healthy = $true; break }
        }
        if ($healthy) { Add-Result $tier 'postgres healthy' PASS }
        else { Add-Result $tier 'postgres healthy' FAIL "did not flip in 90 s" }

        # Wait an extra 10 s for pool to register against postgres
        Start-Sleep -Seconds 10

        # All 4 services Up (pool may take a few extra seconds after postgres)
        $ps = docker compose ps --format '{{.Service}}={{.Status}}' 2>$null
        $upServices = ($ps -split "`n" | Where-Object { $_ -match '=Up' -and $_ -notmatch 'Restart' }).Count
        if ($upServices -ge 4) { Add-Result $tier 'all 4 services Up' PASS "$upServices/4" }
        else {
            $detail = ($ps -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }) -join ' | '
            Add-Result $tier 'all 4 services Up' FAIL "only $upServices/4: $detail"
        }

        # Pool no longer restart-looping
        $poolStatus = docker compose ps pool --format '{{.Status}}' 2>$null
        if ($poolStatus -notmatch 'Restart') { Add-Result $tier 'pool not restart-looping' PASS $poolStatus.Trim() }
        else { Add-Result $tier 'pool not restart-looping' FAIL $poolStatus.Trim() }

        # Dashboard
        try {
            $r = Invoke-WebRequest 'http://localhost:9280' -UseBasicParsing -TimeoutSec 10
            if ($r.StatusCode -eq 200) { Add-Result $tier 'dashboard :9280' PASS "$($r.Content.Length) bytes" }
            else { Add-Result $tier 'dashboard :9280' FAIL "HTTP $($r.StatusCode)" }
        } catch { Add-Result $tier 'dashboard :9280' FAIL $_.Exception.Message }

        # Stratum TCP connect
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $iar = $tcp.BeginConnect('127.0.0.1', 3334, $null, $null)
            $waitOk = $iar.AsyncWaitHandle.WaitOne(5000, $false)
            if ($waitOk -and $tcp.Connected) {
                Add-Result $tier 'stratum :3334 connect' PASS
                $tcp.Close()
            } else { Add-Result $tier 'stratum :3334 connect' FAIL 'no TCP connect in 5s' }
        } catch { Add-Result $tier 'stratum :3334 connect' FAIL $_.Exception.Message }

        # Down (keep volumes - chain data persists for next cycle, password also persists)
        $down = docker compose down 2>&1
        if ($LASTEXITCODE -eq 0) { Add-Result $tier 'compose down' PASS }
        else { Add-Result $tier 'compose down' FAIL }

    } catch { Add-Result $tier 'cycle' FAIL $_.Exception.Message
    } finally { Pop-Location }
}

# Summary
$pass = ($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
$fail = ($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$total = $script:Results.Count
Banner "E2E results: $pass / $total pass, $fail fail"
if ($fail -gt 0) {
    Write-Host "Failures:" -ForegroundColor Red
    $script:Results | Where-Object { $_.Status -eq 'FAIL' } |
        ForEach-Object { Write-Host "  $($_.Tier) $($_.Name) -> $($_.Detail)" -ForegroundColor Red }
}

# Markdown
$resultsDir = Split-Path $ResultsPath -Parent
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Force $resultsDir | Out-Null }
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# E2E results'); [void]$sb.AppendLine('')
[void]$sb.AppendLine("Run at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"); [void]$sb.AppendLine('')
[void]$sb.AppendLine("Summary: $pass / $total pass, $fail fail across $Cycles cycles"); [void]$sb.AppendLine('')
[void]$sb.AppendLine('| Phase | Test | Status | Detail |')
[void]$sb.AppendLine('|-------|------|--------|--------|')
foreach ($r in $script:Results) {
    $det = ($r.Detail -replace '\|','\\|') -replace '\r?\n',' '
    [void]$sb.AppendLine("| $($r.Tier) | $($r.Name) | $($r.Status) | $det |")
}
Set-Content $ResultsPath $sb.ToString() -Encoding UTF8
Write-Host "`nWritten: $ResultsPath" -ForegroundColor Cyan
exit $fail
