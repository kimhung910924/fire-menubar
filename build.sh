#!/bin/bash
# Fire.app 번들을 만든다.
#
# SPM은 실행 파일만 만들 수 있고 .app 번들은 만들지 못한다.
# 하지만 Fire는 LSUIElement, 접근성/화면기록 권한, SMAppService 로그인 항목 때문에
# 반드시 번들 형태여야 하므로 여기서 직접 조립한다.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="Fire"
# 출력을 .build 아래(숨김 폴더)에 둔다. 그냥 build/에 두면 스팟라이트가 색인해서
# 응용 프로그램 검색에 빌드 산출물이 설치본과 나란히 뜬다 (2026-08-28 실측).
BUNDLE=".build/app/${APP_NAME}.app"

echo "==> 빌드 (${CONFIG})"
swift build -c "$CONFIG" --disable-sandbox

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> 번들 구성"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

cp "$BIN_PATH/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# 손쉬운 사용·화면 기록 권한은 코드 서명 신원에 묶인다.
#
# ad-hoc 서명(`-`)은 신원이 없어서 TCC가 바이너리 해시로 권한을 기억한다.
# 그래서 리빌드할 때마다 해시가 바뀌어 승인이 무효가 되고,
# 시스템 설정 목록에는 켜져 있는데 앱은 권한이 없다고 나오는 상태가 된다.
#
# 개발 인증서로 서명하면 팀 식별자 + 번들 식별자로 신원이 고정되어 리빌드해도 승인이 유지된다.
SIGN_ID="${FIRE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | grep -m1 "Apple Development" | sed -E 's/.*\) ([A-F0-9]{40}) .*/\1/')}"

if [ -n "$SIGN_ID" ]; then
    echo "==> 서명 ($SIGN_ID)"
    codesign --force --options runtime --sign "$SIGN_ID" "$BUNDLE"
else
    echo "==> 서명 (ad-hoc — 리빌드마다 권한을 다시 줘야 합니다)"
    codesign --force --sign - "$BUNDLE"
fi

echo "==> 완료: $BUNDLE"
