# 릴리즈 하는 법

## 한 줄이면 끝납니다

```bash
./scripts/release.sh --publish
```

버전만 올려두시면 나머지는 전부 이어서 진행됩니다.

1. 테스트 실행
2. Release 빌드와 Developer ID 서명 (하드닝 런타임 + 타임스탬프)
3. 앱 공증 후 스테이플
4. dmg 생성, 서명, 공증, 스테이플
5. `spctl` 판정 — **accepted가 아니면 여기서 멈춥니다**
6. Sparkle 서명(`sign_update`)과 appcast 항목 생성
7. GitHub 릴리즈에 dmg와 zip 업로드
8. appcast와 릴리즈 노트를 rrllab.com 저장소에 커밋·푸시 (Vercel이 배포합니다)

`--publish` 없이 실행하면 6번까지만 하고 멈춥니다. 먼저 이렇게 확인해 보시는 편이 안전합니다.

## 버전 올리기

`Resources/Info.plist`의 `CFBundleShortVersionString`(표시용)과
`CFBundleVersion`(빌드 번호)을 올립니다.

**`CFBundleVersion`(빌드 번호)도 반드시 함께 올려 주세요.** Sparkle이 새 버전인지 판단할 때
보는 값이 이것입니다. 표시용 버전만 올리면 업데이트가 내려가지 않습니다.

## 릴리즈 노트

`release.sh`가 초안을 만들어 둡니다.

```
<rrl-lab-site>/public/apps/fire/notes/<버전>.html
```

**`--publish` 전에 내용을 채워 주세요.** 앱 안의 업데이터가 이 페이지를 그대로 보여줍니다.
비워 두면 사용자가 안내 문구를 그대로 읽게 됩니다.

사용자가 직접 읽는 글이므로 존댓말로 씁니다. `CHANGELOG.md`도 함께 갱신해 주세요.

## 미리 준비되어 있어야 하는 것

| 항목 | 위치 |
|---|---|
| Developer ID 인증서 | 키체인 — `Developer ID Application: RRLLAB (D9FZ6BL5FD)` |
| 공증 자격 증명 | `~/Desktop/app-development/omniai/_secrets/notarize.env` |
| Sparkle 서명 개인키 | 키체인, 백업은 `_secrets/sparkle-ed25519-private.key` |
| 홈페이지 저장소 | `~/Desktop/app-development/omniai/rrl-lab-site` (`RRLLAB_SITE`로 바꿀 수 있습니다) |

⚠️ **Sparkle 개인키를 잃어버리면 이미 설치된 앱에 영영 업데이트를 보낼 수 없습니다.**
공증 키와 같은 급으로 다뤄 주세요.

## 자주 걸리는 것

### 공증이 `Invalid`로 떨어질 때

추측하지 마시고 로그를 받아 이유를 확인하세요.

```bash
set -a && source ~/Desktop/app-development/omniai/_secrets/notarize.env && set +a
xcrun notarytool log <submission-id> --key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER"
```

실제로 겪은 사유가 둘 있습니다.

- `The executable requests the com.apple.security.get-task-allow entitlement`
  → Xcode가 `build` 액션에서 디버거용 entitlement를 주입합니다.
    `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`로 막습니다.
- `The binary is not signed with a valid Developer ID certificate` (Sparkle의 Updater.app)
  → 중첩된 코드가 ad-hoc 서명으로 남아 있는 경우입니다.
    안쪽부터 같은 신원으로 다시 서명해야 합니다.

### `/Applications`의 기존 앱이 터미널로 바뀌지 않을 때

macOS 14부터 앱 관리 권한이 필요합니다. dmg를 열어 손으로 끌어다 놓아 주세요.
한 번만 하시면 그 뒤로는 Sparkle이 알아서 갈아끼웁니다.

### 권한이 초기화될 때

TCC는 권한을 코드 서명 신원에 묶습니다. 개발 빌드(Apple Development)와
배포본(Developer ID)은 서로 다른 신원이라, 갈아끼우면 권한을 다시 주셔야 합니다.

## 개발 빌드

```bash
./build.sh release
```

배포용이 아닙니다. 다른 분의 맥에서는 Gatekeeper가 막습니다.
