# Tier 4 + Tier 5 lean bash tests. Sources install.sh in 4 distros and
# runs assertions WITHOUT apt-installing anything. ~30-90 sec total.

[CmdletBinding()]
param(
    [string]$InstallerDir = "",
    [string]$ResultsPath  = ""
)

# Resolve defaults relative to this script (empty -> use script-relative path)
if (-not $InstallerDir) { $InstallerDir = Split-Path $PSScriptRoot -Parent }
if (-not $ResultsPath)  { $ResultsPath  = Join-Path $PSScriptRoot 'results-bash.md' }

$script:Results = New-Object System.Collections.ArrayList
function Add-Result($Tier, $Name, $Status, $Detail = '') {
    $null = $script:Results.Add([PSCustomObject]@{ Tier=$Tier; Name=$Name; Status=$Status; Detail=$Detail })
    $col = switch ($Status) { 'PASS' {'Green'} 'FAIL' {'Red'} 'WARN' {'Yellow'} default {'Gray'} }
    Write-Host ("  [{0,-4}] T{1} {2,-44} {3}" -f $Status, $Tier, $Name, $Detail) -ForegroundColor $col
}
function Banner($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

# Bash test script. CRITICAL: install.sh has `set -euo pipefail`. After sourcing,
# disable all three (set +euo pipefail) so OUR test commands aren't killed by
# the very first non-zero exit code or unset variable.
$bashTest = @'
#!/usr/bin/env bash

export INSTALL_SH_NORUN=1
. /s/install.sh 2>/dev/null
set +e          # let test assertions handle non-zero exits
set +u          # tolerate unset vars in tests
set +o pipefail # avoid SIGPIPE killing pipelines like tr|head

fails=0
pass() { printf "PASS\t%s\n" "$1"; }
fail() { printf "FAIL\t%s\t%s\n" "$1" "${2:-}"; fails=$((fails+1)); }
warn() { printf "WARN\t%s\t%s\n" "$1" "${2:-}"; }

# --- T4: function-level ---

p=$(strong_password 28)
[ ${#p} -eq 28 ] && pass T4.1_password_length || fail T4.1_password_length "got ${#p}"

echo "$p" | grep -qE '^[A-HJ-NP-Za-km-z2-9]+$' && pass T4.2_password_charset || fail T4.2_password_charset "[$p]"

samples=$(for i in $(seq 1 50); do strong_password 28; echo; done | sort -u | wc -l)
[ "$samples" -eq 50 ] && pass T4.3_password_50_unique || fail T4.3_password_50_unique "got $samples"

# Don't pipe detect_os - would run in subshell and lose $OS in parent.
detect_os >/dev/null 2>&1
distro_id=$(. /etc/os-release 2>/dev/null && echo "${ID:-unknown}")
case "$distro_id" in
    ubuntu|debian)                       want=linux-debian ;;
    fedora|rhel|centos|rocky|almalinux)  want=linux-rhel ;;
    arch|manjaro)                        want=linux-arch ;;
    *)                                   want=linux-generic ;;
esac
[ "$OS" = "$want" ] && pass T4.4_detect_os "$OS for $distro_id" || fail T4.4_detect_os "got [$OS] for $distro_id, want [$want]"

# render_template
mkdir -p /tmp/tplt
cat > /tmp/tplt/in.tpl <<'EOF'
wallet={{POOL_WALLET}}
user={{NODE_RPC_USER}}
pass={{NODE_RPC_PASS}}
pg={{POSTGRES_PASSWORD}}
fee={{POOL_FEE_PERCENTAGE}}
snap={{SNAPSHOT_PATH_VAL}}
worker={{WORKER_NAME}}
EOF
POOL_WALLET=0xAaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
WORKER_NAME=tnode
NODE_RPC_USER=bdag_t
NODE_RPC_PASS=Pw1234567890ABCDEFGHIJKLMNOP
POSTGRES_PASSWORD=PgPw1234567890ABCDEFGHIJKLMNOP
POOL_FEE_PERCENTAGE=1.5
SNAPSHOT_PATH_VAL=docker/no-snapshot.marker
render_template /tmp/tplt/in.tpl /tmp/tplt/out 2>/dev/null
if grep -q "wallet=0xAaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" /tmp/tplt/out \
   && grep -q "user=bdag_t" /tmp/tplt/out \
   && grep -q "pg=PgPw1234567890ABCDEFGHIJKLMNOP" /tmp/tplt/out \
   && grep -q "snap=docker/no-snapshot.marker" /tmp/tplt/out \
   && ! grep -q "{{" /tmp/tplt/out; then
    pass T4.5_render_template
