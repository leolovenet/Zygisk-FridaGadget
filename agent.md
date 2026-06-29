# Agent Notes

## Project Evolution

This project started as a minimal Zygisk loader prototype that matched a target app process and `dlopen()`ed a fixed payload shared object.

It has been refactored into:

```text
Zygisk - Frida Gadget
```

Current module id:

```text
zygisk_frida_gadget
```

Current build output:

```text
out/zygisk_frida_gadget.zip
```

Current release helper:

```text
release.py
```

## Goal

Build a reusable open-source Zygisk-based Frida Gadget injection method for devices where running `frida-server` directly is not practical.

This is an authorized security research project. It is intended for debugging, defensive testing, compatibility analysis, and research on devices and applications the user owns or has explicit permission to assess. It is not intended for unauthorized access, monitoring, or modification of third-party apps, systems, or data.

The module should:

- Use Zygisk to enter selected app processes.
- Deploy Frida Gadget and its config into a path Gadget can read.
- Load Gadget by real path so the matching `.config.so` file is discovered naturally.
- Avoid opening `/data/adb` permissions to app processes.
- Be target-configurable without recompiling native code.

## Current Configuration Model

Runtime target configuration uses a simple pipe-delimited file:

```text
targets.conf
```

The repository tracks the default template as:

```text
targets.conf.example
```

`customize.sh` creates `targets.conf` from this template only on first install. During updates or local reinstalls, existing runtime config files are preserved from the live module directory before the module zip is extracted and restored afterward. This includes root config files, ABI-specific `gadget/<abi>/libgadget.config.so` files, and profile-specific `libgadget-*.config.so` files.

Format:

```text
# package|process|match|abi|profile
com.example.app|com.example.app|exact|auto|default
```

Supported `match` values:

```text
exact
prefix
suffix
contains
```

`abi` may be:

```text
auto
arm64-v8a
armeabi-v7a
```

`targets.conf` replaced an earlier JSON config idea because Android shell JSON parsing with `awk` was too fragile for a community project.

The earlier deployment-method field was removed because the app native library directory is the only validated deployment path. Other explored paths either broke Gadget config discovery or hit Android executable mapping restrictions.

## Gadget Files

Preferred layout:

```text
gadget/
  arm64-v8a/
    libgadget-<version>.so
    libgadget.so -> libgadget-<version>.so
  armeabi-v7a/
    libgadget-<version>.so
    libgadget.so -> libgadget-<version>.so
libgadget.config.so
libgadget-<profile>.config.so
```

The repository tracks:

```text
libgadget.config.so.example
```

The real runtime `libgadget.config.so` is ignored by git and is created from the example only when absent.

The source filename may keep the Frida version, for example:

```text
gadget/arm64-v8a/libgadget-17.15.3.so
gadget/armeabi-v7a/libgadget-17.15.3.so
```

During deployment the selected source file is normalized to `libgadget.so` for the default profile, or `libgadget-<profile>.so` for non-default profiles, in the target app native library directory. If `gadget/<abi>/libgadget.so` is a symlink, the deployment script resolves it and copies the real target file. This keeps Frida Gadget config discovery simple because the matching `.config.so` file sits next to the loaded Gadget library.

Plain source filenames are still supported:

```text
gadget/arm64-v8a/libgadget.so
gadget/armeabi-v7a/libgadget.so
```

The deployment script also accepts `frida-gadget-*.so` source filenames after `.xz` decompression.

If `libgadget.so` is missing and exactly one versioned Gadget file exists in an ABI directory, deployment creates the symlink automatically. If multiple versioned files exist, the user must select one by creating or updating `libgadget.so`.

## Deployment Flow

`customize.sh` runs during module installation.

`service.sh` runs after boot.

`action.sh` can be run manually from Magisk action support or shell to redeploy without reboot.

Both call:

```text
deploy_gadget.sh
```

`deploy_gadget.sh`:

1. Reads `targets.conf`.
2. Uses `pm path <package>` to locate the target app install directory.
3. Chooses target native library directories from the target APK install:
   - `lib/arm64`
   - `lib/arm`
   - `lib`
4. With `abi=auto`, deploys arm64 Gadget to `lib/arm64` and arm Gadget to `lib/arm` when those directories and source files exist.
5. Copies the source Gadget file as `libgadget.so` or `libgadget-<profile>.so` and copies the matching `.config.so` next to it.
6. Removes duplicate Gadget files from unselected candidate lib dirs.
7. Syncs metadata from an existing `.so` in the same directory:
   - owner
   - group
   - executable mode for `libgadget.so`
   - SELinux context
8. Writes deployment details to `deploy.log`.
9. Force-stops successfully deployed packages when `force_stop=1`.
10. Does not write loader state. `targets.conf` is the single source of truth.

Automatic force-stop details:

