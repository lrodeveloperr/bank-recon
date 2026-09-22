import Foundation
import SwiftUI
import UniformTypeIdentifiers

public extension UTType {
    static let bankReconciliationBackup = UTType(
        exportedAs: "com.worksbienstudios.bankreconciliation.backup",
        conformingTo: .json
    )
}

public struct ReconciliationDocument: FileDocument {
    public static var readableContentTypes: [UTType] {
        [.data, .json, .commaSeparatedText, .pdf, .bankReconciliationBackup]
    }

    public var data: Data

    public init(data: Data = Data()) { self.data = data }

    public init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
