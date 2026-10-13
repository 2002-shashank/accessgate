// GateClient.swift
// Sends the verification decision to the ESP32 access gate over the local network.

import Foundation

enum GateClient {
    /// Calls /grant or /deny on the gate and returns a short status line for the UI.
    static func send(granted: Bool, name: String, reason: String) async -> String {
        var components = URLComponents()
        components.scheme = "http"
        components.host = Secrets.gateHost
        components.path = granted ? "/grant" : "/deny"

        var items = [URLQueryItem(name: "token", value: Secrets.gateToken)]
        if granted {
            items.append(URLQueryItem(name: "name", value: name))
        } else {
            items.append(URLQueryItem(name: "reason", value: reason))
        }
        components.queryItems = items

        guard let url = components.url else { return "Gate address is invalid" }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: return granted ? "Gate unlocked" : "Gate kept locked"
            case 401: return "Gate rejected the token"
            default:  return "Gate returned an error (\(code))"
            }
        } catch {
            return "Gate unreachable: \(error.localizedDescription)"
        }
    }
}
