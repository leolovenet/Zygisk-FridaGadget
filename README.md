# Zygisk - Frida Gadget

Config-driven Zygisk module for injecting Frida Gadget into selected Android app processes.

The default sample target is `com.example.app`, but targets are configured in `targets.conf` and do not require C++ changes.

## Use Case

This module is intended as a Frida Gadget based alternative when `frida-server` cannot run reliably on a device, for example because of vendor restrictions, process hiding, executable mapping policy, or other runtime constraints.

Instead of starting a global `frida-server`, the module uses Zygisk to enter selected app processes and loads Frida Gadget only for configured targets.

## Responsible Use

This project is intended for authorized security research, debugging, compatibility analysis, and defensive testing on devices and applications you own or have explicit permission to assess.

Do not use this project to access, modify, instrument, or monitor applications, systems, or data without authorization.

## Runtime Requirements

- Magisk 27001 / Kitsune Magisk with Zygisk enabled

## Build Requirements

- Android NDK r26+
- `ndk-build`
- Python 3

## Configure NDK On macOS

```bash
export ANDROID_NDK_HOME=/path/to/android-ndk-r26d
export PATH="$ANDROID_NDK_HOME:$PATH"
```

## Download Frida Gadget

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

This is the recommended layout for releases because multiple Gadget versions may coexist while `libgadget.so` selects the version to deploy. During deployment, the module resolves the selected real file and copies it into the target app native lib directory as:

```text
libgadget.so
```

Keeping the deployed filename stable is intentional: Frida Gadget discovers `libgadget.config.so` next to the loaded `libgadget.so`.

The `.gitkeep` files only keep the ABI directories present after cloning the repository. They are not used at runtime.

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

The selector file is intended for short relative names such as `libgadget-17.15.3.so`, or an absolute path if you really need one. Files larger than 256 bytes are treated as real `.so` files, not selectors. This keeps the selector path flexible while avoiding accidental interpretation of binary files.

To switch versions, update the symlink and run `action.sh` again:

```bash
adb shell su -c 'cd /data/adb/modules/zygisk_frida_gadget/gadget/arm64-v8a && ln -sf libgadget-17.15.3.so libgadget.so'
adb shell su -c '/data/adb/modules/zygisk_frida_gadget/action.sh'
```

## Gadget Config

Place Gadget config at the project root:

```text
libgadget.config.so
```

You may also place an ABI-specific config next to the Gadget binary:

```text
gadget/arm64-v8a/libgadget.config.so
gadget/armeabi-v7a/libgadget.config.so
```

ABI-specific config wins over the root config.

The repository tracks `libgadget.config.so.example` as the default template. During installation, `customize.sh` creates `libgadget.config.so` from that template only when the real config file does not already exist.

## Configure Targets

Edit `targets.conf`:

```text
# package|process|match|abi
com.example.app|com.example.app|exact|auto
```

Fields:

```text
package: target Android package name, used for deployment under /data/app
process: optional target process name, compared with args->nice_name from Zygisk
match: optional process-name matching mode, defaults to exact
abi: optional Gadget ABI selection, defaults to auto
```

If `process` is omitted or empty, it defaults to the package name. These forms are equivalent:

```text
com.example.app
com.example.app|
com.example.app|com.example.app
com.example.app|com.example.app|exact
com.example.app|com.example.app|exact|auto
```

Supported `match` values:

```text
exact
prefix
suffix
contains
```

`match` controls how the configured `process` value is compared with the real process name:

```text
exact:    load only when process name is exactly equal
prefix:   load when process name starts with the configured value
suffix:   load when process name ends with the configured value
contains: load when process name contains the configured value
```

For most apps, start with `exact` to avoid injecting child, sandbox, or service processes unintentionally. Use `prefix`, `suffix`, or `contains` only when you intentionally want to cover multiple related processes.

Supported `abi` values:

```text
auto
arm64-v8a
armeabi-v7a
```

With `abi=auto`, deployment copies the arm64 Gadget to `lib/arm64` when that directory exists, and the arm Gadget to `lib/arm` when that directory exists.

