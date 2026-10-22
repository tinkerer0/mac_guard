#!/bin/zsh
# 맥 지킴이를 /Applications에 설치하고 로그인할 때 켜지게 한다. 비정상 종료 때만 다시 켠다(메뉴의 종료는 그대로 꺼짐).
# 전원·잠자기·화면·Lid Mode 같은 시스템 설정은 건드리지 않는다.
#   scripts/install.sh              설치(이미 있으면 새 빌드로 바꿔 다시 켬)
#   scripts/install.sh --uninstall  로그인 항목만 지움(앱·설정·기록은 남김)
set -euo pipefail
cd "${0:A:h:h}"
label=com.jinwoo.macguard
plist="$HOME/Library/LaunchAgents/$label.plist"
app=/Applications/MacGuard.app
domain="gui/$(id -u)"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "$domain/$label" 2>/dev/null || true
  rm -f "$plist"
  echo "로그인 항목을 지웠어요. 앱($app)과 설정(~/.config/mac_guard)은 남겨 두었어요."
  exit 0
fi

[[ -d dist/MacGuard.app ]] || zsh scripts/build-app.sh
zsh scripts/setup-secrets.sh
config="$HOME/.config/mac_guard/config.json"
if [[ ! -f "$config" ]]; then
  (umask 077 && print '{\n  "port": 8787\n}' > "$config")
  echo "기본 설정을 만들었어요: $config"
fi

launchctl bootout "$domain/$label" 2>/dev/null || true
rm -rf "$app"
cp -R dist/MacGuard.app "$app"
codesign --verify --strict "$app"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/MacGuard"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$app/Contents/MacOS/MacGuard</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>StandardOutPath</key>
	<string>$HOME/Library/Logs/MacGuard/launchd.log</string>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/MacGuard/launchd.log</string>
</dict>
</plist>
PLIST
plutil -lint "$plist" >/dev/null
launchctl bootstrap "$domain" "$plist"
echo "설치했어요: $app (로그인 항목 $label)"
