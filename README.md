# Zygisk - Frida Gadget

Config-driven Zygisk module for loading Frida Gadget into selected Android app processes.

Sample target examples use `com.example.app`, but targets are configured in `targets.conf` and do not require C++ changes.

## Use Case

This module is intended as a Frida Gadget based alternative when `frida-server` cannot run reliably on a device, for example because of vendor restrictions, process hiding, executable mapping policy, or other runtime constraints.

Instead of starting a global `frida-server`, the module uses Zygisk to enter selected app processes and loads Frida Gadget only for configured targets.

## Responsible Use

This project is intended for authorized security research, debugging, compatibility analysis, and defensive testing on devices and applications you own or have explicit permission to assess.

Do not use this project to access, modify, instrument, or monitor applications, systems, or data without authorization.

## Install

Requirements:

- Magisk 27001 / Kitsune Magisk with Zygisk enabled
- A device/app ABI supported by this module: `arm64-v8a` or `armeabi-v7a`

Use the prebuilt module zip from this project's GitHub Releases page when you only want to install and use the module:

```text
https://github.com/leolovenet/Zygisk-FridaGadget/releases
```

Copy the zip to the phone, for example:

```bash
adb push zygisk_frida_gadget.zip /sdcard/Download/
```

Before installing, open Magisk settings and make sure Zygisk is enabled. If you just enabled it, reboot once before testing modules that depend on Zygisk.

Install it in Magisk:

```text
Magisk -> Modules -> Install from storage -> zygisk_frida_gadget.zip
```

Reboot after installation. The module creates editable runtime config files under:

```text
/data/adb/modules/zygisk_frida_gadget/
```

## Quick Start

Edit `targets.conf` in the module directory:

```text
# package|process|match|abi|profile
com.example.app|com.example.app|exact|auto|default
com.example.app|com.example.app:remote|exact|auto|remote
```

Non-default profiles such as `remote` need a matching `libgadget-<profile>.config.so`, for example `libgadget-remote.config.so`.

Edit `libgadget.config.so` if you need to change Gadget's listener address, port, or behavior. The shipped default listens on all IPv4 interfaces on port `27042` and lets the app continue immediately:

```json
{
  "interaction": {
    "type": "listen",
    "address": "0.0.0.0",
    "port": 27042,
    "on_port_conflict": "pick-next",
    "on_load": "resume"
  }
}
```

After changing targets, Gadget files, or Gadget config, redeploy:

```bash
adb shell su -c '/data/adb/modules/zygisk_frida_gadget/action.sh'
```

Start the target app again. By default, install and manual redeploy flows force-stop successfully deployed packages so the next launch enters the new Zygisk/Gadget path.

## Connect With Frida

Watch module logs:

```bash
adb logcat -s ZygiskFridaGadget
adb logcat | grep -i Frida
```

Check whether Gadget is listening:

```bash
adb shell su -c 'netstat -lntp 2>/dev/null | grep 27042 || ss -lntp 2>/dev/null | grep 27042'
```

If the phone and computer can reach each other over the network, connect to the device IP:

```bash
frida -H <device-ip>:27042 -n Gadget
```

For USB-only testing, forward the port first:

```bash
adb forward tcp:27042 tcp:27042
frida -H 127.0.0.1:27042 -n Gadget
```

Frida Gadget's Listen interaction exposes a frida-server compatible endpoint, but the visible process name is always `Gadget`, and the visible app identifier is always `re.frida.Gadget`. Use `-n Gadget` even though the real Android package is different. See the official Frida Gadget docs: [frida.re/docs/gadget](https://frida.re/docs/gadget/).

Deployment logs are written to:

```text
/data/adb/modules/zygisk_frida_gadget/deploy.log
```

## Early Startup Hooks

If you need to hook code that runs immediately when the app starts, use a dedicated profile with `on_load=wait`. This blocks the target process until Frida attaches, so start the attach loop before launching the app.

For early startup hooks, use a fixed port and fail on conflict:

```json
{
  "interaction": {
    "type": "listen",
    "address": "0.0.0.0",
    "port": 27042,
    "on_port_conflict": "fail",
    "on_load": "wait"
  }
}
```

`on_port_conflict=pick-next` is convenient for casual attach, but it is not recommended here because the actual listening port may change. Early startup hooks need the computer side to connect to the exact Gadget endpoint as soon as it appears. Before launching the target app, make sure no previous Gadget instance is still listening on that port.

Use a small POSIX `sh` loop to retry Frida itself:

```sh
#!/bin/sh
HOST="${1:-127.0.0.1:27042}"
SCRIPT="${2:-hooks.js}"

while :; do
  frida -H "$HOST" -n Gadget -l "$SCRIPT" && exit 0
  status=$?
  [ "$status" -eq 130 ] && exit "$status"
  sleep 0.1
done
```

For USB-only testing:

```sh
adb forward tcp:27042 tcp:27042
./attach-gadget.sh 127.0.0.1:27042 hooks.js
```

Keep critical hook registration as early as possible in your script. Slow setup, delayed async work, or heavy logic before installing hooks can miss early lifecycle calls.

