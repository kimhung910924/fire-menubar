# Fire — 인수인계

새 대화에서 이 파일부터 읽고 시작한다.
기획안은 [Fire_맥_메뉴바_앱_기획안.md](Fire_맥_메뉴바_앱_기획안.md), 기술 메모는 [README.md](README.md)에 있다.

---

## 1. 지금 상황 한 줄

**2026-08-28 — 레이아웃 엔진이 자기 결과를 검증하고, 실패해도 쓸 수 있는 쪽으로 무너진다.**

쓰고 나서 메뉴바를 다시 재고, 어긋나면 재시도하고, 그래도 안 되면 **실패 방향에 따라**
다르게 대응한다. 접힌 채 틀려서 아이콘이 통째로 사라지는 모드가 없어졌다.
`FireKit` 타깃에 순수 로직을 분리했고 `swift test` 56개가 돈다.

- 순수 로직은 `FireKit` 타깃으로 분리. `swift test` 28개 통과.
- 냉시작 3회 반복에서 위치값이 `separator 444 / fire 443`으로 수렴. 어제 사고 미재현.
- 외부 모니터 연결 상태에서 양쪽 화면이 동일하게 동작(요구 6번) 실측 확인.
- 설계·계획: `docs/superpowers/specs/2026-08-27-fire-layout-engine-design.md`,
  `docs/superpowers/plans/2026-08-27-fire-layout-engine.md`

### 2026-08-28 — "숨겨둔 게 한 번씩 튀어나온다" (해결)

사용자 보고. 원인이 세 겹이었고 셋 다 다른 문제였다.

**① 검증할 때마다 메뉴바를 펼쳤다.** `applySectionsVerified`가 기준선을 다시 재려고
매번 `realignSeparator`(= `expand()`)를 탔다. 그때마다 숨겨둔 아이콘이 전부 드러난다.
2초 간격 12회 표본에서 **절반이 펼쳐진 상태**였다.
→ 기준선이 없거나 재시도일 때만 펼친다. 평상시 검증은 지금 상태 그대로 확인한다.

**② 못 숨기는 항목 하나가 전체를 무너뜨렸다.** `sys:AudioVideoModule`(소리 날 때만
나타나는 제어 센터 모듈)은 macOS가 위치를 정하므로 Fire가 옮길 수 없다. 얘 하나가
검증을 3회 실패시켜 안전 모드로 보내고, 안전 모드가 **전체를 펼쳤다.**
→ **실패 방향을 갈랐다.** 이게 핵심이다.

| 실패 | 뜻 | 대응 |
|---|---|---|
| `unexpectedlyHidden` 있음 | 보여야 할 게 사라졌다 | **위험.** 펼쳐서 되돌린다 |
| `unexpectedlyVisible`만 | 숨기기로 한 게 안 숨겨졌다 | 접힌 상태 유지, 주황색 경고만 |

**③ 그래도 매 주기 재시도가 돌았다.** 재시도가 기준선을 다시 재려고 펼친다.
→ `knownUnhideableIds` — 끝내 못 숨긴다고 확인된 항목은 판정에서 빼고 재시도하지 않는다.
분류가 바뀌면 `forgetUnhideable()`로 잊는다.

실측 (숨겨둔 아이콘이 보인 표본):

```
처음                    6 / 12  (50%)
① 불필요한 펼침 제거     2 / 12  (17%)
③ 못 숨기는 항목 기억    2 / 20  (10%)
```

곁들여: **Watchdog이 항목 수 변화를 실제로 감시한다.** 클래스 주석에 "어떤 앱이 자기
status item을 새로 만든 경우를 잡는다"고 적혀 있었는데, `Snapshot.statusItemCount`를
담아두기만 하고 **비교하지 않고 있었다.** Claude·Gemini처럼 아이콘을 넣었다 뺐다 하는
앱이 숨김을 빠져나가도 아무도 안 잡았다. 이제 잡는다.
(접힘 상태가 같을 때만 비교한다 — 접었다 펴는 사이엔 개수가 당연히 다르다.)

### 2026-08-28 — 과도기 스캔이 유령을 만든다 (해결)

항목이 새로 나타나는 순간 CGWindow는 이미 옮겨갔는데 접근성 프레임이 아직 옛 위치라,
매칭이 **한 칸씩 밀려 엉뚱한 앱의 신원이 붙는다.** 실측:

```
x=2683 → ord:14          신원 상실
x=2731 → menubarx        실제로는 HiddenNotch
x=2769 → Gemini          실제로는 menubarx
x=2803 → controlcenter   실제로는 Gemini      ← 유령이 이렇게 생긴다
```

