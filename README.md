# BlockDAG Pool-Stack Installer

One-command install of the official BlockDAG `pool-stack-docker` release on Windows, Linux, or macOS. Detects your OS, installs Docker if missing, prompts for the values you need to customize, builds the stack, brings it up, and tells the maintainer it landed.

## TL;DR

**Linux / macOS:**
```bash
curl -fsSL https://raw.githubusercontent.com/Dagtechltd/blockdag-node-and-pool-installer/main/install.sh | bash
```

**Windows (PowerShell as Administrator for clean Docker install + firewall rule):**
```powershell
iwr -useb https://raw.githubusercontent.com/Dagtechltd/blockdag-node-and-pool-installer/main/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

## What it actually does

1. **Detects your OS** (Ubuntu/Debian, RHEL/Fedora, Arch, macOS, Windows).
2. **Installs Docker + Compose v2** if not already there:
   - Linux: native package manager (`apt`/`dnf`/`pacman`)
   - macOS: `brew install --cask docker` (you launch the GUI once and re-run)
   - Windows: `winget install Docker.DockerDesktop`
3. **Starts the engine**, waits up to 120 s for it.
4. **Verifies disk space** (recommends 30 GB free) and **scans the host ports** the stack needs (8150, 38131, 18545, 18546, 6060, 3334, 8080, 9280).
5. **Downloads the official release tarball** for the pinned tag (`v1.3.21` at the time of writing) and **verifies its SHA-256** against `checksums.json`.
6. **Asks you for** the values that genuinely need customization — wallet, worker name, pool fee, RPC creds, snapshot Y/N. Validates each input with regex, retries up to 3 times.
7. **Optionally downloads a snapshot** for fast bootstrap (you supply a file path or URL). Verifies the bundled binary can read its manifest BEFORE you commit to a multi-minute build, falling back gracefully to no-snapshot if the formats don't match.
8. **Renders `.env` and `node.conf` from templates** — auto-generates a strong `POSTGRES_PASSWORD`, mirrors `rpcuser`/`rpcpass` between the two files.
9. **Drops a `docker-compose.override.yml`** that uses `network: host` for build steps. Belt-and-braces against Ubuntu mirror flakiness during `apt-get install`.
10. **Builds the stack** — auto-retries once with `--no-cache` if the first attempt fails on apt.
11. **Brings the stack up** and waits for the postgres healthcheck.
12. **Adds a Windows Defender Firewall rule** for inbound `:3334` (Windows only).
13. **POSTs an install-complete payload** to a Cloudflare Worker maintained by DAG Tech, which forwards an email to the project maintainer at `dawie@dagminingtrust.com`. Opt-out: `NOTIFY_OPT_OUT=true`.
14. **Prints a success summary** with every reachable endpoint.

## Requirements

- **64-bit Windows 10/11**, **Linux** (Debian/Ubuntu/RHEL/Fedora/Arch), or **macOS 13+** (Apple Silicon or Intel)
- **30 GB free disk** under `~/bdag-pool-stack` (or `%USERPROFILE%\bdag-pool-stack` on Windows)
- **Internet** for ~5 GB of Docker image downloads + the release tarball + (optional) snapshot
- **Sudo** on Linux (Docker install + firewall rule)
- **Local admin** on Windows (winget Docker install + firewall rule)

## What you'll be asked

| Field                       | Why                                                                                               | Default                       |
| --------------------------- | ------------------------------------------------------------------------------------------------- | ----------------------------- |
| Pool reward / dashboard wallet | The 0x-prefixed 40-hex address shown in the dashboard as the pool's address. External miners that connect via Stratum send their **own** wallet over the protocol — this is purely for display. | (required) |
| Worker / node name           | Friendly name for this node in dashboards and the install notification.                          | hostname                      |
| Strong RPC creds?            | Replace the demo `test/test` JSON-RPC credentials with strong ones. Necessary if the node will be reachable from outside localhost. | n |
| Pool fee %                   | What share of mined rewards the pool retains.                                                    | 1.0                           |
| Use snapshot fast-bootstrap? | Skip genesis sync by importing a 4 GB+ snapshot. Saves ~30–60 minutes on first sync.              | (Snapshot URL: `https://bdagstack.bdagdev.xyz/latest.bdsnap` — verify it's reachable before you set USE_SNAPSHOT=yes; the page sometimes 404s while the team rotates it.) | n                             |

