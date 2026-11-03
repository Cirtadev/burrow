# Burrow

A one-click menu-bar OpenVPN client that types the one-time password for you. Standalone: OpenVPN 3
(OpenVPNAdapter) runs inside Burrow's own packet-tunnel system extension, so neither Tunnelblick nor a root helper
is needed. It started as a rework of Tunnelblick: `re/` holds the REA analysis of Tunnelblick 8.0 that showed how
its login and "security token" work.

© 2026 Cirtadev GmbH ([cirtadev.com](https://cirtadev.com), [cirta.dev](https://cirta.dev)). Not affiliated with
Tunnelblick or OpenVPN Inc.

![Settings](docs/screenshots/settings-light.png)

## Install

Burrow is distributed outside the Mac App Store as a notarized, Developer ID-signed disk image (it can't be in the
store: OpenVPN 3 is AGPL). It needs macOS 15 or later.

1. Download `Burrow-<version>.dmg` from [cirta.dev/burrow](https://cirta.dev/burrow/), open it and drag **Burrow**
   onto **Applications**. Burrow only works from the Applications folder: started anywhere else (from the disk image,
   Downloads) its panel says *Move Burrow to the Applications folder and open it from there*.
2. Open Burrow from Applications. macOS asks *"Burrow" is an app downloaded from the internet. Are you sure you
   want to open it?*: click **Open**.
3. Burrow installs its VPN tunnel, a network system extension. macOS shows *System Extension Blocked* (or
   *"Burrow" would like to add a network extension*): click **Open System Settings**, then in
   **General › Login Items & Extensions › Network Extensions** turn on **Burrow** and confirm with your password or
   Touch ID. Until then the panel says *Allow Burrow's VPN in System Settings › …*; clicking connect again opens the
   right pane.
4. Burrow asks to send notifications (reconnects, "enter a new code").
5. The first connect asks *"Burrow" Would Like to Add VPN Configurations*: click **Allow**. Burrow then appears in
   System Settings › VPN.
6. On its second launch Burrow asks whether to check for updates automatically.

**Updates**: *Check for Updates…* in the panel or the right-click menu (or automatic checks). Sparkle downloads the
new disk image, checks its EdDSA signature and Developer ID signature, replaces Burrow in Applications and relaunches
it; the new tunnel extension replaces the old one without asking again. Quitting Burrow disconnects, so an update
interrupts the VPN briefly.

**Uninstall**: delete the configurations in Settings (that removes their keychain items), quit Burrow and drag it
to the Trash; macOS asks to remove its network extension as well. Remove *Burrow – …* in System Settings › VPN if it
is still listed.

## Build and run

Needs Xcode 27 or later, XcodeGen (`brew install xcodegen`) and an Apple ID of the Cirtadev GmbH team
(`GXHYVQ677L`) signed in to Xcode (Settings › Accounts). The Network Extension and System Extension entitlements
only work with a provisioning profile, so these targets can't be ad-hoc signed. Development builds are signed with
an Apple Development certificate; `scripts/release.sh` makes the Developer ID ones.

```bash
./scripts/build-app.sh             # xcodegen + xcodebuild → build/Burrow.app, build/burrowctl
./scripts/build-app.sh --install   # the same, then copies it to /Applications/Burrow.app and opens it there
```

The tunnel is a system extension (`Contents/Library/SystemExtensions/dev.cirta.burrow.tunnel.systemextension`), and
macOS only installs one from an app in /Applications, so connect with the `--install` copy (or run
`systemextensionsctl developer on`, which needs SIP turned off, to allow any location). The first install asks for
approval as in [Install](#install). Every development build gets its own build number
(`<CURRENT_PROJECT_VERSION>.<date>.<time>`), because macOS only replaces an active extension whose version changed;
Burrow activates the bundled extension at launch and before connecting, and a newer one replaces the old one.
Both scripts refuse to replace the app while Burrow's VPN is connected.

The first build compiles OpenVPN 3 and mbedTLS (about 8 minutes) and lets Xcode register the app IDs
`dev.cirta.burrow` and `dev.cirta.burrow.tunnel` (Network Extension and System Extension capabilities) and this Mac.

```bash
systemextensionsctl list                                               # is the tunnel extension active?
log stream --info --predicate 'subsystem == "dev.cirta.burrow.tunnel"'   # tunnel log
```

First launch opens Settings. Add configurations with **+**:

- **Import from Tunnelblick…** reads every Tunnelblick configuration: the config itself (shared ones are root-only, so
  macOS asks for an administrator password once), the saved username and password (macOS asks to allow access to
  Tunnelblick's keychain items), and whether Tunnelblick asked for a security token. Referenced certificate/key
  files are inlined.
- **Import .ovpn File…** takes a config from the VPN portal. Certificates and keys it names (`ca ca.crt`) are
  inlined from the same folder, since the tunnel extension can't read files. Logins it carries (`<auth-user-pass>`,
  `auth-user-pass login.txt`, `askpass`, proxy logins) move into the keychain, and a PKCS#12 certificate
  (`pkcs12 me.p12` or `<pkcs12>`) is converted to `<cert>`/`<key>` with macOS's `openssl` after asking for its
  password. New configurations start in *Ask me for the code* mode.

Each configuration has:

- **Account**: username and password for configs with `auth-user-pass`; a config without it signs in with its
  certificate only. An encrypted `<key>` adds a **Key passphrase** field.
- **Save password in the keychain** (and the passphrase): off means the sign-in window asks each time.
- **One-time password mode**:
  - *1-click: Burrow generates the code* (marked **Caution**) from the stored Base32 secret / `otpauth://` link.
    The fastest, not the recommended way: the setup key lives on the Mac next to the password, so the Mac alone
    is enough to sign in. The live preview must match your authenticator app.
  - *Ask me for the code* (**Recommended**): the sign-in window takes the code from your phone.
  - *No one-time password*: username and password only (or the certificate).
- **Send the code**: *with the password* (`password123456`, what most servers expect) or *when the server asks for
  it* (a dynamic challenge or CR_TEXT after the password). A config with `static-challenge` always gets the code in
  its own field.

The first connect makes macOS ask to *add VPN configurations*; allow it. Burrow then appears in
System Settings › VPN. Disconnect and quit Tunnelblick before connecting: two tunnels with the same routes conflict.

![Sign-in](docs/screenshots/sign-in-light.png)

## Using it

- **Click** the shield for the panel: the configuration (pick another from its name), a big power button that
  connects or disconnects (grey = off, pulsing blue = connecting, green = connected, orange = failed; a 1-click
  configuration connects at once, the others show the sign-in window), status, tunnel address, uptime and
  traffic, the current OTP code (click to copy), *Settings…*, *Show Log*, *Check for Updates…* and *Quit*. **Right-click** (or
  Control/Option-click) gives the same as a compact menu.

![Panel](docs/screenshots/panel-menubar-light.png)

- Icon: outline shield = off, half-filled blinking = connecting, filled lock shield = connected,
  exclamation shield = failed (the menu says why).
- General settings: *Start Burrow at login*, *Connect when Burrow starts*, *Reconnect after drops and sleep*,
  *Show notifications*, *Send all DNS lookups through the VPN*.
- Reconnecting: a 1-click configuration recovers on its own with a fresh code (after sleep, network changes,
  server restarts or a drop, backing off 5 s → 2 min) and posts a "Reconnected" notification. A configuration that
  asks for the code posts "Enter a new code to reconnect" and opens the sign-in window.
- *Send all DNS lookups through the VPN* is off by default, which matches how Tunnelblick behaved on this Mac
  (manually set DNS kept).
- Quitting Burrow disconnects, like Tunnelblick.

## How sign-in works

Burrow hands the configuration to the tunnel extension with each connect (see [Security notes](#security-notes)).
It supports what OpenVPN 3 clients support:

| Method | How Burrow handles it |
|---|---|
| Username + password (`auth-user-pass`) | saved in the keychain, or asked in the sign-in window |
| Certificate only (no `auth-user-pass`) | nothing to ask |
| Encrypted private key | passphrase saved or asked; a rejected saved one is forgotten and asked again |
| Password + OTP appended | `password123456`, generated (1-click) or typed |
| Static challenge (`static-challenge "text" 1`) | the code or answer goes in its own field (SCRV1) |
| Dynamic challenge (`CRV1`, e.g. privacyIDEA, RADIUS SMS/PIN) | 1-click answers with a fresh code; otherwise the server's question pops up |
| `CR_TEXT` (OpenVPN 2.6 auth-pending) | same; the answer goes back as `CR_RESPONSE` |
| Web sign-in / SSO (`OPEN_URL`, `WEB_AUTH`, e.g. Access Server SAML, CloudConnexa, openvpn-auth-oauth2) | Burrow announces `IV_SSO=openurl,webauth,crtext`, opens the page in your browser and waits; *Open Sign-in Page* in the panel reopens it |
| Static challenge, `concat` format (OpenVPN 2.6) | the code is appended to the password |
| PKCS#12 certificate (`.p12`) | converted at import |
| Credentials in the file or a file next to it | moved into the keychain at import |
| HTTP proxy login (`http-proxy`) | proxy username and password in Settings |
| Session tokens (`auth-token`) | reconnects use the token instead of a new code |

Not supported: certificates kept in the macOS keychain or on a smart card / YubiKey (PKCS#11), and static-key
(`secret`) configs, which OpenVPN 3 dropped. A server's sign-in page link must be `https://` or `http://`;
anything else is ignored.

### Routing

When the network you're on uses the same addresses as the VPN (both `192.168.1.x`), macOS would send them all to
the local network, and the company servers there would be unreachable. Burrow splits the range by itself: once
connected it looks for the devices on your network (a small UDP packet to each address of the shared range once a
second, bound to the Wi-Fi or Ethernet interface; macOS reports the addresses nobody answers for as down), keeps
those local, and routes every other address of the range through the VPN as more specific routes. It looks again
every 10 minutes and after a network change, and only for shared ranges up to a /22. macOS asks once to allow Burrow on the local network
(Privacy & Security › Local Network); without that, Burrow can't see the devices and says so in the panel.

*Choose Routes…* opens a table of the VPN's routes (remembered from the last connection), the shared ranges and your
own entries, with **Auto** (shared ranges only), **VPN** and **Local** boxes. Addresses show their `/etc/hosts`
name (`192.168.1.20 server`), and you can add a server by name: Burrow stores the addresses it resolves to. VPN entries win over the local network;
Local entries become excluded routes. Changes apply at once to a running tunnel.

With a one-time password, every sign-in gets a fresh code:

- password + current 6-digit code, no separator, as Tunnelblick's "security token" field did;
- a time step is never sent twice; with less than 3 s left Burrow waits for the next code;
- OpenVPN normally resends cached credentials when it reconnects (network change, wake, server restart), and the
  old code would be rejected. Burrow instead restarts the session with a new code, keeping the tunnel up;
- if the server rejects a code, Burrow tries once more with the next one, then stops and says so, so a wrong
  password can't lock the account.

```bash
cd BurrowKit && swift test                         # TOTP, scheduler, .ovpn reader, protocol tests (no network)
build/burrowctl otp <secret>                       # print the current code
build/burrowctl ovpn ~/Downloads/<file>.ovpn       # summarize a config (never prints keys)
build/Burrow.app/Contents/MacOS/Burrow --snapshot docs/screenshots   # render Settings with sample data
log show --last 1h --info --predicate 'subsystem == "dev.cirta.burrow.tunnel"'   # tunnel log
```

## Security notes

- Each configuration (config with its private key, username, password if saved, OTP secret) is one item in
  Burrow's data-protection keychain group (`keychain-access-groups`).
- The tunnel is a system extension that macOS runs as root in its own sandbox; it can't read the user's keychain.
  On every connect Burrow reads the configuration and passes what the tunnel needs in the start options
  (`startVPNTunnel(options:)`): the `.ovpn` text, username, password, OTP mode and either the OTP secret (1-click)
  or the typed code. The extension keeps them in memory for reconnects and drops them when the tunnel stops; it
  never writes them to disk or logs them. A password or code typed in the sign-in window is not stored unless
  *Save password* is on.
- Connecting from System Settings › VPN or the menu-bar VPN menu starts the tunnel without those options: it stops
  at once with *Open Burrow to connect*, and a running Burrow then connects the configuration itself.
- Keeping the OTP secret next to the password turns two factors into one: anyone with this unlocked Mac can
  connect. Check that this fits the VPN owner's policy.
- OpenVPNAdapter vendors OpenVPN 3.6.1 and mbedTLS 2.7.12 (2021-era). They work with this server (TLS 1.2+), but a
  newer OpenVPN 3 core would be better for a long-lived setup.

## Release

`scripts/release.sh` builds a release in `build/release/` and uploads nothing:

1. `xcodegen generate`, `xcodebuild archive` (Release), then `xcodebuild -exportArchive` with method `developer-id`
   and automatic signing (`-allowProvisioningUpdates`).
2. Checks the exported app: `codesign --verify --deep --strict`; app and system extension signed with
   *Developer ID Application: Cirtadev GmbH (GXHYVQ677L)*, hardened runtime, the
   `packet-tunnel-provider-systemextension` entitlement value and a Developer ID provisioning profile in both;
   `spctl -a -vv`.
3. With notary credentials: notarizes and staples the app, puts it in `Burrow-<version>.dmg` (the app and an
   Applications link, made with `hdiutil`), signs the disk image, notarizes and staples it, and checks both with
   `spctl`. Without them it stops at a signed, **not notarized** disk image and prints what is missing.
4. Signs the disk image for Sparkle (`sign_update`) and writes its appcast entry to `build/release/appcast-item.xml`;
   for a notarized release it also adds the entry to `release/appcast.xml`. A `release/notes/<version>.html` file,
   if present, becomes the release notes.
5. Packs `Burrow-<version>-source.tar.gz` (see [AGPL](#agpl-source-for-every-release)) and prints the SHA-256 sums
   (also in `build/release/SHA256SUMS`).

### One-time setup

- **Signing**: the *Developer ID Application: Cirtadev GmbH (GXHYVQ677L)* certificate with its private key in the
  login keychain (only the team's Account Holder can create one), and an Apple ID of the team with the Admin or
  Account Holder role signed in to Xcode. The export then creates the Developer ID provisioning profiles for
  `dev.cirta.burrow` and `dev.cirta.burrow.tunnel`. The project keeps the development entitlement value
  `packet-tunnel-provider`; Xcode 27's Developer ID export turns it into `packet-tunnel-provider-systemextension`,
  which Developer ID requires and the script checks. Older Xcode versions don't, and need the manual re-signing in
  Apple's [Exporting a Developer ID Network Extension](https://developer.apple.com/forums/thread/737894).
- **Notarization**: in App Store Connect › Users and Access › Integrations › App Store Connect API, the Account
  Holder or an Admin creates a team key with the *Developer* role, downloads `AuthKey_<KEY ID>.p8` (possible only
  once) and notes the key ID and the issuer ID. Then store it in the login keychain under the name the script uses:

  ```bash
  xcrun notarytool store-credentials burrow-notary --key AuthKey_<KEY ID>.p8 --key-id <KEY ID> --issuer <ISSUER ID>
  ```

  Keep the `.p8` file somewhere safe (a password manager), not in this folder.
- **Sparkle key**: the EdDSA key pair was made with Sparkle's `generate_keys` on 2026-10-20. Its private key is in
  this Mac's login keychain (item `https://sparkle-project.org`, account `ed25519`); the public key is
  `SUPublicEDKey` in `project.yml`. Every update must be signed with it, so back it up once and keep the copy in a
  password manager; on another release Mac, import it with `-f`:

  ```bash
  build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
  ```

  The tools are ad-hoc signed, so the first `sign_update` makes macOS ask for access to the key: click
  *Always Allow*.
- **Hosting**: the feed URL is `BURROW_FEED_URL` in `project.yml`, the one place it is set (it becomes `SUFeedURL`),
  now `https://cirta.dev/burrow/appcast.xml`. The disk images and source archives are expected in the same folder
  (`https://cirta.dev/burrow/Burrow-<version>.dmg`), served over HTTPS.

### Each release

1. Raise `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`. The build number must grow with
   every release: Sparkle compares it, and macOS only replaces the installed tunnel extension when it changes. The
   script refuses a build number that is already in `release/appcast.xml`.
2. Optionally write `release/notes/<version>.html`.
3. Run `./scripts/release.sh` (about 10 minutes for the build, plus a few minutes per notarization).
4. Try the disk image: install it on a Mac (or user account) that never had a development build, and connect.
5. Upload `Burrow-<version>.dmg` and `Burrow-<version>-source.tar.gz` to `https://cirta.dev/burrow/`, then
   `release/appcast.xml` as `appcast.xml`, last, so the feed never points at a missing file. Keep
   `release/appcast.xml` with the sources.

### AGPL: source for every release

OpenVPN 3 Core and OpenVPNAdapter are AGPLv3, so Burrow is too (`LICENSE`). Whoever gets a disk image must be able
to get the matching source: publish `Burrow-<version>-source.tar.gz` next to each disk image, at the same time,
and keep it there as long as that disk image is offered. The archive holds this repository (without `build/`
and `re/`), which includes OpenVPNAdapter with OpenVPN 3, Mbed TLS, Asio and LZ4 in `ThirdParty/OpenVPNAdapter`
(Burrow's one change is listed in its `BURROW-CHANGES.md`), plus the exact Sparkle source in `third_party/` with
its revision in `third_party/REVISIONS`. The About tab lists the components
and their licences.

## Layout

- `App/`: the menu-bar app (AppKit status item, SwiftUI settings and sign-in window, notifications,
  Tunnelblick importer, `NETunnelProviderManager` control, system extension activation, Sparkle updater).
- `Tunnel/`: the system extension: `main.swift`, `PacketTunnelProvider`, OpenVPN 3 via OpenVPNAdapter, OTP sign-in
  and restarts.
- `BurrowKit/`: Swift package with TOTP, the OTP scheduler, the multi-profile store, the `.ovpn` reader, the
  Tunnelblick config inliner and `burrowctl`;
  also the Tunnelblick daemon and management clients from the first version.
- `ThirdParty/OpenVPNAdapter/`: OpenVPNAdapter (upstream 33afba0) with OpenVPN 3 Core 3.6.1, plus a
  control-channel send for CR_TEXT answers (`BURROW-CHANGES.md`).
- `project.yml`: XcodeGen spec (the `.xcodeproj` is generated and not committed), versions, the update feed URL
  and Sparkle's public key.
- `scripts/`: `build-app.sh` (development), `release.sh` (Developer ID, notarization, disk image, appcast).
- `release/appcast.xml`: the Sparkle feed, created and extended by `release.sh`.
- `LICENSE`: GNU AGPL v3.
- `legacy/tunnelblick-app/`: the first version, which drove Tunnelblick's installed root helper (not built).
- `docs/tunnelblick-protocol.md`, `re/`: the REA analysis of Tunnelblick. `re/target/` holds its binaries and is
  gitignored.