3초 뒤 다시 재면 완전히 정상이었다. **짧은 순간만 틀린다.**

신호는 `ord:`이다 — 접근성과 창 이름이 둘 다 실패했을 때만 나온다.
`FireKit.ScanTrust`가 **`ord:`이 늘어난 스캔**을 버리고 직전의 멀쩡한 결과를 쓴다.

"하나라도 있으면 버린다"로 하면 안 된다. 영영 식별 못 하는 항목이 있으면 스캔이
통째로 얼어붙는다. 늘어난 것만 보고, 20초 상한도 뒀다.

### 2026-08-27 밤 — 유령 항목의 진짜 원인 (해결)

설정 화면 오른쪽에 `?` 항목이 쌓이던 문제. 같은 항목이 두 신원으로 갈라져 있었다.

```
sys:ItsycalStatusItem  ↔  com.mowglii.ItsycalApp
sys:BentoBox-0         ↔  com.apple.controlcenter
```

원인이 두 겹이었다.

**① 우선순위가 서로 반대였다.** `MenuBarItemIdentity`는 고유 이름을 번들 ID보다 먼저 보는데,
`mergedNames`는 번들 ID를 먼저 골랐다. 그래서 **외부 모니터가 붙으면** 번들 ID가 이겨
신원이 뒤집혔다. 붙였다 뗄 때마다 신원이 하나씩 늘어난다.

→ 이름을 하나로 뭉개지 않는다. `FireKit.MenuBarNameMerge`가 고유 이름과 번들 ID를
**종류별로 따로** 돌려주고, 식별자 규칙이 정한 순서대로 쓴다.

**② 화면끼리 짝짓는 기준이 틀렸다.** "오른쪽에서 n번째"로 짝지었는데, 노치 때문에 행마다
항목 개수가 다르면 같은 순번이 서로 다른 항목을 가리킨다. **이웃의 번들 ID**가 붙는다.
실제로 HiddenNotch와 Gemini가 신원을 잃고 `ord:N`이 됐다.

→ **오른쪽 끝 거리**로 짝짓는다(디스플레이 불변). 단, **중심점**으로 잰다.
오른쪽 끝으로 재면 맨 오른쪽 항목의 `maxX`가 화면 폭을 넘어(시계 1472 > 화면 1470)
화면을 못 찾고 이름 후보가 통째로 비어 `sys:Clock`이 사라진다.

곁들여 고친 것:

- **Fire 자기 아이콘은 고정 ID를 쓴다.** 스캔이 만드는 이름에 맡기면 화면 구성에 따라
  `sys:FireControlItem` ↔ `com.rrllab.FireMenuBar`를 오간다. `pruneStaleItems`가
  매번 지우고 있었다. 이제 스캔이 `ControlItemCoordinator.fireIconStableId`를 낸다.
- **구분자는 항목 목록에서 제외한다.** 내부 장치이므로 사용자에게 보이면 안 된다.
- **Fire Bar 드래그가 분류를 오염시키지 않는다.** 패널에는 말려든 항목도 그려지는데,
  `endItemDrag`가 패널 목록을 통째로 FIRE_BAR로 저장하고 있었다. 드래그는 **순서**를
  바꾸는 동작이지 분류를 바꾸는 동작이 아니다. 이제 지정된 항목의 순서만 저장한다.

죽은 유령 두 개(`com.mowglii.ItsycalApp`, `com.apple.controlcenter`)는 수동으로 지웠다.
백업은 `layout-before-ghostclean.json`.

검증(외부 모니터 연결 상태 + 해제 상태 양쪽):

```
scanDump 10개, ord: 0개, 유령 0개
verified: visible=8 collateral=0 attempt=1, 연속실패 0
크래시 0
```

**미검증 — 다음 회차 1번:** 외부 모니터 **연결↔해제를 반복**하며 신원이 유지되는지.
이번 수정이 정확히 그 경로다. `diag.scanDump`로 각 상태에서 신원을 비교할 것.

### 2026-08-27 오후 — 크래시 4건, 전부 같은 원인

앱이 오늘 네 번 죽었다(13:04, 13:10, 13:23, 14:35). 스택이 넷 다 같다.

```
Dictionary.init(uniqueKeysWithValues:)   ← 키 중복이면 trap
SettingsStore.items(in:orderedBy:)
LayoutEditorModel.reload()
```

`physicalOrder`에 **중복**이 들어갔다. 디스플레이가 둘 이상이면 같은 항목이 화면 수만큼
복제되어 스캔에 두 번 나온다. `mergedOrder`가 그걸 거르지 않았다. 외부 모니터를 해제하는
순간 순서가 재계산되면서 터졌다.

두 겹으로 막았다.

