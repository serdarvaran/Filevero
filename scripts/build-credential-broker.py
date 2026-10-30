#!/usr/bin/env python3
"""Freeze, embed and verify the private update credential broker (XPC service).

The broker is built and signed once (--initialize) and then reused byte for byte,
so Keychain items it created stay accessible across app builds. The app pins its
certificate and SHA-256 seals in Info.plist (see CredentialBrokerClient.swift);
the broker pins the app's certificate in its compiled caller requirement.

  build-credential-broker.py               verify the frozen broker
  build-credential-broker.py --test        compile and run the fixtures (no Keychain, no signing)
  build-credential-broker.py --initialize  build, sign and freeze it once (refuses to replace)
  build-credential-broker.py --app APP     embed the frozen broker and its pins before signing APP
  build-credential-broker.py --verify-app APP

Signing mode and certificate SHA-1 come from FILEVERO_SIGNING_MODE / FILEVERO_SIGNING_IDENTITY,
exported by scripts/signing-configuration.sh. Never reads or prints a private key or token.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SERVICE = 'app.filevero.mac.credentials.v1'
CONFIG = ROOT / 'Configuration/CredentialBroker.json'
FROZEN = ROOT / 'local/CredentialBroker' / f'{SERVICE}.xpc'
PROTOCOL_SOURCE = ROOT / 'Sources/FileveroBrokerProtocol/UpdateCredentialBrokerProtocol.swift'
BROKER_SOURCE = ROOT / 'Sources/UpdateCredentialBroker/main.swift'
FIXTURE_SOURCE = ROOT / 'Tests/UpdateCredentialBrokerFixtures/CredentialBrokerFixtures.swift'
TARGET = 'arm64-apple-macos13.0'
MAX_FILES, MAX_FILE_SIZE = 256, 64 * 1024 * 1024
SIGNED_MODES = {'local', 'apple-development', 'developer-id'}


def fail(message):
    sys.exit(f'Credential broker: {message}')


def app_identifier():
    return plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())['CFBundleIdentifier']


def caller_requirement(certificate):
    return f'identifier "{app_identifier()}" and certificate leaf = H"{certificate}"'


def broker_requirement(certificate):
    return f'identifier "{SERVICE}" and certificate leaf = H"{certificate}"'


def signing_identity():
    mode = os.environ.get('FILEVERO_SIGNING_MODE', '')
    identity = os.environ.get('FILEVERO_SIGNING_IDENTITY', '')
    if mode not in SIGNED_MODES or not re.fullmatch(r'[0-9A-F]{40}', identity):
        fail('requires local, apple-development or developer-id signing with a pinned 40-hex certificate SHA-1.')
    return mode, identity


def file_hash(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_FILE_SIZE:
        fail(f'unexpected file in broker bundle: {path.name}')
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bundle_hash(bundle):
    """Mirror UpdateCredentialBrokerClient.computeBundleHash exactly."""
    rows = []
    for directory, folders, files in os.walk(bundle):
        for name in folders + files:
            path = Path(directory, name)
            if path.is_symlink():
                fail('broker bundle must not contain symbolic links.')
        for name in files:
            path = Path(directory, name)
            relative = str(path)[len(str(bundle)) + 1 :]
            if any(character in relative for character in '\0\n\\'):
                fail('broker bundle contains an unsupported file name.')
            rows.append((relative, path))
            if len(rows) > MAX_FILES:
                fail('broker bundle has too many files.')
    if not rows:
        fail('broker bundle is empty.')
    digest = b''.join(
        f'{relative}\0{path.lstat().st_mode & 0o7777:04o}\0{file_hash(path)}\n'.encode()
        for relative, path in sorted(rows)
    )
    return hashlib.sha256(digest).hexdigest()


def seals(bundle):
    executable = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())['CFBundleExecutable']
    return file_hash(bundle / 'Contents/MacOS' / executable), bundle_hash(bundle)


def codesign_requirement(path, requirement):
    result = subprocess.run(['codesign', '--verify', '--strict', '--test-requirement', '=' + requirement, str(path)])
    if result.returncode != 0:
        fail(f'{path.name} does not satisfy its pinned code requirement.')


def compile_swift(sources, output, *flags):
    subprocess.run(
        [
            'xcrun',
            'swiftc',
            '-O',
            '-parse-as-library',
            '-target',
            TARGET,
            *flags,
            '-file-prefix-map',
            f'{ROOT}=/filevero',
            *map(str, sources),
            '-o',
            str(output),
        ],
        check=True,
    )


def identity_source(directory, certificate):
    path = directory / 'CredentialBrokerBuildIdentity.swift'
    requirement = json.dumps(caller_requirement(certificate))
    path.write_text(f'enum CredentialBrokerBuildIdentity {{\n    static let callerRequirement = {requirement}\n}}\n')
    return path


def run_fixtures(certificate):
    with tempfile.TemporaryDirectory() as work:
        work = Path(work)
        runner = work / 'fixtures'
        compile_swift(
            [PROTOCOL_SOURCE, BROKER_SOURCE, FIXTURE_SOURCE, identity_source(work, certificate)],
            runner,
            '-D',
            'CREDENTIAL_BROKER_TESTS',
        )
        subprocess.run([str(runner)], check=True)


def load_config():
    _, identity = signing_identity()
    if not CONFIG.is_file() or not FROZEN.is_dir():
        fail(
            'the frozen broker is missing. Restore Configuration/CredentialBroker.json and '
            f'{FROZEN.relative_to(ROOT)} from your private backup, or review and run '
            'scripts/build-credential-broker.py --initialize once.'
        )
    config = json.loads(CONFIG.read_text())
    if config.get('service') != SERVICE or config.get('callerIdentifier') != app_identifier():
        fail('Configuration/CredentialBroker.json was made for a different service or app identifier.')
    if config.get('certificateSHA1') != identity:
        fail('the frozen broker is pinned to a different certificate than the app signing identity.')
    if seals(FROZEN) != (config.get('binarySHA256'), config.get('bundleSHA256')):
        fail('the frozen broker no longer matches its recorded seals.')
    codesign_requirement(FROZEN, broker_requirement(identity))
    return config


def initialize():
    mode, identity = signing_identity()
    if CONFIG.exists() or FROZEN.exists():
        fail('a frozen broker already exists; it is never replaced. Remove it only after a reviewed migration.')
    run_fixtures(identity)
    with tempfile.TemporaryDirectory() as work:
        work = Path(work)
        bundle = work / FROZEN.name
        (bundle / 'Contents/MacOS').mkdir(parents=True)
        compile_swift(
            [PROTOCOL_SOURCE, BROKER_SOURCE, identity_source(work, identity)], bundle / 'Contents/MacOS' / SERVICE
        )
        subprocess.run(['/usr/bin/strip', '-S', str(bundle / 'Contents/MacOS' / SERVICE)], check=True)
        info = {
            'CFBundleIdentifier': SERVICE,
            'CFBundleExecutable': SERVICE,
            'CFBundleName': SERVICE,
            'CFBundlePackageType': 'XPC!',
            'CFBundleInfoDictionaryVersion': '6.0',
            'CFBundleShortVersionString': '1',
            'CFBundleVersion': '1',
            'LSMinimumSystemVersion': '13.0',
            'CFBundleSupportedPlatforms': ['MacOSX'],
            'XPCService': {'ServiceType': 'Application', 'RunLoopType': 'dispatch_main'},
        }
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        options = (
            ['--options', 'runtime', '--timestamp']
            if mode == 'developer-id'
            else ['--options', '0', '--timestamp=none']
        )
        subprocess.run(['codesign', '--force', '--sign', identity, *options, str(bundle)], check=True)
        codesign_requirement(bundle, broker_requirement(identity))
        binary, sealed = seals(bundle)
        FROZEN.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['ditto', str(bundle), str(FROZEN)], check=True)
    config = {
        'service': SERVICE,
        'callerIdentifier': app_identifier(),
        'certificateSHA1': identity,
        'binarySHA256': binary,
        'bundleSHA256': sealed,
    }
    CONFIG.write_text(json.dumps(config, indent=2) + '\n')
    load_config()
    print(f'Froze {FROZEN.relative_to(ROOT)}; keep it and {CONFIG.relative_to(ROOT)} in a private backup.')


def embed(app):
    config = load_config()
    services = app / 'Contents/XPCServices'
    destination = services / FROZEN.name
    if destination.is_symlink() or services.is_symlink():
        fail('refusing a symbolic link in the app XPCServices folder.')
    if destination.exists():
        shutil.rmtree(destination)
    services.mkdir(parents=True, exist_ok=True)
    subprocess.run(['ditto', str(FROZEN), str(destination)], check=True)
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info.update(
        {
            'FileveroCredentialBrokerService': SERVICE,
            'FileveroCredentialBrokerCertificateSHA1': config['certificateSHA1'],
            'FileveroCredentialBrokerBinarySHA256': config['binarySHA256'],
            'FileveroCredentialBrokerBundleSHA256': config['bundleSHA256'],
        }
    )
    info_path.write_bytes(plistlib.dumps(info))


def verify_app(app):
    config = load_config()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    expected = {
        'FileveroCredentialBrokerService': SERVICE,
        'FileveroCredentialBrokerCertificateSHA1': config['certificateSHA1'],
        'FileveroCredentialBrokerBinarySHA256': config['binarySHA256'],
        'FileveroCredentialBrokerBundleSHA256': config['bundleSHA256'],
    }
    if any(info.get(key) != value for key, value in expected.items()):
        fail('app Info.plist pins do not match the frozen broker.')
    embedded = app / 'Contents/XPCServices' / FROZEN.name
    if seals(embedded) != (config['binarySHA256'], config['bundleSHA256']):
        fail('embedded broker differs from the frozen broker.')
    codesign_requirement(embedded, broker_requirement(config['certificateSHA1']))
    codesign_requirement(app, caller_requirement(config['certificateSHA1']))
    print('PASS credential broker: frozen seals, certificate pins and caller requirement match')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--test', action='store_true')
    group.add_argument('--initialize', action='store_true')
    group.add_argument('--app', type=Path)
    group.add_argument('--verify-app', type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.test:
            run_fixtures('0' * 40)
        elif arguments.initialize:
            initialize()
        elif arguments.app:
            embed(arguments.app.resolve())
        elif arguments.verify_app:
            verify_app(arguments.verify_app.resolve())
        else:
            load_config()
    except subprocess.CalledProcessError as error:
        fail(f'{Path(error.cmd[0]).name} failed with exit status {error.returncode}.')
    except (OSError, KeyError, ValueError, plistlib.InvalidFileException) as error:
        fail(f'{type(error).__name__}: {error}')


if __name__ == '__main__':
    main()