- `module.conf.example` defaults to `force_stop=1`.
- Install and manual Action redeploy flows allow force-stop.
- `service.sh` passes `deploy_gadget "$MODDIR" "0"` so boot-time deployment does not kill apps silently.
- Only packages with successful deployment are force-stopped, and each package is force-stopped once.

`uninstall.sh` removes deployed Gadget files from configured target app native library directories when the Magisk module is removed.

After editing `targets.conf`, the C++ loader sees the new config when the target app process restarts. If the edit changes packages or Gadget deployment, run:

```bash
adb shell su -c '/data/adb/modules/zygisk_frida_gadget/action.sh'
```

By default, successful redeploy force-stops the target package automatically. Users can disable this with:

```text
force_stop=0
```

in `module.conf`.

## Zygisk Loader Flow

Native source:

```text
module/jni/main.cpp
```

Log tag:

```text
ZygiskFridaGadget
```

The loader:

1. Runs in `preAppSpecialize()`.
2. Reads `args->nice_name`.
3. Reads `module.conf` and `targets.conf` through Zygisk companion IPC.
4. Applies the configured process match mode.
5. If matched, resolves the current app install directory from `/proc/self/maps` and stores the resolved `payload_path`.
6. Runs in `postAppSpecialize()`.
7. Checks `/proc/self/maps` for an already mapped Gadget path.
8. Calls:

```cpp
dlopen(payload_path, RTLD_NOW | RTLD_GLOBAL);
```

Because `payload_path` points into the target app native library directory, Frida Gadget can read the matching `.config.so` from the same directory.

If the process already has the configured payload path mapped, the loader logs `payload already loaded, skip dlopen` and skips loading.

`module.conf` currently supports:

```text
debug=0
debug=1
force_stop=0
force_stop=1
```

Debug mode controls noisy non-target process logs. Target matches, load attempts, and errors are always logged.

`force_stop` is consumed by `deploy_gadget.sh`, not the native loader.

The native loader intentionally does not rely on zygote/app processes reading `/data/adb/modules` directly. Some devices deny that with SELinux:

```text
avc: denied { read } for path="/data/adb/modules/zygisk_frida_gadget"
```

For module-private config reads, `main.cpp` uses `Api::connectCompanion()` and exports:

```text
zygisk_companion_entry
```

The companion side only serves a small allowlist:

```text
targets.conf
module.conf
```

There is intentionally no app/zygote-side `getModuleDir/openat` fallback for these config files. Calling that path from zygote/app context can still trigger SELinux denials on affected devices.

## Zygisk/Magisk Development Pitfalls

Treat zygote/app code, companion code, install scripts, and release tooling as separate trust and permission domains. A path or operation working in one domain does not imply it works in another.

Zygote/app side:

- Do not assume app or zygote contexts can read `/data/adb/modules`.
- Avoid `api->getModuleDir()` for runtime config reads from app/zygote paths on affected devices; it can still trigger SELinux denials.
- Keep work in `preAppSpecialize()` small and deterministic. Read config, decide, resolve payload, and load; avoid broad filesystem scans unless needed as fallback.
- Always consider process bitness. A 32-bit app process must not load a 64-bit Gadget. Runtime payload resolution should prefer `lib/arm` for 32-bit and `lib/arm64` for 64-bit.
- Match package and process names with explicit boundaries. `/data/app` directory names may contain package-like prefixes, suffixes, split install randomness, and similar package names.

Companion process:

- Use Zygisk companion IPC for module-private files that app/zygote contexts should not open directly.
- Keep the companion surface small. This project only serves `targets.conf` and `module.conf`.
- Do not expose arbitrary path reads through companion requests. Always use an allowlist and size limits.
- A fixed module id path reduces dynamic module-id flexibility, but avoids app/zygote-side `getModuleDir()` calls and matches the published module id/update metadata.

Install and update scripts:

- `$MODPATH` during install/update may be a staging path, not the live module directory.
- Preserve user runtime config from `/data/adb/modules/<module-id>` during local reinstall/update flows, then restore into the new `$MODPATH`.
- Only create runtime config from `.example` files when no preserved user config exists.
- Do not package real runtime config files in releases. Package `.example` files and let install scripts create runtime files.
- Cleanup should run after a package has been successfully deployed, so a partial failure does not remove the previous working deployment.
- Boot-time deployment should avoid force-stopping apps; install and manual Action redeploy flows may force-stop successfully deployed packages when enabled.

Packaging and release:

- Magisk/Kitsune module zips need traditional `META-INF/com/google/android/updater-script` and `update-binary` entries for broad manager compatibility.
- Preserve Unix modes and symlinks in the zip. Frida Gadget selectors may be symlinks or tiny selector files.
- Validate release zips before publishing: no runtime configs anywhere in the archive, required `.example` files present, both ABI loaders present, and both Zygisk entry symbols exported.
- Use a new version/versionCode for every published fix. Do not reuse a tag after a broken GitHub release exists.
- Local `./build.sh` is for building a test zip; `release.py` owns version metadata, update JSON, release zip validation, and optional GitHub publishing.

