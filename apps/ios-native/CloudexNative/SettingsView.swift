import SwiftUI

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
                                        Text("Token (item.maskedToken) · \(item.connectionMode.title)")
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

                Section("状态") {
                    Text(viewModel.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPresented = false }
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
