# 한글 폰트 cascade 처리

damson는 NSTextView + NSAttributedString 기반 렌더링을 쓴다 (cmux 통합에 필요한
DamsonTerminal package의 설계). macOS의 system font fallback chain은 *언어* 글리프
(Hangul/Hanzi 등)는 자동 처리하지만, 자동 fallback이 항상 우리가 원하는 한글 폰트로
가는 것은 아니다. 또 macOS 버전마다 fallback 우선순위가 미세하게 달라 line height에
차이가 생기기도 한다.

→ `Sources/DamsonTerminal/FontCascade.swift`의 `fontWithNerdFallback(family:size:)`이
   모든 폰트 생성 지점에서 호출되어, NSFontDescriptor의 `cascadeList`에 한글 fallback을
   **명시적으로** 박는다.

## Cascade 순위

```
1. Primary           = 사용자가 Settings → Font → Family에서 고른 폰트
                       (디폴트: Menlo)
2. Nerd Font         = 시스템에 설치된 Nerd Font Mono 임의 1개 — Powerline glyph
                       (PUA U+E0A0+) 용. primary가 이미 Nerd Font면 skip.
3. 한글 monospace     = 아래 순서로 시도, 첫 설치된 것 선택:
                         - D2Coding
                         - D2CodingLigature
                         - D2Coding Nerd Font Mono
                         - D2Coding Nerd Font
                         - D2CodingLigature Nerd Font Mono
                         - D2CodingLigature Nerd Font
                         - NanumGothicCoding
4. Apple SD Gothic Neo = 위 3.이 모두 미설치인 경우만. macOS 모든 시스템에 있음.
                         단 monospace가 아니라 한글 글자 폭이 약간씩 다를 수 있음.
```

## 왜 D2Coding 우선인가

| 측면 | D2Coding | Apple SD Gothic Neo |
|---|---|---|
| **monospace** | ✅ 한글 글자 폭이 균일. cell-grid에 정확히 정렬 | ❌ proportional. 한글마다 폭 미세 차이 |
| **개발자 가독성** | ✅ 한국 개발자 표준. NHN/네이버가 코딩용으로 디자인 | ❌ UI/문서용 폰트 |
| **무료 + 설치** | ⚠️ 별도 설치 필요 (대부분 한국 개발자는 이미 가짐) | ✅ macOS 기본 |

D2Coding이 monospace로 정렬되므로 터미널의 셀 격자와 일치 → 한영 혼용 시 정렬이
어긋나지 않는다. 한국 개발자 대부분이 이미 설치해 두므로 fallback 우선순위 최상위로
두는 게 합리적. 미설치 환경에서는 Apple SD Gothic Neo가 최소한의 안전망 역할.

## 변형 이름들

D2Coding은 변형이 많다. 명시적으로 enumerate한 이름 (`koreanMono` 배열):

| 이름 | 설명 |
|---|---|
| `D2Coding` | 기본 |
| `D2CodingLigature` | 코딩 ligature(==, !=, =>) 포함 |
| `D2Coding Nerd Font` | Nerd Font patch (Powerline glyph 포함) |
| `D2Coding Nerd Font Mono` | + 1셀폭 강제 (글리프 align 보장) |
| `D2CodingLigature Nerd Font` | Ligature + Nerd Font |
| `D2CodingLigature Nerd Font Mono` | Ligature + Nerd Font + 1셀폭 |
| `NanumGothicCoding` | 네이버 이전 세대 한글 코딩 폰트 |

설치된 것을 **첫 번째 hit으로** 선택. 사용자 시스템에 여러 변형이 있어도 cascade는
하나만 들어감.

## 추가 / 변경 시 주의

`fontWithNerdFallback`은 DamsonSurfaceView의 세 군데에서 호출된다:

- `init` (윈도우 첫 생성)
- `applyConfig` (Settings에서 폰트 변경 hot-reload)
- `setZoom` (Cmd+= / - / 0)

폰트 생성 신규 경로를 추가하는 경우 반드시 이 helper를 거치도록 해야 한글 cascade가
유지된다. 직접 `NSFont(name:size:)`를 호출하면 fallback이 안 박혀서 폰트 변경 후
한글이 다른 폰트로 그려지는 회귀가 발생함.

## 향후 후보

- 사용자가 Settings에서 한글 fallback 폰트를 직접 고르도록 picker 추가 (D2Coding /
  Nanum / SD Gothic Neo / Pretendard Mono / ...)
- 한자(Hanzi) / 일본어(Hiragana/Katakana) 전용 fallback도 같은 패턴으로 추가 가능
