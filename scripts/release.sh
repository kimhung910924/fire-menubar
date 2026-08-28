#!/bin/bash
# Developer ID 서명 → 공증 → DMG → 배포 판정까지 한 번에.
#
# ## 왜 build.sh로 안 끝나는가
#
# build.sh는 **개발용**이다. Apple Development 인증서로 서명한다 —
# 내 맥에서만 열린다. 남의 맥에서는 Gatekeeper가 막는다.
# 배포하려면 Developer ID 인증서 + 하드닝 런타임 + 애플 공증 티켓이 필요하고,
# 티켓은 앱과 dmg **양쪽에** 박아야 한다(사용자는 dmg를 먼저 연다 —
# omni-windows/scripts/notarize-dmg.sh 2026-08-24 실측).
#
# ## 주의 — 서명 신원이 바뀌면 권한이 리셋된다
#
# 손쉬운 사용·화면 기록 승인은 코드 서명 신원에 묶인다(build.sh 주석 참고).
# 개발 빌드(Apple Development)와 이 릴리즈 빌드(Developer ID)는 다른 신원이라
# 이 dmg로 갈아끼우면 시스템 설정에서 권한을 다시 줘야 한다.
#
# 사용법:
#   ./scripts/release.sh          # dmg까지
#   ./scripts/release.sh --publish  # GitHub 릴리즈 업로드까지
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Fire"
IDENTITY="Developer ID Application: RRLLAB (D9FZ6BL5FD)"
SECRETS="${NOTARIZE_ENV:-$HOME/Desktop/app-development/omniai/_secrets/notarize.env}"

APP=".build/app/${APP_NAME}.app"
DIST="dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DMG="${DIST}/${APP_NAME}-${VERSION}.dmg"
ZIP="${DIST}/${APP_NAME}-${VERSION}.zip"

PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1

# ── 자격 증명 ─────────────────────────────────────────────
[ -f "$SECRETS" ] || { echo "공증 자격 증명이 없다: $SECRETS" >&2; exit 1; }
set -a; source "$SECRETS"; set +a
: "${APPLE_API_KEY:?notarize.env에 APPLE_API_KEY가 없다}"
: "${APPLE_API_KEY_ID:?notarize.env에 APPLE_API_KEY_ID가 없다}"
: "${APPLE_API_ISSUER:?notarize.env에 APPLE_API_ISSUER가 없다}"

notarize() {  # $1 = 파일
    xcrun notarytool submit "$1" \
        --key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER" \
        --wait --output-format json
}

echo "==> ${APP_NAME} ${VERSION} 릴리즈"

# ── 테스트 ────────────────────────────────────────────────
echo "==> 테스트"
swift test 2>&1 | tail -3

# ── 빌드 + Developer ID 재서명 ────────────────────────────
FIRE_SIGN_IDENTITY="$IDENTITY" ./build.sh release

# build.sh는 --timestamp를 안 붙인다. 공증은 보안 타임스탬프를 요구한다.
echo "==> Developer ID 재서명 (타임스탬프 포함)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# ── 앱 공증 ───────────────────────────────────────────────
mkdir -p "$DIST"
rm -f "$ZIP" "$DMG"
echo "==> 앱 공증"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$APP"

# ── dmg ───────────────────────────────────────────────────
echo "==> dmg 생성"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

echo "==> dmg 서명·공증"
codesign --sign "$IDENTITY" --timestamp -f "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

# ── 사용자가 받는 것과 같은 판정 ──────────────────────────
echo "==> 판정 (accepted가 아니면 배포하면 안 된다)"
spctl -a -t open --context context:primary-signature -vv "$DMG"
spctl -a -vv "$APP"

# 공증 zip은 제출용이었을 뿐이다. 배포물은 dmg 하나로 끝낸다.
rm -f "$ZIP"
echo "==> 완료: $DMG"

# ── GitHub 릴리즈 ─────────────────────────────────────────
if [ "$PUBLISH" = "1" ]; then
    TAG="v${VERSION}"
    echo "==> GitHub 릴리즈 $TAG"
    gh release view "$TAG" >/dev/null 2>&1 \
        && gh release upload "$TAG" "$DMG" --clobber \
        || gh release create "$TAG" "$DMG" --title "$APP_NAME $VERSION" --generate-notes
    gh release view "$TAG" --json url --jq .url
fi
