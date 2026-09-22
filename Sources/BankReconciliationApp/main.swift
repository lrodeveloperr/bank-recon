import BankReconciliationAppCore
import SwiftUI

@main
struct BankReconciliationApp: App {
    var body: some Scene {
        WindowGroup {
            BankReconciliationBootstrapView()
        }
        .defaultSize(width: 1_080, height: 760)
    }
}
