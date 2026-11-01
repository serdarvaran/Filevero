#!/usr/bin/env python3
"""Sign a Windows or Linux release file and write its update manifest (windows-update.json, linux-*-update.json).

The private key arrives in FILEVERO_UPDATE_ED_KEY exactly as `generate_keys -x` exports it (a base64 Ed25519
seed). It is checked against the public key baked into both apps, so a wrong secret fails the release instead of
publishing updates that every installed copy would reject.
"""

import base64
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
# PKCS#8 header for a raw 32-byte Ed25519 private key (RFC 8410).
PKCS8_PREFIX = bytes.fromhex("302e020100300506032b657004220420")


def configured_public_key():
    with (ROOT / "Configuration/Updates.public.plist").open("rb") as stream:
        mac = plistlib.load(stream)["PublicEDKey"]
    source = (ROOT / "windows/Filevero.Core/PublicUpdates.cs").read_text(encoding="utf-8")
    windows = re.search(r'PublicKey="([^"]*)"', source).group(1)
    if mac != windows:
        raise ValueError("The macOS and Windows apps embed different update keys")
    return mac


def openssl(*arguments):
    return subprocess.run(["openssl", *arguments], check=True, capture_output=True).stdout


def sign(archive, version, url, output):
    seed = base64.b64decode(os.environ.get("FILEVERO_UPDATE_ED_KEY", "").strip(), validate=True)
    if len(seed) != 32:
        raise ValueError("FILEVERO_UPDATE_ED_KEY must be the base64 Ed25519 key exported by generate_keys -x")
    with tempfile.TemporaryDirectory() as work:
        key = Path(work, "key.der")
        key.touch(mode=0o600)
        key.write_bytes(PKCS8_PREFIX + seed)
        public = openssl("pkey", "-inform", "DER", "-in", str(key), "-pubout", "-outform", "DER")
        if base64.b64encode(public[-32:]).decode() != configured_public_key():
            raise ValueError("FILEVERO_UPDATE_ED_KEY does not match the public key built into Filevero")
        Path(work, "public.der").write_bytes(public)
        signature = Path(work, "signature")
        common = ["-keyform", "DER", "-rawin", "-in", str(archive)]
        openssl("pkeyutl", "-sign", "-inkey", str(key), *common, "-out", str(signature))
        openssl("pkeyutl", "-verify", "-pubin", "-inkey", str(Path(work, "public.der")), *common, "-sigfile", str(signature))
        manifest = {
            "version": version,
            "url": url,
            "length": Path(archive).stat().st_size,
            "edSignature": base64.b64encode(signature.read_bytes()).decode(),
        }
    Path(output).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit("Usage: sign-windows-update.py ARCHIVE VERSION URL OUTPUT_JSON")
    try:
        sign(*sys.argv[1:])
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
