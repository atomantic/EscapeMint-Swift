import Foundation

actor FundStore {
    static let shared = FundStore()

    private let fileManager = FileManager.default

    var fundsDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let funds = docs.appendingPathComponent("funds")
        try? fileManager.createDirectory(at: funds, withIntermediateDirectories: true)
        return funds
    }

    // MARK: - Read

    func readAllFunds() -> [FundData] {
        let dir = fundsDirectory
        guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "tsv" }
            .compactMap { readFund(tsvURL: $0) }
    }

    func readFund(tsvURL: URL) -> FundData? {
        let configURL = tsvURL.deletingPathExtension().appendingPathExtension("json")
        guard fileManager.fileExists(atPath: configURL.path),
              fileManager.fileExists(atPath: tsvURL.path) else { return nil }

        guard let configData = try? Data(contentsOf: configURL),
              var config = try? JSONDecoder().decode(FundConfig.self, from: configData) else { return nil }

        guard let platform = config.platform, let ticker = config.ticker else { return nil }

        // Clean metadata from config
        config.platform = nil
        config.ticker = nil

        guard let tsvContent = try? String(contentsOf: tsvURL, encoding: .utf8) else { return nil }
        let entries = parseTSV(tsvContent)

        return FundData(platform: platform, ticker: ticker, config: config, entries: entries)
    }

    func readFundById(_ id: String) -> FundData? {
        let tsvURL = fundsDirectory.appendingPathComponent("\(id).tsv")
        return readFund(tsvURL: tsvURL)
    }

    // MARK: - Write

    func writeFund(_ fund: FundData) throws {
        let tsvURL = fundsDirectory.appendingPathComponent("\(fund.id).tsv")
        let configURL = fundsDirectory.appendingPathComponent("\(fund.id).json")

        // Write config with metadata
        var configWithMeta = fund.config
        configWithMeta.platform = fund.platform
        configWithMeta.ticker = fund.ticker
        let configData = try JSONEncoder.pretty.encode(configWithMeta)
        try configData.write(to: configURL)

        // Write entries
        let tsv = buildTSV(fund.entries)
        try tsv.write(to: tsvURL, atomically: true, encoding: .utf8)
    }

    func appendEntry(fundId: String, entry: FundEntry) throws {
        let tsvURL = fundsDirectory.appendingPathComponent("\(fundId).tsv")
        guard fileManager.fileExists(atPath: tsvURL.path) else { return }
        let line = serializeEntry(entry) + "\n"
        let handle = try FileHandle(forWritingTo: tsvURL)
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    }

    func updateConfig(fundId: String, config: FundConfig) throws {
        let configURL = fundsDirectory.appendingPathComponent("\(fundId).json")
        guard fileManager.fileExists(atPath: configURL.path) else { return }

        guard let existing = try? Data(contentsOf: configURL),
              let existingConfig = try? JSONDecoder().decode(FundConfig.self, from: existing) else { return }

        var updated = config
        updated.platform = existingConfig.platform
        updated.ticker = existingConfig.ticker
        let data = try JSONEncoder.pretty.encode(updated)
        try data.write(to: configURL)
    }

    func deleteFund(id: String) throws {
        let tsvURL = fundsDirectory.appendingPathComponent("\(id).tsv")
        let configURL = fundsDirectory.appendingPathComponent("\(id).json")
        try? fileManager.removeItem(at: tsvURL)
        try? fileManager.removeItem(at: configURL)
    }
}

// MARK: - TSV Parsing

private let entryHeaders = ["date", "value", "cash", "action", "amount", "shares", "price", "dividend", "expense", "cash_interest", "fund_size", "margin_available", "margin_borrowed", "margin_expense", "notes", "contracts", "entry_price", "liquidation_price", "unrealized_pnl", "margin_locked", "fee", "margin"]

func parseTSV(_ content: String) -> [FundEntry] {
    let lines = content.replacingOccurrences(of: "\r\n", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: true)
    guard lines.count > 1 else { return [] }

    let headers = lines[0].split(separator: "\t").map(String.init)
    return lines.dropFirst().compactMap { line in
        parseEntry(String(line), headers: headers)
    }
}

func parseEntry(_ line: String, headers: [String]) -> FundEntry {
    let values = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    var entry = FundEntry(date: "", value: 0)

    for (i, header) in headers.enumerated() {
        let val = i < values.count ? values[i] : ""
        if val.isEmpty { continue }

        switch header {
        case "date": entry.date = val
        case "value": entry.value = Double(val) ?? 0
        case "cash": entry.cash = Double(val)
        case "action": entry.action = FundAction(rawValue: val)
        case "amount": entry.amount = Double(val)
        case "shares": entry.shares = Double(val)
        case "price": entry.price = Double(val)
        case "dividend": entry.dividend = Double(val)
        case "expense": entry.expense = Double(val)
        case "cash_interest": entry.cash_interest = Double(val)
        case "fund_size": entry.fund_size = Double(val)
        case "margin_available": entry.margin_available = Double(val)
        case "margin_borrowed": entry.margin_borrowed = Double(val)
        case "margin_expense": entry.margin_expense = Double(val)
        case "notes": entry.notes = val.replacingOccurrences(of: "\\t", with: "\t").replacingOccurrences(of: "\\n", with: "\n")
        case "contracts": entry.contracts = Double(val)
        case "entry_price": entry.entry_price = Double(val)
        case "liquidation_price": entry.liquidation_price = Double(val)
        case "unrealized_pnl": entry.unrealized_pnl = Double(val)
        case "margin_locked": entry.margin_locked = Double(val)
        case "fee": entry.fee = Double(val)
        case "margin": entry.margin = Double(val)
        default: break
        }
    }
    return entry
}

func optStr(_ val: Double?) -> String { val.map { String($0) } ?? "" }

func serializeEntry(_ entry: FundEntry) -> String {
    var parts: [String] = []
    parts.append(entry.date)
    parts.append(String(entry.value))
    parts.append(optStr(entry.cash))
    parts.append(entry.action?.rawValue ?? "")
    parts.append(optStr(entry.amount))
    parts.append(optStr(entry.shares))
    parts.append(optStr(entry.price))
    parts.append(optStr(entry.dividend))
    parts.append(optStr(entry.expense))
    parts.append(optStr(entry.cash_interest))
    parts.append(optStr(entry.fund_size))
    parts.append(optStr(entry.margin_available))
    parts.append(optStr(entry.margin_borrowed))
    parts.append(optStr(entry.margin_expense))
    let notes = (entry.notes ?? "").replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\n", with: "\\n")
    parts.append(notes)
    parts.append(optStr(entry.contracts))
    parts.append(optStr(entry.entry_price))
    parts.append(optStr(entry.liquidation_price))
    parts.append(optStr(entry.unrealized_pnl))
    parts.append(optStr(entry.margin_locked))
    parts.append(optStr(entry.fee))
    parts.append(optStr(entry.margin))
    return parts.joined(separator: "\t")
}

func buildTSV(_ entries: [FundEntry]) -> String {
    var lines = [entryHeaders.joined(separator: "\t")]
    for entry in entries {
        lines.append(serializeEntry(entry))
    }
    return lines.joined(separator: "\n") + "\n"
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