1. `FireKit.PhysicalOrder.merge` — 결과에 중복이 없음을 보장. 테스트로 고정.
2. `SettingsStore.items(in:orderedBy:)` — `uniquingKeysWith:`로 바꿔 중복이 와도 안 죽는다.

**교훈: 실측할 때 크래시 로그를 반드시 같이 본다.** `recovery.json`이 `verified`라고
적혀 있어도 프로세스가 죽어 있을 수 있다. 메뉴바 배치만 재고 프로세스 생존을 안 봤다.

```bash
ls -lt ~/Library/Logs/DiagnosticReports/Fire*.ips | head -3
pgrep -f "Fire.app/Contents/MacOS/Fire"
```

### 2026-08-27 오후 — 검증이 두 번 거짓말했다

`LayoutVerifier`를 **비대칭**으로 바꿨다. 한 집합 비교로 뭉뚱그리면 안 된다.

- `mustStayVisible` — 보이기로 한 것. 하나라도 사라지면 실패.
- `mustBeHidden` — 숨기기로 한 것 중 지금 메뉴바에 있는 것. 하나라도 보이면 실패.
- 어느 쪽도 아닌 것(노치에 가린 것, 경계 때문에 말려든 것)은 판정에서 뺀다.

뭉뚱그렸을 때 두 가지가 실제로 났다. ① 기준선에 없던 항목이 판정에서 통째로 빠져
**숨김이 하나도 안 걸린 상태를 `verified`로 기록**. ② 말려듦을 실패로 세어 검증이
영원히 실패하고 안전 모드에 갇혀 숨김 기능 자체가 죽음.

### 2026-08-27 오후 — Fire Bar 관련 3건

1. **숨긴 것이 Fire Bar에도 없었다.** `fireBarItems`가 사용자 지정 항목만 돌려줘서,
   경계 때문에 말려든 Gemini·HiddenNotch·Kiro CLI가 메뉴바에도 Fire Bar에도 없었다.
   닿을 방법이 아예 없는 상태. `FireKit.FireBarContents`로 말려든 것도 포함한다.
2. **아이콘이 앱 아이콘으로 대체됐다.** `warmIcons()`가 지정 항목만 미리 캡처해서,
   말려든 항목은 캡처 기회를 놓치고 1024x1024 Dock 아이콘으로 그려졌다.
   이제 펼친 상태에서 **보이는 것 전부** 떠둔다.
3. **아이콘이 작았다.** 캡처가 status item 창 전체라 앱마다 다른 여백이 그대로 들어갔다.
   `FireKit.ImageBounds.opaqueBounds`로 여백을 잘라내고 칸을 24 → 30pt로 키웠다.

### 2026-08-27 사고와 원인

재부팅 후 Fire가 메뉴바 아이콘 17개를 없앴는데 `recovery.json`에는 성공으로 적혀 있었다.
`applySections()`가 `collapse()` 직후 결과를 재보지 않고 성공을 기록했기 때문이다.

직접 원인은 **기준 행 선택**이었다. `alignSeparator()`가 두 화면 항목을 절대 x로 한 줄에
세워서 경계가 외부 화면 기준으로 잡혔다(값 307 → 내장 x=1163). 그리고 노치 있는 내장
화면은 항목이 가려 식별에 실패하는 일이 잦은데, 못 찾으면 경계를 안 옮기고 **낡은 값
그대로 접힌다.**

### 실측이 깬 설계 가정 3개

1. ~~"분류된 항목이 스캔에 없으면 중단"~~ — 없는 이유가 그 앱 미실행이었다(WorkspaceShelf
   미실행, AudioVideoModule은 소리 날 때만). 계산에서 빼고 `absent`로 보고만 한다.
2. ~~"MAIN인데 안 보이면 실패"~~ — 노치에 가린 것과 구분자가 민 것을 갈라야 한다.
   펼친 상태 기준선(`expandedVisibleIds`)을 잡아 구분한다. 예측된 말려듦
   (`unintentionallyHiddenIds`)도 실패가 아니다 — 구분자가 하나뿐이라 필연이다.
3. ~~"기준 행은 주 디스플레이"~~ — 항목이 **가장 많은 행**을 쓴다. 노치 화면은 증거가 적다.
   위치값은 "화면 오른쪽 끝에서의 거리"라 어느 행에서 계산해도 결과는 화면 무관하다.

---

## 1-1. 이전 상황(2026-08-01)

핵심 세 가지가 **내장 화면(단일 디스플레이)에서 전부 실측으로 검증됐다.**

