// swift-tools-version:5.9

import PackageDescription

// OpenVPN 3 Core 3.11.8, Mbed TLS 3.6.7 LTS, Asio 1.24.0 with OpenVPN's patches, LZ4 1.10.0 (BURROW-CHANGES.md).
// The OpenVPN 3 defines must be the same wherever its headers are compiled: the ObjC++ wrapper sees the same
// ClientAPI classes as the core.
let openVPNSettings: [CXXSetting] = [
    .headerSearchPath("../ASIO/asio/include"),
    .headerSearchPath("../OpenVPN3"),
    .define("ASIO_STANDALONE"),
    .define("USE_ASIO"),
    .define("USE_MBEDTLS"),
    .define("HAVE_LZ4"),
    .define("USE_TUN_BUILDER"),
    .define("OPENVPN_FORCE_TUN_NULL"),
]

let package = Package(
    name: "OpenVPNAdapter",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "OpenVPNAdapter", type: .static, targets: ["OpenVPNAdapter"]),
    ],
    targets: [
        .target(
            name: "OpenVPNAdapter",
            dependencies: [
                .target(name: "mbedTLS"),
                .target(name: "OpenVPNClient")
            ],
            sources: ["library"],
            cxxSettings: openVPNSettings
        ),
        .target(
            name: "LZ4",
            sources: ["lib/lz4.c"]
        ),
        .target(
            name: "mbedTLS",
            exclude: ["library/CMakeLists.txt", "library/Makefile"],
            sources: ["library"]
        ),
        .target(
            name: "OpenVPNClient",
            dependencies: [
                .target(name: "LZ4"),
                .target(name: "mbedTLS")
            ],
            sources: ["library"],
            cxxSettings: openVPNSettings
        )
    ],
    cxxLanguageStandard: .gnucxx17
)
