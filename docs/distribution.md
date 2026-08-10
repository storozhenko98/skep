# Distribution and updates

Skep is currently distributed as a signed beta. Repository visibility is a
separate release decision and must remain private until the owner explicitly
changes it. Vercel serves only the static product site, the packaged macOS
application, release notes, checksums, and the Sparkle appcast.

Production endpoints:

- product: <https://skep-compute.vercel.app>
- current download: <https://skep-compute.vercel.app/download>
- app update feed: <https://skep-compute.vercel.app/updates/appcast.xml>
- release metadata: <https://skep-compute.vercel.app/release.json>

## Release contract

`VERSION` is the user-facing semantic version and `BUILD_NUMBER` is the
monotonically increasing macOS bundle version. Every release must increment at
least `BUILD_NUMBER`; a public product change also increments `VERSION`.
Versioned artifacts include both values so a signing-only rebuild never replaces
previously published bytes or becomes invisible to Sparkle. The public website
serves a signed, notarized DMG with an Applications shortcut; Sparkle retains its
independently signed ZIP archives for in-app updates.

Create the complete local release with:

```sh
./scripts/package-release.sh
```

If only release notes changed after the notarized archive was created,
regenerate the signed feed without rebuilding or resubmitting the app:

```sh
SKEP_APPCAST_ONLY=1 ./scripts/package-release.sh
```

Set `SKEP_REBUILD_APPCAST=1` alongside that flag only when intentionally
reconstructing the feed from the retained immutable archives, such as when
removing a previously generated delta.

The command builds and tests the Rust and Swift components, creates
`artifacts/Skep.app`, bundles the local and Linux host payloads, signs the
Sparkle appcast with the Ed25519 update key stored in the macOS Keychain, and
and writes the Sparkle archive under `artifacts/updates`, plus the public disk
image and its `SHA256SUMS` under `artifacts/distribution`.
The beta channel publishes full archives rather than binary deltas, which keeps
the first transition from an ad-hoc build to a Developer ID build explicit.

The Sparkle account is `com.storozhenko.skep`. Its private key must never be
committed or placed in Vercel. Back it up in a secure credential store before
shipping the first external beta; losing it prevents existing installations
from trusting future updates. The public key in `Info.plist` is safe to ship.

## macOS application updates

Skep uses Sparkle 2 and checks the HTTPS appcast automatically. The feed signs
each archive independently, so a compromised static host cannot create a
trusted update without the private Ed25519 key. A user can also run **Check for
Updates** from the app menu or Settings.

The production beta is signed with `Developer ID Application: Mykyta
Storozhenko (QB9BZ77543)` and notarized through the local `skep-notary`
Keychain profile. On a replacement release Mac, create that profile once:

```sh
xcrun notarytool store-credentials skep-notary
```

Then package with:

```sh
SKEP_CODESIGN_IDENTITY="Developer ID Application: Mykyta Storozhenko (QB9BZ77543)" \
SKEP_NOTARY_PROFILE=skep-notary \
./scripts/package-release.sh
```

This enables the hardened runtime, timestamps the signature, notarizes and
staples the app, creates and signs the DMG, notarizes and staples that container,
and only then creates the public artifacts. Run `spctl --assess --type execute
-vv artifacts/Skep.app` and `spctl --assess --type open --context
context:primary-signature -vv artifacts/distribution/Skep-*.dmg` as the final
Gatekeeper checks.

## Host-service updates

The Mac app carries checksum manifests for the matching `skepctl` and `skepd`
release. During remote-host inspection it compares those checksums with the
installed binaries. On an x86-64 systemd host with non-interactive sudo, Skep
uploads the new checksummed payload through the existing SSH or Google Cloud
IAP connection, invokes the idempotent installer, restarts `skepd`, and
re-inspects the host before issuing normal RPCs.

If automatic elevation is unavailable, the UI reports that an update is
required instead of silently speaking a potentially incompatible protocol.
Host state under `/var/lib/skep` and Microsandbox data are preserved. The local
Mac helper follows the same bundled-checksum principle and remains user-owned.

## Vercel publication

The launch site has no runtime dependencies or server-side credentials. Build,
validate, and publish it with the Vercel CLI:

```sh
cd website
npm run build
npm run check
npx --yes vercel@55.0.0 build --prod
npx --yes vercel@55.0.0 deploy --prebuilt --prod --yes
```

`website/scripts/build.mjs` copies only the explicit public release files into
`website/dist`; it never uploads source, Keychain material, or the Vercel local
configuration. The stable `/download` route points to the version-independent
DMG while the Sparkle feed retains immutable, versioned ZIP URLs.

After every production deployment, verify without a Vercel login:

```sh
curl -I https://skep-compute.vercel.app/
curl -I https://skep-compute.vercel.app/privacy
curl -I https://skep-compute.vercel.app/download
curl -I https://skep-compute.vercel.app/updates/appcast.xml
curl -I https://skep-compute.vercel.app/release.json
```

Download the DMG through the production URL and compare its SHA-256 with
`artifacts/distribution/SHA256SUMS`. Mount it, verify the Applications shortcut,
and assess both the disk image and contained app. Do not announce a release if
the public bytes, appcast signature, bundle version, icon, or Gatekeeper
assessment do not match.
