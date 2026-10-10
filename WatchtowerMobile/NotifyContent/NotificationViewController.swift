import UIKit
import UserNotifications
import UserNotificationsUI

/// Notification Content Extension for the `ASK_QUICK` category (mobile POC
/// spec §7). The quick-answer options come with Task 13; until then it shows
/// the notification's body.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private let bodyLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        bodyLabel.numberOfLines = 0
        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bodyLabel)
        NSLayoutConstraint.activate([
            bodyLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: view.layoutMarginsGuide.topAnchor),
            bodyLabel.bottomAnchor.constraint(equalTo: view.layoutMarginsGuide.bottomAnchor)
        ])
    }

    func didReceive(_ notification: UNNotification) {
        bodyLabel.text = notification.request.content.body
    }
}
