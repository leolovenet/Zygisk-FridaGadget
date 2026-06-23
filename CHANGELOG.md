# Changelog

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
