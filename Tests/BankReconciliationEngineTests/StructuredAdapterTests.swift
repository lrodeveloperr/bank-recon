import Foundation
import XCTest
@testable import BankReconciliationEngine

final class StructuredAdapterTests: XCTestCase {
    private func january() throws -> ReconciliationPeriod {
        try ReconciliationPeriod(start: LocalDate(iso8601: "2026-01-01"), end: LocalDate(iso8601: "2026-01-31"))
    }

    func testXLSXSelectedWorksheetRichStringsAndExcelDate() throws {
        let entries: [String: Data] = [
            "[Content_Types].xml": Data("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>".utf8),
            "xl/workbook.xml": Data("""
                <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
                  <workbookPr date1904="false"/><sheets><sheet name="Transactions" sheetId="1" r:id="rId1"/></sheets>
                </workbook>
                """.utf8),
            "xl/_rels/workbook.xml.rels": Data("""
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
                </Relationships>
                """.utf8),
            "xl/styles.xml": Data("""
                <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                  <cellXfs count="2"><xf numFmtId="0"/><xf numFmtId="14"/></cellXfs>
                </styleSheet>
                """.utf8),
            "xl/sharedStrings.xml": Data("""
                <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="2" uniqueCount="2">
                  <si><r><t>US</t></r><r><t>D</t></r></si><si><t>X1</t></si>
                </sst>
                """.utf8),
            "xl/worksheets/sheet1.xml": Data("""
                <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
                  <row r="1"><c r="A1" t="inlineStr"><is><t>Date</t></is></c><c r="B1" t="inlineStr"><is><t>Amount</t></is></c><c r="C1" t="inlineStr"><is><t>Account</t></is></c><c r="D1" t="inlineStr"><is><t>Currency</t></is></c><c r="E1" t="inlineStr"><is><t>ID</t></is></c></row>
                  <row r="2"><c r="A2" s="1" t="n"><v>46024</v></c><c r="B2" t="n"><v>10.00</v></c><c r="C2" t="inlineStr"><is><t>A</t></is></c><c r="D2" t="s"><v>0</v></c><c r="E2" t="s"><v>1</v></c></row>
                </sheetData></worksheet>
                """.utf8)
        ]
        let data = storedZIP(entries)
        let mapping = DelimitedMapping(
            delimiter: ",", hasHeader: true, dateColumn: 0, amountColumn: 1,
            accountColumn: 2, currencyColumn: 3, strongIDColumn: 4,
            dateOrder: .ymd, decimalSeparator: "."
        )
        let replay = ParseReplayDescriptor(
            format: .xlsx, parserVersion: XLSXParser.version,
            delimitedMapping: mapping, selectedWorksheet: "Transactions"
        )
        let source = try FormatRouter().parse(data: data, filename: "book.xlsx", role: .bank, period: january(), replay: replay)
        XCTAssertEqual(source.transactions.count, 1)
        XCTAssertEqual(source.transactions[0].bookingDate.description, "2026-01-02")
        XCTAssertEqual(source.transactions[0].currency.value, "USD")
        XCTAssertEqual(source.transactions[0].strongID, "X1")
        XCTAssertEqual(try XLSXParser().worksheetNames(data: data), ["Transactions"])
    }

