# tmux 통합 계획 (tmux `-CC` control mode)

Claude Code의 **agent teams** "split-pane" 모드를 Damson의 **네이티브 탭/패널**로 렌더링하기 위한 설계.
Damson가 iTerm2의 "iTerm2 + tmux -CC" 위치를 맡는다 — Damson가 tmux control client가 되어,
tmux window → Damson Tab, tmux pane → Damson split으로 매핑한다.

---

## 1. 목표 / 사용 시나리오

Claude Code의 **agent teams** (experimental, env `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, v2.1.32+)는
두 가지 디스플레이 모드를 가진다.

- **in-process**: 하나의 터미널 안에서 팀원 세션을 순환(Shift+Down)한다. 어디서나 동작하지만 **동시에 볼 수 없다**.
- **split-pane**: 팀원 하나당 패널 하나. **여러 agent 세션을 동시에** 한 화면에서 본다. 단 tmux 또는 iTerm2를 요구한다.

split-pane 모드는 현재 **Ghostty, VS Code terminal, Windows Terminal에서 지원되지 않는다**.
즉, 이걸 지원하면 Damson만의 분명한 차별점이 된다. (출처: https://code.claude.com/docs/en/agent-teams)

**목표**: 사용자가 Damson에서 `tmux -CC`로 시작한 세션 안에서 Claude Code agent teams를 split-pane으로 켜면,
각 팀원 패널이 Damson의 **네이티브 탭/split**으로 나타나도록 한다. Damson 자체 UI(탭바, 분할 리사이즈, 포커스)로
여러 agent를 동시에 보고 조작한다.

핵심: **Claude Code는 tmux를 평범한 명령(`split-window`, `send-keys`, pane id `%N`)으로 구동한다.**
`-CC` control protocol은 **tmux ↔ 터미널 에뮬레이터** 사이에서만 쓰인다. 따라서 Damson는 Claude Code를
전혀 알 필요가 없다 — Damson가 `tmux -CC` 세션을 네이티브로 렌더링하면 agent-team 패널은 **자동으로** 나타난다.
공식 문서도 "tmux -CC in iTerm2"를 권장 진입점으로 든다.

---

## 2. 접근 결정

채택: **tmux `-CC` control mode (iTerm2 모델)**.

기각한 대안:

| 대안 | 기각 사유 |
|---|---|
| Claude Code in-process 모드만 지원 | 한 터미널 안에서 순환할 뿐, **동시 표시가 불가능**. 사용자가 원한 그림(여러 패널 동시)을 못 준다. |
| Damson 자체 persistence daemon (세션 영속화) | 프로세스 생존성은 줄 수 있어도 **tmux 호환을 주지 못한다**. Claude Code가 기대하는 tmux 명령(`split-window` 등)을 받을 주체가 없다. |
| iTerm2 it2 / Python API 재구현 | Damson는 iTerm2가 아니다. agent teams는 iTerm2 API가 아니라 **tmux 명령**으로 구동되므로 잘못된 타깃. |

tmux `-CC`를 고른 이유:

- agent teams가 **이미 tmux를 가정**하고, tmux는 `-CC`로 **구조화된 control protocol**(window/pane/layout/output 알림)을
  내보낸다. Damson는 이 protocol만 말하면 된다.
- Grid가 PTY로부터 **분리되어 있다**(아래 §5). 한 pane의 터미널 상태/렌더링은 bytes가 local forkpty에서 오는지
  tmux `%output`에서 오는지 신경 쓰지 않는다 — 이미 검증된 분리.
- iTerm2가 같은 모델로 수년간 검증했다. 우리는 그 제약(아래 §8)까지 그대로 물려받는다.

---

## 3. 동작 그림

```
사용자
  │  (Damson에서 "tmux -CC attach" / "tmux -CC new")
  ▼
Damson  ──spawn──▶  tmux -CC  (control client = Damson)
  │                    │
  │  stdin: 평범한 tmux 명령        stdout: %begin/%end, %output, %layout-change ...
  │  (refresh-client -C, send-keys) │
  ▼                                 ▼
  │   tmux 세션 안에서 사용자가:
  │     $ claude   (agent teams, split-pane)
  │        └─ claude가 tmux에 split-window / send-keys 명령 발행
  │             └─ tmux가 pane %2,%3... 생성, 각 pane에서 agent 프로세스 실행
  │
  │   tmux ──▶ Damson:  %window-add @1
  │                     %layout-change @1 <layout> ...
  │                     %output %2 <agent2 출력>
  │                     %output %3 <agent3 출력>
  ▼
Damson가 위 알림을 해석:
  %window-add  → 새 Tab
  %layout-change → PaneTree 재조정(네이티브 split)
  %output %N   → 해당 pane의 Grid에 bytes 주입
  → 사용자는 Damson 네이티브 패널에서 여러 agent를 동시에 본다
키 입력 → Damson가 send-keys -t %N 으로 tmux에 전달
리사이즈 → Damson가 refresh-client -C <w>,<h> 로 tmux에 전달
```

Claude Code 자신은 `-CC` protocol을 전혀 모른다. 그저 tmux 명령을 쏠 뿐이고, control protocol은
tmux와 Damson 사이의 일이다.

---

## 4. control mode 프로토콜 요약

출처: https://github.com/tmux/tmux/wiki/Control-Mode

### 4.1 명령 프레이밍

control client(Damson)가 stdin으로 보낸 모든 tmux 명령의 응답은 다음으로 감싸진다.

```
%begin <timestamp> <command-number> <flags>
... 명령 출력 (성공 시) ...
%end   <timestamp> <command-number> <flags>
```

실패 시 `%end` 대신 `%error <timestamp> <command-number> <flags>`. begin/end의 `timestamp`/`command-number`/`flags`는
서로 매칭된다 → 어느 명령에 대한 응답인지 식별 가능.

### 4.2 출력 알림

- `%output %<paneid> <data>` — pane 출력.
  **인코딩**: ASCII 32 미만 바이트와 `\`는 octal escape로 치환된다 (CR=`\015`, LF=`\012`, backslash=`\134`).
  그 외 바이트는 verbatim (raw escape sequence를 포함할 수 있다). → Damson는 디코드 후 그대로 해당 pane의 VTParser/Grid에 먹인다.
- `%extended-output %<pane> <ms> : <data>` — lag(지연) 정보가 붙은 출력. flow control(아래)과 함께 쓰인다.

### 4.3 layout / window 알림

- `%window-add @<win>`
- `%window-close @<win>`
- `%window-renamed @<win> <name>`
- `%unlinked-window-add/-close/-renamed @<win>`
- `%window-pane-changed @<win> %<pane>` — window의 active pane 변경
- `%layout-change @<win> <layout> <visible-layout> <flags>` — **핵심**. window의 pane 배치가 바뀜.

### 4.4 session 알림

- `%session-changed $<sid> <name>`
- `%session-renamed <name>`
- `%sessions-changed`
- `%session-window-changed $<sid> @<win>`
- `%client-session-changed`

### 4.5 기타

- `%pane-mode-changed %<pane>` — pane이 copy-mode 등으로 진입/이탈
- `%subscription-changed`
- `%exit` — control client가 `-CC`에서 빠져나감

### 4.6 flow control

- tmux → client: `%pause %<pane>` / `%continue %<pane>`
- client → tmux: `refresh-client -A '%<pane>:continue|pause|off'`
- 활성화: `refresh-client -f pause-after=N` (N초 이상 lag면 pause)
- 출력 억제: `refresh-client -f no-output`

### 4.7 ID 규칙

- session `$N`, window `@N`, pane `%N`.
- **항상 name/index가 아니라 ID를 쓴다** (name/index는 변할 수 있음).

### 4.8 client → tmux

- control client의 stdin에 **평범한 tmux 명령**을 한 줄씩 쓴다.
- 클라이언트 크기 설정: `refresh-client -C <w>,<h>`.
- 입력 전달: `send-keys -t %<pane>` (`-l` literal, `-H` hex).

### 4.9 layout string 포맷

`%layout-change`가 싣는 layout 문자열:

- 단일 pane: `<checksum>,<WxH>,<x>,<y>,<paneid>`
- 좌우(horizontal) 분할: children을 `{...}`로 묶음
- 상하(vertical) 분할: children을 `[...]`로 묶음
- **N-ary 중첩**이다. 예: `e7b2,80x24,0,0{40x24,0,0,1,39x24,41,0,2}`

이 N-ary 구조를 Damson의 **BINARY** PaneTree로 매핑하는 게 §5의 핵심 난제.

---

## 5. Damson 매핑

| tmux 개념 | Damson 개념 | 메커니즘 |
|---|---|---|
| window `@N` | `Tab` (`CompactWindowController.Tab`) | `%window-add`→`addTab`, `%window-close`→`closeTab` |
| pane `%N` | `PaneNode.leaf(session:surface:)` (`PaneTree.swift`) | leaf 하나당 pane id `%N` 바인딩 |
| `%output %N <data>` | 해당 leaf의 `DamsonSession`에 bytes 주입 → `Grid` | octal 디코드 후 `session`의 backend가 `onData`를 통해 주입 (§6) |
| `%layout-change @N` | 해당 Tab의 `PaneTreeView` 재조정 | layout string → BINARY tree로 reconcile |
| 키 입력 | tmux `send-keys -t %N` | local PTY write 대신 control client stdin에 명령 |
| 리사이즈 | tmux `refresh-client -C <w>,<h>` | local PTY `ioctl(TIOCSWINSZ)` 대신 |

### 5.1 BINARY vs N-ary layout 매핑 (핵심 난제)

- tmux layout은 **N-ary**: 한 split group에 child가 2개 이상일 수 있다 (`{a,b,c}`).
- Damson PaneTree는 **BINARY**: `case split(direction, first, second, ratio)` — 항상 자식 2개 (`PaneTree.swift` ~13-50).

**제안 전략 (P2)**: N-ary group을 **right-leaning binary chain**으로 펼친다.
`{a,b,c}` (horizontal) → `split(.horizontal, a, split(.horizontal, b, c))`.
ratio는 layout string의 `WxH`로부터 각 child의 폭/높이 비율을 계산해 채운다.
reconcile 시:

1. tmux layout을 파싱해 "원하는 트리"를 만든다 (pane id가 leaf 식별자).
2. 현재 Damson PaneTree와 **pane id 기준으로 diff**: 새 pane id → leaf 생성(빈 Grid), 사라진 id → `closeLeaf`,
   구조 변경 → split 재배치.
3. ratio만 바뀐 경우는 `rebuild(animation:)`로 비율만 갱신 (트리 구조 보존).

reconcile는 idempotent해야 한다 (같은 layout이 두 번 와도 안전). pane id가 stable identity이므로 가능.

right-leaning chain은 사용자가 Damson에서 직접 리사이즈할 때 약간 부자연스러울 수 있다 →
P2 이후 필요하면 PaneTree를 N-ary로 일반화하는 것도 고려 (별도 작업).

---

## 6. 새 컴포넌트

### 6.1 `SessionIOBackend` protocol (P0 — 이 문서가 명세하는 seam)

`DamsonSession`이 의존하는 I/O 표면을 추상화한다. local forkpty와 tmux pane이 모두 이 protocol로 들어온다.

```swift
/// A pluggable source/sink of terminal bytes for a DamsonSession.
/// Local sessions use a forkpty-backed implementation; a future tmux backend
/// will feed bytes from `%output` and send input via `send-keys`.
public protocol SessionIOBackend: AnyObject {
    var onData: ((Data) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }

    func spawn(argv: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) throws
    func write(_ data: Data)
    func resize(cols: Int, rows: Int)
    func terminate()

    var childWorkingDirectory: String? { get }
    var isRunningForegroundJob: Bool { get }
}
```

`PTYHost`(또는 얇은 `LocalPTYBackend` 어댑터)가 이 protocol을 conform한다. P0 단계에서는 `PTYHost` 자체가
이미 이 표면을 그대로 갖고 있으므로 **직접 conform**시킨다 (어댑터 불필요).

### 6.2 `TmuxControlClient` (P1+)

`tmux -CC`를 spawn하고, stdout을 라인 파싱해 control 알림을 해석, stdin에 명령을 쓴다.

```swift
public final class TmuxControlClient {
    // 한 control client = 한 PTYHost (tmux -CC를 forkpty로 띄움)
    public var onWindowAdd: ((_ window: TmuxWindowID) -> Void)?
    public var onWindowClose: ((_ window: TmuxWindowID) -> Void)?
    public var onLayoutChange: ((_ window: TmuxWindowID, _ layout: TmuxLayout) -> Void)?
    public var onPaneOutput: ((_ pane: TmuxPaneID, _ data: Data) -> Void)?
    public var onPaneExit: ((_ pane: TmuxPaneID) -> Void)?

    public func attach(target: String?) throws        // tmux -CC [attach|new]
    public func sendKeys(to pane: TmuxPaneID, data: Data)   // send-keys -t %N -H ...
    public func setClientSize(cols: Int, rows: Int)         // refresh-client -C w,h
    public func sendCommand(_ line: String)                 // raw tmux 명령
}
```

`%output`의 octal escape 디코더, `%begin/%end/%error` 프레이밍 매칭, layout string 파서가 여기 포함된다.

### 6.3 `TmuxPaneBackend` (P1+)

특정 pane id `%N`에 묶인 `SessionIOBackend` 구현. `spawn`은 no-op(이미 tmux가 띄움),
`write`는 `client.sendKeys`, `resize`는 client 전체 리사이즈로 위임, `onData`는 `client.onPaneOutput`이 호출.

```swift
final class TmuxPaneBackend: SessionIOBackend {
    init(client: TmuxControlClient, pane: TmuxPaneID) { ... }
    // write → client.sendKeys(to: pane, ...)
    // onData ← client가 %output %pane 받을 때 호출
    // terminate → kill-pane -t %pane (또는 무시)
}
```

### 6.4 layout reconciler (P2+)

```swift
struct TmuxLayoutReconciler {
    /// tmux layout string → 원하는 BINARY 트리로 변환 후 PaneTreeView에 적용.
    func reconcile(_ layout: TmuxLayout, into tab: PaneTreeView,
                   makeSession: (TmuxPaneID) -> DamsonSession)
}
```

---

## 7. 단계별 로드맵 (P0–P3)

### P0 — backend abstraction (이 PR)

- `SessionIOBackend` protocol 도입. `PTYHost`가 conform. `DamsonSession`이 concrete `PTYHost` 대신 protocol 타입을 보유.
- 기본 생성은 여전히 local PTY → **런타임 동작 byte-for-byte 동일**.
- **exit 기준**: 동작 변화 0, `DamsonSession`/`DamsonTerminalView` public API 불변, `swift build` + `swift test` 통과.

### P1 — single `-CC` session attach

- `TmuxControlClient` 구현: `tmux -CC` spawn, `%begin/%end/%error` 프레이밍, `%output` octal 디코드,
  `%window-add`/`%window-close`/`%session-changed` 처리.
- tmux window → Damson Tab 매핑. `%output`→ 해당 pane Grid 주입(`TmuxPaneBackend`).
- 이 단계에서 **split은 tmux가 텍스트로 그려도 된다** (네이티브 split 아님). 즉 한 window = 한 Tab = 한 pane(또는 tmux가 ASCII로 그린 분할).
- **exit 기준**: `tmux -CC`로 attach한 세션이 Damson 탭으로 뜨고, 입력/출력/타이틀/종료가 정상.

### P2 — `%layout-change` → 네이티브 split

- layout string 파서 + `TmuxLayoutReconciler` (BINARY↔N-ary, §5.1).
- `%layout-change`를 받아 PaneTree를 재조정 → **agent-team 패널이 네이티브 동시 패널로 보인다** (이 단계가 목표 달성 지점).
- pane id 기준 diff, idempotent reconcile.
- **exit 기준**: `tmux split-window`(또는 agent teams split-pane)가 Damson 네이티브 split으로 렌더, 리사이즈/포커스 동작.

### P3 — 협상 / 자동화 / 마감

- resize 협상: `refresh-client -C <w>,<h>`. Damson 셀 크기 ↔ tmux 셀 크기 정합.
- flow control: `%pause`/`%continue`, `refresh-client -f pause-after=N`.
- `tmux -CC` handshake **자동 감지** (iTerm2 스타일: DCS tmux escape 감지 시 자동으로 control mode 진입).
- copy-mode / scrollback 접근.
- **exit 기준**: 큰 출력에서 끊김 없음, 윈도우 리사이즈 자연스러움, 일반 명령으로 `tmux -CC` 띄우면 자동 통합.

---

## 8. 리스크 / 제약

- **control protocol long tail**: VTParser가 그랬듯, control mode도 코너 케이스(unlinked window, subscription, pane-mode)가
  많다. P1은 핵심 알림만, 나머지는 점진적으로.
- **BINARY ↔ N-ary layout**: §5.1. right-leaning chain은 임시 해법이며 사용자 리사이즈 UX가 어색할 수 있다.
  최종적으로 PaneTree를 N-ary로 일반화할지 여부는 P2 결과를 보고 결정.
- **iTerm2가 물려준 제약** (출처: https://iterm2.com/documentation-tmux-integration.html):
  - tmux-backed 탭에 **non-tmux split pane을 섞을 수 없다**. 한 Tab은 전부 tmux이거나 전부 local.
  - **셀 크기 불일치**로 pane에 빈 영역이 생길 수 있다 (Damson 셀 크기 ≠ tmux가 가정하는 크기).
  - **scrollback이 네이티브만큼 빠르지 않다** — tmux copy-mode를 거쳐야 한다.
- **Claude Code가 tmux를 띄우는 방식**: Claude Code는 **이미 tmux 세션 안**에 있어야 split-pane을 쓴다.
  즉 사용자가 Damson에서 `tmux -CC`로 세션을 호스팅하고 그 안에서 `claude`를 실행해야 한다.
  Damson가 tmux를 자동 spawn해 줄지(편의), 사용자가 수동으로 할지는 P3 자동 감지에서 다룬다.
- **프로세스 모델 변화**: 현재 Damson는 단일 GUI 프로세스가 모든 PTY를 소유한다(daemon 없음).
  tmux 통합 시 tmux server가 별도 프로세스로 생존하므로 — Damson가 죽어도 tmux 세션은 남는다(영속성 보너스).
  단 `TmuxControlClient`의 생명주기와 Tab/PaneTree 생명주기 정합을 주의해야 한다.

---

## 9. P0 상세 설계 (Deliverable 2의 명세)

목표: **동작 변화 0**으로 backend seam을 넣는다.

### 9.1 `PTYHost`가 외부에 노출하는 실사용 표면 (검증됨)

`grep`으로 확인한, `PTYHost` 외부(주로 `DamsonSession`)가 실제로 쓰는 멤버:

- 콜백: `onData: ((Data) -> Void)?`, `onExit: ((Int32) -> Void)?`
- 메서드: `spawn(argv:env:cwd:cols:rows:)`, `write(_:)`, `resize(cols:rows:)`, `terminate()`
- 쿼리: `childWorkingDirectory: String?`, `isRunningForegroundJob: Bool`

`childPID`/`masterFD`는 **`PTYHost.swift` 내부에서만** 쓰인다 (`main.swift`의 언급은 주석뿐).
→ protocol에 넣지 않는다.

테스트(`Tests/DamsonTerminalTests/PTYResizeDiagTests.swift`)는 `PTYHost`를 **concrete 타입**으로 직접 쓴다 →
`PTYHost`의 public API를 그대로 두면 영향 없음.

### 9.2 protocol 정의 (`Sources/DamsonTerminal/SessionIOBackend.swift`, 신규)

§6.1의 `SessionIOBackend`. `spawn`의 `cols`/`rows`는 default arg를 protocol 요구사항에 둘 수 없으므로
명시 파라미터로 두고, 호출부(`DamsonSession`)는 항상 값을 넘긴다.

### 9.3 `PTYHost` conform

`PTYHost`의 현재 시그니처가 protocol과 정확히 일치한다 (`spawn`만 default arg가 있는데, default가 있어도
protocol 요구를 충족한다). → `extension PTYHost: SessionIOBackend {}` 한 줄, 또는 선언부에 `: SessionIOBackend` 추가.
어댑터(`LocalPTYBackend`)는 불필요 — 가장 덜 침습적인 방법.

### 9.4 `DamsonSession` 변경

- `private let pty = PTYHost()` → `private let pty: SessionIOBackend`.
- `init`에서 `self.pty = LocalPTYBackend()` 대신, 가장 단순하게 `self.pty = PTYHost()`로 기본 생성.
  (protocol 타입 변수에 concrete 인스턴스를 대입 — 동작 동일.)
- 나머지 `pty.onData`/`pty.onExit`/`pty.spawn`/`pty.write`/`pty.resize`/`pty.terminate`/
  `pty.childWorkingDirectory`/`pty.isRunningForegroundJob` 호출은 **그대로** (모두 protocol에 포함).
- public API(`write`, `resize`, `terminate`, `currentWorkingDirectory`, `hasRunningForegroundJob`, 등) **불변**.
- `// TODO(tmux P1): TmuxPaneBackend will conform to SessionIOBackend` 주석을 backend 선언 옆에 남긴다.

### 9.5 비-변경 보장

- 새 파일 1개(`SessionIOBackend.swift`) + `PTYHost.swift`에 conform 한 줄 + `DamsonSession.swift`의 타입 한 줄.
- 그 외 파일 무수정. tmux backend 미구현. reversible.
- 검증: `swift build` 성공, `swift test` 통과 (baseline green).

---

## 10. P1 구현 노트 (실제 구현됨)

### 10.1 새 파일 / 타입

- `Sources/DamsonTerminal/TmuxControlProtocol.swift`
  - ID 타입 `TmuxSessionID`/`TmuxWindowID`/`TmuxPaneID` (`$N`/`@N`/`%N` 토큰).
  - `TmuxLayout`(P1은 raw layout 문자열 보존), `TmuxCommandReply`, `TmuxControlEvent`.
  - `TmuxControlParser` — **순수 로직, I/O 없음**. 한 줄씩 먹여 이벤트를 받는다. `%begin/%end/%error`
    프레이밍(블록 안의 줄은 reply body로 모음), `%output` octal 디코드(`decodeOctalEscaped`),
    각 알림 파서, 알 수 없는 `%`/비-`%` 줄은 `.unhandled`로 흘려 crash 없음.
- `Sources/DamsonTerminal/TmuxControlClient.swift`
  - `PTYHost`(기본 backend)로 `tmux -C` spawn(P1.1에서 `-CC`→`-C`, §10.4.1) → stdout을 `\n` 단위로 잘라(끝의 `\r` 제거) 파서에 먹이고,
    이벤트를 public 콜백으로 팬아웃. writers: `sendKeys(to:data:)`(`send-keys -t %N -H <hex>`),
    `setClientSize(cols:rows:)`(`refresh-client -C w,h`, 동일 크기 coalesce), `sendCommand`, `killPane`.
- `Sources/DamsonTerminal/TmuxPaneBackend.swift`
  - `SessionIOBackend` 구현. `spawn`=no-op, `write`→`sendKeys`, `resize`→client 크기,
    `deliver(_:)`로 `%output` 주입, `terminate`→`kill-pane`.
- `Sources/damson/TmuxIntegrationController.swift`
  - `TmuxControlClient` + 전용 Compact 창 소유. window→tab, active pane→`TmuxPaneBackend`-backed
    `DamsonSession` 매핑. `%window-pane-changed`/`%layout-change`/`%output` 중 먼저 오는 것으로 pane을
    바인딩하고 탭을 lazily 생성. `firstPaneID(in:)`로 layout 문자열의 첫 leaf pane id 추출.

변경(추가만): `DamsonSession`에 backend 주입 init 추가(기본 경로 불변), `CompactWindowController`에
`addExternalTab(session:)`/`closeTab(matching:)` 추가, `main.swift`에 tmux 메뉴 + `attachTmux(_:)` 추가.

### 10.2 수동 테스트 절차 (tmux + 디스플레이 필요 — CI에서 불가)

1. tmux 설치: `brew install tmux` (빌드 머신엔 미설치).
2. 앱 실행: `DAMSON_NO_TRAMPOLINE=1 swift run damson` (또는 빌드된 .app).
3. 메뉴 **tmux ▸ Attach tmux (-CC)…** 선택.
   - 대상 세션 이름을 비워두면 **새 세션**(`tmux -C new-session`, P1.1부터 `-C`)을 띄운다.
   - 기존 세션 이름을 넣으면 그 세션에 attach(`tmux -C attach-session -t <name>`).
4. 기대 동작:
   - tmux 세션의 각 window가 Damson **탭**으로 뜬다(P1: 한 window=한 tab=active pane 하나).
   - 탭 안에서 입력 → 셸이 받음(input은 `send-keys`로 전달). 출력/타이틀이 정상 표시.
   - tmux에서 `tmux new-window`(또는 `Ctrl-b c`) → 새 탭 추가, window 닫으면 탭 닫힘.
   - 셸 종료(`exit`)/세션 detach(`%exit`) → 탭/통합 teardown.
5. agent-team 시나리오: 위 tmux 세션 안에서 `claude`를 split-pane으로 실행하면, P1에서는 분할이
   **tmux가 그린 텍스트 한 패널**로 보인다(네이티브 split은 P2).

### 10.3 P1이 아직 커버하지 않는 것 (P2/P3로 연기)

- **네이티브 split reconcile**: `%layout-change`는 파싱해 콜백으로 노출만 하고, PaneTree 재조정은 안 한다.
  한 window에 pane이 여럿이면 P1은 active pane 하나만 Damson pane으로 보여준다(나머지는 tmux가 텍스트로 그림).
- **resize 협상**: `setClientSize`로 `refresh-client -C`는 보내지만 Damson 셀 크기 ↔ tmux 셀 크기 정합/
  per-pane 사이징은 미구현.
- **flow control**: `%pause`/`%continue`/`%extended-output`은 `.unhandled`로 흘린다.
- **자동 감지**: DCS tmux escape 감지 후 control mode 자동 진입 없음(메뉴로 수동 트리거).
- **command-reply 상관**: reply의 command number를 노출만 하고, 보낸 명령과 1:1 매칭/대기는 안 한다.
- **pane cwd / foreground-job / copy-mode scrollback**: tmux backend는 `childWorkingDirectory=nil`,
  `isRunningForegroundJob=false`.

### 10.4.1 P1.1 수정 (실기(tmux 설치된 GUI) 테스트로 발견된 두 버그)

P1을 실제 tmux로 돌려 보니 빌드 머신(tmux 미설치)에선 못 잡은 두 버그가 나왔다.

**BUG 1 — `-CC` DCS handshake가 첫 프레임을 깨뜨림.**
`tmux -CC`는 첫 control 줄 앞에 DCS "enter control mode" 시퀀스(`ESC P1000p`)를 **`%begin`에 바로 붙여서**
보내고, 스트림 끝에 ST(`ESC \`)를 붙인다. 파서가 이를 안 벗겨서 첫 줄이 `\033P1000p%begin …`로 들어와
`.unhandled`가 되고, **첫 `%begin/%end` reply 블록 전체가 유실**됐다.
- **선택한 수정 (b)**: `attach()`를 `tmux -CC` → **`tmux -C`(single-C)**로 바꿨다. `-CC`의 DCS wrapper는
  *호스트 터미널*(사람이 `tmux -CC`를 친 iTerm2 등)이 control mode를 in-band로 감지하라고 붙는 것인데,
  Damson는 **전용 control client**로 tmux를 spawn하므로 필요 없다. `-C`는 tmux 3.6b에서 검증한 결과
  **byte-for-byte 동일한** control 알림(`%begin/%end`, `%window-add`, `%output`, `%exit` …)을 wrapper 없이 낸다.
  Claude Code의 "내가 tmux 안인가?" 감지는 `-C`/`-CC`가 아니라 `$TMUX` env var를 보므로 영향 없다.
- **방어**: 그래도 파서에 `stripDCSWrapper`를 넣어 stray DCS wrapper(선행 `ESC P…p`, 후행 `ESC \`)를
  벗긴다 — 누가 `-CC`를 쓰거나 P3 자동 감지가 들어와도 framing이 안 깨지게.

**BUG 2 — tmux pane이 Damson 탭에서 빈 화면(검정)으로 뜸.**
근본 원인은 **client size가 tmux에 전송되지 않음**이었다. 이전 `attach()`는 `lastSize=(cols,rows)`만 기록하고
`refresh-client -C`를 **보내지 않았다**. tmux는 PTY winsize가 아니라 `refresh-client -C`로만 control-client
크기를 받으므로, 윈도우가 0/기본 크기로 잡혀 **컨텐츠를 안 그렸다**(실기에서 `capture-pane -p`도 비어 있었음).
게다가 `setClientSize`의 no-op coalesce가 `lastSize`를 보고 같으면 스킵하므로, 나중에 같은 크기가 와도
영영 전송되지 않았다.
- **수정 1 (size)**: `attach()`가 spawn 직후 `setClientSize(cols,rows)`를 **실제로 호출**해 첫
  `refresh-client -C`를 보낸다. 이때 `lastSize`를 미리 seed하지 **않아** 첫 전송이 coalesce에 먹히지 않게 했다.
- **수정 2/3 (render path)**: 데이터 경로를 점검한 결과 `%output` → `TmuxControlClient.onPaneOutput`
  → `TmuxIntegrationController.deliverOutput` → `ensureTab`(첫 output에 lazy 생성) → `TmuxPaneBackend.deliver`
  → `DamsonSession`의 `onData` → `VTParser` → `Grid`로, **로컬 PTY와 동일한 경로**임을 확인했다(추가 수정 불필요).
  `deliverOutput`이 `ensureTab`를 먼저 부르므로 첫 output도 유실되지 않는다. 이 경로를 헤드리스로 증명하는
  통합 테스트(`testPaneOutputReachesDamsonSessionGrid`)를 추가했다 — 실제 tmux `%output`이 `DamsonSession.grid`
  셀에 도달함을 검증.
- **남은 검증**: 실제 **화면 렌더**(검정 화면 해소)는 디스플레이+accessibility가 필요해 헤드리스로 확인 불가.
  데이터 경로는 테스트로 증명했고, on-screen 확인은 GUI 재테스트(부모가 계측 실행)로 남긴다.

### 10.4 설계상 임의 결정 (문서에 없던 것)

- **input 인코딩**: `send-keys -H <hex>` 선택(`-l` literal 대신). 제어 바이트/셸 메타문자 escape 함정이 없어
  raw 바이트 전달에 안전.
- **탭 lazy 생성**: `%window-add`만으로는 pane id를 모르므로, pane이 처음 보이는 시점
  (`%window-pane-changed`/`%layout-change`/`%output` 중 먼저 오는 것)에 탭+세션을 만든다.
- **호스트 창**: 기존 창에 섞지 않고 attach마다 전용 `CompactWindowController` 창을 새로 띄운다
  (iTerm2 제약 §8: 한 탭은 전부 tmux이거나 전부 local).
