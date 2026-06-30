#!/usr/bin/env python3
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


REPO = "leolovenet/Zygisk-FridaGadget"
MODULE_ID = "zygisk_frida_gadget"
RUNTIME_CONFIGS = {
    "targets.conf",
    "module.conf",
    "libgadget.config.so",
}
EXAMPLE_CONFIGS = {
    "targets.conf.example",
    "module.conf.example",
    "libgadget.config.so.example",
}


def die(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def run(command, cwd, env=None):
    print("+ " + " ".join(str(part) for part in command))
    subprocess.run([str(part) for part in command], cwd=cwd, env=env, check=True)


def capture(command, cwd):
    return subprocess.check_output([str(part) for part in command], cwd=cwd, text=True).strip()


def normalize_version(version):
    version = version[1:] if version.startswith("v") else version
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}(?:[-+][0-9A-Za-z.-]+)?", version):
        die(f"invalid version: {version}")
    return version


def release_zip_name(version):
    return f"{MODULE_ID}-v{version}.zip"


def update_module_prop(path, version, version_code):
    lines = path.read_text().splitlines()
    keys = {"version": False, "versionCode": False}
    result = []

    for line in lines:
        if line.startswith("version="):
            result.append(f"version={version}")
            keys["version"] = True
        elif line.startswith("versionCode="):
            result.append(f"versionCode={version_code}")
            keys["versionCode"] = True
        else:
            result.append(line)

    if not all(keys.values()):
        missing = ", ".join(key for key, found in keys.items() if not found)
        die(f"module.prop missing required keys: {missing}")

    path.write_text("\n".join(result) + "\n")


def update_json(path, version, version_code, repo):
    tag = f"v{version}"
    metadata = {
        "version": version,
        "versionCode": version_code,
        "zipUrl": f"https://github.com/{repo}/releases/download/{tag}/{release_zip_name(version)}",
        "changelog": f"https://raw.githubusercontent.com/{repo}/main/CHANGELOG.md",
    }
    path.write_text(json.dumps(metadata, indent=2) + "\n")


def ensure_changelog(path, version):
    text = path.read_text() if path.exists() else "# Changelog\n"
    heading = f"## {version}"
    if heading not in text:
        if not text.endswith("\n"):
            text += "\n"
        text = text.replace("# Changelog\n", f"# Changelog\n\n{heading}\n\n- TODO: add release notes.\n", 1)
        path.write_text(text)


def extract_changelog_section(path, version):
    text = path.read_text()
    heading = f"## {version}"
    match = re.search(rf"^##\s+{re.escape(version)}\s*$", text, re.MULTILINE)
    if match is None:
        die(f"CHANGELOG.md missing section: {heading}")

    start = match.end()
    next_match = re.search(r"^##\s+", text[start:], re.MULTILINE)
    end = start + next_match.start() if next_match else len(text)
    section = text[start:end].strip()
    if not section:
        die(f"CHANGELOG.md section is empty: {heading}")
    if "TODO" in section:
        die(f"CHANGELOG.md section still contains TODO: {heading}")
    return section + "\n"


def is_runtime_config_name(name):
    return (
        name in RUNTIME_CONFIGS
        or (name.startswith("libgadget-") and name.endswith(".config.so"))
    )


def validate_release_zip(zip_path):
    if not zip_path.is_file():
        die(f"release zip not found: {zip_path}")

    with zipfile.ZipFile(zip_path, "r") as zf:
        bad = zf.testzip()
        if bad is not None:
            die(f"release zip test failed at: {bad}")

        names = set(zf.namelist())

    forbidden = sorted(name for name in names if is_runtime_config_name(Path(name).name))
    if forbidden:
        die("release zip contains runtime config files: " + ", ".join(forbidden))

    missing = sorted(name for name in EXAMPLE_CONFIGS if name not in names)
    if missing:
        die("release zip missing example config files: " + ", ".join(missing))

    for name in ("zygisk/armeabi-v7a.so", "zygisk/arm64-v8a.so"):
        if name not in names:
            die(f"release zip missing native loader: {name}")


def has_uncommitted_changes(cwd):
    return bool(capture(["git", "status", "--porcelain"], cwd))


def require_clean_publish_state(cwd):
    if has_uncommitted_changes(cwd):
        die("working tree has uncommitted changes; commit and push metadata before publishing")

    upstream = capture(["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], cwd)
    local = capture(["git", "rev-parse", "HEAD"], cwd)
    remote = capture(["git", "rev-parse", upstream], cwd)
    if local != remote:
        die(f"HEAD is not pushed to {upstream}; push before publishing")


def build(root_dir, strict):
    env = os.environ.copy()
    if strict:
        env["STRICT_BUILD"] = "1"
    run([sys.executable, root_dir / "build.py"], root_dir, env=env)


def prepare_release_asset(root_dir, version):
    zip_path = root_dir / "out" / f"{MODULE_ID}.zip"
    release_path = root_dir / "out" / release_zip_name(version)
    if not zip_path.is_file():
        die(f"release zip not found: {zip_path}")
    shutil.copy2(zip_path, release_path)
    return release_path


def publish(root_dir, repo, version):
    gh = shutil.which("gh")
    if gh is None:
        die("gh not found; install GitHub CLI before publishing")

    tag = f"v{version}"
    zip_path = root_dir / "out" / release_zip_name(version)
    if not zip_path.is_file():
        die(f"release zip not found: {zip_path}")

    notes = extract_changelog_section(root_dir / "CHANGELOG.md", version)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as tmp:
        tmp.write(notes)
        notes_path = Path(tmp.name)

    try:
        run([
            gh,
            "release",
            "create",
            tag,
            zip_path,
            "--repo",
            repo,
            "--target",
            "main",
            "--title",
            tag,
            "--notes-file",
            notes_path,
        ], root_dir)
    finally:
        notes_path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description="Prepare and optionally publish a Magisk module release.")
    parser.add_argument("version", help="release version, for example 0.1.1 or v0.1.1")
    parser.add_argument("version_code", type=int, help="integer Magisk versionCode")
    parser.add_argument("--repo", default=REPO, help=f"GitHub repository, default: {REPO}")
    parser.add_argument("--publish", action="store_true", help="create GitHub release and upload the built zip")
    parser.add_argument("--allow-missing-gadget", action="store_true", help="do not require Gadget binaries during build")
    args = parser.parse_args()

    root_dir = Path(__file__).resolve().parent
    version = normalize_version(args.version)

    update_module_prop(root_dir / "module.prop", version, args.version_code)
    update_json(root_dir / "update.json", version, args.version_code, args.repo)
    ensure_changelog(root_dir / "CHANGELOG.md", version)

    if args.publish:
        require_clean_publish_state(root_dir)

    build(root_dir, strict=not args.allow_missing_gadget)
    release_zip_path = prepare_release_asset(root_dir, version)
    validate_release_zip(release_zip_path)

    if args.publish:
        publish(root_dir, args.repo, version)

    print(f"Release metadata prepared for v{version}.")


if __name__ == "__main__":
    main()
