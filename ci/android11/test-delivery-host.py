"""Exercise report parsers with synthetic AOSP-format text."""
import runpy

runner = runpy.run_path("test-delivery.py")
dump = """Event Hub State:
  Devices:
    3: Another device
      Path: /dev/input/event3
    9: tizen_detent
      Path: /dev/input/event8
      ConfigurationFile: /data/system/devices/idc/tizen_detent.idc
Input Reader State:
  Device 4: unrelated
    Rotary Encoder Input Mapper:
  Device 7: tizen_detent
    Rotary Encoder Input Mapper:
    Cursor Input Mapper:
Input Dispatcher State:
"""
assert runner["eventhub_path"](dump) == ("/dev/input/event8", runner["IDC"])
assert runner["reader_device"](dump) == 7
assert runner["reader_device"](dump.replace("    Rotary Encoder Input Mapper:\n    Cursor", "    Cursor")) is None
raw = """[    10.234] EV_REL REL_WHEEL ffffffff
[    10.234] EV_REL REL_X 00000006
[    10.234] EV_SYN SYN_REPORT 00000000
"""
assert runner["raw_frame"](raw) == [("REL_WHEEL", -1), ("REL_X", 6), ("SYN_REPORT", 0)]
event = ("Watch3Rotary: view=fixture mapperClass=ROTARY viewFocus=true windowFocus=true "
         "device=tizen_detent deviceId=7 source=0x400000 action=ACTION_SCROLL "
         "AXIS_SCROLL=-1.0 rotation=0")
noise = "\n".join([event.replace("deviceId=7", "deviceId=8"),
                    event.replace("source=0x400000", "source=0x2002"),
                    event.replace("ACTION_SCROLL", "ACTION_HOVER_MOVE")])
assert runner["wheel_events"](event + "\n" + noise, 7) == [("fixture", "true", "true", 0, -1.)]
print("PASS synthetic dump, frame, source and device-ID parser controls")

# The guest returned a cumulative log for CCW even after logcat -c.
# Its old unbounded selection found both the previous CW and current CCW.
prefix = "11-15 20:00:00.000    10    10 I Watch3Rotary: "
cw = event.replace("AXIS_SCROLL=-1.0", "AXIS_SCROLL=1.0")
ccw = event
cw_marker, ccw_marker, x_marker = ("ROTARY_CASE_cw_0", "ROTARY_CASE_ccw_1", "ROTARY_CASE_x_2")
cursor = (ccw.replace("view=fixture", "view=decoy")
          .replace("source=0x400000", "source=0x2002")
          .replace("mapperClass=ROTARY", "mapperClass=CURSOR")
          .replace("AXIS_SCROLL=-1.0", "AXIS_SCROLL=0.0 AXIS_VSCROLL=-1.0"))
case_log = runner["case_log"]
rotary = runner["wheel_events"]
wanted_ccw = [("fixture", "true", "true", 0, -1.0)]
cumulative = "\n".join((prefix + cw_marker, cw, prefix + ccw_marker, cursor, ccw)) + "\n"
assert rotary(cumulative, 7) == [("fixture", "true", "true", 0, 1.0), *wanted_ccw]
scoped = case_log(cumulative, ccw_marker)
assert rotary(scoped, 7) == wanted_ccw and cursor in scoped and cw not in scoped
assert rotary(case_log(cumulative + ccw + "\n", ccw_marker), 7) == wanted_ccw * 2
assert case_log(cumulative, x_marker) is None
assert rotary(case_log(cumulative + prefix + x_marker + "\n" + cursor, x_marker), 7) == []
print("PASS cumulative CW contamination, duplicate CCW, missing marker and REL_X isolation")
