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
