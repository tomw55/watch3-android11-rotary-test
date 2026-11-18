"""Require observed legacy key installation and a successful vdc command."""
import re
import sys
from pathlib import Path

def check(log):
    return {
        "legacy_keyring_selected": bool(re.search(
            r"Kernel doesn't support FS_IOC_ADD_ENCRYPTION_KEY.*Falling back to", log)),
        "legacy_key_added": bool(re.search(r"Added key \d+ .*to keyring", log)),
        "filecrypto_command_succeeded": bool(re.search(
            r"Service 'exec \d+ \(/system/bin/vdc --wait cryptfs enablefilecrypto\)'"
            r".*exited with status 0\b", log)),
        "no_filecrypto_failure": not bool(re.search(
            r"enablefilecrypto_failed|Failed to install fscrypt key|cryptfs enablefilecrypto Failed",
            log)),
    }

if __name__ == "__main__":
    results = check(Path(sys.argv[1]).read_text(errors="replace"))
    for name, passed in results.items():
        print(f"{'PASS' if passed else 'FAIL'} {name}")
    sys.exit(0 if all(results.values()) else 1)
