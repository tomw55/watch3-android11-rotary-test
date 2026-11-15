#!/usr/bin/env python3
"""Confirm EventHub selects the IDC on an event-free guest probe."""
import os
from pathlib import Path
import re
import subprocess as sp
import time

EVIDENCE = Path("evidence")
IDC = "/data/system/devices/idc/tizen_detent.idc"
NAME = "tizen_detent"


def adb_args(*args):
    return ["adb", "-s", os.environ["CI_SERIAL"], *args]


def adb(*args):
    return sp.check_output(adb_args(*args), text=True, timeout=20)


def save(name, text):
    (EVIDENCE / name).write_text(text, encoding="utf-8")


def poll(label, test, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = test()
        if result:
            return result
        time.sleep(.25)
    raise RuntimeError(f"Timed out waiting for {label}")


def eventhub_path(dump):
    blocks = re.split(r"(?m)^    (?=-?\d+: )", dump.split("Input Reader State:")[0])
    for block in blocks:
        if re.match(r"-?\d+: tizen_detent\s*\n", block):
            path = re.search(r"(?m)^\s+Path: (/dev/input/event\d+)\s*$", block)
            info = re.search(r"(?m)^\s+ConfigurationFile: (\S+)$", block)
            if path:
                return path[1], info[1] if info else ""
    return None


def reader_device(dump):
    reader = dump.partition("Input Reader State:")[2].split("Input Dispatcher State:")[0]
    blocks = re.split(r"(?m)^  (?=Device -?\d+: )", reader)
    for block in blocks:
        head = re.match(r"Device (\d+): tizen_detent\s*\n", block)
        if head and all(mapper in block for mapper in
                        ("Rotary Encoder Input Mapper:", "Cursor Input Mapper:")):
            return int(head[1])
    return None


def main():
    with (EVIDENCE / "uinput-probe.txt").open("w", encoding="utf-8") as probe_log:
        probe = sp.Popen(adb_args("shell", "-T", "/data/local/tmp/uinput-probe"),
                        stdin=sp.PIPE, stdout=probe_log, stderr=sp.STDOUT, text=True)
        try:
            def created():
                text = (EVIDENCE / "uinput-probe.txt").read_text(encoding="utf-8")
                if probe.poll() is not None:
                    raise RuntimeError(f"Guest uinput probe exited: {text.strip()}")
                return "CREATE tizen_detent OK" in text

            poll("guest uinput open and create under enforcing SELinux", created)

            def discovered():
                dump = adb("shell", "dumpsys", "input")
                save("input-while-probe-open.txt", dump)
                hub = eventhub_path(dump)
                device_id = reader_device(dump)
                return hub[0] if hub and hub[1] == IDC and device_id is not None else None

            node = poll("EventHub selecting the staged IDC and both InputReader mappers", discovered)
            caps = adb("shell", "getevent", "-lp", node)
            save("probe-getevent.txt", caps)
            for bit in ("REL_X", "REL_Y", "REL_WHEEL", r"(?:BTN_LEFT|BTN_MOUSE)"):
                if not re.search(r"\b" + bit + r"\b", caps):
                    raise RuntimeError(f"Missing guest evdev capability: {bit}")
            probe.stdin.write("q\n")
            probe.stdin.flush()
            if probe.wait(timeout=10):
                raise RuntimeError("Guest uinput probe teardown failed")
        finally:
            if probe.poll() is None:
                probe.terminate()
                try:
                    probe.wait(timeout=3)
                except sp.TimeoutExpired:
                    probe.kill()
                    probe.wait()


if __name__ == "__main__":
    main()
