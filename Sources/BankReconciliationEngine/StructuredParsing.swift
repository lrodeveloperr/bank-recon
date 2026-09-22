import Compression
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

final class BoundedXMLNode {
    let name: String
    let namespaceURI: String?
    let attributes: [String: String]
    var children: [BoundedXMLNode] = []
    var textFragments: [String] = []

    init(name: String, namespaceURI: String?, attributes: [String: String]) {
        self.name = name.split(separator: ":").last.map(String.init) ?? name
        self.namespaceURI = namespaceURI
        self.attributes = attributes
    }

    var text: String {
        textFragments.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func children(named expected: String, namespace: String? = nil) -> [BoundedXMLNode] {
        children.filter { $0.name == expected && (namespace == nil || $0.namespaceURI == namespace) }
    }

    func first(named expected: String, namespace: String? = nil) -> BoundedXMLNode? {
        children(named: expected, namespace: namespace).first
    }

    func path(_ names: String..., namespace: String? = nil) -> BoundedXMLNode? {
        names.reduce(Optional(self)) { node, name in node?.first(named: name, namespace: namespace) }
    }

    func descendants(named expected: String, namespace: String? = nil) -> [BoundedXMLNode] {
        var result: [BoundedXMLNode] = []
        for child in children {
            if child.name == expected && (namespace == nil || child.namespaceURI == namespace) { result.append(child) }
            result.append(contentsOf: child.descendants(named: expected, namespace: namespace))
        }
        return result
    }

    var recursiveText: String {
        ([text] + children.map(\.recursiveText)).filter { !$0.isEmpty }.joined()
    }
}

private final class BoundedXMLDelegate: NSObject, XMLParserDelegate {
    private let limits: ParserLimits
    private(set) var root: BoundedXMLNode?
    private var stack: [BoundedXMLNode] = []
    private var nodeCount = 0
    private var textBytes = 0
    private(set) var failure: EngineError?

    init(limits: ParserLimits) { self.limits = limits }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard failure == nil else { parser.abortParsing(); return }
        nodeCount += 1
        guard nodeCount <= limits.maximumXMLNodes else {
            failure = .resourceLimit("XML nodes")
            parser.abortParsing()
            return
        }
        guard stack.count < limits.maximumXMLDepth else {
            failure = .resourceLimit("XML depth")
            parser.abortParsing()
            return
        }
        let node = BoundedXMLNode(name: elementName, namespaceURI: namespaceURI, attributes: attributeDict)
        if let parent = stack.last {
            parent.children.append(node)
        } else if root == nil {
            root = node
        } else {
            failure = .malformedInput("XML has multiple document roots")
            parser.abortParsing()
            return
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard failure == nil else { return }
        textBytes += string.utf8.count
        guard textBytes <= limits.maximumExpandedBytes else {
            failure = .resourceLimit("XML text")
            parser.abortParsing()
            return
        }
        stack.last?.textFragments.append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let value = String(data: CDATABlock, encoding: .utf8) else {
            failure = .malformedInput("XML CDATA is not UTF-8")
            parser.abortParsing()
            return
        }
        self.parser(parser, foundCharacters: value)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let last = stack.last,
              last.name == (elementName.split(separator: ":").last.map(String.init) ?? elementName) else {
            failure = .malformedInput("XML element nesting is inconsistent")
            parser.abortParsing()
            return
        }
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if failure == nil { failure = .malformedInput("XML parse failed: \(parseError.localizedDescription)") }
    }

