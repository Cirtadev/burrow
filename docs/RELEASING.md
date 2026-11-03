# Releasing Burrow

[Back to the README](../README.md)

Releases are GitHub releases of [Cirtadev/burrow](https://github.com/Cirtadev/burrow/releases). Burrow's update
feed is the newest release's `appcast.xml`
(`https://github.com/Cirtadev/burrow/releases/latest/download/appcast.xml`, `BURROW_FEED_URL` in `project.yml`, the
one place it is set); each disk image stays at its own release (`…/releases/download/v<version>/`), so older appcast
entries keep working. The repository must stay public: Sparkle can't download from private releases.

## Each release

1. Raise `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`. The build number must grow with
   every release: Sparkle compares it, and macOS only replaces the installed tunnel extension when it changes.
2. Optionally write `release/notes/<version>.html` (the release notes Sparkle shows).
3. In Terminal.app (the scripts use your Xcode account, which sandboxed tools can't reach):

   ```bash
   scripts/release.sh     # archive, Developer ID export, checks, DMG, Sparkle signature, AGPL source (~10 min)
   scripts/notarize.sh    # notarizes with the Apple ID signed in to Xcode, then packages the notarized app
   ```

   `release.sh` uploads nothing and stops at a signed, not yet notarized disk image. `notarize.sh` uploads it to
   Apple, waits, staples the ticket, and makes `Burrow-<version>.dmg` and `.zip` around the notarized app, the
   Sparkle entry in `release/appcast.xml` and `SHA256SUMS` (if it gives up waiting, `scripts/notarize-collect.sh`
   continues). Running it again makes a new disk image and replaces that build's appcast entry; never run it after
   publishing, the published disk image would no longer match.
4. Try the disk image on a Mac (or user account) that never had a development build, and connect.
5. Publish, then commit `release/appcast.xml`:

   ```bash
   scripts/publish.sh     # GitHub release v<version>: DMG, ZIP, source, SHA256SUMS, appcast.xml
   ```

   It refuses when the source archive contains any of the private patterns listed in
   `scripts/private-patterns.local` (one extended regex per line; that file is never committed nor packed).

## Website

`site/` is the website, [burrow.cirta.dev](https://burrow.cirta.dev) (burrow.cirtadev.com redirects there): plain
HTML and CSS that `.github/workflows/website.yml` publishes to GitHub Pages whenever `site/` changes on master. Its
download buttons ask GitHub for the newest release, so a release needs no change there. After a UI change, refresh
its screenshots with `scripts/build-app.sh` and then `scripts/site-screenshots.sh` (2x, sample data).

## One-time setup

- **Signing**: the *Developer ID Application: Cirtadev GmbH (GXHYVQ677L)* certificate with its private key in the
  login keychain (only the team's Account Holder can create one), and an Apple ID of the team with the Admin or
  Account Holder role signed in to Xcode. The export creates the Developer ID provisioning profiles for
  `dev.cirta.burrow` and `dev.cirta.burrow.tunnel`. The project keeps the development entitlement value
  `packet-tunnel-provider`; Xcode 27's Developer ID export turns it into `packet-tunnel-provider-systemextension`,
  which Developer ID requires and the script checks. Older Xcode versions don't, and need the manual re-signing in
  Apple's [Exporting a Developer ID Network Extension](https://developer.apple.com/forums/thread/737894).
- **Notarization** uses the Apple ID signed in to Xcode. Alternatively `release.sh` notarizes by itself when a
  notarytool profile named `burrow-notary` exists: in App Store Connect › Users and Access › Integrations ›
  App Store Connect API, create a team key with the *Developer* role, download `AuthKey_<KEY ID>.p8` (possible only
  once), then:

  ```bash
  xcrun notarytool store-credentials burrow-notary --key AuthKey_<KEY ID>.p8 --key-id <KEY ID> --issuer <ISSUER ID>
  ```

  Keep the `.p8` file in a password manager, not in this folder.
- **Sparkle key**: updates must be signed with the EdDSA key whose public half is `SUPublicEDKey` in `project.yml`.
  The private key is in the release Mac's login keychain (item `https://sparkle-project.org`, account `ed25519`).
  Back it up once into a password manager; on another release Mac, import it with `generate_keys -f`:

  ```bash
  build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
  ```

  The tools are ad-hoc signed, so the first `sign_update` makes macOS ask for access to the key: click
  *Always Allow*.
- **GitHub**: the `gh` CLI signed in with an account that can create releases in Cirtadev/burrow.
- **Website**: GitHub Pages of Cirtadev/burrow with *GitHub Actions* as its source and `burrow.cirta.dev` as its
  custom domain (Enforce HTTPS on). At Cloudflare, `burrow.cirta.dev` is a CNAME to `cirtadev.github.io` (DNS only),
  and a redirect rule sends `burrow.cirtadev.com` to `https://burrow.cirta.dev` with the path kept.

## AGPL: source for every release

OpenVPN 3 Core and OpenVPNAdapter are AGPLv3, so Burrow is too (`LICENSE`). Whoever gets a disk image must be able
to get the matching source: `publish.sh` attaches `Burrow-<version>-source.tar.gz` to the same release. The archive
holds this repository (without `build/`), which includes OpenVPNAdapter with OpenVPN 3, Mbed TLS, Asio and LZ4 in
`ThirdParty/OpenVPNAdapter` (Burrow's one change is listed in its `BURROW-CHANGES.md`), plus the exact Sparkle
source in `third_party/` with its revision in `third_party/REVISIONS`. The About tab lists the components and their
licences.
