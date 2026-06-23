#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

cd "$ROOT_DIR"

bash -n build.sh customize.sh deploy_gadget.sh action.sh service.sh uninstall.sh check.sh
"$PYTHON_BIN" -m py_compile build.py release.py
"$PYTHON_BIN" -m json.tool update.json >/dev/null

./build.sh

"$PYTHON_BIN" - <<'PY'
import zipfile
from pathlib import Path

zip_path = Path("out/zygisk_frida_gadget.zip")
required = {
    "targets.conf.example",
    "module.conf.example",
    "libgadget.config.so.example",
    "zygisk/armeabi-v7a.so",
    "zygisk/arm64-v8a.so",
}
forbidden = {
    "targets.conf",
    "module.conf",
    "libgadget.config.so",
}

with zipfile.ZipFile(zip_path) as z:
    bad = z.testzip()
    if bad is not None:
        raise SystemExit(f"zip test failed at: {bad}")
    names = set(z.namelist())

missing = sorted(required - names)
if missing:
    raise SystemExit("zip missing required files: " + ", ".join(missing))

present = sorted(name for name in names if Path(name).name in forbidden)
if present:
    raise SystemExit("zip contains runtime config files: " + ", ".join(present))
PY

for abi in arm64-v8a armeabi-v7a; do
  so="module/libs/$abi/libzygiskfridagadget.so"
  nm -D "$so" | grep -q 'zygisk_module_entry'
  nm -D "$so" | grep -q 'zygisk_companion_entry'
done

echo "All checks passed."