    func parser(_ parser: XMLParser, validationErrorOccurred validationError: Error) {
        if failure == nil { failure = .malformedInput("XML validation failed: \(validationError.localizedDescription)") }
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        failure = .malformedInput("external XML entities are forbidden")
        parser.abortParsing()
        return nil
    }
}

enum BoundedXMLTree {
    static func parse(_ data: Data, limits: ParserLimits) throws -> BoundedXMLNode {
        guard data.count <= limits.maximumExpandedBytes else { throw EngineError.resourceLimit("XML bytes") }
        let uppercasePrefix = String(decoding: data.prefix(65_536), as: UTF8.self).uppercased()
        guard !uppercasePrefix.contains("<!DOCTYPE"), !uppercasePrefix.contains("<!ENTITY") else {
            throw EngineError.malformedInput("DTD and entity declarations are forbidden")
        }
        let delegate = BoundedXMLDelegate(limits: limits)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        let succeeded = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard succeeded, let root = delegate.root else { throw EngineError.malformedInput("XML document is empty or invalid") }
        return root
    }
}

extension StructuredImportProfile {
    func separators() throws -> (decimal: Character, grouping: Character?) {
        guard decimalSeparator.count == 1, let decimal = decimalSeparator.first else {
            throw EngineError.invalidConfiguration("structured decimal separator must be one character")
        }
        let grouping: Character?
        if let groupingSeparator {
            guard groupingSeparator.count == 1, let value = groupingSeparator.first else {
                throw EngineError.invalidConfiguration("structured grouping separator must be one character")
            }
            grouping = value
        } else {
            grouping = nil
        }
        guard decimal != grouping else { throw EngineError.invalidConfiguration("structured number separators collide") }
        return (decimal, grouping)
    }
}

enum StructuredValueParser {
    static func exactAmount(_ raw: String, profile: StructuredImportProfile?) throws -> ExactAmount {
        let selected = profile ?? StructuredImportProfile()
        let separators = try selected.separators()
        return try ExactAmount(
            parsing: raw.trimmingCharacters(in: .whitespacesAndNewlines),
            decimalSeparator: separators.decimal,
            groupingSeparator: separators.grouping
        )
    }

    static func exactISOAmount(_ raw: String) throws -> ExactAmount {
        try ExactAmount(parsing: raw.trimmingCharacters(in: .whitespacesAndNewlines), decimalSeparator: ".")
    }

    static func date(_ raw: String, order: DateOrder) throws -> LocalDate {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.utf8.count >= 10 {
            let prefix = String(trimmed.prefix(10))
            if let iso = try? LocalDate(iso8601: prefix) { return iso }
        }
        let normalized = trimmed.replacingOccurrences(of: "'", with: "/")
        let fields = normalized.split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == "." })
        guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            throw EngineError.invalidDate(raw)
        }
        let first = String(fields[0]), second = String(fields[1]), third = String(fields[2])
        func year(_ value: String) throws -> Int {
            guard let parsed = Int(value) else { throw EngineError.invalidDate(raw) }
            if value.count == 4 { return parsed }
            guard value.count == 2 else { throw EngineError.invalidDate(raw) }
            return parsed >= 70 ? 1_900 + parsed : 2_000 + parsed
        }
        let y: Int
        let m: Int
        let d: Int
        switch order {
        case .ymd:
            y = try year(first); guard let month = Int(second), let day = Int(third) else { throw EngineError.invalidDate(raw) }
            m = month; d = day
        case .dmy:
            y = try year(third); guard let month = Int(second), let day = Int(first) else { throw EngineError.invalidDate(raw) }
            m = month; d = day
        case .mdy:
            y = try year(third); guard let month = Int(first), let day = Int(second) else { throw EngineError.invalidDate(raw) }
            m = month; d = day
        }
        return try LocalDate(year: y, month: m, day: d)
    }

    static func ofxDate(_ raw: String) throws -> LocalDate {
        let digits = raw.prefix { $0.isNumber }
        guard digits.count >= 8 else { throw EngineError.invalidDate(raw) }
        return try LocalDate(iso8601: "\(digits.prefix(4))-\(digits.dropFirst(4).prefix(2))-\(digits.dropFirst(6).prefix(2))")
    }
}

struct SourceIdentity {
    let digest: String
    let sourceID: String

    init(data: Data) {
        digest = Hashing.sha256(data)
        sourceID = "source-" + digest
    }

    func proof(filename: String, byteCount: Int) -> SourceFileProof {
        SourceFileProof(sourceID: sourceID, filename: filename, byteCount: byteCount, sha256: digest)
    }
}