else
    out=$(cat /tmp/tplt/out 2>/dev/null | head -c 200)
    fail T4.5_render_template "out=[$out]"
fi

# read_validated good
result=$(echo '0x6387C32ccDD60BfBa00EC70A67715Dcd52E8083f' | read_validated 'wallet' '^0x[a-fA-F0-9]{40}$' 2>/dev/null)
[ "$result" = '0x6387C32ccDD60BfBa00EC70A67715Dcd52E8083f' ] \
    && pass T4.6_read_validated_good \
    || fail T4.6_read_validated_good "got [$result]"

# read_validated bad (3 retries -> fail)
if printf "0xnope\n0xnope\n0xnope\n" | read_validated 'wallet' '^0x[a-fA-F0-9]{40}$' '' 3 >/dev/null 2>&1; then
    fail T4.7_read_validated_bad "should have failed"
else
    pass T4.7_read_validated_bad
fi

# --- T5: smoke (gather_config in unattended mode + render templates) ---

export POOL_WALLET=0x6387C32ccDD60BfBa00EC70A67715Dcd52E8083f
export WORKER_NAME=smoke
export STRONG_RPC=n
export POOL_FEE_PERCENTAGE=1.0
export USE_SNAPSHOT=no
export UNATTENDED=yes
export RELEASE_TAG=v1.3.21
export SCRIPT_DIR=/s
export SNAPSHOT_PATH_VAL=docker/no-snapshot.marker
mkdir -p /tmp/release-fake
export RELEASE_ROOT=/tmp/release-fake

# install.sh's gather_config is a function we sourced. Run it under tolerant set state.
gather_config </dev/null >/dev/null 2>&1
[ $? -eq 0 ] && pass T5.1_gather_config_unattended || fail T5.1_gather_config_unattended "non-zero exit"

# Render templates with the env we set
render_template /s/templates/env.template       /tmp/release-fake/.env       2>/dev/null
render_template /s/templates/node.conf.template /tmp/release-fake/node.conf  2>/dev/null
if grep -q "0x6387C32ccDD60BfBa00EC70A67715Dcd52E8083f" /tmp/release-fake/.env \
   && grep -q "rpcuser=test" /tmp/release-fake/node.conf \
   && grep -q "rpcpass=test" /tmp/release-fake/node.conf \
   && ! grep -qE '\{\{[A-Z_]+\}\}' /tmp/release-fake/.env /tmp/release-fake/node.conf; then
    pass T5.2_render_realistic
else
    fail T5.2_render_realistic "values missing or placeholders left"
fi

# T5.3 fee validation: bad input rejected. Fork a child shell so we don't pollute parent state.
if POOL_WALLET=0x6387C32ccDD60BfBa00EC70A67715Dcd52E8083f WORKER_NAME=t STRONG_RPC=n USE_SNAPSHOT=no UNATTENDED=yes \
   POOL_FEE_PERCENTAGE=abc bash -c '
       export INSTALL_SH_NORUN=1
       . /s/install.sh 2>/dev/null
       set +e +u +o pipefail
       gather_config </dev/null
   ' >/dev/null 2>&1; then
    fail T5.3_fee_validation_rejects_bad "should have failed for POOL_FEE_PERCENTAGE=abc"
else
    pass T5.3_fee_validation_rejects_bad
fi

# T5.4 fee validation: good input accepted
if POOL_WALLET=0x6387C32ccDD60BfBa00EC70A67715Dcd52E8083f WORKER_NAME=t STRONG_RPC=n USE_SNAPSHOT=no UNATTENDED=yes \
   POOL_FEE_PERCENTAGE=2.5 bash -c '
       export INSTALL_SH_NORUN=1
       . /s/install.sh 2>/dev/null
       set +e +u +o pipefail
       gather_config </dev/null
   ' >/dev/null 2>&1; then
    pass T5.4_fee_validation_accepts_good
