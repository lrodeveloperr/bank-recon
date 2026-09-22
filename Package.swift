// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BankReconciliationEngine",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "BankReconciliationEngine", targets: ["BankReconciliationEngine"]),
        .executable(name: "bank-reconcile", targets: ["BankReconciliationCLI"])
    ],
    targets: [
        .target(
            name: "BankReconciliationEngine",
            resources: [.process("Resources")],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "BankReconciliationCLI",
            dependencies: ["BankReconciliationEngine"]
        ),
        .testTarget(
            name: "BankReconciliationEngineTests",
            dependencies: ["BankReconciliationEngine"]
        )
    ]
)
