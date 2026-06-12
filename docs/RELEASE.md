# damson release pipeline

`swift build -c release` → `.app` bundle → Developer ID codesigning →
Apple notarization → `.dmg`. Sparkle auto-updates and GitHub Actions
automation are left as separate steps.

## One-time setup

### Apple Developer certificate

A Developer ID Application certificate must be in the keychain.

```sh
security find-identity -p codesigning -v
# Example output:
#   1) 1234ABCD... "Developer ID Application: Your Name (TEAMID)"
```

Set the full identity string as `APPLE_SIGNING_IDENTITY`.

### Notarization credentials

Pick one of two methods:

**Method A — keychain profile (recommended)**

```sh
xcrun notarytool store-credentials damson-notary \
    --apple-id you@example.com \
    --team-id TEAMID \
    --password "xxxx-xxxx-xxxx-xxxx"   # app-specific password
```

Then just set `NOTARY_KEYCHAIN_PROFILE=damson-notary`.

**Method B — pass via env every time**

Export `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD` (issued at appleid.apple.com),
and `APPLE_TEAM_ID` on every run.

## Release in one shot

```sh
export APPLE_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export NOTARY_KEYCHAIN_PROFILE=damson-notary
MARKETING_VERSION=0.1.0 ./scripts/release.sh
```

Result:
```
dist/
├── Damson.app          # signed + notarized + stapled
└── Damson-0.1.0.dmg    # signed + notarized + stapled
```

## Step by step

For fast iteration:

```sh
# 1) Build only — dev verification without signing
SKIP_NOTARIZE=1 ./scripts/build-app.sh
open dist/Damson.app

# 2) Sign only — notarization takes time, so keep it separate
SKIP_NOTARIZE=1 ./scripts/sign-and-notarize.sh

# 3) The real thing (sign + notarize)
./scripts/sign-and-notarize.sh

# 4) dmg
./scripts/build-dmg.sh
```

## Verification

To confirm the distribution actually passes Gatekeeper:

```sh
spctl --assess --type execute --verbose=4 dist/Damson.app
# accepted, source=Notarized Developer ID
```

The `.dmg` too:

```sh
spctl --assess --type open --context context:primary-signature dist/Damson-0.1.0.dmg
```

## Installing damson-cli

It ships inside the `.app` bundle as `Contents/Resources/damson-cli`. Users
typically symlink it into `/usr/local/bin`:

```sh
sudo ln -sf /Applications/Damson.app/Contents/Resources/damson-cli \
    /usr/local/bin/damson-cli
damson-cli --list-instances
```

An "Install Command-Line Tool…" button in the Settings UI is planned.

## Versioning

Set the marketing version (CFBundleShortVersionString) via the
`MARKETING_VERSION` env var. If `BUILD_NUMBER` is unset, it is auto-filled
with epoch seconds.

```sh
MARKETING_VERSION=0.2.0 BUILD_NUMBER=20260526 ./scripts/release.sh
```

## Sparkle auto-updates

The `.app` automatically checks for updates at launch via
SPUStandardUpdaterController. Users can check immediately via the App menu →
"Check for Updates…".

### One-time: generate the EdDSA key

```sh
./scripts/sparkle-keygen.sh
# Example output: rxFA7zVTQNxX1cd...= (base64 public key)
```

Put this public key string in the `SPARKLE_PUBLIC_KEY` env var and
build-app.sh automatically bakes it into Info.plist as `SUPublicEDKey`. The
private key stays stored in the macOS keychain
(`security find-generic-password -s "https://sparkle-project.org" -a ed25519`).

### When releasing

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

`SUFeedURL` is baked in as `https://raw.githubusercontent.com/.../main/appcast.xml`,
so once the appcast.xml commit is pushed to main, users get notified on the
next background check.

## GitHub Actions automated release

`.github/workflows/release.yml` — pushing a `v*` tag runs every step
automatically (build → sign → notarize → .dmg → appcast update → GitHub
Release creation).

### Required secrets (Settings → Secrets and variables → Actions)

| Key | Description |
|---|---|
| `APPLE_CERTIFICATE_BASE64` | Developer ID Application `.p12` via `base64 -i cert.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | Password used when importing the `.p12` |
| `APPLE_SIGNING_IDENTITY` | `"Developer ID Application: Your Name (TEAMID)"` |
| `APPLE_ID` | Apple ID email |
| `APPLE_APP_SPECIFIC_PASSWORD` | Issued at appleid.apple.com |
| `APPLE_TEAM_ID` | `ABCDE12345` |
| `SPARKLE_PUBLIC_KEY` | base64 EdDSA public key (sparkle-keygen.sh output) |
| `SPARKLE_PRIVATE_KEY` | base64 EdDSA private key (keychain export) |

How to export the private key:
```sh
security find-generic-password -s "https://sparkle-project.org" -a ed25519 -w \
  | base64
# Paste this output into the SPARKLE_PRIVATE_KEY secret.
```

### Usage

```sh
git tag v0.1.0
git push --tags
# Actions runs automatically. Watch progress: gh run watch
```

Manual trigger also works: Actions tab → "release" workflow → "Run workflow" → enter version.

## Known limitations

- **No universal binary support** — only the build machine's architecture
  (arm64 or x86_64). CI also runs only on arm64 (macos-14). Supporting Intel
  users would require a `swift build --arch arm64 --arch x86_64` + `lipo`
  merge step.
- **App icon not applied** — build-app.sh is already set up to include
  `Resources/Damson.icns` in the bundle automatically once it's added.