Frida Gadget deployment:

- Loading Gadget from `/data/adb/modules` can break Gadget config discovery or hit SELinux restrictions.
- `/data/local/tmp` is not a reliable executable mapping location on modern Android.
- Deploy Gadget and `libgadget.config.so` into the target app native library directory so Gadget can discover its config next to the loaded library.
- Sync owner, group, permissions, and SELinux context from an existing native library when writing into `/data/app`.
- App updates may replace the native library directory, so users may need to run `action.sh` again after app updates.

## Important Lessons Learned

### Magisk/Kitsune ZIP Format

Kitsune Magisk required traditional flashable zip entries:

```text
META-INF/com/google/android/updater-script
META-INF/com/google/android/update-binary
```

Without them, the UI showed:

```text
Unzip error
```

The logcat clue was:

```text
FileNotFoundException: .../cache/flash/updater-script
```

The build script now creates a very plain zip through Python `zipfile`.

### `/data/adb/modules` Is Not App-Readable

Loading Gadget by fd from the module dir worked, but Frida tried to read:

```text
/data/adb/modules/<old-module-id>/libgadget.config.so
```

and failed with:

```text
Permission denied
```

Opening `/data/adb` permissions with `post-fs-data.sh` was rejected as too broad and unsafe.

Later, direct native config reads from zygote also hit SELinux denial on some devices. The fix is to read module-private config through Zygisk companion IPC instead of making app/zygote contexts open files under `/data/adb/modules`.

### `/data/local/tmp` Is Not Suitable For Executable Mapping

Trying to load:

```text
/data/local/tmp/libgadget.so
```

failed with:

```text
couldn't map ".../libgadget.so" segment 1: Permission denied
```

### Native Lib Directory Deployment

Copying Gadget and config to the target app native library directory allows Frida Gadget to discover config naturally. This is the only validated deployment method at the moment, so it is now implicit and no longer appears as a `targets.conf` field.

It is practical but not perfect:

- App updates may remove the files.
- Some systems may object to files written into `/data/app`.
- Metadata must be synchronized from existing native libraries.

## Current Names

Module metadata:

```text
id=zygisk_frida_gadget
name=Zygisk - Frida Gadget
description=Configurable Zygisk loader for Frida Gadget
```

Native module:

```text
zygiskfridagadget
```

Log tag:

```text
ZygiskFridaGadget
```

## Build

```bash
./build.sh
```

Current build script:

- Cleans old `module/obj` and `module/libs`.
- Builds `armeabi-v7a` and `arm64-v8a`.
- Packages `zygisk/armeabi-v7a.so` and `zygisk/arm64-v8a.so`.
- Packages deploy scripts, `.example` config templates, and Gadget files.
- Does not package real runtime config files:
  - `targets.conf`
  - `module.conf`
  - `libgadget.config.so`

## Release Procedure

Use `release.py`; do not hand-edit release metadata unless there is a specific reason.

Release metadata lives in:

```text
module.prop
update.json
CHANGELOG.md
```

For a normal release:

```bash
./release.py <version> <versionCode>
```

Example:

```bash
./release.py 0.1.2 3
```

This command:

- Updates `module.prop`:
  - `version`
  - `versionCode`
- Updates `update.json`:
  - `version`
  - `versionCode`
  - `zipUrl`
  - `changelog`
- Ensures `CHANGELOG.md` has a section for the version.
- Runs the deterministic build and writes `out/zygisk_frida_gadget.zip`.
- Validates the release zip before publishing.
- Uses only the matching `CHANGELOG.md` version section as GitHub release notes.

Before publishing:

1. Replace any generated TODO release notes in `CHANGELOG.md`.
2. Run the local pre-release check:

```bash
./check.sh
```

3. Commit and push `main`.
4. Publish the GitHub release:

```bash
./release.py <version> <versionCode> --publish
```

`--publish` requires:

- clean working tree
- local `HEAD` pushed to upstream
- `gh` installed and authenticated

The release script creates a tag named `v<version>` and uploads:

```text
out/zygisk_frida_gadget.zip
```

Development-only builds without Gadget binaries can use:

```bash
./release.py <version> <versionCode> --allow-missing-gadget
```

Do not use `--allow-missing-gadget` for official releases unless intentionally publishing a loader-only package.

## Useful Commands

Check deployed files:

```bash
adb shell su -c 'find /data/app -name "libgadget*.so" -ls'
adb shell su -c 'ls -lZ /data/app/*/lib/arm64/libgadget* 2>/dev/null'
```

Check loader logs:

```bash
adb shell su -c 'logcat -d -s ZygiskFridaGadget'
```

Check Frida/Gadget logs:

```bash
adb shell su -c 'logcat -d | grep -i -E "Frida|gadget|gum|GLib|Gio"'
```

Check port:

```bash
adb shell su -c 'ss -ltnp | grep 27042'
```

## Rename Note

The user will handle the local project directory rename separately.