At runtime, the native loader also chooses the deployed payload path for the current process bitness. A 64-bit process looks under `lib/arm64`, while a 32-bit process looks under `lib/arm`; both fall back to `lib` only when the ABI-specific directory does not provide `libgadget.so`.

The `abi` field is optional. If omitted, it defaults to `auto`:

```text
com.example.app|com.example.app|exact
```

The repository tracks `targets.conf.example` and `module.conf.example`. During installation, the module creates real runtime files from these examples only on first install:

```text
targets.conf
module.conf
libgadget.config.so
```

On module updates, existing runtime config files are preserved before the new zip is extracted and restored afterward.

## Debug Logging

Edit `module.conf`:

```text
debug=0
```

Set `debug=1` to log non-target process checks and other verbose matching details.

Important logs are always emitted:

- target matched
- payload path resolved
- start loading payload
- dlopen success/failure

## Build

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

## Release

Use `release.py` to keep version metadata and release packaging in sync:

```bash
./release.py 0.1.1 2
```

This updates:

```text
module.prop
update.json
CHANGELOG.md
```

and runs the deterministic build. Review the changes, commit them, and push `main`. Then publish the GitHub release and upload the built module zip:

```bash
./release.py 0.1.1 2 --publish
```

Release builds use strict mode by default and require Gadget binaries/config to be present. For development-only packaging without Gadget binaries:

```bash
./release.py 0.1.1 2 --allow-missing-gadget
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
```

New defaults are shipped as `.example` files. If you add new configuration options in a release, document them in the changelog so users can merge them into their existing configs if needed.

## Install

Install in Magisk:

```text
Magisk -> Modules -> Install from storage
```

Reboot after installation.

## Redeploy Without Reboot

The native loader reads `targets.conf` when each app process starts. If you only change process matching and Gadget has already been deployed for that package, force-stop and restart the target app.

If you add a new package, change Gadget files, or need to redeploy into the target app native lib directory, run:

```bash
adb shell su -c '/data/adb/modules/zygisk_frida_gadget/action.sh'
```

Some Magisk managers show an Action button for modules that provide `action.sh`. If the button is available, tapping it runs the same redeploy flow and prints `deploy.log`. If your Magisk/Kitsune build only shows Remove, use the adb command above.

Then force-stop and restart the target app:

```bash
adb shell am force-stop com.example.app
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
```

6. It syncs owner, group, mode, and SELinux context from an existing `.so` in that directory.
7. The Zygisk module reads `targets.conf`, matches the current process name, resolves the current app install directory from `/proc/self/maps` or `/data/app`, checks whether Gadget is already mapped in the process, and calls:

```cpp
dlopen(payload_path, RTLD_NOW | RTLD_GLOBAL);
```

Because Gadget is loaded from the app native library directory, Frida can read `libgadget.config.so` from the same directory without opening `/data/adb` to app processes.

If the process already has the configured payload path, `libgadget.so`, or a versioned `libgadget-*.so` mapped, the loader logs `payload already loaded, skip dlopen` and does not load Gadget again.

## Limitations

- The current deployment path is the target app native library directory under `/data/app`.
- App updates may replace the install directory, so run `action.sh` again after updating the target app.
- Only `arm64-v8a` and `armeabi-v7a` Gadget packages are handled by the current scripts.
- The module does not try to hide Frida artifacts; it only provides a practical Gadget loading path.

## Logs

```bash
adb logcat -s ZygiskFridaGadget
adb logcat | grep -i Frida
```

Deployment logs are written to:

```text
/data/adb/modules/zygisk_frida_gadget/deploy.log
```

## Verify Deployment

```bash
adb shell su -c 'find /data/app -name "libgadget*.so" -ls'
adb shell su -c 'ls -lZ /data/app/*/lib/arm64/libgadget* 2>/dev/null'
```

## Cleanup

Removing the Magisk module runs `uninstall.sh`, which removes deployed `libgadget.so` and `libgadget.config.so` from configured target app native lib directories.

## Safety Notes

The module deliberately avoids broadening `/data/adb` permissions; Gadget and config are deployed into the target app native lib directory instead.
