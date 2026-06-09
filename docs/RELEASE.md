# damson release pipeline

`swift build -c release` → `.app` bundle → Developer ID 코드사인 →
Apple notarization → `.dmg`. Sparkle 자동업데이트와 GitHub Actions 자동화는
별도 단계로 남겨둠.

## 1회성 준비

### Apple Developer 인증서

Developer ID Application 인증서가 keychain에 있어야 함.

```sh
security find-identity -p codesigning -v
# 출력 예:
#   1) 1234ABCD... "Developer ID Application: Your Name (TEAMID)"
```

해당 식별자 전체 문자열을 `APPLE_SIGNING_IDENTITY`에 설정.

### Notarization credentials

두 가지 방법 중 하나:

**방법 A — keychain profile (권장)**

```sh
xcrun notarytool store-credentials halite-notary \
    --apple-id you@example.com \
    --team-id TEAMID \
    --password "xxxx-xxxx-xxxx-xxxx"   # app-specific password
```

이후 `NOTARY_KEYCHAIN_PROFILE=halite-notary`만 설정.

**방법 B — env로 매번 전달**

`APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD` (appleid.apple.com에서 발급),
`APPLE_TEAM_ID`를 매 실행마다 export.

## 한 번에 릴리즈

```sh
export APPLE_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export NOTARY_KEYCHAIN_PROFILE=halite-notary
MARKETING_VERSION=0.1.0 ./scripts/release.sh
```

결과:
```
dist/
├── Damson.app          # 서명 + 노타라이즈 + staple 완료
└── Damson-0.1.0.dmg    # 서명 + 노타라이즈 + staple 완료
```

## 단계별로

빠른 iteration:

```sh
# 1) 빌드만 — 서명 없이 dev 검증
SKIP_NOTARIZE=1 ./scripts/build-app.sh
open dist/Damson.app

# 2) 서명만 — 노타라이즈는 시간 걸리므로 분리
SKIP_NOTARIZE=1 ./scripts/sign-and-notarize.sh

# 3) 정식 (서명 + 노타라이즈)
./scripts/sign-and-notarize.sh

# 4) dmg
./scripts/build-dmg.sh
```

## 검증

배포본이 실제로 Gatekeeper를 통과하는지:

```sh
spctl --assess --type execute --verbose=4 dist/Damson.app
# accepted, source=Notarized Developer ID
```

`.dmg`도:

```sh
spctl --assess --type open --context context:primary-signature dist/Damson-0.1.0.dmg
```

## halite-cli 설치

`.app` 번들 안에 `Contents/Resources/halite-cli`로 들어가 있음. 사용자가
`/usr/local/bin`에 symlink 거는 게 일반적:

```sh
sudo ln -sf /Applications/Damson.app/Contents/Resources/halite-cli \
    /usr/local/bin/halite-cli
halite-cli --list-instances
```

향후 Settings UI에서 "Install Command-Line Tool…" 버튼 추가 예정.

## 버전 관리

`MARKETING_VERSION` env로 marketing version (CFBundleShortVersionString)
지정. `BUILD_NUMBER` 미지정 시 epoch seconds로 자동 채움.

```sh
MARKETING_VERSION=0.2.0 BUILD_NUMBER=20260526 ./scripts/release.sh
```

## Sparkle 자동업데이트

`.app`은 SPUStandardUpdaterController로 부팅 시 자동으로 업데이트 체크.
사용자는 App 메뉴 → "Check for Updates…"로 즉시 체크 가능.

### 1회성: EdDSA 키 발급

```sh
./scripts/sparkle-keygen.sh
# 출력 예: rxFA7zVTQNxX1cd...= (base64 public key)
```

이 public key 문자열을 `SPARKLE_PUBLIC_KEY` env에 넣어두면 build-app.sh가
Info.plist의 `SUPublicEDKey`로 자동 박는다. private key는 macOS keychain에
저장된 상태로 유지 (`security find-generic-password -s "https://sparkle-project.org" -a ed25519`).

### 릴리즈할 때

```sh
export SPARKLE_PUBLIC_KEY='rxFA7zVTQNxX1cd...='
MARKETING_VERSION=0.1.0 ./scripts/release.sh
./scripts/sparkle-appcast.sh \
    --dmg dist/Damson-0.1.0.dmg \
    --version 0.1.0 \
    --build 1 \
    --url 'https://github.com/hulryung/damson/releases/download/v0.1.0/Damson-0.1.0.dmg' \
    > /tmp/entry.xml
python3 .github/scripts/insert-appcast-entry.py appcast.xml /tmp/entry.xml > appcast.new.xml
mv appcast.new.xml appcast.xml
git add appcast.xml && git commit -m "appcast 0.1.0"
git tag v0.1.0 && git push --tags
gh release create v0.1.0 dist/Damson-0.1.0.dmg
```

`SUFeedURL`이 `https://raw.githubusercontent.com/.../main/appcast.xml`로
박혀 있어서, appcast.xml 커밋이 main에 push되면 다음 백그라운드 체크에서
사용자에게 알림이 뜬다.

## GitHub Actions 자동 릴리즈

`.github/workflows/release.yml` — `v*` 태그 push 시 자동으로 모든 단계 실행
(빌드 → 사인 → 노타라이즈 → .dmg → appcast 갱신 → GitHub Release 생성).

### 필요한 secrets (Settings → Secrets and variables → Actions)

| 키 | 설명 |
|---|---|
| `APPLE_CERTIFICATE_BASE64` | Developer ID Application `.p12`를 `base64 -i cert.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | `.p12` import 시 사용한 password |
| `APPLE_SIGNING_IDENTITY` | `"Developer ID Application: Your Name (TEAMID)"` |
| `APPLE_ID` | Apple ID 이메일 |
| `APPLE_APP_SPECIFIC_PASSWORD` | appleid.apple.com 발급 |
| `APPLE_TEAM_ID` | `ABCDE12345` |
| `SPARKLE_PUBLIC_KEY` | base64 EdDSA public key (sparkle-keygen.sh 출력) |
| `SPARKLE_PRIVATE_KEY` | base64 EdDSA private key (keychain export) |

private key export 방법:
```sh
security find-generic-password -s "https://sparkle-project.org" -a ed25519 -w \
  | base64
# 이 출력을 SPARKLE_PRIVATE_KEY secret에 붙여넣음.
```

### 사용

```sh
git tag v0.1.0
git push --tags
# Actions가 자동 실행됨. 진행 상황: gh run watch
```

수동 트리거도 가능: Actions 탭 → "release" workflow → "Run workflow" → version 입력.

## 알려진 제한

- **Universal binary 미지원** — 현재 빌드 머신 아키텍처(arm64 또는 x86_64)만.
  CI도 arm64(macos-14)에서만 돌아감. Intel 사용자도 지원하려면
  `swift build --arch arm64 --arch x86_64` + `lipo`로 합치는 단계 필요.
- **App icon 미적용** — `Resources/Damson.icns` 추가하면 자동으로 번들에
  포함되도록 build-app.sh가 미리 처리해 둠.