private struct ZIPEntry {
    let path: String
    let compressionMethod: UInt16
    let flags: UInt16
    let crc32: UInt32
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
}

struct BoundedZIPArchive {
    private let bytes: Data
    private let entriesByPath: [String: ZIPEntry]
    private let limits: ParserLimits

    init(data: Data, limits: ParserLimits) throws {
        guard data.count <= limits.maximumBytes else { throw EngineError.resourceLimit("archive bytes") }
        self.bytes = data
        self.limits = limits
        let minimumEOCD = 22
        guard data.count >= minimumEOCD else { throw EngineError.malformedInput("ZIP is truncated") }
        let searchStart = max(0, data.count - 65_557)
        var eocd: Int?
        if data.count >= 4 {
            for offset in stride(from: data.count - 4, through: searchStart, by: -1) {
                if try data.littleEndianUInt32(at: offset) == 0x0605_4B50 { eocd = offset; break }
            }
        }
        guard let eocd else { throw EngineError.malformedInput("ZIP end record is missing") }
        let disk = try data.littleEndianUInt16(at: eocd + 4)
        let centralDisk = try data.littleEndianUInt16(at: eocd + 6)
        let diskEntries = try data.littleEndianUInt16(at: eocd + 8)
        let totalEntries = try data.littleEndianUInt16(at: eocd + 10)
        let centralSize = Int(try data.littleEndianUInt32(at: eocd + 12))
        let centralOffset = Int(try data.littleEndianUInt32(at: eocd + 16))
        let commentLength = Int(try data.littleEndianUInt16(at: eocd + 20))
        guard disk == 0, centralDisk == 0, diskEntries == totalEntries,
              totalEntries != UInt16.max, centralSize != Int(UInt32.max), centralOffset != Int(UInt32.max) else {
            throw EngineError.malformedInput("multi-disk and ZIP64 archives are unsupported")
        }
        guard Int(totalEntries) <= limits.maximumArchiveEntries else { throw EngineError.resourceLimit("archive entries") }
        guard eocd + minimumEOCD + commentLength == data.count,
              centralOffset >= 0, centralSize >= 0, centralOffset + centralSize == eocd else {
            throw EngineError.malformedInput("ZIP central directory bounds are invalid")
        }

        var output: [String: ZIPEntry] = [:]
        var cursor = centralOffset
        var expandedTotal = 0
        for _ in 0..<Int(totalEntries) {
            guard try data.littleEndianUInt32(at: cursor) == 0x0201_4B50 else {
                throw EngineError.malformedInput("ZIP central entry signature is invalid")
            }
            let flags = try data.littleEndianUInt16(at: cursor + 8)
            let method = try data.littleEndianUInt16(at: cursor + 10)
            let crc = try data.littleEndianUInt32(at: cursor + 16)
            let compressed = Int(try data.littleEndianUInt32(at: cursor + 20))
            let expanded = Int(try data.littleEndianUInt32(at: cursor + 24))
            let nameLength = Int(try data.littleEndianUInt16(at: cursor + 28))
            let extraLength = Int(try data.littleEndianUInt16(at: cursor + 30))
            let entryCommentLength = Int(try data.littleEndianUInt16(at: cursor + 32))
            let externalAttributes = try data.littleEndianUInt32(at: cursor + 38)
            let localOffset = Int(try data.littleEndianUInt32(at: cursor + 42))
            let headerEnd = cursor + 46
            let entryEnd = headerEnd + nameLength + extraLength + entryCommentLength
            guard nameLength > 0, entryEnd <= eocd else { throw EngineError.malformedInput("ZIP central entry is truncated") }
            let nameData = data.subdata(in: headerEnd..<(headerEnd + nameLength))
            guard let path = String(data: nameData, encoding: .utf8) else { throw EngineError.malformedInput("ZIP path is not UTF-8") }
            try Self.validate(path: path)
            guard output[path] == nil else { throw EngineError.malformedInput("ZIP contains a duplicate path: \(path)") }
            guard flags & 0x0001 == 0 else { throw EngineError.malformedInput("encrypted ZIP entries are unsupported") }
            guard method == 0 || method == 8 else { throw EngineError.malformedInput("unsupported ZIP compression method") }
            let unixMode = UInt16((externalAttributes >> 16) & 0xFFFF)
            guard unixMode & 0xF000 != 0xA000 else { throw EngineError.malformedInput("ZIP symbolic links are forbidden") }
            guard compressed >= 0, expanded >= 0, localOffset >= 0 else { throw EngineError.malformedInput("ZIP size is invalid") }
            if expanded > 0 {
                guard compressed > 0 || method == 0 else { throw EngineError.resourceLimit("archive compression ratio") }
                if method == 8, Int64(expanded) > Int64(max(1, compressed)) * 100 {
                    throw EngineError.resourceLimit("archive compression ratio")
                }
            }
            expandedTotal += expanded
            guard expandedTotal <= limits.maximumExpandedBytes else { throw EngineError.resourceLimit("expanded archive bytes") }
            output[path] = ZIPEntry(
                path: path, compressionMethod: method, flags: flags, crc32: crc,
                compressedSize: compressed, uncompressedSize: expanded, localHeaderOffset: localOffset
            )
            cursor = entryEnd
        }
        guard cursor == eocd else { throw EngineError.malformedInput("ZIP central directory has trailing records") }
        entriesByPath = output
    }

