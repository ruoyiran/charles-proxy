// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProxyLab",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProxyLabCore", targets: ["ProxyLabCore"]),
        .executable(name: "ProxyLab", targets: ["ProxyLabApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.35.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "CBodyCodec", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "ProxyLabCore", dependencies: [
            "CBodyCodec",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .executableTarget(name: "ProxyLabApp", dependencies: ["ProxyLabCore"]),
        .testTarget(name: "ProxyLabCoreTests", dependencies: [
            "ProxyLabCore",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
    ]
)
