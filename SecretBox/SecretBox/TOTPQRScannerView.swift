#if canImport(UIKit)
import AVFoundation
import SwiftUI

/// Camera scanner for `otpauth://` Key URIs (iOS only — macOS keeps manual
/// entry, matching Bitwarden's desktop client). Simulator builds have no
/// camera, so authorization failure surfaces a hint instead of a dead sheet;
/// manual paste remains available next to the scan button.
struct TOTPQRScannerView: View {
    var onScanned: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var cameraUnavailable = false

    var body: some View {
        NavigationStack {
            ZStack {
                if cameraUnavailable {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.on.rectangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("相机不可用\n请改用上方输入框手动粘贴 otpauth:// 链接")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    TOTPQRCameraPreview(onScanned: {
                        onScanned($0)
                        dismiss()
                    }, unavailable: $cameraUnavailable)
                        .ignoresSafeArea()
                    reticle
                }
            }
            .background(AppTheme.pageBackground(colorScheme))
            .navigationTitle("扫描验证码二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private var reticle: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(Color.white.opacity(0.9), lineWidth: 3)
            .frame(width: 240, height: 240)
            .shadow(radius: 8)
    }
}

/// Raw AVCaptureSession preview layer wrapped for SwiftUI.
private struct TOTPQRCameraPreview: UIViewRepresentable {
    var onScanned: (String) -> Void
    @Binding var unavailable: Bool

    final class PreviewView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            DispatchQueue.main.async { unavailable = true }
            return view
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            DispatchQueue.main.async { unavailable = true }
            return view
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        view.previewLayer = layer
        context.coordinator.session = session
        session.startRunning()
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer?.frame = uiView.bounds
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.session.stopRunning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let parent: TOTPQRCameraPreview
        var session: AVCaptureSession!
        private var didCapture = false

        init(parent: TOTPQRCameraPreview) {
            self.parent = parent
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !didCapture,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  object.type == .qr,
                  let value = object.stringValue else { return }
            didCapture = true
            session.stopRunning()
            parent.onScanned(value)
        }
    }
}
#endif
