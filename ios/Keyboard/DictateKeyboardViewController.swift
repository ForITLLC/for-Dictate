import ForITCommon
import UIKit

/// A microphone key and the four keys dictation needs beside it. The keyboard
/// has no microphone of its own: it asks the app, shows where the dictation
/// stands, and types the text the app hands back. It reads nothing the person types.
final class DictateKeyboardViewController: UIInputViewController {
    private enum Mode: Equatable {
        case idle
        case starting
        case recording
        case transcribing
    }

    private static let pendingIDKey = "keyboard.pending-request.id"
    private static let pendingDateKey = "keyboard.pending-request.date"
    /// After Stop, an app that still says "recording" this much later is no longer running.
    private static let stopGrace: TimeInterval = 4
    /// Longest wait for the text once the app says it is transcribing.
    private static let transcriptionLimit: TimeInterval = 180

    private static let fullAccessMessage =
        "Turn on Allow Full Access for ForIT Dictate in Settings, under General, Keyboard, Keyboards."

    #if DEBUG
    /// A state to draw with no dictation behind it, for the pictures the device matrix takes of
    /// this view inside the app (ios/App/KeyboardPreviewScene.swift). The keyboard never sets it.
    enum Preview {
        case idle
        case listening
        case fullAccessNeeded
    }

    var preview: Preview?
    #endif

    private var mode = Mode.idle
    private var message: String?
    private var stopRequestedAt: Date?
    private var signals: DarwinSignalObserver?
    private var poll: Timer?
    private var fallback: Task<Void, Never>?

