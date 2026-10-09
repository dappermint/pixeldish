APP_NAME := "Pixeldish"
BUNDLE   := "lgbt.dappy.pixeldish"
VERSION  := "0.3.0"
APP      := "build/Pixeldish.app"
BIN      := APP / "Contents/MacOS/Pixeldish"
SWIFTC   := "/usr/bin/xcrun swiftc"

# build the app bundle; the shader ships beside the binary and is compiled at
# launch because this machine has Command Line Tools only, no metal compiler
build:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "{{APP}}/Contents/MacOS" "{{APP}}/Contents/Resources"
    {{SWIFTC}} -O -o "{{BIN}}" $(find src -name "*.swift")
    cp src/render/shader.metal "{{APP}}/Contents/Resources/"
    cp Info.plist "{{APP}}/Contents/"
    if [ -f build/AppIcon.icns ]; then cp build/AppIcon.icns "{{APP}}/Contents/Resources/"; fi
    codesign -s - -f "{{APP}}"
    echo "built {{APP}}"

# fmt and lint need the pinned tools: run them inside `nix develop`
fmt:
    swiftformat .
    swiftlint lint --fix --quiet

lint:
    swiftformat --lint .
    swiftlint lint --strict --quiet

# selftest (every shape/dither renders), then the palette and dither audit
test: build audit
    "{{BIN}}" --selftest

# dev-only, so it gets its own binary and never ships in the bundle
audit:
    mkdir -p build
    {{SWIFTC}} -O -D AUDIT -o build/audit $(find src dev -name "*.swift")
    build/audit --audit > build/audit.txt || { cat build/audit.txt; exit 1; }
    tail -1 build/audit.txt

# prove the live window path actually draws, which the offscreen test cannot see
test-live: build
    #!/usr/bin/env bash
    set -euo pipefail
    pkill -x {{APP_NAME}} 2>/dev/null || true
    out=$(PIXELDISH_PROBE=1 PIXELDISH_PROBE_EXIT=1 "{{BIN}}" 2>&1 | grep "live frame" | head -1)
    pkill -x {{APP_NAME}} 2>/dev/null || true
    [ -n "$out" ] || { echo "no live frame drawn"; exit 1; }
    echo "$out"

# every shape x dither in one png, to judge the audit's numbers by eye
sheet: build
    "{{BIN}}" --sheet build/contact-sheet.png

icon:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p build
    rm -rf build/icon.iconset
    {{SWIFTC}} -O -o build/make-icon tools/make-icon.swift
    build/make-icon build/icon.iconset
    iconutil -c icns build/icon.iconset -o build/AppIcon.icns
    echo "icon: build/AppIcon.icns"

# the icon has to exist before the bundle is signed, so build it first
install: icon build
    rm -rf "/Applications/{{APP_NAME}}.app"
    cp -R "{{APP}}" "/Applications/{{APP_NAME}}.app"
    @echo "installed /Applications/{{APP_NAME}}.app"

run: install
    pkill -x {{APP_NAME}} 2>/dev/null || true
    open "/Applications/{{APP_NAME}}.app"

dmg: icon build
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf build/dmg && mkdir -p build/dmg
    cp -R "{{APP}}" build/dmg/
    ln -s /Applications build/dmg/Applications
    rm -f "build/{{APP_NAME}}-{{VERSION}}.dmg"
    hdiutil create -quiet -volname "{{APP_NAME}}" -srcfolder build/dmg \
        -ov -format UDZO "build/{{APP_NAME}}-{{VERSION}}.dmg"
    shasum -a 256 "build/{{APP_NAME}}-{{VERSION}}.dmg"

clean:
    rm -rf build

uninstall:
    pkill -x {{APP_NAME}} 2>/dev/null || true
    rm -rf "/Applications/{{APP_NAME}}.app"
    defaults delete {{BUNDLE}} 2>/dev/null || true
    @echo "removed"
