#!/usr/bin/env bash
# Generates Flutter's standard macOS host and attaches ExifTool read/write bridge.
# Run on macOS with Flutter and Xcode installed.
set -euo pipefail
cd "$(dirname "$0")/.."

flutter create --project-name exif_date_sync --org dev.exifdatesync --platforms=macos .

python3 - <<'PY'
from pathlib import Path
import re
import subprocess

main=Path('macos/Runner/MainFlutterWindow.swift')
bridge=Path('macos/ExifCaptureTime.swift').read_text() + '\n' + Path('macos/ExifToolMtimeSync.swift').read_text() + '\n' + Path('macos/ExifToolMacBridge.swift').read_text()
source=main.read_text()
if 'import QuickLookThumbnailing' not in source:
    source='import QuickLookThumbnailing\n'+source
begin='// BEGIN EXIF DATE SYNC GENERATED SOURCES'
end='// END EXIF DATE SYNC GENERATED SOURCES'
anchor='class MainFlutterWindow: NSWindow {'
if 'private var exifDateSyncBridge' not in source:
    assert anchor in source, 'Flutter macOS Runner template changed'
    source=source.replace(anchor, anchor+'\n  private var exifDateSyncBridge: ExifToolMacBridge?')
    plugin='    RegisterGeneratedPlugins(registry: flutterViewController)'
    assert plugin in source, 'Flutter macOS plugin registration template changed'
    source=source.replace(
        plugin, plugin+'\n    exifDateSyncBridge = ExifToolMacBridge(controller: flutterViewController)'
    )
else:
    # Upgrade old generated hosts only if their appended sources are unchanged.
    # Refuse to overwrite unknown custom content.
    if begin in source:
        assert source.count(begin) == 1 and source.count(end) == 1, 'Invalid generated source markers'
        start=source.index(begin)
        finish=source.index(end, start)+len(end)
        source=source[:start]+source[finish:].lstrip('\n')
    else:
        paths=['macos/ExifCaptureTime.swift', 'macos/ExifToolMtimeSync.swift', 'macos/ExifToolMacBridge.swift']
        old=subprocess.run(['git', 'show', 'HEAD:'+paths[0]], capture_output=True, text=True)
        candidates=[bridge]
        if old.returncode == 0:
            try:
                candidates.append('\n'.join(subprocess.check_output(['git', 'show', 'HEAD:'+p], text=True) for p in paths))
            except subprocess.CalledProcessError:
                pass
        for candidate in candidates:
            suffix='\n\n'+candidate.rstrip()+'\n'
            if source.endswith(suffix):
                source=source[:-len(suffix)]
                break
        else:
            raise SystemExit('Generated Mac host has unknown changes; preserve it and regenerate separately')
if 'self.setContentSize(NSSize(width: 1120, height: 720))' not in source:
    frame='    self.setFrame(windowFrame, display: true)'
    assert frame in source, 'Flutter macOS window template changed'
    source=source.replace(frame, frame+'\n    self.setContentSize(NSSize(width: 1120, height: 720))\n    self.center()')
source=source.rstrip()+'\n\n'+begin+'\n'+bridge.rstrip()+'\n'+end+'\n'
main.write_text(source)

# Personal sideload/development configuration only. Mac App Store support is
# intentionally out of scope; external Homebrew ExifTool is not bundled.
for name in ['DebugProfile.entitlements','Release.entitlements']:
    path=Path('macos/Runner')/name
    entitlements=path.read_text()
    expression=r'(<key>com\.apple\.security\.app-sandbox</key>\s*)<true\s*/>'
    edited, count = re.subn(expression, r'\1<false/>', entitlements)
    assert count == 1 or '<key>com.apple.security.app-sandbox</key>' in entitlements and '<false/>' in entitlements, (
        f'Cannot locate sandbox setting in {path}; check the generated runner'
    )
    if count == 1:
        path.write_text(edited)
PY

flutter pub get
