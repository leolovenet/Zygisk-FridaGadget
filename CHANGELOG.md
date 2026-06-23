# Changelog

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
