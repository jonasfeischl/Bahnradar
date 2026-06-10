import Foundation

// MARK: - Anonyme User-ID (einmalig pro Gerät generiert)

private let keyUserId = "anonymousUserId"

var anonymousUserId: String {
    if let stored = UserDefaults.standard.string(forKey: keyUserId) { return stored }
    let new = "user_\(UUID().uuidString.prefix(8))"
    UserDefaults.standard.set(new, forKey: keyUserId)
    return new
}

// MARK: - Datenstruktur
//
// JSONBin speichert:
// {
//   "osh_dachauer": {
//     "user_abc12345": { "c": [15, 15], "o": [10] },
//     "user_xyz67890": { "c": [200],    "o": [10] }
//   },
//   "feldmoching_lechenauer1": { ... }
// }
//
// Aggregation: pro User Median berechnen → dann Median aller User-Mediane
// → Outlier-User beeinflussen das Ergebnis nicht

// MARK: - Community GPS Offsets (geräteübergreifend)

struct CommunityGPSOffsets {
    let munich: Double?
    let freising: Double?
    let munichCount: Int
    let freisingCount: Int

    static let empty = CommunityGPSOffsets(munich: nil, freising: nil, munichCount: 0, freisingCount: 0)
}

struct JSONBinService {
    private let masterKey = "$2a$10$.oOn8MvUcBcoThvB27IVfemdPNdE7PEGkLxN1rg1s6Z5AyW6daVLK"
    private let binID     = "6a1bf4e8ddf5aa59f77b0ad3"
    private let baseURL   = "https://api.jsonbin.io/v3/b"

    // MARK: Lesen + Aggregieren (Feedback-Votes)

    func loadAggregated(crossingId: String) async -> (closing: Double, opening: Double, munich: Double, freising: Double) {
        guard let url = URL(string: "\(baseURL)/\(binID)/latest") else { return (0, 0, 0, 0) }
        var request = URLRequest(url: url)
        request.setValue(masterKey, forHTTPHeaderField: "X-Master-Key")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record  = json["record"] as? [String: Any],
              let crossing = record[crossingId] as? [String: Any] else { return (0, 0, 0, 0) }

        // Pro User Median berechnen → dann Median aller User-Mediane (Ausreißerschutz)
        var userClosingMedians:  [Double] = []
        var userOpeningMedians:  [Double] = []
        var userMunichMedians:   [Double] = []
        var userFreisingMedians: [Double] = []

        for (_, value) in crossing {
            guard let userEntry = value as? [String: Any] else { continue }
            let c  = userEntry["c"]  as? [Double] ?? []
            let o  = userEntry["o"]  as? [Double] ?? []
            let cm = userEntry["cm"] as? [Double] ?? []
            let cf = userEntry["cf"] as? [Double] ?? []
            if !c.isEmpty  { userClosingMedians.append(median(of: c)) }
            if !o.isEmpty  { userOpeningMedians.append(median(of: o)) }
            if !cm.isEmpty { userMunichMedians.append(median(of: cm)) }
            if !cf.isEmpty { userFreisingMedians.append(median(of: cf)) }
        }

        return (
            median(of: userClosingMedians),
            median(of: userOpeningMedians),
            median(of: userMunichMedians),
            median(of: userFreisingMedians)
        )
    }

    // MARK: GPS-Offsets (geräteübergreifend)

    /// Lädt Community-GPS-Offsets aller Geräte für einen Bahnübergang.
    /// Aggregation: Median aller Rohwerte (GPS ist objektiv, kein Voting-Bias).
    func loadCommunityGPSOffsets(crossingId: String) async -> CommunityGPSOffsets {
        guard let url = URL(string: "\(baseURL)/\(binID)/latest") else { return .empty }
        var request = URLRequest(url: url)
        request.setValue(masterKey, forHTTPHeaderField: "X-Master-Key")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record   = json["record"] as? [String: Any],
              let crossing = record[crossingId] as? [String: Any]
        else { return .empty }

        var allMunich:   [Double] = []
        var allFreising: [Double] = []

        for (_, value) in crossing {
            guard let entry = value as? [String: Any] else { continue }
            if let gm = entry["gm"] as? [Double] { allMunich.append(contentsOf: gm) }
            if let gf = entry["gf"] as? [Double] { allFreising.append(contentsOf: gf) }
        }

        // Ausreißer herausfiltern (außerhalb ±5 Minuten = eindeutig falsch)
        let filteredMunich   = allMunich.filter   { abs($0) < 300 }
        let filteredFreising = allFreising.filter { abs($0) < 300 }

        return CommunityGPSOffsets(
            munich:        filteredMunich.isEmpty   ? nil : median(of: filteredMunich),
            freising:      filteredFreising.isEmpty ? nil : median(of: filteredFreising),
            munichCount:   filteredMunich.count,
            freisingCount: filteredFreising.count
        )
    }

