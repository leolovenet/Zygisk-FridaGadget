# Changelog

## 17.15.4-1

- Rebuild with Frida Gadget 17.15.4.

## 17.15.3-1

- Rebuild with Frida Gadget 17.15.3.

## 0.1.5

- Add optional `profile` field to `targets.conf` for per-process Gadget payload/config profiles.
- Deploy non-default profiles as `libgadget-<profile>.so` with matching `libgadget-<profile>.config.so`.
- Preserve profile-specific Gadget configs during module updates and local reinstalls.
- Remove profile-specific deployed Gadget files during uninstall and unused ABI cleanup.
- Improve manual redeploy output and profile validation diagnostics.

## 0.1.4

- Route module-private config reads exclusively through the Zygisk companion process.
- Remove app/zygote-side `getModuleDir/openat` fallback reads to avoid SELinux denials.
- Fix `target config not found: targets.conf` on devices that block zygote/app access to `/data/adb/modules`.
- Preserve runtime config files from the live module directory during local reinstall/update flows.
- Preserve ABI-specific Gadget config files from `gadget/<abi>/libgadget.config.so`.
- Keep the companion config surface limited to `targets.conf` and `module.conf`.

## 0.1.3

- Read native module configuration through Zygisk companion IPC.
- Avoid direct `/data/adb/modules` reads from zygote/app contexts.
- Keep `getModuleDir/openat` config reads as a fallback path.
- Document the companion-based config read path.

## 0.1.2

- Add optional automatic force-stop after successful Gadget deployment.
- Enable `force_stop=1` by default for install and manual Action redeploy flows.
- Skip force-stop during boot-time `service.sh` deployment.
- Document how to disable automatic force-stop with `force_stop=0`.

## 0.1.1

- Preserve user configuration files during module updates.
- Generate runtime config files from tracked `.example` files on first install.
- Add release automation for metadata sync, packaging, and GitHub release publishing.

## 0.1.0

- Initial public release.
- Add config-driven process targeting through `targets.conf`.
- Load Frida Gadget from target app native library directories.
- Support `arm64-v8a` and `armeabi-v7a` module loaders.
- Add deployment, redeployment, cleanup, and deterministic build tooling.