## Configure Targets

`targets.conf` format:

```text
package|process|match|abi|profile
```

Fields:

```text
package: target Android package name, used for deployment under /data/app
process: optional target process name, compared with args->nice_name from Zygisk
match: optional process-name matching mode, defaults to exact
abi: optional Gadget ABI selection, defaults to auto
profile: optional payload/config profile, defaults to default
```

If `process` is omitted or empty, it defaults to the package name. These forms are equivalent:

```text
com.example.app
com.example.app|
com.example.app|com.example.app
com.example.app|com.example.app|exact
com.example.app|com.example.app|exact|auto
com.example.app|com.example.app|exact|auto|default
```

Supported `match` values:

```text
exact
prefix
suffix
contains
```

For most apps, start with `exact` to avoid injecting child, sandbox, or service processes unintentionally. Use `prefix`, `suffix`, or `contains` only when you intentionally want to cover multiple related processes.

Supported `abi` values:

```text
auto
arm64-v8a
armeabi-v7a
```

With `abi=auto`, deployment copies the arm64 Gadget to `lib/arm64` when that directory exists, and the arm Gadget to `lib/arm` when that directory exists. At runtime, the native loader chooses the deployed payload path for the current process bitness.

`default` profile uses:

```text
libgadget.so
libgadget.config.so
```

Any other profile name uses:

```text
libgadget-<profile>.so
libgadget-<profile>.config.so
```

Profile names may contain only letters, numbers, `.`, `_`, and `-`; they may not start with `.`, contain `..`, or exceed 96 characters. This lets one package use different Gadget configs for different processes:

```text
com.example.app|com.example.app|exact|auto|main
com.example.app|com.example.app:remote|exact|auto|remote
```

## Gadget Config Profiles

Place the default Gadget config at the module root:

```text
libgadget.config.so
```

You may also place an ABI-specific config next to the Gadget binary:

```text
gadget/arm64-v8a/libgadget.config.so
gadget/armeabi-v7a/libgadget.config.so
```

ABI-specific config wins over the root config.

For non-default target profiles, provide a profile-specific config:

```text
libgadget-remote.config.so
gadget/arm64-v8a/libgadget-remote.config.so
gadget/armeabi-v7a/libgadget-remote.config.so
```

Non-default profiles do not fall back to `libgadget.config.so`; deployment is skipped for that target if the matching profile config is missing.

During module updates or local reinstalls, existing root, ABI-specific, and profile-specific Gadget config files are preserved.

## Redeploy Without Reboot

The native loader reads `targets.conf` when each app process starts. If you only change process matching and Gadget has already been deployed for that package, restart the target app.

If you add a new package, change Gadget files, or need to redeploy into the target app native lib directory, run:

```bash
adb shell su -c '/data/adb/modules/zygisk_frida_gadget/action.sh'
```

Some Magisk managers show an Action button for modules that provide `action.sh`. If the button is available, tapping it runs the same redeploy flow and prints `deploy.log`. If your Magisk/Kitsune build only shows Remove, use the adb command above.

To disable automatic force-stop after install or manual redeploy, edit `module.conf`:

```text
force_stop=0
```

Boot-time deployment from `service.sh` always skips force-stop to avoid killing apps silently during startup.

## Debug Logging

Edit `module.conf`:

```text
debug=0
force_stop=1
```

Set `debug=1` to log non-target process checks and other verbose matching details.

Important logs are always emitted:

- target matched
- payload path resolved
- config read failures
- start loading payload
- dlopen success/failure

## Verify Deployment

```bash
adb shell su -c 'find /data/app -name "libgadget*.so" -ls'
adb shell su -c 'ls -lZ /data/app/*/lib/arm64/libgadget* 2>/dev/null'
```

## How It Works

1. `customize.sh` runs during module installation.
2. `service.sh` runs after boot and retries deployment.
3. `deploy_gadget.sh` reads `targets.conf`.
4. For each target, it locates the app install directory with `pm path`.
5. It copies Frida Gadget and config into the target app native library directory, such as:

```text
/data/app/<package-random>/lib/arm64/libgadget.so
/data/app/<package-random>/lib/arm64/libgadget.config.so
/data/app/<package-random>/lib/arm64/libgadget-remote.so
/data/app/<package-random>/lib/arm64/libgadget-remote.config.so
```

6. It syncs owner, group, mode, and SELinux context from an existing `.so` in that directory.
7. The Zygisk module reads `targets.conf` via the companion process, matches the current process name, resolves the current app install directory from `/proc/self/maps` or `/data/app`, checks whether Gadget is already mapped in the process, and calls:

```cpp
dlopen(payload_path, RTLD_NOW | RTLD_GLOBAL);
```

Because Gadget is loaded from the app native library directory, Frida can read the matching `.config.so` file from the same directory without opening `/data/adb` to app processes.

If the process already has the configured payload path, `libgadget.so`, or a versioned `libgadget-*.so` mapped, the loader logs `payload already loaded, skip dlopen` and does not load Gadget again.

## Zygisk Companion

