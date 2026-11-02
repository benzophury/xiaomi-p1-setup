# Xiaomi P1 32" Setup Toolkit

A complete debloat, privacy, and launcher-replacement toolkit for the **Xiaomi P1 32"** (Android / Google TV, Mi TV). Removes Xiaomi PatchWall advertising, Google TV recommendations bloat, and optional streaming apps you don't use — then optionally installs Projectivy Launcher (patched with Morphe) and configures NextDNS Private DNS.

Nothing is uninstalled. Everything is disabled per-user (`pm disable-user --user 0`) so a single restore command puts the TV back exactly as it was.

---

## What It Does

| Step | Script | What changes |
|------|--------|-------------|
| Preflight | `scripts/preflight.sh` | **Read-only** — prints current state, counts packages that would be disabled |
| Configure | `scripts/configure.sh` | Interactive interview → writes/updates `setup.conf` |
| Debloat | `scripts/debloat.sh` | Disables Xiaomi/Google TV bloat, applies privacy settings, sets NextDNS |
| Launcher | `scripts/launcher.sh` | Pushes & activates Morphe-patched Projectivy via `b64push.py` |
| Restore | `scripts/restore.sh` | Re-enables everything using the pre-run snapshot |
| All-in-one | `scripts/all.sh` | Runs the above in order with a confirmation prompt |

---

## Prerequisites

| Requirement | Notes |
|------------|-------|
| Python 3.8+ | `python3 --version` |
| pip | `python3 -m pip --version` |
| `adb_shell` Python library | Installed via `pip install -r tools/requirements.txt` (no `adb` binary needed) |
| `adb` binary (optional) | Only needed for `require_adb()` native fallback in shell scripts |
| TV on same network | Enable **Settings → Device Preferences → ADB Debugging** on the TV |

---

## Quick Start

```bash
# 1. Clone / download this repo
cd /path/to/xiaomi-p1-setup

# 2. Install Python deps (once)
python3 -m venv tools/venv
tools/venv/bin/pip install -r tools/requirements.txt

# 3. Enable ADB on the TV
#    Settings → Device Preferences → Developer options → USB debugging (network ADB)
#    Note the IP shown under Settings → Network → Wi-Fi

# 4. Configure
cp setup.conf setup.conf   # it ships with defaults
nano setup.conf            # set TV_IP at minimum; fill NEXTDNS_ID if you have one
# — OR — run the interactive interview:
./scripts/configure.sh

# 5. Preflight (read-only, safe to run any time)
./scripts/preflight.sh

# 6. Full run (debloat + optional launcher)
./scripts/all.sh

# Dry-run (prints every command, touches nothing)
./scripts/all.sh --dry-run

# Undo everything
./scripts/restore.sh
```

> **Tip:** To re-run just the debloat without reinstalling the launcher:
> ```bash
> ./scripts/debloat.sh
> ```

---

## Projectivy + Morphe Patch

