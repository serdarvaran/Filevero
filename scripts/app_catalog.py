"""The app's own catalog export, so build scripts never parse Swift source."""

import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]


def app_catalog():
    # Build errors go straight to the terminal; only the JSON is captured.
    output = subprocess.run(
        ['swift', 'run', '--quiet', 'filevero-cli', 'catalog'], cwd=ROOT, check=True, stdout=subprocess.PIPE, text=True
    ).stdout
    return json.loads(output)
