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
        .library(name: "BankReconciliationAppCore", targets: ["BankReconciliationAppCore"]),
        .executable(name: "bank-reconciliation-app", targets: ["BankReconciliationApp"]),
        .executable(name: "bank-reconcile", targets: ["BankReconciliationCLI"])
    ],
    targets: [
        .target(
            name: "BankReconciliationEngine",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedLibrary("compression"),
                .linkedFramework("Security"),
                .linkedFramework("StoreKit")
            ]
        ),
        .target(
            name: "BankReconciliationAppCore",
            dependencies: ["BankReconciliationEngine"]
        ),
        .executableTarget(
            name: "BankReconciliationApp",
            dependencies: ["BankReconciliationAppCore"]
        ),
        .executableTarget(
            name: "BankReconciliationCLI",
            dependencies: ["BankReconciliationEngine"]
        ),
        .testTarget(
            name: "BankReconciliationEngineTests",
            dependencies: ["BankReconciliationEngine"]
        ),
        .testTarget(
            name: "BankReconciliationAppCoreTests",
            dependencies: ["BankReconciliationAppCore", "BankReconciliationEngine"]
        )
    ]
)