1. ✅ 노치에 갇혀 사라졌던 아이콘 6개 복구 — 접근성 전용 항목 합성으로 해결 (2026-08-01)
2. ✅ Fire Bar 아이콘 클릭 → 원본 앱 메뉴 열림 — Maccy로 실측 검증 (AXPress 경로)
3. ✅ 사용자 분류(MenubarX 숨김, WorkspaceShelf 표시)가 실제 메뉴바에 정확히 반영, 충돌 0개

**남은 최대 과제: 외부 모니터를 연결한 상태의 검증(5.1).** 코드는 화면 독립적으로
고쳐뒀지만(오른쪽 끝 거리 기준 매칭) 실기기 검증을 못 했다. 모니터가 연결되면 즉시 7절 1번을 할 것.

---

## 2. 사용자가 원하는 것

1. **외부 모니터가 있든 없든 똑같이 동작할 것.** ← 유일하게 검증이 남은 항목
2. **아이콘이 사라지지 않을 것.** ← 해결됨(4.7)
3. **Fire Bar만 확실히 되면 된다.** 구분선 같은 내부 장치는 사용자에게 보이지 말 것.
4. **설정 화면 드래그가 부드럽고, 순서가 실제로 바뀔 것.** (드래그 지연 개선은 미측정 — 5.4)
5. 기획안 28절 완료 기준 전반(잠자기·모니터 복구, 빈 영역 클릭 등).

사용자는 반복된 헛발질에 지쳐 있다. **추측으로 고치지 말고 반드시 측정 후 수정할 것.**

---

## 2-1. 위치와 저장소 (2026-08-28 이전)

구글 드라이브에서 로컬로 옮겼다. 소스는 1MB인데 빌드 산출물 271M이 매 빌드마다
드라이브 동기화를 갈고 있었다.

- 경로: `~/Desktop/app-development/macapps/fire`
- 저장소: https://github.com/kimhung910924/fire-menubar (공개)

**옮긴 뒤 로그인 항목을 다시 등록해야 한다.** `SMAppService.mainApp`은 등록 당시 경로를
물고 있어서, 설정 화면에서 "로그인 시 자동 실행"을 껐다 켜야 새 경로가 잡힌다.
접근성·화면 기록 권한은 서명 신원에 묶여 있어 경로가 바뀌어도 유지된다(4.8절).

## 3. 빌드 · 실행 · 진단

```bash
cd "/Users/kimheunggi/Desktop/app-development/macapps/fire"
./build.sh release
open build/Fire.app
```

진단 모드. **셸에서 직접 실행하면 접근성 권한이 없는 것으로 잡히므로**,
권한이 필요한 확인은 반드시 `open -n ... --args`로 번들 실행하고 결과 파일을 읽는다.

```bash
open -n build/Fire.app --args --dump      && sleep 5 && cat ~/Library/Application\ Support/Fire/dump.txt
open -n build/Fire.app --args --hittest   && sleep 3 && cat ~/Library/Application\ Support/Fire/dump.txt
open -n build/Fire.app --args --verify-hide && sleep 6 && cat ~/Library/Application\ Support/Fire/dump.txt
```

### 실행 중인 Fire를 셸에서 조작하는 훅 (2026-08-01 추가)

사람이 누르지 않고도 Fire Bar를 검증할 수 있다. 결과는 `Application Support/Fire/diag-result.txt`.

```bash
# Fire Bar 열기/닫기
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.rrllab.FireMenuBar.diag.toggleBar"), object: nil, userInfo: nil, deliverImmediately: true)'
# Fire Bar 항목 누르기 (object = stableId). 우클릭은 diag.pressRight.
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.rrllab.FireMenuBar.diag.press"), object: "org.p0deje.Maccy", userInfo: nil, deliverImmediately: true)'
```

상태 파일: `~/Library/Application Support/Fire/{layout,settings,recovery}.json`

**주의: `layout.json`을 함부로 지우지 말 것.** 사용자의 Fire Bar 배치가 날아간다.
수정 전 반드시 백업을 뜬다. 사용자가 설정창에서 실시간으로 드래그 중일 수 있으니
앱 실행 중에는 파일을 직접 고치지 말 것(앱이 저장하면서 덮어쓴다).

주의: 셸에서 `ps aux | grep Fire.app` 하지 말 것 — 작업 디렉터리 경로에 fire가 들어 있어
자기 셸이 잡힌다. `pgrep -f "Fire.app/Contents/MacOS/Fire"`를 쓴다.

---

## 4. 실측으로 확정된 사실

이 맥(macOS 26.5, MacBook Pro 노치 1470pt + 외부 모니터)에서 직접 측정한 것들.
새로 시작해도 다시 확인할 필요 없다.

### 4.1 소유 앱 식별

