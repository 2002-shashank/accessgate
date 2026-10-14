// ContentView.swift
// Screens: license check → ready → scanning → verifying → result.

import SwiftUI

struct ContentView: View {
    @StateObject private var verifier = VerifierService()

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.07, blue: 0.09).ignoresSafeArea()
            content
        }
        .preferredColorScheme(.dark)
        .task { verifier.start() }
    }

    @ViewBuilder
    private var content: some View {
        switch verifier.phase {
        case .idle, .checkingLicense:
            StatusView(icon: nil, tint: .white, title: "Checking license…", message: nil, showsSpinner: true)

        case .licenseFailed(let message):
            VStack(spacing: 24) {
                StatusView(icon: "key.slash", tint: .red, title: "License not valid", message: message)
                Button("Retry") { verifier.start() }
                    .buttonStyle(.borderedProminent)
            }

        case .ready:
            ReadyView(verifier: verifier)

        case .scanning:
            ScanView(onCode: { verifier.handleScanned($0) },
                     onCancel: { verifier.cancelScan() })

        case .verifying(let stage):
            StatusView(icon: nil, tint: .white, title: "Verifying ID", message: stage, showsSpinner: true)

        case .finished(let outcome):
            ResultView(outcome: outcome, gateStatus: verifier.gateStatus) { verifier.reset() }

        case .failed(let message):
            VStack(spacing: 24) {
                StatusView(icon: "exclamationmark.triangle.fill", tint: .orange,
                           title: "Verification failed", message: message)
                if !verifier.gateStatus.isEmpty {
                    Text(verifier.gateStatus).font(.footnote).foregroundStyle(.secondary)
                }
                Button("Try again") { verifier.reset() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
        }
    }
}

// MARK: - Ready

struct ReadyView: View {
    @ObservedObject var verifier: VerifierService
    @AppStorage(AppConfig.acceptTestIssuersKey) private var acceptTestIssuers = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 72))
                .foregroundStyle(.blue)
            VStack(spacing: 10) {
                Text("Access Gate")
                    .font(.largeTitle.bold())
                Text("Verify a mobile driver's license to unlock the door.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                verifier.beginScan()
            } label: {
                Label("Scan ID", systemImage: "qrcode.viewfinder")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }
            .buttonStyle(.borderedProminent)

            Toggle(isOn: $acceptTestIssuers) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accept test issuers")
                    Text("Development only")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .tint(.orange)
            .padding(.horizontal, 4)

            Button("Test gate connection") { verifier.testGate() }
                .font(.footnote)

            if !verifier.gateStatus.isEmpty {
                Text(verifier.gateStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(verifier.licenseInfo)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
    }
}

// MARK: - Scanning

struct ScanView: View {
    let onCode: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            QRScannerView(onCode: onCode)
                .ignoresSafeArea()
            VStack {
                Text("Scan the QR code shown in the wallet")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 24)
                Spacer()
                RoundedRectangle(cornerRadius: 28)
                    .stroke(.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 260, height: 260)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .padding(.bottom, 32)
            }
        }
    }
}

// MARK: - Result

struct ResultView: View {
    let outcome: VerificationOutcome
    let gateStatus: String
    let onDone: () -> Void

    private var tint: Color { outcome.passed ? .green : .red }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: outcome.passed ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(tint)
                    .padding(.top, 40)

                Text(outcome.passed ? "Access Granted" : "Access Denied")
                    .font(.largeTitle.bold())

                Text(outcome.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                if let data = outcome.portrait, let image = UIImage(data: data) {
                    VStack(spacing: 6) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 110, height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        Text("Compare with the person at the door")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !outcome.details.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(outcome.details, id: \.label) { row in
                            HStack {
                                Text(row.label).foregroundStyle(.secondary)
                                Spacer()
                                Text(row.value).fontWeight(.semibold)
                            }
                        }
                    }
                    .padding()
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                }

                if !outcome.checks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Security checks")
                            .font(.headline)
                        ForEach(outcome.checks, id: \.label) { row in
                            HStack {
                                Image(systemName: row.value == "Passed" ? "checkmark.circle.fill"
                                                  : row.value == "Failed" ? "xmark.circle.fill"
                                                  : "exclamationmark.circle.fill")
                                    .foregroundStyle(row.value == "Passed" ? .green
                                                     : row.value == "Failed" ? .red : .orange)
                                Text(row.label)
                                Spacer()
                                Text(row.value).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                }

                if !outcome.technical.isEmpty {
                    DisclosureGroup("Technical details") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(outcome.technical, id: \.label) { row in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.label).font(.caption).foregroundStyle(.secondary)
                                    Text(row.value).font(.caption.monospaced()).textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    }
                    .font(.footnote)
                    .padding()
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
                }

                if !gateStatus.isEmpty {
                    Label(gateStatus, systemImage: "antenna.radiowaves.left.and.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button(action: onDone) {
                    Text("Scan next ID")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)

            }
            .padding(24)
        }
    }
}

// MARK: - Shared status view

struct StatusView: View {
    let icon: String?
    let tint: Color
    let title: String
    let message: String?
    var showsSpinner = false

    var body: some View {
        VStack(spacing: 18) {
            if showsSpinner {
                ProgressView().controlSize(.large)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 56))
                    .foregroundStyle(tint)
            }
            Text(title).font(.title2.bold())
            if let message {
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}