The installer always **auto-generates a strong `POSTGRES_PASSWORD`** so operators don't accidentally publish the placeholder.

All of these can be set via env vars for unattended installs:

```bash
POOL_WALLET=0x6387C32ccDD60BfBa00EC70A67715Dcd52E8083f \
WORKER_NAME=node-3 \
STRONG_RPC=y \
POOL_FEE_PERCENTAGE=1.0 \
USE_SNAPSHOT=yes \
SNAPSHOT_URL=https://example.com/path/to/latest.bdsnap \
NOTIFY_OPT_OUT=false \
UNATTENDED=yes \
bash install.sh
```

## Phone-home telemetry — what gets sent

On a successful install the script POSTs JSON to `https://notify.dagminingtrust.com/install-complete`:

```
version           pool-stack-docker-v1.3.21
hostname          <your machine name>
os                windows | linux-debian | linux-rhel | linux-arch | macos
ip_country        <2-letter ISO from Cloudflare>
wallet            <the wallet you entered>
worker_name       <the worker name you entered>
started_at        <ISO 8601>
duration_seconds  <integer>
use_snapshot      yes | no
status            running
```

A Cloudflare Worker (source in `notify-worker/`) validates the payload, rate-limits per IP, and forwards a single email to the maintainer. **No private keys, no passwords, no RPC credentials are ever sent.** Source visible in this repo.

To opt out, set `NOTIFY_OPT_OUT=true` before running, or pass `-NotifyURL ''` (Windows) / `NOTIFY_URL='' bash install.sh` (Linux/macOS).

## After install

| What                | Where                                                                          |
| ------------------- | ------------------------------------------------------------------------------ |
| Dashboard           | `http://localhost:9280`                                                        |
| Mining pool Stratum | `stratum+tcp://localhost:3334`                                                 |
| DAG JSON-RPC        | `http://localhost:38131` (HTTP Basic, user/pass from your `.env`)              |
| EVM JSON-RPC        | `http://localhost:18545` (no auth)                                             |
| Node native metrics | `http://localhost:6060/metrics`                                                |
| Live node logs      | `cd ~/bdag-pool-stack/pool-stack-docker-pool-v1.3.21 && docker compose logs -f node` |

To stop:
```bash
cd ~/bdag-pool-stack/pool-stack-docker-pool-v1.3.21
docker compose down            # keep chain data
docker compose down -v         # wipe everything (DESTRUCTIVE)
```

## Pointing extra miners at the pool

Same-LAN miners:
```
stratum+tcp://<this-machine-LAN-ip>:3334
```

Across the internet (you'll need a router port-forward of `3334`):
```
stratum+tcp://<your-public-ip>:3334
```

Username = any 0x-prefixed wallet (the miner's payout address), password = `x`. **Note:** shares only flow once your local node finishes initial sync. Until `is_synced=true` in the dashboard, the pool can't issue work.

## Known issues this installer works around

| BlockDAG ref | What we work around | How |
| --- | --- | --- |
| Bug 6 (Docker Desktop on Windows) | Crash on launch when `%ProgramData%` is stripped from the spawned shell environment | Force-set both `ProgramData` and `ALLUSERSPROFILE` before launching Docker |
| Bug 7 (compose git-dev defaults) | `BUILD_CONTEXT=..` and `dockerfile-dev` defaults break tarball builds | Render `.env` from a template that always sets the release values |
| Bug 8 (`.env.example` SNAPSHOT_PATH) | Default `./latest.bdsnap` causes builds to fail when no snapshot is staged | Auto-detect snapshot presence, flip `SNAPSHOT_PATH` to `docker/no-snapshot.marker` if absent |
| Bug 14 (apt-mirror flakiness) | `archive.ubuntu.com` / `security.ubuntu.com` intermittent failures during build | `network: host` build override + auto-retry with `--no-cache` on first failure |

Full bug catalogue and recommended fixes for the BlockDAG team are in the project bug-tracker (sent to BlockDAG separately).

## Reporting a bug

Open an issue with:
- OS + version (`uname -a` / `Get-ComputerInfo`)
- Docker engine version (`docker --version`)
- The most recent file in `~/bdag-pool-stack/logs/build-*.log`
- Output of `docker compose ps` and `docker compose logs --tail=50`
- Whether you used a snapshot

## License

MIT. Use, modify, redistribute freely. No warranty for lost mining rewards if you misconfigure your wallet — measure twice, run once.
