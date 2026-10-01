#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
app="build/口播制作.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -parse-as-library -o "$app/Contents/MacOS/口播制作" NativeApp/*.swift
cp NativeApp/Info.plist "$app/Contents/Info.plist"
cp NativeApp/Resources/draft.schema.json NativeApp/Resources/render_media.py "$app/Contents/Resources/"
cp NativeApp/Resources/whiteboard-draft.schema.json "$app/Contents/Resources/"
cp NativeApp/Resources/whiteboard_core.py NativeApp/Resources/render_whiteboard.py "$app/Contents/Resources/"
cp NativeApp/Resources/workflows.json "$app/Contents/Resources/"
codesign --force --deep --sign - "$app"
echo "${PWD}/${app}"
