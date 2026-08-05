import SwiftUI
import UserNotifications

@main
struct CloudexNativeApp: App {
    @UIApplicationDelegateAdaptor(CloudexAppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AppViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            CloudexRootView()
                .environmentObject(viewModel)
                .onAppear {
                    CloudexAppDelegate.notifications.attach(viewModel: viewModel)
                    CloudexAppDelegate.notifications.setAppIsInForeground(scenePhase == .active)
                }
                .onChange(of: scenePhase) { _, phase in
                    CloudexAppDelegate.notifications.setAppIsInForeground(phase == .active)
                    if phase == .active {
                        Task { await viewModel.resumeFromForeground() }
                    } else {
                        for approval in viewModel.pendingApprovals {
                            CloudexAppDelegate.notifications.scheduleApproval(approval)
                        }
                    }
                }
        }
    }
}

final class CloudexAppDelegate: NSObject, UIApplicationDelegate {
    static let notifications = CloudexNotificationManager()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Self.notifications.configure()
        return true
    }
}

final class CloudexNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let approvalCategory = "CLOUDEX_APPROVAL"
    static let allowAction = "CLOUDEX_APPROVAL_ALLOW"
    static let sessionAction = "CLOUDEX_APPROVAL_SESSION"
    static let denyAction = "CLOUDEX_APPROVAL_DENY"

    private weak var viewModel: AppViewModel?
    private var appIsInForeground = true

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.approvalCategory,
                actions: [
                    UNNotificationAction(identifier: Self.allowAction, title: "允许", options: []),
                    UNNotificationAction(identifier: Self.sessionAction, title: "始终允许", options: []),
                    UNNotificationAction(identifier: Self.denyAction, title: "禁止", options: [.destructive])
                ],
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func attach(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    func setAppIsInForeground(_ value: Bool) {
        appIsInForeground = value
    }

    func scheduleApproval(_ approval: ApprovalRequest) {
        guard UserDefaults.standard.object(forKey: "cloudex.notifyApprovals") as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = "Cloudex 需要你的确认"
        content.body = approval.notificationSummary
        content.sound = .default
        content.categoryIdentifier = Self.approvalCategory
        content.userInfo = ["approvalID": approval.id]
        let request = UNNotificationRequest(
            identifier: "approval-\(approval.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func removeApproval(_ approvalID: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["approval-\(approvalID)"])
        center.removeDeliveredNotifications(withIdentifiers: ["approval-\(approvalID)"])
    }

    func scheduleTaskResult(threadID: String, title: String, success: Bool, detail: String? = nil) {
        let enabled = UserDefaults.standard.object(
            forKey: success ? "cloudex.notifyTaskSuccess" : "cloudex.notifyTaskFailure"
        ) as? Bool ?? true
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = success ? "任务已完成" : "任务失败"
        content.body = detail?.isEmpty == false ? "\(title)\n\(detail!)" : title
        content.sound = .default
        content.userInfo = ["threadID": threadID]
        let request = UNNotificationRequest(
            identifier: "task-result-\(threadID)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard response.notification.request.content.categoryIdentifier == Self.approvalCategory,
              let approvalID = response.notification.request.content.userInfo["approvalID"] as? String else {
            completionHandler()
            return
        }
        let decision: ApprovalDecision?
        switch response.actionIdentifier {
        case Self.allowAction: decision = .accept
        case Self.sessionAction: decision = .acceptForSession
        case Self.denyAction: decision = .decline
        default: decision = nil
        }
        guard let decision else {
            completionHandler()
            return
        }
        Task { @MainActor [weak self] in
            await self?.viewModel?.respondToApproval(id: approvalID, decision: decision)
            self?.removeApproval(approvalID)
            completionHandler()
        }
    }
}

private extension ApprovalRequest {
    var notificationSummary: String {
        if let command, !command.isEmpty { return "命令：\(command)" }
        if let permissionSummary, !permissionSummary.isEmpty { return "权限：\(permissionSummary)" }
        if let context = networkApprovalContext, let host = context.host, !host.isEmpty {
            return "网络：\(context.protocolName.map { "\($0)://" } ?? "")\(host)\(context.port.map { ":\($0)" } ?? "")"
        }
        if let reason, !reason.isEmpty { return reason }
        return "有一项操作等待确认"
    }
}