- **모든 status item 윈도우의 `kCGWindowOwnerPID`는 제어 센터를 가리킨다.** PID로는 소유 앱을 알 수 없다.
- 실제 소유자는 ① 접근성 `AXExtrasMenuBar` 열거(정확, 권한 필요) ② `kCGWindowName`의 번들 식별자
  (권한 불필요하나 **이웃 항목 것이 들어올 때가 있음**) 두 경로뿐.
- 접근성 기본 타임아웃 6초 → 전체 순회 시 20초 멈춤. `AXUIElementSetMessagingTimeout(app, 0.25)` 필수.
- 접근성 제목(`배터리 62%`)은 계속 바뀌므로 식별자에 넣으면 안 된다.

### 4.2 식별자 설계

순서: **① 항목 고유 이름(`sys:WiFi`) → ② 번들 식별자 → ③ 상대 순서(`ord:N`)**.
`ord:N`과 `#1` 꼬리표는 절대 저장하지 않는다(유령 항목 양산, 43개까지 쌓인 적 있음).

### 4.3 status item 위치 조작

- 키: `NSStatusItem Preferred Position <autosaveName>`, 값: **화면 오른쪽 끝에서의 거리(pt)**.
- 값이 클수록 왼쪽. 실제 배치는 이 값의 **순서**로 오른쪽부터 빈틈없이 채워진다(간격 없음).
- Fire 자신의 항목은 `제거 → 값 기록 → 재생성` 순서로 옮길 수 있다(반대 순서면 값이 지워짐).
- 구분자는 `(화면오른쪽 − 값)` 좌표를 품은 항목의 **바로 왼쪽**에 끼어든다.
  → **남길 첫 항목의 한가운데**를 노려야 한다. 경계를 노리면 한 칸씩 어긋난다.
- **남의 앱 항목도 옮길 수 있다(수동 개입 한정):** 그 앱 종료 → `defaults write <그 앱 도메인> "NSStatusItem Preferred Position <키>" -float <값>` → 재실행.
  MenubarX(`com.app.menubarx`, 키 이름이 타임스탬프 `1780665820.6382918`)를 554→600으로 옮겨
  숨김 구간을 연속으로 만드는 데 실제로 사용했다(2026-08-01). 샌드박스 앱(Maccy, Shottr)은
  `~/Library/Containers/<번들ID>/Data/Library/Preferences/`에 있다.
  단, `defaults read org.p0deje.Maccy`는 도메인이 커서 **행이 걸린다** — 키 지정 읽기도 걸리므로 PlistBuddy로 파일을 직접 읽을 것.
- 시스템 아이콘(시계, 제어 센터)보다 오른쪽으로는 갈 수 없다.

### 4.4 디스플레이

- 같은 항목이 디스플레이 수만큼 중복 생성된다. 보조 사본은 창 이름에 `Clone`.
- 외부 디스플레이는 메뉴바가 있어도 `visibleFrame`이 화면 전체와 같게 온다(높이 0). status item 존재로 보완.
- **"화면 오른쪽 끝에서의 거리"는 디스플레이 불변이다.** 메뉴바가 모든 화면에서 오른쪽 정렬 미러이기 때문.
  스캐너 매칭·합성 판정 전부 이 좌표계로 통일했다(`MenuBarScanner.rightEdgeDistance`).

### 4.5 노치 (2026-08-01 확정)

- 이 맥 내장 화면(1470pt)의 노치 구간: **x 646~825** (`auxiliaryTopLeftArea.maxX ~ auxiliaryTopRightArea.minX`).
- 오른쪽부터 채우다가 노치에 닿으면 **그 항목부터 왼쪽 전부**를 macOS가 감춘다(부분 겹침도 감춤).
- 감춰진 항목은 CGWindow가 없지만 **접근성 프레임은 양수 좌표로 정상 보고된다.**
- 앱이 스스로 숨긴 항목은 가짜 좌표로 온다: x=-1(Google Drive), x=7(rcmd, Chrome). → x≥50 필터로 구분.
- Fire가 다른 항목을 숨겨 공간이 나면 노치에 갇혔던 항목은 **자동으로 풀린다**(오른쪽으로 당겨짐).

### 4.6 아이콘 이미지

- 메뉴바 글리프는 흰색으로 캡처됨 → 단색이면 `labelColor` 재도색. 다수는 완전 투명 → 앱 아이콘 대체.
- **창 번호 0이거나 숨겨진 항목은 절대 캡처 금지.** 창 번호 재사용으로 엉뚱한 창이 찍힌다(실제 발생).
- 노치 합성 항목(`isNotchConcealed`)은 `windowNumber == 0`이라 캡처 경로가 차단돼 있다.

### 4.7 Fire Bar 클릭 (2026-08-01 검증)

