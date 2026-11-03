# Changes made for Burrow

This is [OpenVPNAdapter](https://github.com/ss-abramchuk/OpenVPNAdapter) by Sergey Abramchuk at revision
`33afba081c8592e8632128c7f9d6ebe53cae3d08` (2022-03-19), with OpenVPN 3 Core 3.6.1, Mbed TLS, Asio and LZ4 as
that revision ships them. It is licensed under the GNU Affero General Public License v3 (see `LICENSE` and
`NOTICE`); Burrow's own source is published under the same licence.

Left out of the copy: the upstream Xcode project, CocoaPods spec, tests, CI scripts and contributor guides.
Nothing in `Sources` was removed.

Modified by Cirtadev GmbH on 2026-11-03:

- `Sources/OpenVPNAdapter/library/OpenVPNAdapterImpl.h` and `OpenVPNAdapterImpl.mm`: added
  `-[OpenVPNAdapter sendControlChannelMessage:]`, which calls OpenVPN 3's `ClientAPI::OpenVPNClient::post_cc_msg`.
  Burrow uses it to answer `CR_TEXT` challenges with `CR_RESPONSE`.
