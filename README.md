<div align="center">
  <img src="assets/logo.svg" alt="VAC logo" width="100"/>
  <h1>VAC — Versatile Autoregistration Client</h1>
</div>

[![en](https://img.shields.io/badge/lang-en-blue.svg)](README.md)
[![es](https://img.shields.io/badge/lang-es-green.svg)](README.es.md)

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Debian package](https://img.shields.io/badge/package-versatile--autoreg--vac-brightgreen)](https://github.com/GabrielNavi/vac/releases)
[![Bash](https://img.shields.io/badge/shell-bash-89e051.svg)](https://www.gnu.org/software/bash/)
[![Platform: Linux](https://img.shields.io/badge/platform-Linux-lightgrey.svg)]()

Autoregistration client for centrally managed Linux networks. Registers the machine in VAS with a persistent UUID, maintains liveness heartbeats, and publishes extensible extra fields. Supports simultaneous registration in multiple VAS servers via sub-instances.

---

## Table of Contents

- [Ecosystem](#ecosystem)
- [Quick Start](#quick-start)
- [Installed Files](#installed-files)
- [Configuration](#configuration)
- [Main Loop](#main-loop)
- [Extras System](#extras-system)
- [Parallelization](#parallelization)
- [Service Management](#service-management)
- [Wiki](#wiki)
- [License](#license)

---

## Ecosystem

```
VAC  ──POST /register──►  VAS  ──bump──►  VAL
     ──POST /heartbeat──►
```

| Package | Repository | Description |
|---------|------------|-------------|
| `versatile-autoreg-vas` | [vas](https://github.com/GabrielNavi/vas) | Inventory server |
| `versatile-autoreg-vac` | [vac](https://github.com/GabrielNavi/vac) ← *this* | Autoregistration client |
| `versatile-autoreg-val` | [val](https://github.com/GabrielNavi/val) | Generic consumer with hooks |
| `versatile-autoreg-vaf` | vaf | Server federation (experimental) |

---

## Quick Start

```bash
# Install
sudo dpkg -i versatile-autoreg-vac_*.deb
sudo apt-get -f install

# Configure — minimum required
sudo nano /etc/vac/vac.conf
# VAS_HOST=10.0.0.1

# Start
sudo systemctl enable --now vac

# Verify
journalctl -u vac -f
```

> **Dependencies:** `bash`, `curl`, `jq`, `uuid-runtime`, `iproute2`  
> See [Installation](https://github.com/GabrielNavi/vac/wiki/EN_Install) in the wiki for full instructions.

---

## Installed Files

| Path | Description |
|------|-------------|
| `/usr/bin/vac` | Main service loop (two independent timers: selfcheck + heartbeat) |
| `/usr/bin/vac-register` | One-shot idempotent registration (for timers, external scripts) |
| `/usr/bin/vac-sub` | Full VAC loop for parallelization sub-instances |
| `/usr/bin/vac-sub-manager` | Sub-instance supervisor with fail counter |
| `/usr/bin/vac-sub-instance` | CLI to create, list and delete sub-instances |
| `/usr/lib/vac/vac-common.sh` | Shared library: log, network, identity, extras, registration |
| `/etc/vac/vac.conf` | Main configuration file |
| `/etc/vac/vac.conf.d/` | Config overlays in lexical order |
| `/etc/vac/extras_imperative.d/` | Cyclic hook scripts for imperative extras |
| `/etc/vac/extras_informative.d/` | Cyclic hook scripts for informative extras |
| `/usr/share/vac/vac.conf.defaults` | Exhaustive variable reference (read-only) |
| `/lib/systemd/system/vac.service` | systemd unit |

**Runtime state:**

| Path | Description |
|------|-------------|
| `/etc/vac/vac-id` | Persistent machine UUID (generated once, mode 600) |
| `/var/lib/vac/identity.json` | Own data as confirmed by VAS |
| `/var/lib/vac/version` | Last known inventory version |
| `/var/lib/vac/clients.json` | Local inventory copy (`SYNC_CLIENTS=true`) |

---

## Configuration

```ini
# /etc/vac/vac.conf  (full reference at /usr/share/vac/vac.conf.defaults)

VAS_HOST=10.0.0.1        # IP/hostname — no scheme, port 8000 implicit
# VAS_SCHEME=http        # http (default) | https
CHECK_SECONDS=300        # selfcheck + version comparison interval
# HEARTBEAT_SECONDS=60   # liveness heartbeat; empty = same as CHECK_SECONDS
SYNC_CLIENTS=false       # download local inventory copy
EXTRAS_ENABLED=true
EXTRAS_TTL=86400         # key expiry in seconds (0 = no expiry)
LOG_LEVEL=normal         # no | normal | debug
PARALLEL_MODE=both       # both | only_parallel | only_main
```

`VAS_HOST` accepts `10.0.0.1`, `10.0.0.1:9000` or `vas.example.org`. The scheme (`http://...`) is extracted automatically with `[WARN]`.

Full guide: [Configuration](https://github.com/GabrielNavi/vac/wiki/EN_Config)

---

## Main Loop

```
Every CHECK_SECONDS:
  collect_extras() → selfcheck vs identity.json
  If changed → POST /register; save identity.json
  GET /version → if new: GET /clients (SYNC_CLIENTS) + refresh identity

Every HEARTBEAT_SECONDS:
  POST /heartbeat → if 404 or error: POST /register (full re-registration)
```

A successful registration in either block resets the other timer, avoiding redundant signals in the same cycle.

More details: [Operation Flow](https://github.com/GabrielNavi/vac/wiki/EN_Operation)

---

## Extras System

Each key in `extra_imperative` / `extra_informative` is managed independently with an internal timestamp. Cyclic producers and one-shot producers coexist without conflict.

```bash
# Cyclic hook: executable script in extras_imperative.d/
# Key = basename without extension; 10s timeout per hook
echo '{"server": "10.0.0.2"}'   # /etc/vac/extras_imperative.d/10-cups.sh

# External one-shot producer (idempotent)
echo '{"server":"10.0.0.2"}' | vac-register --imperative --key cups -

# Delete a key
vac-register --imperative --key cups -d
```

With `EXTRAS_TTL=86400`, keys not updated in >24h are removed automatically with `[WARN]` in log (detects silenced producers).

More details: [Extras](https://github.com/GabrielNavi/vac/wiki/EN_Extras)

---

## Parallelization

A machine can register in multiple VAS servers with distinct UUIDs and independent state per sub-instance:

```bash
vac-sub-instance --create samba --vas 10.0.1.5
vac-sub-instance --list
# NAME    VAS_HOST       ENABLED  STATUS
# samba   10.0.1.5:8000  yes      active
systemctl restart vac   # with PARALLEL_MODE=both
```

`PARALLEL_MODE`: `both` (main + instances) · `only_parallel` (`exec vac-sub-manager`) · `only_main` (no instances).

The supervisor distinguishes hard failures (process died in <30s) from transient ones and stops restarting an instance after 5 consecutive hard failures.

More details: [Parallelization](https://github.com/GabrielNavi/vac/wiki/EN_Sub-instances)

---

## Service Management

```bash
sudo systemctl status vac
sudo systemctl restart vac
journalctl -u vac -f
journalctl -u vac | grep '\[SELFCHECK\]'
journalctl -u vac | grep '\[PARALLEL\]'
journalctl -u vac | grep '\[ERROR\]'
```

---

## Wiki

[Installation](https://github.com/GabrielNavi/vac/wiki/EN_Install) · [Configuration](https://github.com/GabrielNavi/vac/wiki/EN_Config) · [Operation](https://github.com/GabrielNavi/vac/wiki/EN_Operation) · [Extras](https://github.com/GabrielNavi/vac/wiki/EN_Extras) · [Sub-instances](https://github.com/GabrielNavi/vac/wiki/EN_Sub-instances) · [Logging](https://github.com/GabrielNavi/vac/wiki/EN_Logging)

---

## License

[Apache License 2.0](LICENSE)