- **좌클릭**: `AXPress`(1순위)가 Maccy에서 성공. 원본 아이콘이 화면 밖(숨김)이어도 동작한다.
- 숨겨진 항목의 팝업은 macOS가 **화면 왼쪽 끝(x=0, 메뉴바 바로 아래)에 클램프해서** 연다.
- **우클릭**(2026-08-01 추가, `activateSecondary`): Fire Bar 아이콘 우클릭/⌃클릭 → 원본 컨텍스트 메뉴.
  - `AXShowMenu` 액션은 **이 맥의 어떤 앱도 지원하지 않았다**(Maccy, Shottr, Claude, LinearMouse, MenubarX 전부 실패).
  - 실제 경로는 "잠깐 표시 → 좌표 우클릭 합성". pizzaClip으로 실측 검증 완료(컨텍스트 메뉴 열림).
  - **한계**: 표시하는 순간 노치로 들어가는 항목은 우클릭 불가. 이 맥 내장 화면은 항목이 18개라
    Fire Bar의 6개 전부 여기 해당 → 정직하게 실패(비프음) 처리. 외부 모니터(노치 없음)에서는 될 것 — 미검증.
  - `postToPid`로 이벤트를 소유 앱에 직접 배달하는 것도 시도했으나 **그려지지 않은 창은 이벤트를 받지 못한다**(실측).
    코드에는 마지막 시도로 남아 있고, 메뉴가 실제로 열렸는지 확인한 뒤에만 성공을 보고한다.

### 4.8 TCC (권한)

`build.sh`가 `Apple Development` 인증서 자동 사용(TeamIdentifier `ALUDNZX6BP`).
ad-hoc으로 빌드된 적 있으면 시스템 설정에서 Fire 항목 삭제 후 재추가.

---

## 5. 남은 문제

### 5.1 디스플레이 독립성 — 코드 수정 완료, 실기기 검증 필요

2026-08-01 수정 내용:
- AX↔CGWindow 매칭을 절대 x → **오른쪽 끝 거리**로 변경 (`nearestOwner`)
- 기준 행 선택을 결정적으로: 항목 수 최다, 동수면 주 디스플레이 우선
- 노치 합성 판정도 오른쪽 끝 거리 기준

**외부 모니터를 연결한 상태에서 반드시 확인할 것:**
`--dump`에서 ① 접근성 프레임이 어느 화면 좌표로 오는지 ② 매칭이 유지되는지 ③ 식별자가 안 바뀌는지.
연결↔해제 반복, 잠자기 복귀, 클램셸(기획안 25·27절)도 전부 미검증.

### 5.0 남은 실기기 검증 (2026-08-27 기준)

사람 손이 필요해 못 한 것들이다. `swift scripts/measure-menubar.swift`로 재고
`recovery.json`의 `lastRebuildResult`가 `verified:`로 시작하는지 본다.

- [x] 외부 모니터 **연결 상태**에서 신원 안정 확인(2026-08-28). `sys:ItsycalStatusItem`,
      `sys:BentoBox-0`, `sys:Clock` 전부 단일 화면일 때와 동일. `ord:` 0개, 크래시 0.
- [ ] 외부 모니터 **연결↔해제를 여러 번 반복**. 한 번씩은 해봤으나 반복 검증은 안 했다.
- [ ] 잠자기 복귀
- [ ] 클램셸(내장 닫기) — `ScreenRows.reference`가 외부 행을 고르는지
- [ ] Fire Bar 패널을 **끌어서** 옮기고 닫았다 열기. 복원 경로는 좌표 주입으로
      검증했으나(AppKit `(300,700)` → CG `y=216` 일치) 드래그 저장 경로는 미검증.
- [x] Fire를 FIRE_BAR로 지정 — 메뉴바에서 사라지고 Fire Bar에 불꽃 버튼 생김(폭 72pt = 2항목)

### 5.2 alignSeparator의 일시적 어긋남 — 2026-08-27 해결

검증 루프가 대체했다. 어긋나면 최대 3회 재시도하고, 소진하면 펼친 상태로 고정한다.
"재정렬에서 수렴 확인"이라던 자기수복은 실제로는 작동하지 않았다 — 저장값만 바뀌고
실제 배치는 그대로였다(307 → 454.5, 배치 불변).

### 5.2-old alignSeparator의 일시적 어긋남 (2026-08-01 기록)

첫 적용 때 스캔 타이밍에 따라 구분자가 한두 칸 오른쪽에 앉는 경우를 봤다(값 640에 앉아
Shottr·WorkspaceShelf가 안 숨겨짐). **재정렬(재시작 포함)에서 정확한 값으로 수렴하는 것 확인.**
원인 후보: 정렬 시점에 특정 항목이 접근성 타임아웃으로 식별 실패 → fireBarIds에서 빠짐.
재현되면 alignSeparator 직전 스캔의 식별 결과를 로그로 남겨 확인할 것.

