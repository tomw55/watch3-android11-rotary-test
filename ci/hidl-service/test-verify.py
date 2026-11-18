#!/usr/bin/env python3
"""Synthetic verifier tests; these are not Binder or Android runtime tests."""
import importlib.util
import pathlib
spec = importlib.util.spec_from_file_location('verify', pathlib.Path(__file__).with_name('verify-serial.py'))
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
text = '''Linux version 4.9.59
PASS fixture SELinux policy loaded and readable bytes=3631 enforcing=1
PASS HIDL transport baseline
HIDL INIT manager=24 server=30
PASS HIDL fixture registered server=30 instance=watch3.fixture
HIDL CLIENT pid=32 server=30 manager=24 remote=1
'''
for i in range(32):
    text += f'HIDL SERVER create id={i+1} caller=32 server=30 bytes=8\nPASS HIDL lifecycle sequence={i} token={i+1} server=30\n'
for n in (0, 7, 8, 9):
    text += f'PASS HIDL invalid-token bytes={n}\n'
text += 'PASS HIDL typed lifecycle and negative controls\nPASS registered HIDL service gate\n'
assert v.verify(text) == (32, 30, 24)
mutants = [text.replace('sequence=10 token=11', 'sequence=10 token=99'),
           text.replace('caller=32', 'caller=31', 1),
           text.replace('pid=32 server=30', 'pid=30 server=30'),
           text.replace('PASS HIDL invalid-token bytes=7', 'REMOVED'),
           text.replace('PASS HIDL lifecycle sequence=31 token=32 server=30', ''),
           text + 'FAIL synthetic\n']
for mutant in mutants:
    try:
        v.verify(mutant)
    except ValueError:
        pass
    else:
        raise AssertionError('bad synthetic log accepted')
print('PASS synthetic verifier positive plus six negative controls; runtime NOT RUN')
