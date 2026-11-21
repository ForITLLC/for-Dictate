import Foundation

/// Darwin notifications: the one signal that crosses from a keyboard extension to
/// its app and back. They carry a name and nothing else.
enum DarwinSignal {
    static func post(_ signal: DictationHandoff.Signal) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(signal.rawValue as CFString),
            nil, nil, true)
    }
}

/// Calls `handler` on the main queue for each named signal until it is released.
final class DarwinSignalObserver {
    private let handler: (DictationHandoff.Signal) -> Void

    init(_ signals: [DictationHandoff.Signal], handler: @escaping (DictationHandoff.Signal) -> Void) {
        self.handler = handler
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        for signal in signals {
            CFNotificationCenterAddObserver(
                center, observer,
                { _, observer, name, _, _ in
                    guard let observer, let name,
                          let signal = DictationHandoff.Signal(rawValue: name.rawValue as String)
                    else { return }
                    let target = Unmanaged<DarwinSignalObserver>.fromOpaque(observer).takeUnretainedValue()
                    let handler = target.handler
                    DispatchQueue.main.async { handler(signal) }
                },
                signal.rawValue as CFString, nil, .deliverImmediately)
        }
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque())
    }
}
