#!/usr/bin/env python3
import os
import shutil
import stat
import subprocess
import sys
import zipfile
from pathlib import Path


MODULE_ID = "zygisk_frida_gadget"
FIXED_TIME = (2020, 1, 1, 0, 0, 0)


def warn(message):
    print(f"Warning: {message}", file=sys.stderr)


def die(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def find_ndk_build():
    for env_name in ("ANDROID_NDK_HOME", "ANDROID_NDK_ROOT"):
        ndk_root = os.environ.get(env_name)
        if ndk_root:
            candidate = Path(ndk_root) / "ndk-build"
            if candidate.is_file() and os.access(candidate, os.X_OK):
                return candidate

    found = shutil.which("ndk-build")
    if found:
        return Path(found)

    die("ndk-build not found. Please set ANDROID_NDK_HOME or add ndk-build to PATH.")


def has_any(paths):
    return any(path.exists() or path.is_symlink() for path in paths)


def is_gadget_candidate(path):
    name = path.name
    return name == "libgadget.so" or name.startswith("libgadget-") or name.startswith("frida-gadget-")


def check_inputs(root_dir):
    gadget_paths = [
        *(path for path in root_dir.glob("gadget/arm64-v8a/*.so") if is_gadget_candidate(path)),
        *(path for path in root_dir.glob("gadget/armeabi-v7a/*.so") if is_gadget_candidate(path)),
        root_dir / "libgadget.so",
    ]
    config_paths = [
        root_dir / "libgadget.config.so",
        root_dir / "libgadget.config.so.example",
        root_dir / "gadget/arm64-v8a/libgadget.config.so",
        root_dir / "gadget/armeabi-v7a/libgadget.config.so",
    ]

    missing = []
    if not has_any(gadget_paths):
        missing.append("no Frida Gadget .so found; add gadget/<abi>/libgadget.so before install or redeploy")
    if not has_any(config_paths):
        missing.append("libgadget.config.so not found; deployment requires a root or ABI-specific Gadget config")

    strict = os.environ.get("STRICT_BUILD") == "1"
    for message in missing:
        if strict:
            die(message)
        warn(message)


def run(command, cwd=None):
    subprocess.run([str(arg) for arg in command], cwd=cwd, check=True)


def remove(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def copy_file(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst, follow_symlinks=False)


def chmod_tree(path):
    if not path.exists():
        return
    for root, dirs, files in os.walk(path):
        for name in dirs:
            os.chmod(Path(root) / name, 0o755)
        for name in files:
            os.chmod(Path(root) / name, 0o644)


def prepare_build(root_dir, build_dir, out_dir):
    for path in (build_dir, out_dir, root_dir / "module/obj", root_dir / "module/libs"):
        if path.exists() or path.is_symlink():
            remove(path)

    (build_dir / "zygisk").mkdir(parents=True, exist_ok=True)
    out_dir.mkdir(parents=True, exist_ok=True)


def build_native(root_dir, ndk_build):
    module_dir = root_dir / "module"
    run([ndk_build, "-C", module_dir, "clean"])
    run([
        ndk_build,
        "-C",
        module_dir,
        f"NDK_PROJECT_PATH={module_dir}",
        f"APP_BUILD_SCRIPT={module_dir / 'jni/Android.mk'}",
        f"NDK_APPLICATION_MK={module_dir / 'jni/Application.mk'}",
        f"APP_CPPFLAGS=-ffile-prefix-map={root_dir}=.",
    ])

    obj_dir = module_dir / "obj"
    if obj_dir.exists():
        for dep_file in obj_dir.rglob("*.d"):
            dep_file.unlink()


def stage_files(root_dir, build_dir):
    copies = [
        ("module/libs/armeabi-v7a/libzygiskfridagadget.so", "zygisk/armeabi-v7a.so"),
        ("module/libs/arm64-v8a/libzygiskfridagadget.so", "zygisk/arm64-v8a.so"),
        ("module.prop", "module.prop"),
        ("customize.sh", "customize.sh"),
        ("service.sh", "service.sh"),
        ("action.sh", "action.sh"),
        ("uninstall.sh", "uninstall.sh"),
        ("deploy_gadget.sh", "deploy_gadget.sh"),
        ("module.conf.example", "module.conf.example"),
        ("targets.conf.example", "targets.conf.example"),
        ("libgadget.config.so.example", "libgadget.config.so.example"),
        ("META-INF/com/google/android/updater-script", "META-INF/com/google/android/updater-script"),
        ("META-INF/com/google/android/update-binary", "META-INF/com/google/android/update-binary"),
    ]

    for src, dst in copies:
        copy_file(root_dir / src, build_dir / dst)

    gadget_dir = root_dir / "gadget"
    if gadget_dir.is_dir():
        shutil.copytree(gadget_dir, build_dir / "gadget", symlinks=True)

    for optional in ("libgadget.so", "libgadget.config.so"):
        src = root_dir / optional
        if src.exists() or src.is_symlink():
            copy_file(src, build_dir / optional)

    for name in ("module.prop", "module.conf.example", "targets.conf.example", "libgadget.config.so.example"):
        os.chmod(build_dir / name, 0o644)

    for name in ("customize.sh", "service.sh", "action.sh", "uninstall.sh", "deploy_gadget.sh"):
        os.chmod(build_dir / name, 0o755)

    os.chmod(build_dir / "zygisk/armeabi-v7a.so", 0o644)
    os.chmod(build_dir / "zygisk/arm64-v8a.so", 0o644)
    os.chmod(build_dir / "META-INF/com/google/android/updater-script", 0o644)
    os.chmod(build_dir / "META-INF/com/google/android/update-binary", 0o755)

    chmod_tree(build_dir / "gadget")
    for optional in ("libgadget.so", "libgadget.config.so"):
        path = build_dir / optional
        if path.exists() and not path.is_symlink():
            os.chmod(path, 0o644)


def zip_entries(build_dir):
    entries = [
        "META-INF/com/google/android/updater-script",
        "META-INF/com/google/android/update-binary",
        "module.prop",
        "customize.sh",
        "service.sh",
        "action.sh",
        "uninstall.sh",
        "deploy_gadget.sh",
        "module.conf.example",
        "targets.conf.example",
        "libgadget.config.so.example",
        "zygisk/armeabi-v7a.so",
        "zygisk/arm64-v8a.so",
    ]

    gadget_dir = build_dir / "gadget"
    if gadget_dir.exists():
        for root, dirs, files in os.walk(gadget_dir):
            dirs.sort()
            files.sort()
            for name in files:
                entries.append(str((Path(root) / name).relative_to(build_dir)))

    for optional in ("libgadget.so", "libgadget.config.so"):
        if (build_dir / optional).exists() or (build_dir / optional).is_symlink():
            entries.append(optional)

    return entries


def write_zip(build_dir, zip_path):
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_STORED) as zf:
        for arcname in zip_entries(build_dir):
            src_path = build_dir / arcname
            info = zipfile.ZipInfo(arcname, FIXED_TIME)
            info.create_system = 3
            info.create_version = 10
            info.extract_version = 10
            info.compress_type = zipfile.ZIP_STORED

            st = os.lstat(src_path)
            if stat.S_ISLNK(st.st_mode):
                info.external_attr = ((stat.S_IFLNK | 0o777) << 16)
                zf.writestr(info, os.readlink(src_path))
                continue

            mode = st.st_mode & 0o777
            info.external_attr = (mode << 16) | 0x20
            zf.writestr(info, src_path.read_bytes())

    with zipfile.ZipFile(zip_path, "r") as zf:
        bad = zf.testzip()
        if bad is not None:
            die(f"zip test failed at: {bad}")


def main():
    root_dir = Path(__file__).resolve().parent
    build_dir = root_dir / "build"
    out_dir = root_dir / "out"
    zip_path = out_dir / f"{MODULE_ID}.zip"

    ndk_build = find_ndk_build()
    check_inputs(root_dir)
    prepare_build(root_dir, build_dir, out_dir)
    build_native(root_dir, ndk_build)
    stage_files(root_dir, build_dir)
    write_zip(build_dir, zip_path)
    print(f"Output: {zip_path}")


if __name__ == "__main__":
    main()
