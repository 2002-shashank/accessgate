// QRScannerView.swift
// Camera-based QR scanner (AVFoundation) that reports the first ISO 18013-5
// engagement QR code it sees. Engagement codes start with "mdoc:".

import SwiftUI
import AVFoundation
import UIKit

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, nonisolated AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasReported = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor [weak self] in
                if granted {
                    self?.configureSession()
                } else {
                    self?.showMessage("Camera access is needed to scan the ID QR code. Enable it in Settings.")
                }
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showMessage("Camera is not available on this device.")
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showMessage("Could not start the QR scanner.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        nonisolated(unsafe) let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()
        }
    }

    private func stopSession() {
        nonisolated(unsafe) let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            if captureSession.isRunning { captureSession.stopRunning() }
        }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        guard let code = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = code.stringValue else { return }
        // The delegate queue is .main, so this runs on the main thread.
        MainActor.assumeIsolated {
            self.handle(value)
        }
    }

    private func handle(_ value: String) {
        guard !hasReported else { return }
        // Ignore QR codes that are not mobile ID engagement codes.
        guard value.lowercased().hasPrefix("mdoc:") else { return }
        hasReported = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        stopSession()
        onCode?(value)
    }

    private func showMessage(_ text: String) {
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)
        ])
    }
}