The native loader needs `targets.conf` and `module.conf` when an app process starts. On some devices, zygote/app contexts cannot read files under `/data/adb/modules` directly because of SELinux policy.

To avoid broadening permissions, the module reads these module-private config files through the Zygisk companion process. The app/zygote side connects to the companion, requests one allowed config file, and receives the file contents over Zygisk IPC.

Only these files are served by the companion:

```text
targets.conf
module.conf
```

Frida Gadget itself is still loaded from the target app native library directory under `/data/app`, and the matching config is deployed next to it so Gadget can read its own config normally.

## Build From Source

Build requirements:

- Android NDK r26+
- `ndk-build`
- Python 3

Configure NDK on macOS:

```bash
export ANDROID_NDK_HOME=/path/to/android-ndk-r26d
export PATH="$ANDROID_NDK_HOME:$PATH"
```

Download Android Gadget from the official Frida releases page:

```text
https://github.com/frida/frida/releases
```

Use the ABI files matching your target device/app:

```text
frida-gadget-<version>-android-arm64.so.xz
frida-gadget-<version>-android-arm.so.xz
```

After decompressing, keep the version in the source filename if you like:

```text
gadget/
  arm64-v8a/
    .gitkeep
    libgadget-17.15.3.so
    libgadget.so -> libgadget-17.15.3.so
  armeabi-v7a/
    .gitkeep
    libgadget-17.15.3.so
    libgadget.so -> libgadget-17.15.3.so
libgadget.config.so
```

The source filename may also be plain:

```text
gadget/arm64-v8a/libgadget.so
gadget/armeabi-v7a/libgadget.so
```

Selection rules for each ABI directory:

```text
1. If libgadget.so is a symlink, its target is used.
2. If libgadget.so is a small selector file, its contents are treated as the selected Gadget path.
3. If libgadget.so is a regular Gadget file, that file is used.
4. If libgadget.so is missing and exactly one versioned Gadget file exists, deployment creates libgadget.so as a symlink to it.
5. If multiple versioned Gadget files exist and libgadget.so is missing, deployment is skipped for that ABI and deploy.log records the ambiguity.
```

Build:

```bash
./build.sh
```

Output:

```text
out/zygisk_frida_gadget.zip
```

`build.sh` is a small compatibility wrapper around `build.py`. Python is used for deterministic zip packaging and preserving Unix file modes/symlinks without depending on a platform-specific `zip` command.

By default, missing Gadget binaries or config files produce warnings so you can build the loader first and add Gadget later. For release builds, use strict mode:

```bash
STRICT_BUILD=1 ./build.sh
```

To run the full local pre-release check, use:

```bash
./check.sh
```

## Release

Use `release.py` to keep version metadata and release packaging in sync:

```bash
./release.py <version> <versionCode>
```

This updates:

```text
module.prop
update.json
CHANGELOG.md
```

and runs the deterministic build. Review the changes, commit them, and push `main`. Then publish the GitHub release and upload the built module zip:

```bash
./release.py <version> <versionCode> --publish
```

`release.py` validates the generated zip before publishing: runtime config files must stay out of the release package, `.example` config files must be present, and both Zygisk ABI loaders must be included. GitHub release notes are generated from the matching `CHANGELOG.md` version section.

Release builds use strict mode by default and require Gadget binaries/config to be present. For development-only packaging without Gadget binaries:

```bash
./release.py <version> <versionCode> --allow-missing-gadget
```

## Updates

Magisk-compatible module managers can check for updates when `module.prop` contains:

```text
updateJson=https://raw.githubusercontent.com/leolovenet/Zygisk-FridaGadget/main/update.json
```

The update metadata is published in `update.json` and points to the release zip attached to the matching GitHub release tag. When releasing a new version, update these values together:

```text
module.prop: version, versionCode
update.json: version, versionCode, zipUrl
CHANGELOG.md: release notes
```

Then build and upload `out/zygisk_frida_gadget.zip` to a GitHub release whose tag matches the `zipUrl`.

User-edited runtime config files are intentionally not replaced by automatic updates:

```text
targets.conf
module.conf
libgadget.config.so
libgadget-*.config.so
gadget/arm64-v8a/libgadget.config.so
gadget/arm64-v8a/libgadget-*.config.so
gadget/armeabi-v7a/libgadget.config.so
gadget/armeabi-v7a/libgadget-*.config.so
```

New defaults are shipped as `.example` files. If you add new configuration options in a release, document them in the changelog so users can merge them into their existing configs if needed.

## Limitations

- The current deployment path is the target app native library directory under `/data/app`.
- App updates may replace the install directory, so run `action.sh` again after updating the target app.
- Only `arm64-v8a` and `armeabi-v7a` Gadget packages are handled by the current scripts.
- The module does not try to hide Frida artifacts; it only provides a practical Gadget loading path.

## Cleanup

Removing the Magisk module runs `uninstall.sh`, which removes deployed `libgadget.so`, `libgadget.config.so`, and profile-specific `libgadget-*` files from configured target app native lib directories.

## Safety Notes

The module deliberately avoids broadening `/data/adb` permissions; Gadget and config are deployed into the target app native lib directory instead.