    private let status = UILabel()
    private let microphone = UIButton(type: .system)
    private let cancel = UIButton(type: .system)
    private let globe = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)

    private static let tint = UIColor { traits in
        let token = ForITBrand.tint(dark: traits.userInterfaceStyle == .dark)
        return UIColor(red: token.red, green: token.green, blue: token.blue, alpha: 1)
    }
    private static let onTint = UIColor { traits in
        let token = ForITBrand.onTint(dark: traits.userInterfaceStyle == .dark)
        return UIColor(red: token.red, green: token.green, blue: token.blue, alpha: 1)
    }

    // MARK: The request this keyboard is waiting on

    /// Kept in the keyboard's own defaults: iOS may discard the keyboard while the app is in front.
    private var pending: (id: UUID, since: Date)? {
        get {
            let defaults = UserDefaults.standard
            guard let raw = defaults.string(forKey: Self.pendingIDKey), let id = UUID(uuidString: raw),
                  let since = defaults.object(forKey: Self.pendingDateKey) as? Date
            else { return nil }
            return (id, since)
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue?.id.uuidString, forKey: Self.pendingIDKey)
            defaults.set(newValue?.since, forKey: Self.pendingDateKey)
        }
    }

    // MARK: View

    override func viewDidLoad() {
        super.viewDidLoad()
        view.tintColor = Self.tint
        buildLayout()
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        #if DEBUG
        if let preview {
            // A picture: it listens for nothing, asks the app for nothing and takes no taps.
            view.isUserInteractionEnabled = false
            switch preview {
            case .idle: show(.idle)
            case .listening: show(.recording)
            case .fullAccessNeeded: show(.idle, message: Self.fullAccessMessage)
            }
            return
        }
        #endif
        globe.isHidden = !needsInputModeSwitchKey
        // Dictated text nobody took in time does not wait on disk for the app's next launch.
        DictationHandoffStore.shared()?.removeStaleResult()
        refresh()
        // Only the keyboard on screen listens, so one that is gone cannot take the text.
        signals = DarwinSignalObserver([.changed]) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // The signal is the fast path; this covers one missed while the keyboard was away.
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.pending != nil else { return }
                self.refresh()
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        signals = nil
        poll?.invalidate()
        poll = nil
        fallback?.cancel()
    }

    private func buildLayout() {
        status.font = .preferredFont(forTextStyle: .footnote)
        status.adjustsFontForContentSizeCategory = true
        status.textColor = .secondaryLabel
        status.textAlignment = .center
        // Every line shows at every text size: the keyboard grows (the height below gives way)
        // before the Full Access instruction is cut short.
        status.numberOfLines = 0
        status.setContentCompressionResistancePriority(UILayoutPriority(999), for: .vertical)
        status.accessibilityIdentifier = "dictate.keyboard.status"

        microphone.layer.cornerRadius = 36
        microphone.accessibilityIdentifier = "dictate.keyboard.microphone"
        microphone.addTarget(self, action: #selector(microphoneTapped), for: .touchUpInside)
        microphone.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        microphone.addSubview(spinner)

        cancel.setTitle("Cancel", for: .normal)
        scaleTitle(of: cancel)
        cancel.accessibilityIdentifier = "dictate.keyboard.cancel"
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let microphoneRow = UIView()
        microphoneRow.addSubview(microphone)

        globe.setImage(UIImage(systemName: "globe"), for: .normal)
        globe.accessibilityLabel = "Next keyboard"
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        let space = key(title: "space", label: "Space", action: #selector(spaceTapped))
        let delete = key(symbol: "delete.left", label: "Delete", action: #selector(deleteTapped))
        let enter = key(symbol: "return", label: "Return", action: #selector(returnTapped))
        style(globe)

        let keys = UIStackView(arrangedSubviews: [globe, space, delete, enter])
        keys.axis = .horizontal
        keys.spacing = 6
        for narrow in [globe, delete, enter] {
            narrow.widthAnchor.constraint(equalToConstant: 56).isActive = true
        }

        let root = UIStackView(arrangedSubviews: [status, microphoneRow, cancel, keys])
        root.axis = .vertical
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        // 250 points, and more when the text size needs it: the status line outranks this.
        let height = view.heightAnchor.constraint(equalToConstant: 250)
        height.priority = UILayoutPriority(998)
        NSLayoutConstraint.activate([
            height,
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            root.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 6),
            root.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -6),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            microphone.centerXAnchor.constraint(equalTo: microphoneRow.centerXAnchor),
            microphone.topAnchor.constraint(equalTo: microphoneRow.topAnchor),
            microphone.bottomAnchor.constraint(equalTo: microphoneRow.bottomAnchor),
            microphone.widthAnchor.constraint(equalToConstant: 72),
            microphone.heightAnchor.constraint(equalToConstant: 72),
            spinner.centerXAnchor.constraint(equalTo: microphone.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: microphone.centerYAnchor),
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: ForITBrand.minimumTarget),
        ])
    }

    private func key(title: String? = nil, symbol: String? = nil, label: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        if let title {
            button.setTitle(title, for: .normal)
            scaleTitle(of: button)
        }
        if let symbol { button.setImage(UIImage(systemName: symbol), for: .normal) }
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
        style(button)
        return button
    }

    /// A key's word follows the person's text size, as its symbol-only neighbours already do.
    private func scaleTitle(of button: UIButton) {
        button.titleLabel?.font = .preferredFont(forTextStyle: .callout)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
    }

    private func style(_ button: UIButton) {
        button.backgroundColor = .tertiarySystemFill
        button.tintColor = .label
        button.setTitleColor(.label, for: .normal)
        button.layer.cornerRadius = 8
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: ForITBrand.minimumTarget).isActive = true
    }

    private func render() {
        let symbol: String?
        let text: String
        switch mode {
        case .idle:
            symbol = "mic.fill"
            text = "Tap to dictate"
            microphone.backgroundColor = Self.tint
            microphone.accessibilityLabel = "Dictate"
        case .starting:
            symbol = nil
            text = "Starting"
            microphone.backgroundColor = .systemGray3
            microphone.accessibilityLabel = "Starting"
        case .recording:
            symbol = "stop.fill"
            text = "Listening. Tap to finish."
            microphone.backgroundColor = .systemRed
            microphone.accessibilityLabel = "Finish dictating"
        case .transcribing:
            symbol = nil
            text = "Writing it out"
            microphone.backgroundColor = .systemGray3
            microphone.accessibilityLabel = "Writing it out"
        }
        let configuration = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        microphone.setImage(symbol.flatMap { UIImage(systemName: $0, withConfiguration: configuration) }, for: .normal)
        microphone.tintColor = mode == .recording ? .white : Self.onTint
        if symbol == nil { spinner.startAnimating() } else { spinner.stopAnimating() }
        microphone.isEnabled = mode == .idle || mode == .recording
        cancel.isHidden = mode != .recording
        status.text = mode == .idle ? (message ?? text) : text
    }

    private func show(_ mode: Mode, message: String? = nil) {
        self.mode = mode
        self.message = message
        render()
    }

    // MARK: Dictation

    @objc private func microphoneTapped() {
        guard hasFullAccess, let store = DictationHandoffStore.shared() else {
            show(.idle, message: Self.fullAccessMessage)
            return
        }
        switch mode {
        case .idle:
            start(with: store)
        case .recording:
            stopRequestedAt = Date()
            DarwinSignal.post(.stop)
            show(.transcribing)
        case .starting, .transcribing:
            break
        }
    }

    @objc private func cancelTapped() {
        DarwinSignal.post(.cancel)
        pending = nil
        stopRequestedAt = nil
        show(.idle)
    }

    private func start(with store: DictationHandoffStore) {
        let id = UUID()
        do {
            try store.write(DictationRequest(id: id, createdAt: Date()))
        } catch {
            show(.idle, message: "Dictation could not start. Open ForIT Dictate once, then try again.")
            return
        }
        pending = (id, Date())
        stopRequestedAt = nil
        show(.starting)

        guard store.state()?.acceptsRequests(at: Date()) == true else {
            openApp(for: id)
            return
        }
        // The app says its microphone is on. Ask it directly, and open it if it does not answer.
        DarwinSignal.post(.start)
        fallback?.cancel()
        fallback = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self, self.mode == .starting, self.pending?.id == id else { return }
            self.openApp(for: id)
        }
    }

    private func openApp(for id: UUID) {
        guard open(DictationHandoff.openURL(for: id)) else {
            pending = nil
            show(.idle, message: "ForIT Dictate could not be opened. Open it from the Home Screen, then try again.")
            return
        }
    }

    /// Reads where the dictation stands and types the text when it is there.
    private func refresh() {
        guard let pending else {
            if mode != .idle { show(.idle, message: message) }
            return
        }
        guard let store = DictationHandoffStore.shared() else { return }
        let now = Date()

        if let result = store.takeResult(for: pending.id, now: now) {
            finish()
            if let failure = result.failure {
                show(.idle, message: failure)
            } else {
                insert(result.text)
                show(.idle)
            }
            return
        }

        let state = store.state()
        if let state, state.requestID == pending.id {
            switch state.phase {
            case .recording:
                if let stopRequestedAt, now.timeIntervalSince(stopRequestedAt) > Self.stopGrace {
                    abandon("ForIT Dictate stopped listening. Tap to start again.")
                } else if stopRequestedAt == nil, mode != .recording {
                    fallback?.cancel()
                    show(.recording)
                }
            case .transcribing:
                if now.timeIntervalSince(state.updatedAt) > Self.transcriptionLimit {
                    abandon("Dictation did not finish. Tap to try again.")
                } else if mode != .transcribing {
                    show(.transcribing)
                }
            case .idle, .ready:
                break
            }
            return
        }

        // The app never picked this request up, or moved on without a result for it.
        if now.timeIntervalSince(pending.since) > DictationHandoff.requestLifetime, mode != .recording {
            abandon("Dictation did not start. Tap to try again.")
        }
    }

    private func finish() {
        pending = nil
        stopRequestedAt = nil
        fallback?.cancel()
    }

    private func abandon(_ message: String) {
        finish()
        DictationHandoffStore.shared()?.clearRequest()
        show(.idle, message: message)
    }

    private func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let proxy = textDocumentProxy
        proxy.insertText(InsertionSpacing.separator(after: proxy.documentContextBeforeInput, before: text) + text)
    }

    // MARK: Keys

    @objc private func spaceTapped() { textDocumentProxy.insertText(" ") }
    @objc private func deleteTapped() { textDocumentProxy.deleteBackward() }
    @objc private func returnTapped() { textDocumentProxy.insertText("\n") }

    // MARK: Opening the app

    /// A keyboard has no `UIApplication.shared`; the application is reached through the responder chain.
    /// iOS 26 honours this only with Full Access on, which the microphone key already requires.
    private func open(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return true
            }
            responder = current.next
        }
        return false
    }
}