    /// Lädt Community-Offsets für alle bekannten Bahnübergänge auf einmal (ein API-Call).
    func loadAllCommunityGPSOffsets() async -> [String: CommunityGPSOffsets] {
        guard let url = URL(string: "\(baseURL)/\(binID)/latest") else { return [:] }
        var request = URLRequest(url: url)
        request.setValue(masterKey, forHTTPHeaderField: "X-Master-Key")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = json["record"] as? [String: Any]
        else { return [:] }

        var result: [String: CommunityGPSOffsets] = [:]

        for crossingId in CrossingLocation.all.map(\.id) {
            guard let crossing = record[crossingId] as? [String: Any] else { continue }

            var allMunich:   [Double] = []
            var allFreising: [Double] = []

            for (_, value) in crossing {
                guard let entry = value as? [String: Any] else { continue }
                if let gm = entry["gm"] as? [Double] { allMunich.append(contentsOf: gm) }
                if let gf = entry["gf"] as? [Double] { allFreising.append(contentsOf: gf) }
            }

            let fM = allMunich.filter   { abs($0) < 300 }
            let fF = allFreising.filter { abs($0) < 300 }

            result[crossingId] = CommunityGPSOffsets(
                munich:        fM.isEmpty ? nil : median(of: fM),
                freising:      fF.isEmpty ? nil : median(of: fF),
                munichCount:   fM.count,
                freisingCount: fF.count
            )
        }
        return result
    }

    /// Speichert einen GPS-Rohoffset dieses Geräts für einen Bahnübergang.
    /// Pro Gerät werden max. 50 Messungen gehalten (älteste werden verworfen).
    func submitGPSOffset(crossingId: String,
                         munichOffset:   Double? = nil,
                         freisingOffset: Double? = nil) async {
        guard munichOffset != nil || freisingOffset != nil else { return }
        guard let url = URL(string: "\(baseURL)/\(binID)/latest") else { return }
        var getReq = URLRequest(url: url)
        getReq.setValue(masterKey, forHTTPHeaderField: "X-Master-Key")

        guard let (data, _) = try? await URLSession.shared.data(for: getReq),
              var record = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["record"] as? [String: Any]
        else { return }

        var crossingData = record[crossingId] as? [String: Any] ?? [:]
        var userEntry    = crossingData[anonymousUserId] as? [String: Any] ?? [:]

        func appendGPS(_ offset: Double, key: String) {
            var values = userEntry[key] as? [Double] ?? []
            values.append(offset)
            if values.count > 50 { values = Array(values.suffix(50)) }
            userEntry[key] = values
        }

        if let m = munichOffset   { appendGPS(m, key: "gm") }
        if let f = freisingOffset { appendGPS(f, key: "gf") }

        crossingData[anonymousUserId] = userEntry
        record[crossingId] = crossingData

        try? await putRecord(record)
    }

    // MARK: Speichern (eigene Votes anhängen)

    func submitVote(crossingId: String, closingDelta: Double?, openingDelta: Double?,
                    closingMunich: Double? = nil, closingFreising: Double? = nil) async {
        guard let url = URL(string: "\(baseURL)/\(binID)/latest") else { return }
        var getReq = URLRequest(url: url)
        getReq.setValue(masterKey, forHTTPHeaderField: "X-Master-Key")

        guard let (data, _) = try? await URLSession.shared.data(for: getReq),
              var record = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["record"] as? [String: Any]
        else { return }

        // Crossing-Eintrag holen oder neu anlegen
        var crossingData = record[crossingId] as? [String: Any] ?? [:]
        var userEntry    = crossingData[anonymousUserId] as? [String: Any] ?? [:]

        func append(_ delta: Double, key: String) {
            var votes = userEntry[key] as? [Double] ?? []
            votes.append(delta)
            if votes.count > 20 { votes = Array(votes.suffix(20)) }
            userEntry[key] = votes
        }

        if let d = closingDelta   { append(d, key: "c") }
        if let d = openingDelta   { append(d, key: "o") }
        if let d = closingMunich  { append(d, key: "cm") }
        if let d = closingFreising { append(d, key: "cf") }

        crossingData[anonymousUserId] = userEntry
        record[crossingId] = crossingData

        try? await putRecord(record)
    }

    /// Löscht alle eigenen Votes für alle Übergänge aus JSONBin
    func resetUserVotes() async {
        guard let url = URL(string: "\(baseURL)/\(binID)/latest") else { return }
        var getReq = URLRequest(url: url)
        getReq.setValue(masterKey, forHTTPHeaderField: "X-Master-Key")

        guard let (data, _) = try? await URLSession.shared.data(for: getReq),
              var record = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["record"] as? [String: Any]
        else { return }

        // Eigenen User-Eintrag aus allen Übergängen entfernen
        for crossingId in record.keys {
            if var crossingData = record[crossingId] as? [String: Any] {
                crossingData.removeValue(forKey: anonymousUserId)
                record[crossingId] = crossingData
            }
        }

        try? await putRecord(record)
    }

    private func putRecord(_ record: [String: Any]) async throws {
        guard let putUrl = URL(string: "\(baseURL)/\(binID)") else { return }
        var putReq = URLRequest(url: putUrl)
        putReq.httpMethod = "PUT"
        putReq.setValue(masterKey, forHTTPHeaderField: "X-Master-Key")
        putReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        putReq.httpBody = try? JSONSerialization.data(withJSONObject: record)
        _ = try? await URLSession.shared.data(for: putReq)
    }

    // MARK: - Median

    private func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }
}
