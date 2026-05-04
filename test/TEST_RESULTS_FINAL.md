# Installer test harness - final results

**Run on:** 2026-05-04
**Installer release tag pinned:** `v1.3.21`

## TL;DR

**750 test executions, 0 failures.** Four real installer bugs caught by the harness and fixed:

1. UTF-8 BOM missing on `install.ps1` -> PowerShell 5.1 parser failed on em-dashes
2. Pool fee prompt accepted any input -> added regex + range + retry loop
3. Pool fee `[double]''` silently returned 0 -> empty-string guard added
4. **`POSTGRES_PASSWORD` regenerated on re-install** -> would cause SASL auth failures against existing `postgres-data` volume. Fixed by preserving the existing password from `.env` if present.

All four fixes shipped in `install.ps1` and `install.sh`.

## Test matrix executed

| Tier | What's tested                                                                  | Run count | Tests/run | Total executions | Result |
| ---- | ------------------------------------------------------------------------------ | --------- | --------- | ---------------- | ------ |
| 1    | Static (PS parser, JSON, template placeholders)                                | 10        | 4         | 40               | All PASS |
| 2    | PowerShell function-level (password gen, regex)                                | 10        | 5         | 50               | All PASS |
| 3    | Template rendering (env + node.conf, no leftover placeholders)                 | 10        | 4         | 40               | All PASS |
| 4    | Bash function-level (sourced install.sh) in 4 distros                          | 10        | 28        | 280              | All PASS |
| 5    | Linux distro smoke (gather_config + render in fresh container) in 4 distros    | 10        | 20        | 200              | All PASS |
| 6    | Edge cases (bad inputs, retry behavior, validation guards)                     | 10        | 9         | 90               | All PASS |
| 7    | Real end-to-end on Windows (compose up + verify + down, 3 cycles per run)      | 2         | 25        | 50               | All PASS |
| **TOTAL** |                                                                            |           |           | **750**          | **All PASS** |

Distros covered in tier 4/5: Ubuntu 22.04, Ubuntu 24.04, Debian 12, Fedora 41.

## Bugs caught and fixed during the harness

### Bug-T1 (BOM/encoding)

**Symptom:** `install.ps1` parsed cleanly when invoked interactively, but Tier 1 reported "5 errors" via `[Parser]::ParseFile()`. PowerShell 5.1 reads UTF-8 files without a BOM as Windows-1252; em-dash characters mojibake'd into bytes the parser rejects.

**Fix:** re-save `install.ps1`, `install.sh`, and all test scripts as UTF-8 with BOM (PowerShell files) or UTF-8-no-BOM with LF endings (bash). Replaced em-dashes with ASCII hyphens defensively. Test harness re-runs cleanly.

### Bug-T2 (fee validation: empty input slips through)

**Symptom:** Tier 6 case `'' (empty string) -> false` failed: empty input returned `True` (range 0.0-10.0 inclusive of 0.0).

**Root cause:** `[double]''` in PowerShell silently returns `0` (no exception). The original `try { [double]$f; ... } catch { false }` couldn't catch this because nothing throws.

**Fix in test:** add explicit `IsNullOrWhiteSpace` and regex pre-checks.
**Fix in installer (production):** add the same guards plus a 3-retry validation loop in BOTH `install.ps1` and `install.sh`. The user would have hit this if they pressed Enter at the fee prompt without typing anything.

### Bug-T3 (no validation on fee prompt)

**Symptom:** Caught by reading the installer code: the fee prompt was just `Read-WithDefault 'Pool fee % (0.0-10.0)' '1.0'`. No validation. User could type "abc" or "99" and the value flowed straight into `.env`.

**Fix:** wrapped both PowerShell and bash fee prompts in 3-retry validation that requires a numeric value in `[0.0, 10.0]`. Env-var override path also validates and aborts loudly on bad value (so unattended installs fail-fast rather than silently misconfigure).

### Bug-T4 (POSTGRES_PASSWORD regenerated on re-install) - the meaningful one

**Symptom:** Tier 7 cycle 1 showed `pool=Restarting (1)` while postgres reported `healthy`. Pool logs:

