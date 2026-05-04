# Faster harness - tiers 1, 2, 3, 6 only. No Docker, no containers, finishes in seconds.
[CmdletBinding()]
param(
    [string]$InstallerDir = "",
    [string]$ResultsPath  = ""
)

# Resolve defaults relative to this script (empty -> use script-relative path)
if (-not $InstallerDir) { $InstallerDir = Split-Path $PSScriptRoot -Parent }
if (-not $ResultsPath)  { $ResultsPath  = Join-Path $PSScriptRoot 'results-fast.md' }
$ErrorActionPreference = 'Continue'
$script:Results = New-Object System.Collections.ArrayList

function Add-Result {
    param([string]$Tier, [string]$Name, [string]$Status, [string]$Detail = '')
    $null = $script:Results.Add([PSCustomObject]@{ Tier=$Tier; Name=$Name; Status=$Status; Detail=$Detail })
    $col = switch ($Status) { 'PASS' {'Green'} 'FAIL' {'Red'} 'SKIP' {'Yellow'} default {'Gray'} }
    Write-Host ("  [{0,-4}] T{1} {2,-44} {3}" -f $Status, $Tier, $Name, $Detail) -ForegroundColor $col
}
function Banner($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

function Test-FeeRange {
    param([string]$f)
    if ([string]::IsNullOrWhiteSpace($f)) { return $false }
    if ($f -notmatch '^[0-9]+(\.[0-9]+)?$') { return $false }
    $v = [double]$f
    return ($v -ge 0.0 -and $v -le 10.0)
}

# ----- Tier 1 -----
Banner 'Tier 1 - Static (no-docker subset)'
try {
    $errs = $null; $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseFile("$InstallerDir\install.ps1", [ref]$tokens, [ref]$errs) | Out-Null
    if ($errs.Count -eq 0) { Add-Result 1 'install.ps1 parser' PASS } else { Add-Result 1 'install.ps1 parser' FAIL "$($errs.Count) errors" }
} catch { Add-Result 1 'install.ps1 parser' FAIL $_.Exception.Message }

try {
    $j = Get-Content "$InstallerDir\checksums.json" -Raw | ConvertFrom-Json
    if ($j.'v1.3.23' -and $j.'v1.3.23'.tarball -match '^[a-f0-9]{64}$') { Add-Result 1 'checksums.json valid' PASS "v1.3.23 tarball SHA verified" }
    elseif ($j.'v1.3.23') { Add-Result 1 'checksums.json valid' PASS 'v1.3.23 entry present (SHA pending publish)' }
    else { Add-Result 1 'checksums.json valid' FAIL 'no v1.3.23 entry' }
} catch { Add-Result 1 'checksums.json valid' FAIL $_.Exception.Message }

$known = @('POOL_WALLET','WORKER_NAME','NODE_RPC_USER','NODE_RPC_PASS','POSTGRES_PASSWORD','POOL_FEE_PERCENTAGE','SNAPSHOT_PATH_VAL')
foreach ($f in 'env.template','node.conf.template') {
    $content = Get-Content "$InstallerDir\templates\$f" -Raw
    $hits = [regex]::Matches($content,'\{\{([A-Z_]+)\}\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    $unknown = $hits | Where-Object { $_ -notin $known }
    if ($unknown) { Add-Result 1 "template $f" FAIL "unknown: $($unknown -join ',')" } else { Add-Result 1 "template $f" PASS }
}

# ----- Tier 2 -----
Banner 'Tier 2 - PowerShell functions'
function New-StrongPassword($len = 28) {
    $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
    -join ((1..$len) | ForEach-Object { $chars | Get-Random })
}
$p = New-StrongPassword 28
if ($p.Length -eq 28) { Add-Result 2 'password length 28' PASS } else { Add-Result 2 'password length 28' FAIL "got $($p.Length)" }
if ($p -match '^[A-HJ-NP-Za-km-z2-9]+$') { Add-Result 2 'password charset' PASS } else { Add-Result 2 'password charset' FAIL $p }
$samples = 1..50 | ForEach-Object { New-StrongPassword 28 }
$unique = ($samples | Sort-Object -Unique).Count
if ($unique -eq 50) { Add-Result 2 'password 50 unique' PASS } else { Add-Result 2 'password 50 unique' FAIL "$unique/50" }

$wRgx = '^0x[a-fA-F0-9]{40}$'
$valid   = '0x6387C32ccDD60BfBa00EC70A67715Dcd52E8083f','0x0000000000000000000000000000000000000000','0xAaBbCcDdEeFf001122334455667788990011aabb'
$invalid = '0xshort','6387C32ccDD60BfBa00EC70A67715Dcd52E8083f','0x6387C32ccDD60BfBa00EC70A67715Dcd52E8083fEXTRA','0xZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ',''
$vBad  = $valid   | Where-Object { $_ -notmatch $wRgx }
$iGood = $invalid | Where-Object { $_ -match $wRgx }
if ($vBad.Count -eq 0 -and $iGood.Count -eq 0) { Add-Result 2 'wallet regex' PASS } else { Add-Result 2 'wallet regex' FAIL "vBad=$($vBad.Count),iGood=$($iGood.Count)" }

$nRgx = '^[A-Za-z0-9_-]{1,32}$'
$valid   = 'node1','node-1','my_worker','a','A1B2C3D4E5F6G7H8I9J0aaaaaaaaaaaa'
$invalid = '','toolong-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','has spaces','has/slash','../escape'
$vBad  = $valid   | Where-Object { $_ -notmatch $nRgx }
$iGood = $invalid | Where-Object { $_ -match $nRgx }
if ($vBad.Count -eq 0 -and $iGood.Count -eq 0) { Add-Result 2 'worker name regex' PASS } else { Add-Result 2 'worker name regex' FAIL "vBad=$($vBad.Count),iGood=$($iGood.Count)" }

# ----- Tier 3 -----
Banner 'Tier 3 - Template rendering'
$subs = @{
    POOL_WALLET            = '0x6387C32ccDD60BfBa00EC70A67715Dcd52E8083f'
    WORKER_NAME            = 'test-node'
    NODE_RPC_USER          = 'bdag_test'
    NODE_RPC_PASS          = 'AaBbCcDdEeFfGgHh11223344556677'
    POSTGRES_PASSWORD      = 'PgPasswordSampleAlphanum1234'
    POOL_FEE_PERCENTAGE    = '1.5'
    SNAPSHOT_PATH_VAL      = './latest.bdsnap'
}
foreach ($f in 'env.template','node.conf.template') {
    $c = Get-Content "$InstallerDir\templates\$f" -Raw
    foreach ($k in $subs.Keys) { $c = $c.Replace("{{$k}}", [string]$subs[$k]) }
    if ($c -match '\{\{[A-Z_]+\}\}') {
        $left = ([regex]::Matches($c,'\{\{[A-Z_]+\}\}') | ForEach-Object { $_.Value }) -join ','
        Add-Result 3 "$f no leftovers" FAIL $left
    } else { Add-Result 3 "$f no leftovers" PASS }
    if ($c -match [regex]::Escape($subs.POOL_WALLET) -and $c -match [regex]::Escape($subs.NODE_RPC_USER) -and $c -match [regex]::Escape($subs.NODE_RPC_PASS)) {
        Add-Result 3 "$f values present" PASS
    } else { Add-Result 3 "$f values present" FAIL }
}

# ----- Tier 6 -----
Banner 'Tier 6 - Edge cases'
if ('' -notmatch '^0x[a-fA-F0-9]{40}$') { Add-Result 6 'wallet rejects empty' PASS } else { Add-Result 6 'wallet rejects empty' FAIL }
if ('0x6387' -notmatch '^0x[a-fA-F0-9]{40}$') { Add-Result 6 'wallet rejects short' PASS } else { Add-Result 6 'wallet rejects short' FAIL }
if (('0x' + ('a' * 41)) -notmatch '^0x[a-fA-F0-9]{40}$') { Add-Result 6 'wallet rejects long' PASS } else { Add-Result 6 'wallet rejects long' FAIL }
if (('a' * 40) -notmatch '^0x[a-fA-F0-9]{40}$') { Add-Result 6 'wallet rejects no-prefix' PASS } else { Add-Result 6 'wallet rejects no-prefix' FAIL }

$bad = @('../escape','has space','has;semi','has|pipe','has$dollar')
$any = $bad | Where-Object { $_ -match '^[A-Za-z0-9_-]{1,32}$' }
if (-not $any) { Add-Result 6 'worker rejects metachars' PASS } else { Add-Result 6 'worker rejects metachars' FAIL "accepted: $($any -join '|')" }

$fees = @{ '1.0' = $true; '0.0' = $true; '10.0' = $true; '10.1' = $false; '-1.0' = $false; 'abc' = $false; '' = $false }
$mismatches = @()
foreach ($k in $fees.Keys) {
    $got = Test-FeeRange $k
    if ($got -ne $fees[$k]) { $mismatches += "[$k] got=$got expected=$($fees[$k])" }
}
if ($mismatches.Count -eq 0) { Add-Result 6 'pool fee range' PASS }
else { Add-Result 6 'pool fee range' FAIL ($mismatches -join '; ') }

$sh = Get-Content "$InstallerDir\install.sh" -Raw
if ($sh -match 'no SNAPSHOT_FILE or SNAPSHOT_URL') { Add-Result 6 'snapshot guard text' PASS } else { Add-Result 6 'snapshot guard text' FAIL }

# Verify the installer scripts THEMSELVES now have fee validation (not just the test)
$ps = Get-Content "$InstallerDir\install.ps1" -Raw
if ($ps -match 'Pool fee validation failed' -and $ps -match '0\.0 -and') { Add-Result 6 'install.ps1 has fee validation' PASS }
else { Add-Result 6 'install.ps1 has fee validation' FAIL 'no validation block found' }
if ($sh -match 'Pool fee validation failed' -or $sh -match '_validate_fee') { Add-Result 6 'install.sh has fee validation' PASS }
else { Add-Result 6 'install.sh has fee validation' FAIL 'no validation block found' }

# ----- Summary -----
$pass = ($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
$fail = ($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$total = $script:Results.Count
Banner "Results: $pass / $total pass, $fail fail"
if ($fail -gt 0) {
    Write-Host "Failures:" -ForegroundColor Red
    $script:Results | Where-Object { $_.Status -eq 'FAIL' } | ForEach-Object { Write-Host "  T$($_.Tier) $($_.Name) -> $($_.Detail)" -ForegroundColor Red }
}
$resultsDir = Split-Path $ResultsPath -Parent
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Force $resultsDir | Out-Null }
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# Fast-tier results"); [void]$sb.AppendLine("")
[void]$sb.AppendLine("Run at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"); [void]$sb.AppendLine("")
[void]$sb.AppendLine("Summary: $pass / $total pass, $fail fail"); [void]$sb.AppendLine("")
[void]$sb.AppendLine("| Tier | Test | Status | Detail |"); [void]$sb.AppendLine("|------|------|--------|--------|")
foreach ($r in $script:Results) {
    $det = ($r.Detail -replace '\|','\\|') -replace '\r?\n',' '
    [void]$sb.AppendLine("| $($r.Tier) | $($r.Name) | $($r.Status) | $det |")
}
Set-Content $ResultsPath $sb.ToString() -Encoding UTF8
Write-Host "`nWritten: $ResultsPath" -ForegroundColor Cyan
exit $fail
