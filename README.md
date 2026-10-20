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
    ├── requirements.txt    ← Python deps (adb-shell, rsa, cryptography)
    └── adbkey/             ← auto-generated ADB key pair (git-ignored)
```

---

## Recovery

The debloat run writes a JSON snapshot to `~/.cleanyourtv/` **before** touching anything. `restore.sh` replays that snapshot exactly — packages that were already disabled before you ran this toolkit stay disabled; everything else comes back.

```bash
./scripts/restore.sh
```

If you lose the snapshot, restore falls back to enabling every listed package and resetting the stock launcher — safe but not perfectly surgical.

---

## Safety Notes

- **setupwraith check**: `com.google.android.tungsten.setupwraith` owns your Wi-Fi credentials on first-run Google TV. Disabling it drops the TV off Wi-Fi immediately. The scripts detect this automatically and skip it until you re-join the network from Settings (which transfers ownership to `android.uid.system`).
- **Stock launcher**: Never disabled until Projectivy successfully owns the Home intent.
- **OTA**: `com.xiaomi.mitv.updateservice` is in `packages.txt` so updates are blocked. Re-enable it before applying a firmware update you want.
- All operations require **network ADB** on the same subnet. Nothing requires root.