    var paths: [String] { entriesByPath.keys.sorted() }

    func contains(_ path: String) -> Bool { entriesByPath[path] != nil }

    func data(for path: String) throws -> Data {
        guard let entry = entriesByPath[path] else { throw EngineError.notFound("archive entry \(path)") }
        let offset = entry.localHeaderOffset
        guard try bytes.littleEndianUInt32(at: offset) == 0x0403_4B50 else {
            throw EngineError.malformedInput("ZIP local entry signature is invalid")
        }
        let localFlags = try bytes.littleEndianUInt16(at: offset + 6)
        let localMethod = try bytes.littleEndianUInt16(at: offset + 8)
        let nameLength = Int(try bytes.littleEndianUInt16(at: offset + 26))
        let extraLength = Int(try bytes.littleEndianUInt16(at: offset + 28))
        let nameStart = offset + 30
        let payloadStart = nameStart + nameLength + extraLength
        let payloadEnd = payloadStart + entry.compressedSize
        guard payloadEnd <= bytes.count, localFlags == entry.flags, localMethod == entry.compressionMethod else {
            throw EngineError.malformedInput("ZIP local and central entries disagree")
        }
        let localNameData = bytes.subdata(in: nameStart..<(nameStart + nameLength))
        guard String(data: localNameData, encoding: .utf8) == entry.path else {
            throw EngineError.malformedInput("ZIP local path differs from central path")
        }
        let compressed = bytes.subdata(in: payloadStart..<payloadEnd)
        let expanded: Data
        if entry.compressionMethod == 0 {
            guard compressed.count == entry.uncompressedSize else { throw EngineError.malformedInput("stored ZIP size mismatch") }
            expanded = compressed
        } else {
            expanded = try Self.inflate(compressed, expectedSize: entry.uncompressedSize)
        }
        guard Self.crc32(expanded) == entry.crc32 else { throw EngineError.integrityFailure("ZIP CRC mismatch for \(path)") }
        return expanded
    }

    private static func validate(path: String) throws {
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
            throw EngineError.malformedInput("unsafe ZIP path")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw EngineError.malformedInput("unsafe ZIP path")
        }
    }

    private static func inflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize >= 0 else { throw EngineError.malformedInput("negative expanded size") }
        if expectedSize == 0 { return Data() }
        var output = Data(count: expectedSize)
        let decoded = output.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { source in
                guard let destinationAddress = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceAddress = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationAddress, expectedSize,
                    sourceAddress, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard decoded == expectedSize else { throw EngineError.malformedInput("DEFLATE stream size mismatch") }
        return output
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB8_8320 : 0)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    func littleEndianUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { throw EngineError.malformedInput("binary input is truncated") }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func littleEndianUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw EngineError.malformedInput("binary input is truncated") }
        return UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }
}
