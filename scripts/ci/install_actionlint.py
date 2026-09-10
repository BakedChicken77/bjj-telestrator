"""Install the checksum-pinned Linux x64 workflow validator."""

import hashlib
import io
import tarfile
import urllib.request
from pathlib import Path

VERSION = "1.7.12"
SHA256 = "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"


def main() -> None:
    url = f"https://github.com/rhysd/actionlint/releases/download/v{VERSION}/actionlint_{VERSION}_linux_amd64.tar.gz"
    with urllib.request.urlopen(url, timeout=90) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise SystemExit("actionlint download checksum mismatch")
    output = Path(".ci-artifacts/tools/actionlint")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        member = archive.getmember("actionlint")
        if not member.isfile():
            raise SystemExit("Unexpected actionlint archive")
        stream = archive.extractfile(member)
        assert stream is not None
        output.write_bytes(stream.read())
    output.chmod(0o755)
    print(output)


if __name__ == "__main__":
    main()
