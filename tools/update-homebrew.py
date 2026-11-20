"""Update the tap's Pixeldish cask from the latest published DMG."""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def update(cask):
    repo = "dappermint/pixeldish"
    release = json.loads(subprocess.check_output(["gh", "api", f"repos/{repo}/releases/latest"]))
    tag = release["tag_name"]
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError(f"unexpected release tag {tag!r}")
    version = tag[1:]
    filename = f"Pixeldish-{version}.dmg"
    asset, = [asset for asset in release["assets"] if asset["name"] == filename]
    with tempfile.TemporaryDirectory() as directory:
        subprocess.run(["gh", "release", "download", tag, "--repo", repo, "--pattern", filename,
                        "--dir", directory], check=True)
        digest = hashlib.sha256((Path(directory) / filename).read_bytes()).hexdigest()
    if asset["digest"] != f"sha256:{digest}":
        raise ValueError(f"checksum mismatch for {filename}")

    contents = cask.read_text()
    for key, value in (("version", version), ("sha256", digest)):
        contents, count = re.subn(rf'^  {key} "[^"]*"$', f'  {key} "{value}"', contents, flags=re.M)
        if count != 1:
            raise ValueError(f"expected one {key} in {cask}")
    cask.write_text(contents)
    print(f"Verified {filename}: {digest}")


if __name__ == "__main__":
    update(Path(sys.argv[1]))
