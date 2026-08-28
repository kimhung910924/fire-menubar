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

# Sparkle.framework를 번들에 넣는다.
#
# SPM은 프레임워크를 빌드 폴더에 풀어놓기만 하고 .app 안으로 넣어주지 않는다(Xcode가
# 하던 일이다). 안 넣으면 실행 즉시 dyld가 Sparkle을 못 찾아 앱이 죽는다.
# 프레임워크 안에는 XPC 서비스와 Updater.app 같은 중첩 실행 파일이 들어 있어서
# 서명도 안쪽부터 해야 한다(아래 참고).
mkdir -p "$BUNDLE/Contents/Frameworks"
rm -rf "$BUNDLE/Contents/Frameworks/Sparkle.framework"
ditto "$BIN_PATH/Sparkle.framework" "$BUNDLE/Contents/Frameworks/Sparkle.framework"

# SPM이 실행 파일에 박아 준 rpath는 `@loader_path`(= Contents/MacOS)뿐이라 한 칸 위의
# Frameworks를 못 본다. Xcode였다면 자동으로 들어갔을 경로를 여기서 직접 넣는다.
# 없으면 실행 즉시 "Library not loaded: @rpath/Sparkle.framework"로 죽는다.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
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

SIGN_ARGS=(--force --options runtime)
if [ -n "$SIGN_ID" ]; then
    echo "==> 서명 ($SIGN_ID)"
    SIGN_ARGS+=(--sign "$SIGN_ID")
else
    echo "==> 서명 (ad-hoc — 리빌드마다 권한을 다시 줘야 합니다)"
    SIGN_ARGS+=(--sign -)
fi

# 중첩 코드부터 안쪽 순서로 서명한다.
#
# 바깥 번들을 먼저 서명하면 그 안의 실행 파일을 나중에 건드리는 순간 바깥 서명이 깨진다.
# --deep은 애플이 권장하지 않는다(하드닝 런타임·entitlements가 안쪽에 그대로 복사된다).
FRAMEWORK="$BUNDLE/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_ARGS[@]}" "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
codesign "${SIGN_ARGS[@]}" "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
codesign "${SIGN_ARGS[@]}" "$FRAMEWORK/Versions/B/Updater.app"
codesign "${SIGN_ARGS[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
codesign "${SIGN_ARGS[@]}" "$FRAMEWORK"
codesign "${SIGN_ARGS[@]}" "$BUNDLE"

echo "==> 완료: $BUNDLE"
