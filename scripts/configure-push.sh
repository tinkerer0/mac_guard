#!/bin/zsh
# APNs 키 파일(AuthKey_<KeyID>.p8)을 ~/.config/mac_guard/ 에 둔 뒤 실행한다.
# 파일 이름에서 Key ID를 읽어 config.json의 apns 항목을 채우고 권한을 0600으로 맞춘 뒤 앱을 다시 켠다.
# 키 내용은 읽거나 출력하지 않는다.
#   scripts/configure-push.sh [sandbox|production]
set -euo pipefail
home="${MAC_GUARD_HOME:-$HOME/.config/mac_guard}"
environment="${1:-sandbox}"
keys=("$home"/AuthKey_*.p8(N))
if (( ${#keys} != 1 )); then
  echo "$home 에 AuthKey_<KeyID>.p8 파일이 정확히 하나 있어야 해요(지금 ${#keys}개)." >&2
  exit 1
fi
key="${keys[1]}"
key_id="${${key:t}#AuthKey_}"
key_id="${key_id%.p8}"
if [[ ! "$key_id" =~ '^[A-Z0-9]{10}$' ]]; then
  echo "파일 이름에서 Key ID(10자리)를 읽지 못했어요: ${key:t}" >&2
  exit 1
fi
chmod 600 "$key"
config="$home/config.json"
python3 -I - "$config" "$key" "$key_id" "$environment" <<'PY'
import json, os, sys
path, key, key_id, environment = sys.argv[1:]
config = json.load(open(path)) if os.path.exists(path) else {}
config["apns"] = {
    "teamID": "Y35NBHS9WU",
    "keyID": key_id,
    "keyFile": key,
    "topic": "com.jinwoo.macguard.watch",
    "environment": environment,
}
tmp = path + ".tmp"
with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
PY
echo "푸시 설정을 넣었어요: Key ID $key_id, 환경 $environment"
if [[ -z "${MAC_GUARD_HOME:-}" ]] && launchctl print "gui/$(id -u)/com.jinwoo.macguard" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/com.jinwoo.macguard"
  echo "맥 지킴이를 다시 켰어요."
fi
