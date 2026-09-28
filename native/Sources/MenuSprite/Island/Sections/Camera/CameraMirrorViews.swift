import AppKit
import AVFoundation
import IslandKit
import SwiftUI

/// The Camera page: a start card until the person opens the camera, then a 4:3 mirrored preview with
/// Stop camera below it. The settings preview shows a still picture and never the camera.
struct CameraMirrorPage: View {
    @ObservedObject var service: CameraMirrorService
    let context: IslandPageContext
    let open: () -> Void
    let stop: () -> Void

    var body: some View {
        Group {
            if context.isPreview {
                live(still: true)
            } else if service.status == .off {
                startCard
            } else {
                live(still: service.preview != nil && service.status == .running)
            }
        }
        .frame(width: context.width, height: context.budget)
    }

    private var startCard: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: "web.camera").font(.system(size: 30, weight: .light)).foregroundStyle(Color.white.opacity(0.85)))
            VStack(alignment: .leading, spacing: 8) {
                Text("Open a live mirror here. The camera stops when you leave this view.")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open camera", action: open)
                    .buttonStyle(CameraProminentButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func live(still: Bool) -> some View {
        let size = CameraMirrorLayout.previewSize(pageWidth: context.width, pageHeight: context.budget)
        return VStack(spacing: CameraMirrorLayout.controlsGap) {
            ZStack(alignment: .bottom) {
                Color.black
                if still {
                    CameraStill()
                } else {
                    content
                }
                if service.cameras.count > 1, service.status == .running || service.status == .starting {
                    cameraMenu.padding(.bottom, 10)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            Button("Stop camera", action: stop)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(context.isPreview)
                .frame(height: CameraMirrorLayout.controlsHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var content: some View {
        switch service.status {
        case .running:
            if let session = service.session { CameraPreviewLayerView(session: session) }
        case .denied:
            message("video.slash", "Camera access for MenuSprite is turned off in System Settings.",
                    button: "Open System Settings") { service.openPrivacySettings() }
        case .unavailable:
            message("video.slash", "The camera could not start. Try opening it again.", button: "Open camera", action: open)
        case .noCamera:
            message("web.camera", "No camera detected", button: nil, action: {})
        case .off, .waitingForPermission, .starting:
            ProgressView().controlSize(.small).tint(.white)
        }
    }

    private func message(_ symbol: String, _ text: String, button: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(Color.white.opacity(0.7))
            Text(text).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.85)).multilineTextAlignment(.center)
            if let button { Button(button, action: action).controlSize(.small) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cameraMenu: some View {
        Menu {
            ForEach(service.cameras) { camera in
                Button {
                    service.pick(camera.id)
                } label: {
                    if camera.id == service.currentID { Label(camera.name, systemImage: "checkmark") } else { Text(camera.name) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "web.camera")
                Text(service.currentName ?? "Camera").lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.55)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Camera")
    }
}

/// The accent-filled call to action. The system's prominent style greys out in a window that is not
/// key, which the island usually is not.
private struct CameraProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1)))
            .contentShape(Capsule())
    }
}

/// A calm stand-in for the camera, for the settings preview and renders.
private struct CameraStill: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
            Image(systemName: "person.fill")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.22))
                .offset(y: 14)
        }
    }
}

/// The capture preview, always mirrored like Photo Booth, filling its frame.
struct CameraPreviewLayerView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewNSView { CameraPreviewNSView() }

    func updateNSView(_ view: CameraPreviewNSView, context: Context) { view.attach(session) }

    static func dismantleNSView(_ view: CameraPreviewNSView, coordinator: ()) { view.detach() }
}

final class CameraPreviewNSView: NSView {
    private let preview = AVCaptureVideoPreviewLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        preview.frame = bounds
        mirror()
    }

    func attach(_ session: AVCaptureSession) {
        if preview.session !== session { preview.session = session }
        mirror()
    }

    func detach() { preview.session = nil }

    /// The connection exists only once the session has an input, so this is applied on every update.
    private func mirror() {
        guard let connection = preview.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }
}

/// Settings › Content › Camera mirror: what it does, and camera access.
struct CameraMirrorOptions: View {
    @ObservedObject var service: CameraMirrorService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open the Camera page and press Open camera for a mirrored view of yourself. The camera runs only while that page is on screen; nothing is recorded or saved.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch service.access {
            case .authorized:
                Label {
                    Text("Granted")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            case .notDetermined:
                HStack(spacing: 8) {
                    Button("Request") { service.requestAccessFromSettings() }
                    Button("Open Settings") { service.openPrivacySettings() }
                }
            case .denied:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Camera access for MenuSprite is turned off in System Settings.").font(.callout)
                    Button("Open Settings") { service.openPrivacySettings() }
                }
            }
        }
        .onAppear { service.refreshAccess() }
    }
}
