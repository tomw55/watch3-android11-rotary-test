"""Select fscrypt v1 only for the fresh disposable QEMU /data filesystem."""
from pathlib import Path
import sys

def configure(text):
    result = []
    matches = 0
    for line in text.splitlines(keepends=True):
        fields = line.split()
        if fields and not fields[0].startswith("#") and len(fields) > 1 and fields[1] == "/data":
            if len(fields) != 5 or fields[0] != "/dev/block/vdc" or fields[2] != "ext4":
                raise ValueError("unexpected QEMU /data mount contract")
            flags = fields[4].split(",")
            encryption = [x for x in flags if x.startswith("fileencryption=")]
            if encryption != ["fileencryption=aes-256-xts:aes-256-cts"]:
                raise ValueError("unexpected or duplicate fileencryption option")
            old = encryption[0]
            line = line.replace(old, old + ":v1")
            matches += 1
        result.append(line)
    if matches != 1:
        raise ValueError("expected exactly one disposable /data entry")
    return "".join(result)

if __name__ == "__main__":
    path = Path(sys.argv[1])
    path.write_text(configure(path.read_text()))
