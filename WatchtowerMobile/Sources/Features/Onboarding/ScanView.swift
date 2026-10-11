@preconcurrency import AVFoundation
import os
import SwiftUI
import UIKit

/// "Scan the code on your Mac" (spec §2.3): the camera reads the QR code's
/// `watchtower://link` URL and hands it to the link flow. The system Camera
/// app reaches the same flow through `opensLinkURLs(with:)`.
struct ScanView: View {
    let onCode: (String) -> Void
    let onCancel: () -> Void
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Scan the code on your Mac")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                }
        }
        .task {
            if access == .notDetermined {
                access = await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch access {
        case .authorized:
            if QRScannerView.isAvailable {
                QRScannerView(onCode: onCode)
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottom) {
                        Text("Point the camera at the code on your Mac.")
                            .font(.subheadline)
                            .padding()
                            .background(.regularMaterial, in: Capsule())
                            .padding(.bottom, 32)
                    }
            } else {
                ContentUnavailableView(
                    "No camera",
                    systemImage: "camera",
                    description: Text("Scan the code on your Mac with the Camera app instead.")
                )
            }
        case .notDetermined:
            ProgressView()
        default:
            ContentUnavailableView(
                "Camera access is off",
                systemImage: "camera",
                description: Text("Allow camera access for Watchtower in Settings, or scan the code on your Mac with the Camera app.")
            )
        }
    }
}

extension View {
    /// A `watchtower://link` URL the system opens the app with (the Camera
    /// app scanned the Mac's code): the same flow as an in-app scan.
    func opensLinkURLs(with root: AppRoot) -> some View {
        onOpenURL { url in
            Task { await root.open(url) }
        }
    }
}

/// The camera preview with a QR reader.
struct QRScannerView: UIViewControllerRepresentable {
    static var isAvailable: Bool { AVCaptureDevice.default(for: .video) != nil }

    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {
        controller.onCode = onCode
    }
}

/// An `AVCaptureSession` reading QR codes. It delivers the first
/// `watchtower://` code once, then stops.
final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    private let session = AVCaptureSession()
    /// `startRunning` blocks, so the session runs off the main thread.
    private let sessionQueue = DispatchQueue(label: "WatchtowerMobile.QRScanner")
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "QRScanner")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let camera = AVCaptureDevice.default(for: .video) else { return }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: camera)
        } catch {
            Self.logger.error("camera input failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let output = AVCaptureMetadataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            Self.logger.error("camera session refused its input or output")
            return
        }
        session.addInput(input)
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = session
        sessionQueue.async { session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = session
        sessionQueue.async { session.stopRunning() }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let codes = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        // The delegate queue is `.main`.
        MainActor.assumeIsolated {
            guard !delivered, let code = codes.first(where: { $0.lowercased().hasPrefix("watchtower://") }) else { return }
            delivered = true
            let session = session
            sessionQueue.async { session.stopRunning() }
            onCode?(code)
        }
    }
}
