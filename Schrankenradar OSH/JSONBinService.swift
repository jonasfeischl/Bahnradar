import Foundation

// MARK: - JSONBin Service (ersetzt Firebase)

struct JSONBinService {
    private let masterKey = "$2a$10$.oOn8MvUcBcoThvB27IVfemdPNdE7PEGkLxN1rg1s6Z5AyW6daVLK"
    private let binID     = "6a1bf4e8ddf5aa59f77b0ad3"
    private let baseURL   = "https://api.jsonbin.io/v3/b"

    // MARK: Lesen

    func loadVotes() async -> (closingVotes: [Double], openingVotes: [Double]) {
        guard let url = URL(string: "\(baseURL)/\(binID)/latest") else {
            return ([], [])
        }
        var request = URLRequest(url: url)
        request.setValue(masterKey, forHTTPHeaderField: "X-Master-Key")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let record = json?["record"] as? [String: Any]
            let closing = record?["closingVotes"] as? [Double] ?? []
            let opening = record?["openingVotes"] as? [Double] ?? []
            return (closing, opening)
        } catch {
            return ([], [])
        }
    }

    // MARK: Speichern

    func saveVotes(closingVotes: [Double], openingVotes: [Double]) async {
        guard let url = URL(string: "\(baseURL)/\(binID)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(masterKey, forHTTPHeaderField: "X-Master-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "closingVotes": closingVotes,
            "openingVotes": openingVotes
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        _ = try? await URLSession.shared.data(for: request)
    }
}
