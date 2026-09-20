"""Run on Linux: python3 src/InstallerLinux/tests/test_build_line_endings.py."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


installer = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    checkout = root / "InstallerLinux"
    shutil.copytree(installer, checkout)
    # Reproduce a Windows checkout, including extensionless startup scripts.
    for path in (checkout / "rootfs").rglob("*"):
        if path.is_file():
            path.write_bytes(path.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))
    docker = root / "docker"
    docker.write_text('''#!/bin/sh
set -eu
[ "$1" = build ] || exit 0
for context do :; done
if grep -r "$(printf '\\r')" "$context/rootfs"; then
    echo "CRLF leaked into the boot overlay" >&2
    exit 1
fi
test -s "$context/rootfs/etc/inittab"
test -x "$context/rootfs/usr/local/bin/haos-installer-autostart"
echo "Windows checkout overlay is LF-only"
''')
    docker.chmod(0o755)
    result = subprocess.run(
        ["bash", str(checkout / "build/build-installer-image.sh"), str(root / "out")],
        env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}"},
        capture_output=True, text=True, check=True,
    )
    assert "Windows checkout overlay is LF-only" in result.stdout
print("Build line-ending regression check passed.")
