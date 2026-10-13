// VerifierService.swift
// Wraps the Credence ID Tap2iD SDK: license check, QR engagement,
// verification callbacks, and the access decision sent to the gate.

import Foundation
import Combine
@preconcurrency import Tap2iDVerifierSDK

// MARK: - Policy

enum AppConfig {
    /// Require the holder to be 21 or older to open the gate.
    nonisolated static let requireAgeOver21 = true

    /// UserDefaults key for the "Accept test issuers (development only)" switch.
    nonisolated static let acceptTestIssuersKey = "acceptTestIssuers"

    /// Read at verification time. Off unless the operator turns it on in the app.
    nonisolated static var acceptTestIssuers: Bool {
        UserDefaults.standard.bool(forKey: acceptTestIssuersKey)
    }
}

// MARK: - Models

nonisolated struct DetailRow: Equatable, Sendable {
    let label: String
    let value: String
}

nonisolated struct VerificationOutcome: Equatable, Sendable {
    let passed: Bool
    let headline: String
    let name: String
    let denyReason: String
    let details: [DetailRow]
    let checks: [DetailRow]      // security checks reported by the SDK
    let technical: [DetailRow]   // every simple field returned, for troubleshooting
    let rawStatus: String
}

enum VerifierPhase: Equatable {
    case idle
    case checkingLicense
    case licenseFailed(String)
    case ready
    case scanning
    case verifying(String)
    case finished(VerificationOutcome)
    case failed(String)
}

// MARK: - Service

@MainActor
final class VerifierService: ObservableObject {
    @Published private(set) var phase: VerifierPhase = .idle
    @Published private(set) var licenseInfo = ""
    @Published private(set) var gateStatus = ""

    /// Validates the license key with Verify with Credence.
    func start() {
        switch phase {
        case .idle, .licenseFailed: break
        default: return
        }
        phase = .checkingLicense

        Self.initSDK(apiKey: Secrets.licenseKey) { [weak self] ok, message in
            Task { @MainActor in
                guard let self else { return }
                if ok {
                    self.licenseInfo = message
                    self.phase = .ready
                } else {
                    self.phase = .licenseFailed(message)
                }
            }
        }
    }

    func beginScan() {
        gateStatus = ""
        phase = .scanning
    }

    func cancelScan() {
        phase = .ready
    }

    func reset() {
        gateStatus = ""
        phase = .ready
    }

    /// Called with the "mdoc:" string from the wallet's QR code.
    func handleScanned(_ code: String) {
        guard phase == .scanning else { return }
        phase = .verifying("Connecting to wallet…")
        if let error = Tap2iDVerifySDK.shared.verifyMdoc(engagementConfig: .qrCode(code), delegate: self) {
            phase = .failed("Could not start verification: \(error.localizedDescription)")
        }
    }

    /// Sends a test unlock to the gate. Also triggers the iOS Local Network prompt early.
    func testGate() {
        gateStatus = "Contacting gate…"
        Task {
            gateStatus = await GateClient.send(granted: true, name: "Test", reason: "")
        }
    }

    // MARK: Delegate handlers (main actor)

    fileprivate func handleStage(_ text: String) {
        if case .verifying = phase { phase = .verifying(text) }
    }

    fileprivate func handleStageError(_ text: String) {
        guard case .verifying = phase else { return }
        phase = .failed(text)
        Task {
            gateStatus = await GateClient.send(granted: false, name: "", reason: "Verification failed")
        }
    }

    fileprivate func handleCompleted(_ outcome: VerificationOutcome) {
        guard case .verifying = phase else { return }
        phase = .finished(outcome)
        gateStatus = "Updating gate…"
        Task {
            gateStatus = await GateClient.send(granted: outcome.passed,
                                               name: outcome.name,
                                               reason: outcome.denyReason)
        }
    }

    // MARK: SDK init (off the main actor; the SDK may call back on any thread)

    nonisolated private static func initSDK(apiKey: String,
                                            done: @escaping @Sendable (Bool, String) -> Void) {
        let config = CoreSdkConfig(apiKey: apiKey)
        Tap2iDVerifySDK.shared.initSdk(config: config, initResult: { result in
            if let error = result.error {
                done(false, error.localizedDescription)
                return
            }
            let message = "License valid · profile \(result.profileName ?? "-")"
            // Pull the latest trust settings from Verify with Credence.
            Tap2iDVerifySDK.shared.refreshConfiguration { _ in
                done(true, message)
            }
        })
    }
}

// MARK: - Tap2iD SDK delegate

extension VerifierService: nonisolated Tap2iDVerifySDKDelegate {
    nonisolated func onVerificationStageStarted(stage: VerificationStage) {
        let text = ResultParser.stageText(stage)
        Task { @MainActor in self.handleStage(text) }
    }

