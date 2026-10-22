#!/bin/zsh
# 맥 지킴이 메뉴 막대 앱을 dist/MacGuard.app으로 묶는다.
set -euo pipefail
cd "${0:A:h:h}"

swift build -c release --product MacGuard
bin="$(swift build -c release --show-bin-path)/MacGuard"
app="$PWD/dist/MacGuard.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/MacGuard"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>ko</string>
	<key>CFBundleDisplayName</key>
	<string>맥 지킴이</string>
	<key>CFBundleExecutable</key>
	<string>MacGuard</string>
	<key>CFBundleIdentifier</key>
	<string>com.jinwoo.macguard</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>맥 지킴이</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null

# 임시 서명(-)은 빌드할 때마다 입력 모니터링 허용이 풀린다. 개발 인증서로 서명해 허용을 유지한다.
identity="$(security find-identity -v -p codesigning | sed -nE 's/.*"(Apple Development: [^"]+)".*/\1/p' | head -1)"
if [[ -z "$identity" ]]; then
  echo "Apple Development 서명 인증서를 찾지 못했어요." >&2
  exit 1
fi
codesign --force --sign "$identity" --identifier com.jinwoo.macguard --timestamp=none "$app"
codesign --verify --strict "$app"
echo "BUILD OK -> $app"