[Projectivy Launcher](https://play.google.com/store/apps/details?id=com.spocky.projengmenu) is a polished Google TV replacement launcher. **Morphe** patches it to unlock premium features and strip analytics without spending money.

### Patching Steps

1. **Install Morphe Manager** on your phone or PC:
   - Download from [morphe.software](https://morphe.software) or search the Play Store.

2. **Add the community patch source** in Morphe:
   ```
   https://github.com/hxreborn/morphe-patches
   ```
   (Settings → Patch Sources → Add)

3. **Get the Projectivy APK** — download from APKMirror:
   - Package: `com.spocky.projengmenu`
   - Use the latest stable arm64-v8a build.

4. **Select patches** in Morphe:
   - ✅ Premium Unlock
   - ✅ Remove Analytics / Crashlytics
   - ✅ Remove Intro screen

5. **Build** the patched APK. Morphe saves it to your Downloads folder.

6. **Set the path in `setup.conf`**:
   ```bash
   PROJECTIVY_APK="/home/you/Downloads/projectivy-patched.apk"
   ```

7. Run `./scripts/launcher.sh` (or `./scripts/all.sh` which calls it automatically when `PROJECTIVY_APK` is set).

> **Note:** The stock Google TV launcher (`com.google.android.tvlauncher`) is only disabled **after** Projectivy has successfully claimed the Home intent. If the home activity check fails, the stock launcher is left enabled.

---

## Folder Structure

```
xiaomi-p1-setup/
├── README.md               ← you are here
├── setup.conf              ← your local settings (edit this)
│
├── data/
│   ├── packages.txt        ← packages to disable (Xiaomi + Google TV bloat)
│   ├── never-disable.txt   ← safety list — never touched
│   └── settings.txt        ← `settings put` commands applied by debloat.sh
│
├── scripts/
│   ├── lib.sh              ← shared helpers (sourced by all scripts)
│   ├── preflight.sh        ← read-only system report
│   ├── configure.sh        ← interactive setup.conf interview
│   ├── debloat.sh          ← main debloat + settings
│   ├── launcher.sh         ← Projectivy install & activation
│   ├── restore.sh          ← full undo using recovery snapshot
│   └── all.sh              ← orchestrator (runs everything in order)
│
└── tools/
    ├── tv.py               ← ADB-over-TCP client (adb_shell, no binary needed)
    ├── recovery.py         ← pre-run snapshot + restore batch generator
    ├── b64push.py          ← reliable file transfer via base64 chunks
    ├── check.py            ← firmware drift detection: what a Xiaomi OTA undid
    ├── privacy.py          ← audit the TV for voice/ACR/telemetry candidates
    ├── adb-closed.py       ← verify ADB port is closed after turning off debugging
    ├── relay.py            ← forward ADB to a sandbox that can't reach your network
    ├── relay.md            ← relay usage guide
    ├── requirements.txt    ← Python deps (adb-shell, rsa, cryptography)
    └── adbkey/             ← auto-generated ADB key pair (git-ignored)
```

---

## Recovery

The debloat run writes a JSON snapshot to `~/.xiaomi-p1-setup/` **before** touching anything. `restore.sh` replays that snapshot exactly — packages that were already disabled before you ran this toolkit stay disabled; everything else comes back.

```bash
./scripts/restore.sh
```

If you lose the snapshot, restore falls back to enabling every listed package and resetting the stock launcher — safe but not perfectly surgical.

---

## After a Firmware Update

Xiaomi OTA updates silently re-enable packages you disabled. Use `tools/check.py` to detect and fix this:

```bash
# See what the firmware update undid (exits 1 if drift found):
tools/venv/bin/python -I tools/check.py data/packages.txt

# Re-apply automatically:
tools/venv/bin/python -I tools/check.py --fix data/packages.txt
```

> **Tip:** Run `check.py` from a scheduled task after any OTA. It exits 0 when in sync and 1 when something drifted, so it fits a cron job or a CI check.

---

## Auditing Your TV

`tools/privacy.py` scans the live TV for voice, ACR (screen fingerprinting), and telemetry packages — including ones that are not in `packages.txt` yet:

```bash
# Print a report with evidence for each candidate:
tools/venv/bin/python -I tools/privacy.py

# Write candidates to a new debloat list:
tools/venv/bin/python -I tools/privacy.py --write data/packages-audit.txt
```

---

## Using a Coding Agent (Sandbox Support)

If your coding agent runs in a sandbox that cannot reach your local network (Claude Code on macOS, Codex, etc.), use `tools/relay.py` to forward the ADB port:

```bash
# In a normal terminal — leave running:
tools/venv/bin/python -I tools/relay.py ${TV_IP}

# In the agent's sandbox:
export TV_HOST=127.0.0.1 TV_PORT=15555
tools/venv/bin/python -I tools/tv.py --probe
```

See [`tools/relay.md`](tools/relay.md) for full details.

---

## Closing ADB After Setup

After turning off ADB debugging on the TV, verify port 5555 is actually closed (no `nc` needed):

```bash
tools/venv/bin/python -I tools/adb-closed.py ${TV_IP}
# exits 0 = closed, 1 = still open, 2 = could not tell
```

---

## Safety Notes

- **setupwraith check**: `com.google.android.tungsten.setupwraith` owns your Wi-Fi credentials on first-run Google TV. Disabling it drops the TV off Wi-Fi immediately. The scripts detect this automatically and skip it until you re-join the network from Settings (which transfers ownership to `android.uid.system`).
- **Stock launcher**: Never disabled until Projectivy successfully owns the Home intent.
- **OTA**: `com.xiaomi.mitv.updateservice` is in `packages.txt` so updates are blocked. Re-enable it before applying a firmware update you want.
- All operations require **network ADB** on the same subnet. Nothing requires root.
