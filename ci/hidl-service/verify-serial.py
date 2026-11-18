#!/usr/bin/env python3
"""Require actual three-process HIDL token lifecycle evidence, not daemon liveness."""
import pathlib
import re
import sys


def require(ok, message):
    if not ok:
        raise ValueError(message)


def verify(serial):
    for marker in ('Linux version 4.9.59', 'PASS fixture SELinux policy loaded and readable',
                   'enforcing=1', 'PASS HIDL transport baseline',
                   'PASS HIDL typed lifecycle and negative controls', 'PASS registered HIDL service gate'):
        require(marker in serial, 'missing: ' + marker)
    require(not re.search(r'FAIL |Kernel panic|Call trace:', serial), 'guest failure')
    identities = re.findall(r'HIDL CLIENT pid=(\d+) server=(\d+) manager=(\d+) remote=1', serial)
    require(len(identities) == 1, 'missing/duplicate process identities')
    client, server, manager = map(int, identities[0])
    require(len({client, server, manager}) == 3 and min(client, server, manager) > 1, 'processes not distinct')
    require(re.findall(r'HIDL INIT manager=(\d+) server=(\d+)', serial) == [(str(manager), str(server))], 'init PID mismatch')
    require(re.findall(r'PASS HIDL fixture registered server=(\d+) instance=watch3.fixture', serial) == [str(server)], 'registration mismatch')
    replies = re.findall(r'PASS HIDL lifecycle sequence=(\d+) token=(\d+) server=(\d+)', serial)
    require(replies == [(str(i), str(i + 1), str(server)) for i in range(32)], 'missing/duplicate/out-of-order lifecycle')
    requests = re.findall(r'HIDL SERVER create id=(\d+) caller=(\d+) server=(\d+) bytes=(\d+)', serial)
    require(requests == [(str(i + 1), str(client), str(server), '8') for i in range(32)], 'server receipt/PID/token mismatch')
    require(re.findall(r'PASS HIDL invalid-token bytes=(\d+)', serial) == ['0', '7', '8', '9'], 'invalid-token controls missing')
    return client, server, manager


if __name__ == '__main__':
    ids = verify(pathlib.Path(sys.argv[1]).read_text())
    print('PASS registered HIDL evidence: 32 typed token lifecycles, invalid controls; client=%d server=%d manager=%d' % ids)