### 5.2.1 설정 화면 순서 튐 — 해결 (2026-08-01)

증상: 드래그하다 보면 Fire·WorkspaceShelf가 갑자기 MAIN 목록 오른쪽 끝으로 튀고, 실제로도
Fire 아이콘이 메뉴바 오른쪽 끝으로 날아갔다. 원인 세 가지, 전부 수정:

1. `alignSeparator()`가 physicalOrder를 Fire 아이콘 없는 목록으로 덮어씀 → 설정창이 Fire 위치를
   잃고 맨 뒤로 정렬. → `mergedOrder()`로 병합만 하도록 수정.
2. 재배치 도중 스캔이 항목을 일시적으로 놓치면 그 항목이 순서에서 빠져 맨 뒤로 정렬.
   → `mergedOrder()`: 이번 스캔에 없는 항목은 직전 상대 위치를 유지.
3. `moveFireIcon(before:)`의 대상이 마침 스캔에 없으면 **맨 오른쪽으로 보내는 폴백**을 탔다.
   → `moveFireIcon(beforeAnyOf:)`: 원하는 자리 오른쪽 항목 전체를 받아 첫 가시 항목을 기준으로,
   하나도 없으면 옮기지 않음.

검증: 실행→강제 재정렬(diag.realign)→재확인 3회 덤프(diag.dumpOrder)에서 순서 완전 동일.

또, MAIN 안에서 남의 아이콘을 드래그하면 이제 스낵 메시지로 "macOS 제한, ⌘+드래그 안내"를 보여준다
(전에는 말없이 제자리로 돌아가 고장처럼 보였다).

### 5.3 드래그 성능 — 미측정

접근성 캐싱 + 0.5초 디바운스 + 삽입 표시선은 들어가 있으나 사용자 체감은 미확인.
남은 후보: 드롭마다 도는 `reload()`의 아이콘 재조회, SwiftUI `onDrag`/`onDrop` 자체 지연.
**측정 없이 고치지 말 것.**

### 5.4 원리상 한계 (사용자 안내 사항)

숨김은 왼쪽부터 이어진 연속 구간에만 걸린다. 분류가 불연속이면 설정 화면에 주황색으로 표시된다.
해소 방법 두 가지: ① 사용자가 메뉴바에서 `⌘`+드래그 ② 4.3의 defaults 조작(앱 재시작 필요).

### 5.5 숨긴 항목의 팝업 위치

4.7 참고 — 화면 왼쪽 끝에 열린다. 기획안 9절의 "잠깐 표시 → 좌표 클릭 → 재숨김" 경로를
AXPress보다 앞세우면 원래 위치 근처에 열리겠지만, 메뉴바가 깜빡이는 대가가 있다. 사용자와 상의.

---

## 6. 과거 세션의 실패 (반복 금지)

1. 확인 없이 `layout.json`을 지웠다 → 상태 파일은 사용자 데이터. 지우기 전에 백업하고 묻는다.
2. 식별자 체계 변경으로 유령 항목 양산 → 식별자를 바꾸면 기존 저장 데이터가 전부 유령이 된다.
3. 한 번 측정하고 단정 → **최소 2~3회 반복 측정.**
4. `physicalOrder`를 조기 반환하는 함수 안에서만 갱신해 순서가 비었다 → 지금은 `rescan()`에서 항상 갱신.
5. 성능 개선을 측정 없이 주장.
6. 사용자가 지적한 문제를 설명만 하고 고치지 않음.
7. (2026-08-01) `ps | grep | kill`로 자기 셸을 죽임 → `pgrep -f` 사용.
8. (2026-08-01) 앱 실행 중에 layout.json을 고치면 사용자의 드래그 편집과 충돌한다.
   실제로 사용자가 편집 중이었다 — 앱을 끄고 고치거나, 설정 UI를 통해서만.

---

## 7. 다음에 할 일 (순서대로)

0. **5.0 체크리스트 — 사람 손이 필요한 실기기 검증.** 여기부터 한다.
1. (2026-08-01 기록) **외부 모니터 연결 후 5.1 검증.** `--dump` 2회 이상 + `defaults read com.rrllab.FireMenuBar`.
   아이콘 식별자·배치 유지 확인. 연결↔해제 반복.
