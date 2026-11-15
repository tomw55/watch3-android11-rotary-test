import runpy

check = runpy.run_path("check-discovery.py")
dump = """Event Hub State:
  Devices:
    9: tizen_detent
      Path: /dev/input/event8
      ConfigurationFile: /data/system/devices/idc/tizen_detent.idc
Input Reader State:
  Device 7: tizen_detent
    Rotary Encoder Input Mapper:
    Cursor Input Mapper:
Input Dispatcher State:
"""
assert check["eventhub_path"](dump) == ("/dev/input/event8", check["IDC"])
assert check["reader_device"](dump) == 7
assert check["reader_device"](dump.replace("Cursor Input Mapper:", "Other Input Mapper:")) is None
assert check["eventhub_path"](dump.replace("tizen_detent\n", "different_device\n", 1)) is None
print("PASS synthetic EventHub and InputReader discovery parser controls")