```
2026/05/04 19:41:59 pool server failed: unable to ping database:
failed SASL auth: FATAL: password authentication failed for user "bdag_pool"
```

**Root cause:** PostgreSQL only honors `POSTGRES_PASSWORD` env var on **first init** of the data directory. On subsequent starts with the same volume, the password baked in at first init is the one that authenticates. The original installer code regenerated `POSTGRES_PASSWORD` every run, so a re-install (or re-render of templates without `compose down -v`) produced a `.env` with a password the existing postgres volume rejected. Pool would never connect, ever.

**Real-world impact (60K community):** any operator who:
- runs the installer
- later re-runs the installer (e.g. to change another setting)
- without first running `docker compose down -v`

...would silently lose their pool. They'd see postgres healthy and the dashboard up (dashboard doesn't depend on postgres) and think it's working. In reality, no shares would ever be tracked.

**Fix:** strict precedence in both installers:
1. `POSTGRES_PASSWORD` env var if set (unattended override)
2. **Existing `.env` in the release dir, if present** (preserves password across re-runs)
3. Auto-generate a fresh strong password (first install only)

The installer logs `Preserving POSTGRES_PASSWORD from existing .env (so re-installs still authenticate to the existing postgres volume)` when path 2 fires, so the operator sees what's happening.

After the fix: 25/25 PASS across two complete e2e runs (3 cycles each, total 6 up/down/verify cycles).

## What's NOT covered by these tests

Honest list:

- **Real macOS** (no host available). Bash function tests cover macOS-equivalent code paths via Linux containers; OS-specific code (`brew`, `open -a Docker`) is exercised only by static review.
- **Real fresh Windows install** without Docker pre-installed (test box has Docker already). The winget install path is exercised only by code review.
- **Real network failures during snapshot download / tarball download.** Mocked via SHA-mismatch handling but not actually disrupted on the wire.
- **Cloudflare Worker deployment.** Worker code is unit-shaped (validation, rate-limit, Resend POST) but I did not actually deploy and post-test the live endpoint.
- **`apt-get install ca-certificates tzdata`** mid-build flakiness (Bug 14 from the verification report) is mitigated via `network: host` build override + auto-retry with `--no-cache`, but not adversarially tested under network failure injection.

For the 60K community release, these gaps are acceptable: the tested paths cover the steady-state happy path and all the input validation. The untested paths are environmental (Docker network policy, Resend uptime, Ubuntu mirror health) where we can only design defensively, not eliminate.

## Files touched

```

  install.ps1                            (patched: BOM fix, fee validation, postgres-password preserve)
  install.sh                             (patched: fee validation, postgres-password preserve, source-guard)
  templates/env.template                 (no change)
  templates/node.conf.template           (no change)
  test/
    run-tests-fast.ps1                   (Tiers 1-3, 6 - no Docker - ~5 s per run)
    run-tests-bash.ps1                   (Tiers 4-5 - Docker + 4 distros - ~5-7 s per run)
    run-tests-e2e.ps1                    (Tier 7 - real compose up/down - ~6-8 min per run)
    results-fast.md                      (latest fast-tier results)
    results-bash.md                      (latest bash-tier results)
    results-e2e.md                       (latest e2e results)
    TEST_RESULTS_FINAL.md                (this file)
```

## Verdict

The installer is **green to publish to a public git repo**. The four bugs the harness surfaced are real and the fixes are tight; one of them (the postgres-password regeneration) would have produced an extremely confusing failure mode in production.

Recommended next steps before tagging the release on GitHub:

1. Replace the `Dagtechltd/blockdag-node-and-pool-installer` placeholder URLs in `install.ps1`, `install.sh`, and `installer/README.md` with the real repo URL.
2. Deploy the `notify-worker` Cloudflare Worker (steps in `notify-worker/README.md`); update the verified Resend domain.
3. Run `run-tests-fast.ps1` once more after the URL substitution to confirm nothing got mangled.
4. Cut a tag and announce.

The harness lives in `installer/test/` and can be re-run on every release going forward; suggest wiring it into a GitHub Actions workflow so v1.3.22+ catches the next regression automatically.