    func testOFXXMLAndSGMLPaths() throws {
        let xml = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><CURDEF>USD</CURDEF><BANKACCTFROM><ACCTID>A1</ACCTID></BANKACCTFROM>
            <BANKTRANLIST><DTSTART>20260101000000</DTSTART><DTEND>20260131235959</DTEND><STMTTRN><TRNTYPE>DEBIT</TRNTYPE><DTPOSTED>20260102120000</DTPOSTED><TRNAMT>-5.00</TRNAMT><FITID>F1</FITID><NAME>Vendor</NAME><MEMO>Fee</MEMO></STMTTRN></BANKTRANLIST>
            <LEDGERBAL><BALAMT>95.00</BALAMT><DTASOF>20260131000000</DTASOF></LEDGERBAL></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>
            """.utf8)
        let replay = ParseReplayDescriptor(format: .ofx, parserVersion: OFXParser.version)
        let parsedXML = try FormatRouter().parse(data: xml, filename: "bank.ofx", role: .bank, period: january(), replay: replay)
        XCTAssertEqual(parsedXML.transactions[0].amount.description, "-5")
        XCTAssertEqual(parsedXML.transactions[0].strongID, "F1")
        XCTAssertEqual(parsedXML.balances.count, 1)

        let sgml = Data("""
            OFXHEADER:100
            DATA:OFXSGML
            VERSION:102
            SECURITY:NONE
            ENCODING:USASCII

            <OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><CURDEF>USD<BANKACCTFROM><ACCTID>A1</BANKACCTFROM><BANKTRANLIST><DTSTART>20260101000000<DTEND>20260131235959<STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20260103120000<TRNAMT>7.00<FITID>F2<NAME>Client &amp; Co</STMTTRN></BANKTRANLIST><LEDGERBAL><BALAMT>107.00<DTASOF>20260131000000</LEDGERBAL></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>
            """.utf8)
        let parsedSGML = try FormatRouter().parse(data: sgml, filename: "bank.qfx", role: .bank, period: january(), replay: ParseReplayDescriptor(format: .qfx, parserVersion: OFXParser.version))
        XCTAssertEqual(parsedSGML.transactions[0].payee, "Client & Co")
        XCTAssertEqual(parsedSGML.transactions[0].amount.description, "7")
    }

    func testQIFLocaleProfileAndTermination() throws {
        let data = Data("""
            !Account
            NChecking
            TBank
            ^
            !Type:Bank
            D01/02/2026
            T-12.34
            N1001
            PGrocery
            MWeekly shop
            C*
            ^
            """.utf8)
        let replay = ParseReplayDescriptor(
            format: .qif, parserVersion: QIFParser.version,
            structuredProfile: StructuredImportProfile(dateOrder: .mdy, defaultCurrency: "USD")
        )
        let source = try FormatRouter().parse(data: data, filename: "money.qif", role: .ledger, period: january(), replay: replay)
        XCTAssertEqual(source.transactions.count, 1)
        XCTAssertEqual(source.transactions[0].account, "Checking")
        XCTAssertEqual(source.transactions[0].bookingDate.description, "2026-01-02")
        XCTAssertEqual(source.transactions[0].amount.description, "-12.34")
        XCTAssertThrowsError(try FormatRouter().parse(data: Data(data.dropLast(2)), filename: "bad.qif", role: .ledger, period: january(), replay: replay))
    }

    func testCAMT053AndNotificationCompleteness() throws {
        let namespace = "urn:iso:std:iso:20022:tech:xsd:camt.053.001.08"
        let data = Data("""
            <Document xmlns="\(namespace)"><BkToCstmrStmt><Stmt><Acct><Id><IBAN>DE001</IBAN></Id></Acct>
            <Bal><Tp><CdOrPrtry><Cd>OPBD</Cd></CdOrPrtry></Tp><Amt Ccy="EUR">100.00</Amt><CdtDbtInd>CRDT</CdtDbtInd><Dt><Dt>2026-01-01</Dt></Dt></Bal>
            <Ntry><Amt Ccy="EUR">10.00</Amt><CdtDbtInd>CRDT</CdtDbtInd><Sts>BOOK</Sts><BookgDt><Dt>2026-01-02</Dt></BookgDt><ValDt><Dt>2026-01-02</Dt></ValDt><AcctSvcrRef>ASR1</AcctSvcrRef><NtryDtls><TxDtls><Refs><EndToEndId>E2E1</EndToEndId></Refs><RmtInf><Ustrd>Invoice 1</Ustrd></RmtInf></TxDtls></NtryDtls></Ntry>
            <Bal><Tp><CdOrPrtry><Cd>CLBD</Cd></CdOrPrtry></Tp><Amt Ccy="EUR">110.00</Amt><CdtDbtInd>CRDT</CdtDbtInd><Dt><Dt>2026-01-31</Dt></Dt></Bal>
            </Stmt></BkToCstmrStmt></Document>
            """.utf8)
        let source = try FormatRouter().parse(data: data, filename: "statement.xml", role: .statement, period: january(), replay: ParseReplayDescriptor(format: .camt053, parserVersion: CAMTParser.version))
        XCTAssertEqual(source.transactions[0].reference, "E2E1")
        XCTAssertEqual(source.transactions[0].description, "Invoice 1")
        XCTAssertEqual(source.balances.count, 2)
        let result = try ReconciliationEngine().run(ReconciliationJob(mode: .singleStatement, period: try january(), sources: [source]))
        XCTAssertEqual(result.state, .reconciled)

        let notificationNamespace = "urn:iso:std:iso:20022:tech:xsd:camt.054.001.02"
        let notification = Data("""
            <Document xmlns="\(notificationNamespace)"><BkToCstmrDbtCdtNtfctn><Ntfctn><Acct><Id><IBAN>DE001</IBAN></Id></Acct><Ntry><Amt Ccy="EUR">1.00</Amt><CdtDbtInd>DBIT</CdtDbtInd><BookgDt><Dt>2026-01-03</Dt></BookgDt></Ntry></Ntfctn></BkToCstmrDbtCdtNtfctn></Document>
            """.utf8)
        let parsedNotification = try FormatRouter().parse(data: notification, filename: "notice.xml", role: .bank, period: january(), replay: ParseReplayDescriptor(format: .camt054, parserVersion: CAMTParser.version))
        XCTAssertEqual(parsedNotification.completeness, .notificationOnly)
        XCTAssertEqual(parsedNotification.transactions[0].amount.description, "-1")
    }

    func testMT940ReversalAwareStatement() throws {
        let data = Data("""
            :20:REF1
            :25:ACC1
            :28C:00001/001
            :60F:C260101USD100,00
            :61:2601020102C10,00NTRFCUST//BANK
            :86:Deposit
            :62F:C260131USD110,00
            """.utf8)
        let replay = ParseReplayDescriptor(format: .mt940, parserVersion: MT940Parser.version)
        let source = try FormatRouter().parse(data: data, filename: "statement.sta", role: .statement, period: january(), replay: replay)
        XCTAssertEqual(source.transactions[0].amount.description, "10")
        XCTAssertEqual(source.transactions[0].strongID, "BANK")
        XCTAssertEqual(source.transactions[0].description, "Deposit")
        XCTAssertEqual(source.balances.count, 2)
    }

    func testBAI2ControlTotalsAndCounts() throws {
        let data = Data("""
            01,SENDER,RECEIVER,260131,1200,1,,,2/
            02,RECEIVER,SENDER,1,260131,1200,USD,2/
            03,ACC1,USD,010,10000,1,0,015,11000,1,0/
            16,195,1000,0,BANK1,CUST1,Deposit/
            49,22000,3/
            98,22000,1,5/
            99,22000,1,7/
            """.utf8)
        let day = try LocalDate(iso8601: "2026-01-31")
        let period = try ReconciliationPeriod(start: day, end: day)
        let replay = ParseReplayDescriptor(
            format: .bai2, parserVersion: BAI2Parser.version,
            structuredProfile: StructuredImportProfile(defaultCurrency: "USD")
        )
        let source = try FormatRouter().parse(data: data, filename: "cash.bai", role: .statement, period: period, replay: replay)
        XCTAssertEqual(source.transactions[0].amount.description, "10")
        XCTAssertEqual(source.balances.map(\.amount.description), ["100", "110"])
        let result = try ReconciliationEngine().run(ReconciliationJob(mode: .singleStatement, period: period, sources: [source]))
        XCTAssertEqual(result.state, .reconciled)

        let corrupted = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "49,22000,3", with: "49,21999,3").utf8)
        XCTAssertThrowsError(try FormatRouter().parse(data: corrupted, filename: "bad.bai", role: .statement, period: period, replay: replay))
    }

    private func storedZIP(_ entries: [String: Data]) -> Data {
        struct Central {
            let name: Data
            let crc: UInt32
            let size: UInt32
            let offset: UInt32
        }
        func crc32(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in data {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB8_8320 : 0) }
            }
            return crc ^ 0xFFFF_FFFF
        }
        func append16(_ value: UInt16, to data: inout Data) {
            data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func append32(_ value: UInt32, to data: inout Data) {
            append16(UInt16(truncatingIfNeeded: value), to: &data); append16(UInt16(truncatingIfNeeded: value >> 16), to: &data)
        }
        var output = Data()
        var central: [Central] = []
        for path in entries.keys.sorted() {
            let name = Data(path.utf8)
            let payload = entries[path] ?? Data()
            let crc = crc32(payload)
            central.append(Central(name: name, crc: crc, size: UInt32(payload.count), offset: UInt32(output.count)))
            append32(0x0403_4B50, to: &output); append16(20, to: &output); append16(0x0800, to: &output)
            append16(0, to: &output); append16(0, to: &output); append16(0, to: &output)
            append32(crc, to: &output); append32(UInt32(payload.count), to: &output); append32(UInt32(payload.count), to: &output)
            append16(UInt16(name.count), to: &output); append16(0, to: &output); output.append(name); output.append(payload)
        }
        let centralOffset = UInt32(output.count)
        for entry in central {
            append32(0x0201_4B50, to: &output); append16(20, to: &output); append16(20, to: &output); append16(0x0800, to: &output)
            append16(0, to: &output); append16(0, to: &output); append16(0, to: &output)
            append32(entry.crc, to: &output); append32(entry.size, to: &output); append32(entry.size, to: &output)
            append16(UInt16(entry.name.count), to: &output); append16(0, to: &output); append16(0, to: &output)
            append16(0, to: &output); append16(0, to: &output); append32(0, to: &output); append32(entry.offset, to: &output); output.append(entry.name)
        }
        let centralSize = UInt32(output.count) - centralOffset
        append32(0x0605_4B50, to: &output); append16(0, to: &output); append16(0, to: &output)
        append16(UInt16(central.count), to: &output); append16(UInt16(central.count), to: &output)
        append32(centralSize, to: &output); append32(centralOffset, to: &output); append16(0, to: &output)
        return output
    }
}
