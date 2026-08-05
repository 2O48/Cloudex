import AVFoundation
import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var isPresented: Bool
    @State private var lanServerURL: String
    @State private var tailscaleServerURL: String
    @State private var connectionMode: ConnectionMode
    @State private var token: String
    @State private var notifyApprovals: Bool
    @State private var notifyTaskSuccess: Bool
    @State private var notifyTaskFailure: Bool

    init(isPresented: Binding<Bool>, viewModel: AppViewModel? = nil) {
        _isPresented = isPresented
        let model = viewModel
        _lanServerURL = State(initialValue: model?.lanServerURL ?? "")
        _tailscaleServerURL = State(initialValue: model?.tailscaleServerURL ?? "")
        _connectionMode = State(initialValue: model?.connectionMode ?? .automatic)
        _token = State(initialValue: model?.authToken ?? "")
        _notifyApprovals = State(initialValue: model?.notifyApprovals ?? true)
        _notifyTaskSuccess = State(initialValue: model?.notifyTaskSuccess ?? true)
        _notifyTaskFailure = State(initialValue: model?.notifyTaskFailure ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("连接") {
                    Picker("连接方式", selection: $connectionMode) {
                        ForEach(ConnectionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("局域网地址", text: $lanServerURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    TextField("Tailscale 地址", text: $tailscaleServerURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    SecureField("AUTH_TOKEN", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text(viewModel.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("最近连接") {
                    if viewModel.connectionHistory.isEmpty {
                        Text("保存设置后会在这里显示连接记录")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.connectionHistory) { item in
                            Button {
                                Task {
                                    await viewModel.switchToConnection(item)
                                    lanServerURL = viewModel.lanServerURL
                                    tailscaleServerURL = viewModel.tailscaleServerURL
                                    connectionMode = viewModel.connectionMode
                                    token = viewModel.authToken
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.serverURL)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text("Token \(item.maskedToken) · \(item.connectionMode.title)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if viewModel.serverURL == item.serverURL && viewModel.authToken == item.token {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            viewModel.removeConnectionHistory(at: offsets)
                        }
                    }
                }

                Section("Tailscale") {
                    Text("电脑和 iPhone 需登录同一 Tailnet，并在手机上开启 Tailscale VPN。自动模式会先尝试局域网，失败后切换到 Tailscale。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("当前连接", value: viewModel.activeConnectionTitle)
                }

                Section("通知") {
                    Toggle("需要确认", isOn: $notifyApprovals)
                    Toggle("任务成功", isOn: $notifyTaskSuccess)
                    Toggle("任务失败", isOn: $notifyTaskFailure)
                    Text("关闭后不会显示对应的系统通知；应用内过程和审批卡片仍然保留。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        Task {
                            await viewModel.reconnect()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("重新连接")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            await viewModel.applySettings(
                                lanServerURL: lanServerURL,
                                tailscaleServerURL: tailscaleServerURL,
                                connectionMode: connectionMode,
                                token: token
                            )
                            viewModel.updateNotificationSettings(
                                approvals: notifyApprovals,
                                taskSuccess: notifyTaskSuccess,
                                taskFailure: notifyTaskFailure
                            )
                            isPresented = false
                        }
                    }
                    .disabled(
                        connectionMode == .lan && lanServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || connectionMode == .tailscale && tailscaleServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || connectionMode == .automatic
                            && lanServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && tailscaleServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .onAppear {
                lanServerURL = viewModel.lanServerURL
                tailscaleServerURL = viewModel.tailscaleServerURL
                connectionMode = viewModel.connectionMode
                token = viewModel.authToken
                notifyApprovals = viewModel.notifyApprovals
                notifyTaskSuccess = viewModel.notifyTaskSuccess
                notifyTaskFailure = viewModel.notifyTaskFailure
            }
        }
    }
}

struct CloudexConnectionPayload {
    let serverURL: String
    let token: String

    init?(code: String) {
        guard let components = URLComponents(string: code),
              components.scheme?.lowercased() == "cloudex",
              components.host?.lowercased() == "connect",
              let serverURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let parsedServerURL = URL(string: serverURL),
              ["http", "https"].contains(parsedServerURL.scheme?.lowercased() ?? ""),
              parsedServerURL.host != nil else { return nil }

        self.serverURL = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        token = components.queryItems?.first(where: { $0.name == "token" })?.value ?? ""
    }

    var preferredConnectionMode: ConnectionMode {
        guard let host = URL(string: serverURL)?.host?.lowercased() else { return .lan }
        if host.hasSuffix(".ts.net") { return .tailscale }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts[0] == 100, (64...127).contains(parts[1]) { return .tailscale }
        return .lan
    }
}

struct QRCodeScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        let controller = QRCodeScannerViewController()
        controller.onScan = onScan
        controller.onFailure = onFailure
        return controller
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: QRCodeScannerViewController, coordinator: ()) {
        uiViewController.stopScanning()
    }
}

final class QRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false
    private var didFinish = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestAccessAndStart()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        updateVideoOrientation()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.updateVideoOrientation()
        }
    }

    func stopScanning() {
        if captureSession.isRunning { captureSession.stopRunning() }
    }

    private func requestAccessAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureAndStart()
                    } else {
                        self?.fail("请在系统设置中允许 Cloudex 使用相机。")
                    }
                }
            }
        case .denied, .restricted:
            fail("请在系统设置中允许 Cloudex 使用相机。")
        @unknown default:
            fail("当前设备无法使用相机扫描二维码。")
        }
    }

    private func configureAndStart() {
        if !isConfigured {
            guard let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  captureSession.canAddInput(input) else {
                fail("当前设备没有可用的相机。")
                return
            }
            captureSession.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard captureSession.canAddOutput(output) else {
                fail("无法启动二维码扫描。")
                return
            }
            captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: captureSession)
            layer.videoGravity = .resizeAspectFill
            view.layer.insertSublayer(layer, at: 0)
            previewLayer = layer
            isConfigured = true
            view.setNeedsLayout()
        }

        updateVideoOrientation()
        if !captureSession.isRunning { captureSession.startRunning() }
    }

    private func updateVideoOrientation() {
        guard let interfaceOrientation = view.window?.windowScene?.interfaceOrientation else { return }
        let videoOrientation: AVCaptureVideoOrientation
        switch interfaceOrientation {
        case .portrait:
            videoOrientation = .portrait
        case .portraitUpsideDown:
            videoOrientation = .portraitUpsideDown
        case .landscapeLeft:
            videoOrientation = .landscapeLeft
        case .landscapeRight:
            videoOrientation = .landscapeRight
        default:
            return
        }

        if let connection = previewLayer?.connection,
           connection.isVideoOrientationSupported {
            connection.videoOrientation = videoOrientation
        }
        for connection in captureSession.connections where connection.isVideoOrientationSupported {
            connection.videoOrientation = videoOrientation
        }
    }

    private func fail(_ message: String) {
        guard !didFinish else { return }
        didFinish = true
        onFailure?(message)
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didFinish,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        didFinish = true
        stopScanning()
        onScan?(value)
    }
}
