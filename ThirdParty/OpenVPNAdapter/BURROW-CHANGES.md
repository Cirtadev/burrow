# Changes made for Burrow

This is [OpenVPNAdapter](https://github.com/ss-abramchuk/OpenVPNAdapter) by Sergey Abramchuk at revision
`33afba081c8592e8632128c7f9d6ebe53cae3d08` (2022-03-19), the wrapper's last upstream revision, with its libraries
replaced by current releases and the wrapper adapted to them by Cirtadev GmbH. It is licensed under the GNU Affero
General Public License v3 (see `LICENSE` and `NOTICE`); Burrow's own source is published under the same licence.

Left out of the copy: the upstream Xcode project, CocoaPods spec, tests, CI scripts and contributor guides.

## Libraries (since 2026-11-09)

| Directory | Version | From | Was |
|---|---|---|---|
| `Sources/OpenVPN3` | OpenVPN 3 Core 3.11.8 (2026-10-21) | [OpenVPN/openvpn3](https://github.com/OpenVPN/openvpn3) tag `release/3.11.8`, commit `4f3bdef7`, plus one fix from `master` (below); everything but `.git` and `.github` | 3.6.1 |
| `Sources/mbedTLS` | Mbed TLS 3.6.7 LTS (2026-07-01) | [Mbed-TLS/mbedtls](https://github.com/Mbed-TLS/mbedtls) tag `v3.6.7`; `include`, `library`, `3rdparty`, licence and release notes | 2.7.12 |
| `Sources/ASIO/asio` | Asio 1.24.0 with OpenVPN's 7 patches | [chriskohlhoff/asio](https://github.com/chriskohlhoff/asio) tag `asio-1-24-0`, patched with `Sources/OpenVPN3/deps/asio/patches/*.patch`; `include` and licence | 1.16.0 (patched) |
| `Sources/LZ4` | LZ4 1.10.0 | [lz4/lz4](https://github.com/lz4/lz4) tag `v1.10.0`; `lib` and licence (only `lib/lz4.c` is built) | 1.8.3 |

These are the versions OpenVPN 3 Core 3.11.8 pins for its own builds (`deps/lib-versions` and its vcpkg port name
Asio 1.24.0 with those patches), except Mbed TLS and LZ4: 3.11.8 builds with Mbed TLS 3 (Fedora ships it with
3.6), and LZ4 1.10.0 replaces 1.8.3, which has CVE-2021-3520. Neither OpenVPN 3 Core 3.11.8 nor its `master`
supports Mbed TLS 4. The Mbed TLS 3.6 branch is maintained until March 2027
([BRANCHES.md](Sources/mbedTLS/BRANCHES.md)); by then Burrow needs Mbed TLS 4.1 (once OpenVPN 3 supports it) or
OpenSSL 3.

OpenVPN 3 Core 3.11 is offered under AGPL-3.0-only or MPL-2.0 (`Sources/OpenVPN3/LICENSE.md`); Burrow uses it
under the AGPL like the rest of this package. Mbed TLS is offered under Apache-2.0 or GPL-2.0-or-later; Burrow uses
it under Apache-2.0.

## Modified files

Modified by Cirtadev GmbH on 2026-11-03:

- `Sources/OpenVPNAdapter/library/OpenVPNAdapterImpl.h` and `OpenVPNAdapterImpl.mm`: added
  `-[OpenVPNAdapter sendControlChannelMessage:]`, which calls OpenVPN 3's `ClientAPI::OpenVPNClient::post_cc_msg`.
  Burrow uses it to answer `CR_TEXT` challenges with `CR_RESPONSE`.

Modified by Cirtadev GmbH on 2026-11-09, for OpenVPN 3 Core 3.11.8 and Mbed TLS 3.6.7:

- `Package.swift`: swift-tools 5.9, C++17 (gnu++17), the four libraries above, one set of OpenVPN defines for the
  core and the wrapper. Dropped `MBEDTLS_MD4_C` and `MBEDTLS_RELAXED_X509_DATE` (Mbed TLS 3 has no MD4, and the
  relaxed date parsing was an OpenVPN patch to Mbed TLS 2 that OpenVPN no longer carries), `USE_ASIO_THREADLOCAL`,
  `ASIO_NO_DEPRECATED` and `ASIO_HAS_STD_STRING_VIEW` (unused or automatic now).
- `Sources/OpenVPN3/openvpn/mbedtls/ssl/sslctx.hpp`: OpenVPN 3 commit
  [`ee481a02`](https://github.com/OpenVPN/openvpn3/commit/ee481a02cb6ab946ec388efac7ca13d39305ff7b)
  ("mbedTLS: Always call mbedtls_ssl_set_hostname", Frank Lichtenheld, 2025-04-24), applied as is. It is on OpenVPN
  3's `master` but not in any 3.11 release. Since Mbed TLS 3.6.3 a TLS client that never calls
  `mbedtls_ssl_set_hostname` fails every handshake with "Attempt to verify a certificate without an expected
  hostname"; OpenVPN checks the server with its own options (`remote-cert-tls`, `verify-x509-name`) and now passes
  no hostname explicitly, as with Mbed TLS 2. Drop this change when updating to an OpenVPN 3 release that has it.
- `Sources/mbedTLS/include/mbedtls/mbedtls_config.h`: enabled `MBEDTLS_THREADING_C` and
  `MBEDTLS_THREADING_PTHREAD`. Mbed TLS 3.6's PSA crypto (used by TLS 1.3) keeps global state, and Burrow can run
  two OpenVPN client threads at once while it restarts a session. Nothing else differs from the release.
- `Sources/OpenVPNClient/library/data_epoch.cpp` (new): builds `openvpn/crypto/data_epoch.cpp`, the core's one
  source file besides `client/ovpncli.cpp`.
- `OpenVPNClient.h`, `OpenVPNClient.mm`: OpenVPN 3.11's `TunBuilderBase` and `ClientAPI::OpenVPNClient`:
  `tun_builder_set_dns_options` replaces `tun_builder_add_dns_server` and `tun_builder_add_search_domain` (server
  addresses in priority order; `--dns resolve-domains` become match domains; a DNS port, DoT or DoH can't be set on
  `NEDNSSettings` and is logged), `tun_builder_set_block_ipv6` is gone, `socket_protect` takes a `socket_type`, and
  the now required `acc_event` logs custom control-channel messages.
- `OpenVPNAdapterImpl.mm`: `+evaluateConfiguration:`, `+copyright` and `+platform` use `OpenVPNClientHelper`;
  `addMatchDomain:` for the DNS settings.
- `OpenVPNNetworkSettingsBuilder.h`, `.m`: `matchDomains`, set on `NEDNSSettings` when the server sends any.
- `OpenVPNConfiguration.h`, `.mm`, `OpenVPNConfiguration+Internal.h`: removed `forceCiphersuitesAESCBC` and `ipv6`
  (gone from OpenVPN 3.11); added `enableNonPreferredDCAlgorithms`, `enableLegacyAlgorithms` and
  `dhcpSearchDomainsAsSplitDomains`; `fileContent` now copies exactly the data's length (it read the `NSData` as a
  NUL-terminated string). `OpenVPNMinTLSVersion.h`: `OpenVPNMinTLSVersion13`.
- `OpenVPNIPv6Preference.h` and its `include/` link: removed with the `ipv6` setting; `Umbrella-Header.h` no
  longer imports it.
- `OpenVPNCredentials.h`, `.mm`: removed `replacePasswordWithSessionID` and `cachePassword`. OpenVPN 3.11 always
  uses the server's session token instead of the password once it has one.
- `OpenVPNError.h`, `NSError+OpenVPNError.m`: the error names new in OpenVPN 3.11 (`SESSION_EXPIRED`,
  `NEED_CREDS`, `TLS_ALERT_*`, `TLS_SIGALG_DISALLOWED_OR_UNSUPPORTED`, `NTLM_MISSING_CRYPTO`, `EARLY_NEG_INVALID`,
  `UNUSED_OPTIONS_ERROR`), added before `OpenVPNAdapterErrorUnknown`.
- `OpenVPNPrivateKey.m`: Mbed TLS 3's `mbedtls_pk_parse_key` takes a random generator (`arc4random_buf`).
- `NOTICE`: the new versions, copyright lines and licence choices of the four libraries.

## What changed for connections

- TLS 1.3 is available (Mbed TLS 3.6), and TLS 1.2 stays the minimum unless the profile asks for more.
- OpenVPN 3.11 allows only AEAD data channel ciphers by default; Burrow sets `enableNonPreferredDCAlgorithms` so
  that AES-CBC with an HMAC keeps working. BF-CBC is gone (Mbed TLS 3 has no Blowfish), and other 64-bit block
  ciphers stay off.
- Gone with Mbed TLS 3: NTLM proxy authentication (needs MD4), `ns-cert-type` (use `remote-cert-tls`), and
  certificates with non-standard validity dates that the old relaxed-date patch accepted. PKCS#12 still can't be
  read by Mbed TLS: BurrowKit keeps converting `.p12` files with `/usr/bin/openssl`.
- The Mbed TLS backend doesn't implement TLS keying-material export, so `key-derivation tls-ekm` falls back to
  OpenVPN's own key derivation, as before.
