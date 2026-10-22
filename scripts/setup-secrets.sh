#!/bin/zsh
# 맥과 워치가 같이 쓰는 접속 토큰을 만든다. 값은 화면에 출력하지 않는다.
set -euo pipefail
dir="${MAC_GUARD_HOME:-$HOME/.config/mac_guard}"
mkdir -p "$dir"
chmod 700 "$dir"
token="$dir/api_token"
if [[ -s "$token" ]]; then
  echo "토큰이 이미 있어요: $token"
else
  umask 077
  openssl rand -hex 32 > "$token"
  echo "토큰을 만들었어요: $token"
fi
chmod 600 "$token"
