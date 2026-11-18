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
for number in (0, 1, 18, 47, 255):
    varied = dump.replace("/dev/input/event8", f"/dev/input/event{number}")
    assert check["eventhub_path"](varied)[0] == f"/dev/input/event{number}"
caps = "EV_REL REL_X REL_Y REL_WHEEL EV_KEY BTN_LEFT"
assert check["has_detent_capabilities"](caps)
assert check["has_detent_capabilities"](caps.replace("BTN_LEFT", "BTN_MOUSE"))
for missing in ("REL_X", "REL_Y", "REL_WHEEL", "BTN_LEFT"):
    assert not check["has_detent_capabilities"](caps.replace(missing, ""))
assert check["parse_identity"]("0006\n0001\n0001\n0100\n") == (6, 1, 1, 256)
for bad in ("0006 0001 0001", "0006 0001 0001 nope", "0006 0001 0001 10000"):
    try: check["parse_identity"](bad)
    except ValueError: pass
    else: raise AssertionError("Malformed identity accepted")
print("PASS synthetic EventHub and InputReader discovery parser controls")
