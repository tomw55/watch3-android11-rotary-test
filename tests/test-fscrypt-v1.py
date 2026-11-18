import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1] / "ci/arm64-reference"
def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
fstab = load("fscrypt-v1-fstab")
report = load("check-filecrypto")

class Tests(unittest.TestCase):
    entry = "/dev/block/vdc /data ext4 noatime wait,fileencryption=aes-256-xts:aes-256-cts,keydirectory=/metadata/vold/metadata_encryption\n"
    def test_only_file_policy_changed(self):
        before = "# header\n" + self.entry + "vendor /vendor ext4 ro wait,logical\n"
        after = fstab.configure(before)
        self.assertEqual(after.replace(":aes-256-cts:v1", ":aes-256-cts"), before)
    def test_unexpected_contract_rejected(self):
        for text in ("# empty\n", self.entry * 2,
                     self.entry.replace("vdc", "vdd"),
                     self.entry.replace("aes-256-cts", "aes-256-cts:v2")):
            with self.assertRaises(ValueError):
                fstab.configure(text)
    def test_acceptance_needs_all_evidence(self):
        lines = [
            "Kernel doesn't support FS_IOC_ADD_ENCRYPTION_KEY. Falling back to session keyring",
            "Added key 12 (ext4:test) to keyring 3 in process 132",
            "init: Service 'exec 5 (/system/bin/vdc --wait cryptfs enablefilecrypto)' (pid 201) exited with status 0",
        ]
        self.assertTrue(all(report.check("\n".join(lines)).values()))
        for omitted in range(3):
            self.assertFalse(all(report.check("\n".join(lines[:omitted]+lines[omitted+1:])).values()))
        self.assertFalse(all(report.check("\n".join(lines)+"\nenablefilecrypto_failed").values()))
    def test_empty_log_fails(self):
        self.assertFalse(all(report.check("").values()))

if __name__ == "__main__":
    unittest.main()
