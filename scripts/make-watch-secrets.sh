#!/bin/zsh
# 워치 앱에 넣을 맥 주소와 토큰 파일을 만든다(watch/App/Secrets.generated.swift, git 제외).
# 워치에서 긴 토큰을 직접 칠 수 없어 개인 빌드에 넣는다.
set -euo pipefail
cd "${0:A:h:h}"
url="${1:?사용법: make-watch-secrets.sh <맥 주소 URL> [sandbox|production]}"
environment="${2:-sandbox}"
token_file="${MAC_GUARD_TOKEN_FILE:-$HOME/.config/mac_guard/api_token}"
token="$(tr -d '[:space:]' < "$token_file")"
if [[ ${#token} -lt 32 ]]; then
  echo "토큰이 너무 짧아요: $token_file" >&2
  exit 1
fi
out="watch/App/Secrets.generated.swift"
umask 077
cat > "$out" <<EOF
// scripts/make-watch-secrets.sh가 만든 파일. git에 올리지 않는다.
import Foundation

enum GuardSecrets {
    static let baseURL = URL(string: "$url")!
    static let token = "$token"
    static let apnsEnvironment = "$environment"
}
EOF
echo "만들었어요: $out ($url, $environment)"
