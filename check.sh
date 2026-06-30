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

def is_runtime_config_name(name):
    return (
        name in forbidden
        or (name.startswith("libgadget-") and name.endswith(".config.so"))
    )

with zipfile.ZipFile(zip_path) as z:
    bad = z.testzip()
    if bad is not None:
        raise SystemExit(f"zip test failed at: {bad}")
    names = set(z.namelist())

missing = sorted(required - names)
if missing:
    raise SystemExit("zip missing required files: " + ", ".join(missing))

present = sorted(name for name in names if is_runtime_config_name(Path(name).name))
if present:
    raise SystemExit("zip contains runtime config files: " + ", ".join(present))
PY

"$PYTHON_BIN" - <<'PY'
import tempfile
import zipfile
from contextlib import redirect_stderr
from io import StringIO
from pathlib import Path
from release import validate_release_zip

forbidden_entries = [
    "libgadget.config.so",
    "libgadget-remote.config.so",
    "gadget/arm64-v8a/libgadget.config.so",
    "gadget/armeabi-v7a/libgadget-remote.config.so",
]
required_entries = [
    "targets.conf.example",
    "module.conf.example",
    "libgadget.config.so.example",
    "zygisk/armeabi-v7a.so",
    "zygisk/arm64-v8a.so",
]

with tempfile.TemporaryDirectory() as tmp:
    for forbidden in forbidden_entries:
        zip_path = Path(tmp) / (forbidden.replace("/", "_") + ".zip")
        with zipfile.ZipFile(zip_path, "w") as z:
            for name in required_entries:
                z.writestr(name, b"ok")
            z.writestr(forbidden, b"runtime config")
        stderr = StringIO()
        try:
            with redirect_stderr(stderr):
                validate_release_zip(zip_path)
        except SystemExit as exc:
            if exc.code == 0 or "runtime config files" not in stderr.getvalue():
                raise
        else:
            raise SystemExit(f"release validator allowed runtime config: {forbidden}")
PY

for abi in arm64-v8a armeabi-v7a; do
  so="module/libs/$abi/libzygiskfridagadget.so"
  nm -D "$so" | grep -q 'zygisk_module_entry'
  nm -D "$so" | grep -q 'zygisk_companion_entry'
done

echo "All checks passed."
