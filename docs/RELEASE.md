# halite-swift release pipeline

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
├── Halite.app          # 서명 + 노타라이즈 + staple 완료
└── Halite-0.1.0.dmg    # 서명 + 노타라이즈 + staple 완료
```

## 단계별로

빠른 iteration:

```sh
# 1) 빌드만 — 서명 없이 dev 검증
SKIP_NOTARIZE=1 ./scripts/build-app.sh
open dist/Halite.app

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
spctl --assess --type execute --verbose=4 dist/Halite.app
# accepted, source=Notarized Developer ID
```

`.dmg`도:

```sh
spctl --assess --type open --context context:primary-signature dist/Halite-0.1.0.dmg
```

## halite-cli 설치

`.app` 번들 안에 `Contents/Resources/halite-cli`로 들어가 있음. 사용자가
`/usr/local/bin`에 symlink 거는 게 일반적:

```sh
sudo ln -sf /Applications/Halite.app/Contents/Resources/halite-cli \
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

## 알려진 제한

- **Universal binary 미지원** — 현재 빌드 머신 아키텍처(arm64 또는 x86_64)만.
  CI에서 `swift build --arch arm64 --arch x86_64` + `lipo`로 합치는 단계는
  C4 후속 작업.
- **Sparkle 미통합** — 자동 업데이트는 별도 작업.
- **App icon 미적용** — `Resources/Halite.icns` 추가하면 자동으로 번들에
  포함되도록 build-app.sh가 미리 처리해 둠.
