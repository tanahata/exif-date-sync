#!/usr/bin/env bash
# Run after installing Flutter. Generates disposable Android project files,
# then installs the project's real Kotlin source and manifest permission.
set -euo pipefail
cd "$(dirname "$0")/.."
flutter create --project-name exif_date_sync --org dev.exifdatesync --platforms=android .
mkdir -p android/app/src/main/kotlin/dev/exifdatesync/exif_date_sync
mkdir -p android/app/src/main/kotlin/dev/exifdatesync
cp android/MainActivity.kt android/app/src/main/kotlin/dev/exifdatesync/exif_date_sync/MainActivity.kt
cp android/AndroidFileDateCore.kt android/CaptureTimeParser.kt android/AndroidFolderScanner.kt android/AndroidBatchWriter.kt android/app/src/main/kotlin/dev/exifdatesync/
python3 - <<'PY'
from pathlib import Path
manifest=Path('android/app/src/main/AndroidManifest.xml')
data=manifest.read_text().replace('android:label="exif_date_sync"',
                                  'android:label="EXIF Date Sync"', 1)
permission='<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE" />'
if permission not in data:
    data=data.replace('<application',permission+'\n    <application',1)

provider='''    <provider
        android:name="androidx.core.content.FileProvider"
        android:authorities="${applicationId}.exif_date_sync_files"
        android:exported="false"
        android:grantUriPermissions="true">
        <meta-data
            android:name="android.support.FILE_PROVIDER_PATHS"
            android:resource="@xml/exif_date_sync_file_paths" />
    </provider>'''
if 'androidx.core.content.FileProvider' not in data:
    assert '</application>' in data, 'Cannot find manifest application element'
    data = data.replace('</application>', provider + '\n    </application>', 1)
manifest.write_text(data)

# FileProvider is limited to the folders already handled by AndroidFolderScanner.
file_paths = Path('android/app/src/main/res/xml/exif_date_sync_file_paths.xml')
file_paths.parent.mkdir(parents=True, exist_ok=True)
file_paths_xml = '''<?xml version="1.0" encoding="utf-8"?>
<paths xmlns:android="http://schemas.android.com/apk/res/android">
    <external-path name="dcim" path="DCIM/" />
    <external-path name="pictures" path="Pictures/" />
    <external-path name="downloads" path="Download/" />
</paths>
'''
if file_paths.exists():
    assert file_paths.read_text() == file_paths_xml, (
        'Unknown FileProvider path configuration; preserve before changing')
else:
    file_paths.write_text(file_paths_xml)
# Add the pinned AndroidX ExifInterface dependency to the Flutter app module.
build=Path('android/app/build.gradle.kts')
if build.exists():
    data=build.read_text()
    if 'androidx.exifinterface:exifinterface' not in data:
        data += '\n// Needed by AndroidFileDateCore.\n'
        data += 'dependencies { implementation("androidx.exifinterface:exifinterface:1.4.1") }\n'
    if 'androidx.core:core:' not in data:
        data += '\n// Read-only photo viewing via FileProvider.\n'
        data += 'dependencies { implementation("androidx.core:core:1.13.1") }\n'
    build.write_text(data)
else:
    build=Path('android/app/build.gradle')
    data=build.read_text()
    if 'androidx.exifinterface:exifinterface' not in data:
        data += '\ndependencies { implementation "androidx.exifinterface:exifinterface:1.4.1" }\n'
    if 'androidx.core:core:' not in data:
        data += '\ndependencies { implementation "androidx.core:core:1.13.1" }\n'
    build.write_text(data)
PY
flutter pub get