2. 드래그 지연 실측 후 개선(5.3).
3. 빈 영역 클릭 실검증(코드 있음, `--hittest`는 판정만 확인함).
4. 잠자기 복귀·클램셸 등 기획안 27절 체크리스트.
5. Developer ID 서명 · 공증 · DMG (기획안 Phase 8).

---

## 8. 코드 구조

```
Sources/FireKit/      순수 로직. AppKit 없음. `swift test`로 고정한다
├── BarItem.swift            메뉴바 항목 하나의 식별자 + 가로 좌표
├── StatusItemPosition.swift 위치값 범위 검사 (0 ≤ v ≤ 화면폭)
├── BoundaryPlanner.swift    분류 → 구분자 위치. 없는 항목은 absent로 보고
├── ScreenRows.swift         화면별 행 분리, 기준 행 선택(항목 최다)
├── LayoutVerifier.swift     기대 집합 vs 실측 집합
├── ContiguityAdvisor.swift  "X를 Y 오른쪽으로 ⌘드래그하세요" 계산
├── FireBarContents.swift    Fire Bar에 그릴 항목(지정 + 말려든 것)
├── MenuBarNameMerge.swift   화면마다 다른 창 이름을 종류별로 분리
├── PhysicalOrder.swift      순서 병합. **중복 없음을 보장**(크래시 방지)
├── ImageBounds.swift        아이콘 여백 잘라내기
└── ScanTrust.swift          과도기 스캔 판별(`ord:` 증가)

Sources/Fire/
├── App/              진입점, 조립(AppDelegate), 진단 모드 + 원격 훅(Diagnostics)
├── StatusItem/       Fire 아이콘 + 보이지 않는 구분자, 위치 조작
├── MenuBar/          탐색(Scanner) · 식별(Item) · 구역 적용(LayoutController) · 클릭 프록시(ActionProxy) · 아이콘 렌더링
├── FireBar/          패널 · 아이콘 뷰 · 위치 계산
├── Events/           빈 영역 판정 · 전역 클릭 · 단축키 · 시스템 이벤트
├── Stability/        재구성 코디네이터 · Watchdog
├── Settings/         설정창(SwiftUI) · 저장소
├── Permissions/      손쉬운 사용 · 화면 기록
└── LoginItem/        SMAppService
```

- `MenuBarScanner.swift` — 탐색·식별·아이콘·노치 합성(`concealedItems`)·오른쪽 끝 거리(`rightEdgeDistance`).
- `ControlItemCoordinator.swift` — 숨김 메커니즘과 위치 조작.
- `MenuBarLayoutController.swift` — 분류를 실제 상태로 연결. `alignSeparator()`가 경계를 계산.
- `MenuBarItem.isNotchConcealed` — 노치 합성 항목 표시. 캡처 금지·좌표 클릭 금지의 근거.
- `MenuBarLayoutController.applySectionsVerified` — 적용 후 재측정·재시도·실패 정책.
  **`applySections()`를 직접 부르지 말 것.** 검증 없이 적용하면 2026-08-27이 반복된다.
- `ControlItemCoordinator.rescueFireIconIfCollapsed` — Fire 아이콘이 숨김 구간에 말려들면
  구분자 바로 오른쪽으로 피신시킨다. 남의 아이콘은 못 옮겨도 자기 것은 옮길 수 있다.
- `ControlItemCoordinator.sanitizeStoredPositions` — 시작 시 범위 밖 위치값 삭제.
  `FireControlItem = 2525`가 재부팅을 넘어 살아남아 매번 사고를 재생산했다.

## 8-1. 진단 훅 (2026-08-27 추가)

실행 중인 Fire에 분산 알림을 보내 상태를 뽑는다. 결과는 `Application Support/Fire/diag-result.txt`.

```bash
p() { swift -e "import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name(\"com.rrllab.FireMenuBar.diag.$1\"), object: ${2:-nil}, userInfo: nil, deliverImmediately: true)"; }
p clickProbe      # 전역 클릭 모니터 상태 + 권한 + 마지막 관찰 클릭
p hitTest '"400,948"'   # 임의 좌표의 빈 영역 판정
p fireBarDump     # Fire Bar 내용물 + 아이콘 출처. 아이콘을 panel-*.png로 뽑는다
p openSettings    # 설정 화면 열기. 2026-08-27 크래시 지점을 밟아본다
p toggleBar / dumpOrder / realign / press / pressRight
```

## 9. 실측 방법

앱의 자체 보고를 믿지 않는다. layer 25 창을 직접 센다.

```bash
swift scripts/measure-menubar.swift
python3 -c "import json;print(json.load(open('$HOME/Library/Application Support/Fire/recovery.json')))"
```

`lastRebuildResult`가 `verified:`로 시작하면 통과, `gave up after`면 실패(펼친 상태로 고정).
