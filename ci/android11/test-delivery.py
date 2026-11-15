#!/usr/bin/env python3
"""Assert one isolated API 30 guest's evdev-to-app rotary path."""
from pathlib import Path
import re
import subprocess as sp
import time

from importlib.util import module_from_spec, spec_from_file_location

spec = spec_from_file_location("discovery", Path(__file__).with_name("check-discovery.py"))
discovery = module_from_spec(spec)
spec.loader.exec_module(discovery)
EVIDENCE, IDC, NAME = discovery.EVIDENCE, discovery.IDC, discovery.NAME
adb_args, adb, save, poll = discovery.adb_args, discovery.adb, discovery.save, discovery.poll
eventhub_path, reader_device = discovery.eventhub_path, discovery.reader_device


def wheel_events(log, device_id):
    events = []
    for line in log.splitlines():
        fields = dict(re.findall(r"([\w]+)=([^\s]+)", line))
        if not (fields.get("device") == NAME and fields.get("deviceId") == str(device_id)
                and fields.get("source") == "0x400000"
                and fields.get("action") == "ACTION_SCROLL"):
            continue
        events.append((fields["view"], fields["viewFocus"], fields["windowFocus"],
                       int(fields["rotation"]), float(fields["AXIS_SCROLL"])))
    return events


def raw_frame(text):
    result = []
    for label, value in re.findall(
        r"\b(REL_WHEEL|REL_X|SYN_REPORT)\s+([a-fA-F0-9]{8})\b", text
    ):
        number = int(value, 16)
        result.append((label, number if number < 2**31 else number - 2**32))
    return result


def app_log():
    return adb("logcat", "-d", "-v", "threadtime", "-s", "Watch3Rotary:I", "*:S")


def exercise(generator, node, device_id, label, wheel, hall):
    expected = ([("REL_WHEEL", wheel)] if wheel else []) + [
        ("REL_X", hall), ("SYN_REPORT", 0)
    ]
    adb("logcat", "-c")
    collector = sp.Popen(adb_args("shell", "getevent", "-lt", "-c", str(len(expected)), node),
                         stdout=sp.PIPE, stderr=sp.STDOUT, text=True)
    try:
        time.sleep(.5)
        generator.stdin.write(label + "\n")
        generator.stdin.flush()
        raw, _ = collector.communicate(timeout=10)
        save(f"{label}-getevent.txt", raw)
        if collector.returncode or raw_frame(raw) != expected:
            raise RuntimeError(f"{label}: invalid raw frame: {raw!r}")
    finally:
        if collector.poll() is None:
            collector.kill()
            raw, _ = collector.communicate()
            save(f"{label}-getevent.txt", raw)
    try:
        if wheel:
            poll(f"{label} rotary delivery", lambda: wheel_events(app_log(), device_id), timeout=8)
            time.sleep(.5)
        else:
            time.sleep(2)
    finally:
        log = app_log()
        save(f"{label}-app.txt", log)
    wanted = [("fixture", "true", "true", 0, float(wheel))] if wheel else []
    seen = wheel_events(log, device_id)
    cursor = [line for line in log.splitlines()
              if re.search(rf"\bdeviceId={device_id}\b", line)
              and "device=tizen_detent " in line and "mapperClass=CURSOR " in line]
    save(f"{label}-cursor.txt", "\n".join(cursor) + "\n" if cursor else
         "No cursor event observed by app views; see InputReader mapper dump.\n")
    if seen != wanted:
        raise RuntimeError(f"{label}: expected {wanted!r}, observed {seen!r}")
    cursor_scroll = sum("action=ACTION_SCROLL " in line for line in cursor)
    with (EVIDENCE / "cases.txt").open("a", encoding="utf-8") as report:
        print(f"PASS {label}: raw={expected!r}, deviceId={device_id}, rotary={seen!r}, "
              f"app_cursor_scroll={cursor_scroll}, app_other_cursor={len(cursor) - cursor_scroll}",
              file=report)


def main():
    poll("preflight probe removal", lambda: not eventhub_path(adb("shell", "dumpsys", "input")))
    with (EVIDENCE / "generator.txt").open("w+", encoding="utf-8") as gen_log:
        generator = sp.Popen(adb_args("shell", "-T", "/data/local/tmp/rotary-uinput-ci"),
                             stdin=sp.PIPE, stdout=gen_log, stderr=sp.STDOUT, text=True)
        try:
            def registered():
                data = (EVIDENCE / "generator.txt").read_text()
                if generator.poll() is not None:
                    raise RuntimeError(f"uinput registration failed: {data.strip()}")
                return f"Registered {NAME}." in data

            poll("uinput open and create ioctls", registered)
            (EVIDENCE / "guest-uinput-result.txt").write_text(
                "PASS real guest uinput registration under enforcing SELinux\n")
            def classified():
                dump = adb("shell", "dumpsys", "input")
                save("input-classification.txt", dump)
                hub = eventhub_path(dump)
                device_id = reader_device(dump)
                if hub and hub[1] == IDC and device_id is not None:
                    return hub[0], device_id
                return None

            node, device_id = poll("selected data IDC and both input mappers", classified)
            caps = adb("shell", "getevent", "-lp", node)
            save("getevent-capabilities.txt", caps)
            for capability in ("REL_X", "REL_Y", "REL_WHEEL", r"(?:BTN_LEFT|BTN_MOUSE)"):
                if not re.search(r"\b" + capability + r"\b", caps):
                    raise RuntimeError(f"Guest evdev capability absent: {capability}")
            focus = poll("focused receiver at rotation 0", lambda: (
                log if "windowFocus=true viewFocus(fixture)=true viewFocus(decoy)=false rotation=0"
                in (log := app_log()) else None
            ))
            save("app-focus.txt", focus)
            for test in (("cw", 1, 5), ("ccw", -1, 6), ("x", 0, 5)):
                exercise(generator, node, device_id, *test)
            generator.stdin.write("quit\n")
            generator.stdin.flush()
            if generator.wait(timeout=10):
                raise RuntimeError("Generator teardown failed")
        finally:
            if generator.poll() is None:
                generator.terminate()
                generator.wait(timeout=5)
    save("rotary-result.txt", "PASS API 30 evdev → InputReader → focused app, both signs and REL_X-only control\n")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        save("rotary-result.txt", f"FAIL {error}\n")
        raise
