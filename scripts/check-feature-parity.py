#!/usr/bin/env python3
"""Fail if the Windows embedded catalog differs from the native Swift contract, or Linux lacks a Windows counterpart."""

import json, pathlib, re
from app_catalog import app_catalog

root = pathlib.Path(__file__).resolve().parents[1]
app = app_catalog()
expected = {
    'conversionMatrix': app['sharedConversionMatrix'],
    'singleTools': app['singleTools'],
    'multipleTools': app['multipleTools'],
    'toolNames': app['toolNames'],
}
actual = json.loads((root / 'Resources/FeatureCatalog.json').read_text())
for name, value in expected.items():
    if actual.get(name) != value:
        raise SystemExit(
            f'{name}: Windows and macOS catalogs diverged. Update the shared contract and corresponding engines/tests together.'
        )
print(f'PASS matching catalogs: {len(actual["conversionMatrix"])} input formats, {len(actual["toolNames"])} tools')
# Runtime preview/metadata routing must agree too; matching menu catalogs alone
# would miss aliases such as M4V and AAC.
windows = (root / 'windows/Filevero.Core/FeatureCatalog.cs').read_text()
aliases = app['extensionAliases']
mac_only_inputs = set(app['conversionMatrix']) - set(app['sharedConversionMatrix'])
for category in ['image', 'video', 'audio', 'archive']:
    win = re.search(r'bool Is' + category.capitalize() + r'\(string path\)=>new\[\]\{([^}]+)\}', windows)
    if not win:
        raise SystemExit(f'{category}: Windows category declaration could not be verified')
    expected_category = {aliases.get(ext, ext) for ext in app['categoryExtensions'][category]} - mac_only_inputs
    windows_category = set(re.findall(r'"([a-z0-9]+)"', win[1]))
    if expected_category != windows_category:
        raise SystemExit(
            f'{category}: Windows runtime routing differs from Mac: {expected_category ^ windows_category}'
        )
print('PASS matching image/video/audio/archive preview categories and aliases')
# Every Windows source has a Linux counterpart, so a feature added to Windows cannot silently miss Linux: the same file
# name in windows/Filevero.Linux, a shared Filevero.Core file, or the counterpart named here.
LINUX_COUNTERPARTS = {
    'App.xaml': 'App.axaml',
    'ChoiceTextConverter': 'L10n',
    'ClipboardPaster': 'ClipboardService',
    'DesktopGeometry': 'WheelWindow',
    'DragPayload': 'ClipboardImport',
    'GlobalUsings': 'Compat',
    'ImageCompositions': 'RasterEngine',
    'ImageCompression': 'RasterEngine',
    'ImageEngine': 'RasterEngine',
    'Localization': 'L10n',
    'MainWindow.MediaMetadata': 'MainWindow.Background',
    'MainWindow.Settings': 'MainWindow.Desktop',
    'NativePdf': 'PdfRaster',
    'OfficeRuntime': 'LinuxOfficeRuntime',
    'PrimaryMouseButton': 'DesktopBridge',
    'TrayIconRecovery': 'TrayHost',
    'WebMediaOptions': 'MainWindow.Web',
    'WindowsOcr': 'TesseractOcr',
    'WorkflowRunner': 'PortableWorkflowRunner',
}
# Windows-only plumbing and the Windows UI test suite (Linux: Platform/SmokeTests.cs, Tests/GnomeExtension, Tests/LinuxDesktop).
WINDOWS_ONLY = {'NativeExceptionTrace', 'DesktopCapture', 'DesktopInput', 'UIAudit', 'UIAuditScenes', 'ParitySmokeTests'}
windows_sources = {p.stem for p in (root / 'windows/Filevero.Windows').glob('*.cs')}
linux_sources = {p.stem for p in (root / 'windows/Filevero.Linux').rglob('*.cs') if not {'obj', 'bin'} & set(p.parts)}
core_sources = {p.stem for p in (root / 'windows/Filevero.Core').glob('*.cs')}
unmatched = sorted(
    name
    for name in windows_sources - linux_sources - core_sources - WINDOWS_ONLY
    if not re.search(r'(Checks|Smoke)$', name) and LINUX_COUNTERPARTS.get(name) not in linux_sources | core_sources
)
if unmatched:
    raise SystemExit(f'Windows sources without a Linux counterpart: {unmatched}')
print(f'PASS every Windows source has a Linux counterpart ({len(windows_sources)} files)')