    nonisolated func onVerificationStageError(stage: VerificationStage?, error: CoreCredenceErrorStruct?) {
        let text = ResultParser.friendlyError(error)
        print("[AccessGate] stage error: \(error.map { String(describing: $0) } ?? "nil")")
        Task { @MainActor in self.handleStageError(text) }
    }

    nonisolated func onVerificationStageCompleted(stage: VerificationStage) {}

    nonisolated func onVerificationCompleted(verificationResult: VerificationResult?) {
        let outcome = ResultParser.parse(verificationResult)
        Task { @MainActor in self.handleCompleted(outcome) }
    }
}

// MARK: - Result parsing

/// Reads the verification result into plain values the UI can show.
/// Field lookup walks the result generically, so it tolerates small
/// differences in how the SDK nests document attributes.
nonisolated enum ResultParser {

    static func stageText(_ stage: VerificationStage) -> String {
        let raw = String(describing: stage)
        let lower = raw.lowercased()
        if lower.contains("engage") || lower.contains("connect") { return "Connecting to wallet…" }
        if lower.contains("retriev") || lower.contains("request") { return "Waiting for the holder to approve on their phone…" }
        if lower.contains("verif") || lower.contains("valid") { return "Checking issuer signature…" }
        return raw
    }

    static func parse(_ result: VerificationResult?) -> VerificationOutcome {
        guard let result else {
            return VerificationOutcome(passed: false,
                                       headline: "The wallet did not return a credential.",
                                       name: "",
                                       denyReason: "No credential",
                                       details: [],
                                       checks: [],
                                       technical: [],
                                       rawStatus: "none")
        }

        let rawStatus = String(describing: result.status)
        var attributes: [String: Any] = [:]
        collect(result, into: &attributes, depth: 0)

        // Printed to the Xcode console to help tune the policy during testing.
        print("[AccessGate] ===== FULL RESULT START =====")
        dump(result, maxDepth: 8, maxItems: 400)
        print("[AccessGate] ===== FULL RESULT END =====")
        print("[AccessGate] status = \(rawStatus)")
        for key in attributes.keys.sorted() where key != "portrait" {
            print("[AccessGate]   \(key) = \(attributes[key]!)")
        }

        // 1. Security checks reported by the SDK. Every check that is present must pass,
        //    and the two that matter most (issuer signature + trusted issuer) must be present.
        var checks: [DetailRow] = []
        var cryptoOK = true
        var issuerTrusted = false
        var usedTestIssuer = false
        let issuerName = "\(attributes["issuerDistinguishedName"] ?? "")"
        let isKnownTestIssuer = issuerName.contains("Multipaz TEST")
        for check in securityChecks {
            guard let value = attributes[check.key] else {
                if check.required { cryptoOK = false }
                continue
            }
            let ok = (value as? Bool) ?? ("\(value)".lowercased() == "true")
            if check.key == "isIssuerTrusted" {
                issuerTrusted = ok
                // Development only: accept the Multipaz test issuer when the operator
                // has switched this on. The result screen always says so.
                if !ok && AppConfig.acceptTestIssuers && isKnownTestIssuer {
                    usedTestIssuer = true
                    checks.append(DetailRow(label: check.label, value: "Test issuer (dev)"))
                    continue
                }
            }
            if !ok { cryptoOK = false }
            checks.append(DetailRow(label: check.label, value: ok ? "Passed" : "Failed"))
        }

        // 2. Overall status. "partialSuccess" is accepted only when every security check
        //    passed (it then means an optional field was not shared); anything else is denied.
        let status = rawStatus.lowercased()
        let statusOK: Bool
        if status.contains("fail") || status.contains("error") || status.contains("invalid") {
            statusOK = false
        } else {
            statusOK = cryptoOK && status.contains("success")
        }

        // 3. Is the holder over 21?
        var ageOK: Bool?
        if let value = attributes["age_over_21"] {
            ageOK = (value as? Bool) ?? ("\(value)".lowercased() == "true")
        } else if let dob = attributes["birth_date"], let years = age(from: dob) {
            ageOK = years >= 21
        }

        let name = attributes["given_name"].map { "\($0)" } ?? ""

        let passed: Bool
        let denyReason: String
        if !statusOK {
            passed = false
            denyReason = !issuerTrusted && !usedTestIssuer ? "Issuer not trusted"
                       : (cryptoOK ? "ID not verified" : "Security check failed")
        } else if AppConfig.requireAgeOver21 && ageOK == false {
            passed = false
            denyReason = "Under 21"
        } else if AppConfig.requireAgeOver21 && ageOK == nil {
            passed = false
            denyReason = "Age not shared"
        } else {
            passed = true
            denyReason = ""
        }

        let headline: String
        if passed && usedTestIssuer {
            headline = "Genuine test credential. Test issuer accepted (development mode)."
        } else if passed {
            headline = name.isEmpty ? "Credential verified. Only the over-21 answer was shared."
                                    : "Credential verified for \(name)."
        } else if denyReason == "Issuer not trusted" {
            headline = "The ID is genuine, but its issuer is not on the trusted list."
        } else if !statusOK {
            headline = "The credential could not be verified."
        } else {
            headline = "\(denyReason)."
        }

        let technical = attributes.keys.sorted()
            .filter { $0 != "portrait" }
            .map { DetailRow(label: $0, value: "\(attributes[$0]!)") }
            + [DetailRow(label: "status", value: rawStatus)]

        return VerificationOutcome(passed: passed,
                                   headline: headline,
                                   name: name,
                                   denyReason: denyReason,
                                   details: detailRows(from: attributes),
                                   checks: checks,
                                   technical: technical,
                                   rawStatus: rawStatus)
    }

    /// Pulls the human-readable message out of an SDK error.
    static func friendlyError(_ error: CoreCredenceErrorStruct?) -> String {
        guard let error else { return "Verification failed." }
        for child in Mirror(reflecting: error).children where child.label == "errorMessage" {
            if let text = unwrap(child.value) as? String, !text.isEmpty { return text }
        }
        return String(describing: error)
    }

    private static let securityChecks: [(key: String, label: String, required: Bool)] = [
        ("isIssuerTrusted", "Trusted issuer", true),
        ("isIssuerSignedValid", "Issuer signature", true),
        ("areDigestsValid", "Data not tampered", false),
        ("isDeviceSignedValid", "Bound to holder's phone", false)
    ]

    // MARK: Helpers

    private static let shownFields: [(key: String, label: String)] = [
        ("given_name", "First name"),
        ("family_name", "Last name"),
        ("birth_date", "Date of birth"),
        ("age_over_21", "Over 21"),
        ("issuerDistinguishedName", "Issued by"),
        ("expiry_date", "Expires"),
        ("document_number", "Document no.")
    ]

    private static func detailRows(from attributes: [String: Any]) -> [DetailRow] {
        shownFields.compactMap { field in
            guard let value = attributes[field.key] else { return nil }
            var text = display(value)
            if field.key == "issuerDistinguishedName" {
                text = commonName(from: text)
            }
            if field.key == "document_number", text.count > 4 {
                text = "••••" + text.suffix(4)
            }
            return DetailRow(label: field.label, value: text)
        }
    }

    private static func commonName(from dn: String) -> String {
        for part in dn.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("CN=") { return String(trimmed.dropFirst(3)) }
        }
        return dn
    }

    private static func display(_ value: Any) -> String {
        if let flag = value as? Bool { return flag ? "Yes" : "No" }
        if let date = value as? Date { return date.formatted(date: .abbreviated, time: .omitted) }
        return "\(value)"
    }

    private static func age(from value: Any) -> Int? {
        let birth: Date?
        if let date = value as? Date {
            birth = date
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            birth = formatter.date(from: String("\(value)".prefix(10)))
        }
        guard let birth else { return nil }
        return Calendar.current.dateComponents([.year], from: birth, to: Date()).year
    }

    private static func isLeaf(_ value: Any) -> Bool {
        value is String || value is Bool || value is Int || value is Double || value is Date
    }

    private static func unwrap(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        guard let first = mirror.children.first else { return nil }
        return unwrap(first.value)
    }

    /// Walks the result and records every simple key/value pair it finds.
    private static func collect(_ input: Any, into out: inout [String: Any], depth: Int) {
        guard depth < 12, let value = unwrap(input) else { return }
        if value is Data || value is [UInt8] { return }   // skip images and raw bytes

        let mirror = Mirror(reflecting: value)

        if mirror.displayStyle == .dictionary {
            for pair in mirror.children {
                let parts = Array(Mirror(reflecting: pair.value).children)
                guard parts.count == 2 else { continue }
                let key = "\(unwrap(parts[0].value) ?? "")"
                guard let element = unwrap(parts[1].value) else { continue }
                if isLeaf(element) {
                    out[key] = element
                } else {
                    collect(element, into: &out, depth: depth + 1)
                }
            }
            return
        }

        for child in mirror.children {
            guard let element = unwrap(child.value) else { continue }
            if let label = child.label, isLeaf(element) {
                if out[label] == nil { out[label] = element }
            } else {
                collect(element, into: &out, depth: depth + 1)
            }
        }
    }
}
