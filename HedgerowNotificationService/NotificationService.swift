import Foundation
import HedgerowCore
import UserNotifications

/// Notification Service Extension: swaps the relay's generic "Something needs your attention" for
/// the real text, which it fetches from the user's own server with the token in the shared Keychain.
///
/// All the logic is `NotificationRewriter` in HedgerowCore (tested there). This class only hands it
/// the payload and puts the answer into the notification. It keeps the generic text whenever
/// anything goes wrong, and it answers before the system's time limit in every case: the fetch has
/// its own limit of 10 seconds, and `serviceExtensionTimeWillExpire` delivers what there is.
final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var delivery: Delivery?

    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        // Read here, so the task below holds only values that are safe to pass on.
        let payload = PushPayload.parse(request.content.userInfo)
        let rewriter = NotificationRewriter(
            registry: PushRegistry(fileURL: AppStorageLocation.pushRegistryFile),
            connections: { readConnections(at: AppStorageLocation.connectionsFile) },
            vault: AppStorageLocation.makeVault()
        )
        // What goes out if the text cannot be fetched in time: the generic text, grouped by connection.
        let delivery = Delivery(content: content, handler: contentHandler, fallback: rewriter.grouping(for: payload))
        lock.withLock { self.delivery = delivery }

        Task {
            let rewrite = await rewriter.rewrite(payload)
            delivery.finish(with: rewrite)
        }
    }

    /// The system is about to end the extension: the notification goes out with the generic text, but
    /// still grouped by connection.
    override func serviceExtensionTimeWillExpire() {
        let pending = lock.withLock { delivery }
        pending?.expire()
    }
}

/// The content and the system's completion handler, used once. Whichever of the fetch and the
/// time limit comes first delivers; the other finds it done.
private final class Delivery: @unchecked Sendable {
    private let lock = NSLock()
    private var content: UNMutableNotificationContent?
    private var handler: ((UNNotificationContent) -> Void)?
    private let fallback: NotificationRewrite

    init(
        content: UNMutableNotificationContent, handler: @escaping (UNNotificationContent) -> Void,
        fallback: NotificationRewrite
    ) {
        self.content = content
        self.handler = handler
        self.fallback = fallback
    }

    func expire() {
        finish(with: fallback)
    }

    func finish(with rewrite: NotificationRewrite) {
        lock.lock()
        let content = self.content
        let handler = self.handler
        self.content = nil
        self.handler = nil
        lock.unlock()
        guard let content, let handler else { return }
        // Plain text only: the title and body are set as strings, never parsed.
        if let title = rewrite.title { content.title = title }
        if let body = rewrite.body { content.body = body }
        if let thread = rewrite.threadIdentifier { content.threadIdentifier = thread }
        handler(content)
    }
}
