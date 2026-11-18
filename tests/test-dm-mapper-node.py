#!/usr/bin/env python3
"""Host control-flow tests of the actual helper; no device nodes are created."""
from pathlib import Path
import subprocess
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "scripts/dm-default-key-gates.sh"
TEXT = SOURCE.read_text()
HELPER = TEXT[TEXT.index("ensure_mapper_node() ("):TEXT.index("\nbacking=")]
STUBS = r"""
created=0
dmsetup() {
  case "$*" in
    *major*) printf '%s\n' "$MAJOR" ;;
    *minor*) printf '%s\n' "$MINOR" ;;
    *) return 99 ;;
  esac
}
mknod() {
  printf 'MKNOD %s\n' "$*"
  [ "$*" = "-m 600 /dev/mapper/$NAME b $MAJOR $MINOR" ] || return 98
  if [ "$MODE" = creation-failure ]; then return 1; fi
  created=1
}
stat() {
  case "$*" in
    *%t*) printf '%s\n' "$NODE_MAJOR" ;;
    *%T*) printf '%s\n' "$NODE_MINOR" ;;
    *) return 97 ;;
  esac
}
[() {
  if builtin test "$1" = "!"; then shift; ! [ "$@"; return; fi
  case "$1" in
    -e) builtin test "$MODE" != missing && builtin test "$MODE" != creation-failure; return ;;
    -L) builtin test "$MODE" = dangling; return ;;
    -b) builtin test "$MODE" = block || builtin test "$MODE" = mismatch ||
        builtin test "$created" = 1; return ;;
  esac
  builtin [ "$@"
}
"""

class MapperNodeTests(unittest.TestCase):
    def run_case(self, mode, *, name="dk_test", major="253", minor="0",
                 node_major="fd", node_minor="0"):
        script = "set -eu\n" + STUBS + "\n" + HELPER + "\nensure_mapper_node \"$NAME\"\n"
        import os
        env = dict(os.environ, MODE=mode, NAME=name, MAJOR=major, MINOR=minor,
                   NODE_MAJOR=node_major, NODE_MINOR=node_minor)
        return subprocess.run(["bash", "-c", script], env=env,
                              text=True, capture_output=True)

    def test_missing_nodes_created_for_all_targets(self):
        for name in ("dk_test", "dk_err_backing", "dk_err_test"):
            with self.subTest(name=name):
                r = self.run_case("missing", name=name)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn("MKNOD -m 600 /dev/mapper/" + name, r.stdout)
                self.assertIn("PASS mapper node:", r.stdout)

    def test_existing_block_device_preserved(self):
        r = self.run_case("block")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("MKNOD", r.stdout)

    def test_rejects_invalid_nodes_without_replacing(self):
        for mode in ("regular", "dangling", "mismatch"):
            r = self.run_case(mode, node_minor="1")
            self.assertNotEqual(r.returncode, 0)
            self.assertNotIn("MKNOD", r.stdout)

    def test_creation_failure_propagates(self):
        self.assertNotEqual(self.run_case("creation-failure").returncode, 0)

    def test_invalid_kernel_numbers_rejected(self):
        for value in ("", "253x"):
            r = self.run_case("missing", major=value)
            self.assertNotEqual(r.returncode, 0)
            self.assertNotIn("MKNOD", r.stdout)

    def test_unexpected_name_rejected(self):
        self.assertNotEqual(self.run_case("missing", name="userdata").returncode, 0)

if __name__ == "__main__":
    unittest.main()