else
    fail T5.4_fee_validation_accepts_good "should accept POOL_FEE_PERCENTAGE=2.5"
fi

# T5.5 fee validation: out-of-range rejected
if POOL_WALLET=0x6387C32ccDD60BfBa00EC70A67715Dcd52E8083f WORKER_NAME=t STRONG_RPC=n USE_SNAPSHOT=no UNATTENDED=yes \
   POOL_FEE_PERCENTAGE=99.0 bash -c '
       export INSTALL_SH_NORUN=1
       . /s/install.sh 2>/dev/null
       set +e +u +o pipefail
       gather_config </dev/null
   ' >/dev/null 2>&1; then
    fail T5.5_fee_validation_out_of_range "should reject 99.0"
else
    pass T5.5_fee_validation_out_of_range
fi

[ "$fails" -eq 0 ] && echo TEST_RUN_OK || echo TEST_RUN_FAIL_$fails
'@

# Write with LF-only line endings - bash hates CRLF.
$bashTest = $bashTest -replace "`r`n", "`n"
[IO.File]::WriteAllText("$env:TEMP\bdag-bash-test.sh", $bashTest, [System.Text.UTF8Encoding]::new($false))

$distros = 'ubuntu:22.04','ubuntu:24.04','debian:12','fedora:41'
foreach ($img in $distros) {
    Write-Host "`n>>> $img" -ForegroundColor DarkCyan
    $log = docker run --rm `
        -v "${InstallerDir}:/s:ro" `
        -v "$env:TEMP\bdag-bash-test.sh:/t.sh:ro" `
        $img bash /t.sh 2>&1
    $logStr = $log | Out-String
    foreach ($ln in ($logStr -split "`n")) {
        if ($ln -match '^PASS\s+(\S+)') { Add-Result $img $matches[1] PASS }
        elseif ($ln -match '^FAIL\s+(\S+)\s*(.*)$') { Add-Result $img $matches[1] FAIL $matches[2].Trim() }
        elseif ($ln -match '^WARN\s+(\S+)\s*(.*)$') { Add-Result $img $matches[1] WARN $matches[2].Trim() }
    }
    if ($logStr -notmatch 'TEST_RUN_(OK|FAIL_\d+)') {
        $tail = ($logStr -split "`n" | Where-Object { $_.Trim() -and $_ -notmatch '^Unable to find' -and $_ -notmatch '^[a-f0-9]+:' -and $_ -notmatch '^Status:' -and $_ -notmatch '^Pulling' -and $_ -notmatch '^Digest:' -and $_ -notmatch '^Downloading' } | Select-Object -Last 5) -join ' / '
        Add-Result $img 'runner' FAIL "no terminator: $tail"
    }
}

# Summary
$pass = ($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
$fail = ($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warn = ($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count
$total = $script:Results.Count
Banner "Bash tier results: $pass / $total pass, $fail fail, $warn warn"
if ($fail -gt 0) {
    Write-Host "Failures:" -ForegroundColor Red
    $script:Results | Where-Object { $_.Status -eq 'FAIL' } |
        ForEach-Object { Write-Host "  $($_.Tier) $($_.Name) -> $($_.Detail)" -ForegroundColor Red }
}

# Write results.md
$resultsDir = Split-Path $ResultsPath -Parent
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Force $resultsDir | Out-Null }
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# Bash-tier results'); [void]$sb.AppendLine('')
[void]$sb.AppendLine("Run at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"); [void]$sb.AppendLine('')
[void]$sb.AppendLine("Summary: $pass / $total pass, $fail fail, $warn warn"); [void]$sb.AppendLine('')
[void]$sb.AppendLine('| Distro | Test | Status | Detail |')
[void]$sb.AppendLine('|--------|------|--------|--------|')
foreach ($r in $script:Results) {
    $det = ($r.Detail -replace '\|','\\|') -replace '\r?\n',' '
    [void]$sb.AppendLine("| $($r.Tier) | $($r.Name) | $($r.Status) | $det |")
}
Set-Content $ResultsPath $sb.ToString() -Encoding UTF8
Write-Host "`nWritten: $ResultsPath" -ForegroundColor Cyan
exit $fail
