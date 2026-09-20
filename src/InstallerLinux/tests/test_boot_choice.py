"""Run on Linux: python3 src/InstallerLinux/tests/test_boot_choice.py."""
import os
from pathlib import Path
import pty
import select
import time


source = (Path(__file__).parents[1] / "scripts/installer.sh").read_text()
prompt = source.split("prompt_standalone_legacy_bios() {", 1)[1].split("\nmain() {", 1)[0]


def check(key=b"", *, configured=False, legacy=False, unattended=False):
    script = "\n".join([
        "set -eu",
        f"read_installer_config() {{ {'true' if configured else 'false'}; }}",
        f"installer_unattended_enabled() {{ {'true' if unattended else 'false'}; }}",
        'installer_legacy_bios_enabled() { [ "$HAOS_LEGACY_BIOS" = 1 ]; }',
        "log_info() { :; }; log_warn() { :; }",
        f"export HAOS_LEGACY_BIOS={int(legacy)}",
        "prompt_standalone_legacy_bios() {" + prompt,
        "prompt_standalone_legacy_bios",
        'printf "RESULT=%s\\n" "$HAOS_LEGACY_BIOS"',
    ])
    started = time.monotonic()
    pid, fd = pty.fork()
    if pid == 0:
        os.execlp("bash", "bash", "-c", script)
    output = b""
    try:
        while time.monotonic() - started < 10:
            if not select.select([fd], [], [], 0.1)[0]:
                continue
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            output += chunk
            if key and b"Press U or L:" in output:
                os.write(fd, key)
                key = b""
        else:
            os.kill(pid, 9)
            raise AssertionError("Prompt did not finish within 10 seconds")
    finally:
        os.close(fd)
        _, status = os.waitpid(pid, 0)
    assert status == 0, output
    return output, time.monotonic() - started


output, elapsed = check()
assert b"RESULT=0" in output and 4.5 <= elapsed < 7, (output, elapsed)
for key, expected in [(b"l", 1), (b"L", 1), (b"u", 0), (b"U", 0), (b"\n", 0)]:
    output, elapsed = check(key)
    assert f"RESULT={expected}".encode() in output and elapsed < 2, output
for options in [dict(configured=True), dict(configured=True, legacy=True),
                dict(unattended=True), dict(legacy=True)]:
    output, elapsed = check(**options)
    assert b"Installation boot support" not in output and elapsed < 2, output
    assert f"RESULT={int(options.get('legacy', False))}".encode() in output, output
print("Boot choice checks passed: timeout, UEFI, legacy BIOS, and configured USB bypass.")
