import UIKit
import ObjectiveC

final class KeyboardViewController: UIInputViewController {
    private let store = AppGroupTranscriptStore()
    private var latestTranscriptID: UUID?
    private var pollingTimer: Timer?
    private var manualStatusExpiresAt: Date?
    private var latestRecordingPhase: SharedRecordingPhase = .idle
    private let previewLabel = UILabel()
    private let statusLabel = UILabel()
    private let recordButton = UIButton(type: .system)
    private let insertButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureKeyboard()
        refreshLatestTranscript()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startPolling()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func configureKeyboard() {
        let rootStack = UIStackView()
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.distribution = .fill
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 268)
        ])

        rootStack.addArrangedSubview(makeActionRow())

        previewLabel.numberOfLines = 2
        previewLabel.font = .preferredFont(forTextStyle: .footnote)
        previewLabel.textColor = .secondaryLabel
        previewLabel.text = "Record in the app, then insert here."
        rootStack.addArrangedSubview(previewLabel)

        statusLabel.numberOfLines = 2
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .tertiaryLabel
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.82
        rootStack.addArrangedSubview(statusLabel)

        for row in ["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"] {
            rootStack.addArrangedSubview(makeKeyRow(row.map(String.init)))
        }

        rootStack.addArrangedSubview(makeBottomRow())
    }

    private func makeActionRow() -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = 8

        recordButton.configuration = buttonConfiguration(
            title: "Record",
            imageName: "mic.fill",
            style: .prominent
        )
        recordButton.titleLabel?.adjustsFontSizeToFitWidth = true
        recordButton.titleLabel?.minimumScaleFactor = 0.75
        recordButton.addTarget(self, action: #selector(openRecorder), for: .touchUpInside)

        insertButton.configuration = buttonConfiguration(
            title: "Insert",
            imageName: "text.insert",
            style: .plain
        )
        insertButton.addTarget(self, action: #selector(insertLatestTranscript), for: .touchUpInside)

        stack.addArrangedSubview(recordButton)
        stack.addArrangedSubview(insertButton)
        return stack
    }

    private func makeBottomRow() -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = 8

        let globe = makeButton(title: "Next", imageName: "globe", style: .plain)
        globe.addTarget(self, action: #selector(advanceToNextInputMode), for: .touchUpInside)

        let space = makeButton(title: "Space", imageName: nil, style: .plain)
        space.addTarget(self, action: #selector(insertSpace), for: .touchUpInside)

        let delete = makeButton(title: "Delete", imageName: "delete.left", style: .plain)
        delete.addTarget(self, action: #selector(deleteBackward), for: .touchUpInside)

        let returnButton = makeButton(title: "Return", imageName: "return", style: .plain)
        returnButton.addTarget(self, action: #selector(insertReturn), for: .touchUpInside)

        stack.addArrangedSubview(globe)
        stack.addArrangedSubview(space)
        stack.addArrangedSubview(delete)
        stack.addArrangedSubview(returnButton)
        space.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.38).isActive = true
        return stack
    }

    private func makeKeyRow(_ keys: [String]) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.spacing = 5

        for key in keys {
            let button = makeButton(title: key, imageName: nil, style: .plain)
            button.addTarget(self, action: #selector(insertKey(_:)), for: .touchUpInside)
            stack.addArrangedSubview(button)
        }

        return stack
    }

    private func makeButton(
        title: String,
        imageName: String?,
        style: ButtonStyle
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = buttonConfiguration(title: title, imageName: imageName, style: style)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.75
        return button
    }

    private func buttonConfiguration(
        title: String,
        imageName: String?,
        style: ButtonStyle
    ) -> UIButton.Configuration {
        var configuration: UIButton.Configuration
        switch style {
        case .plain:
            configuration = .filled()
            configuration.baseBackgroundColor = .secondarySystemBackground
            configuration.baseForegroundColor = .label
        case .prominent:
            configuration = .filled()
            configuration.baseBackgroundColor = .systemBlue
            configuration.baseForegroundColor = .white
        case .danger:
            configuration = .filled()
            configuration.baseBackgroundColor = .systemRed
            configuration.baseForegroundColor = .white
        }

        configuration.title = title
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10)

        if let imageName {
            configuration.image = UIImage(systemName: imageName)
            configuration.imagePadding = 5
        }

        return configuration
    }

    private func startPolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.refreshLatestTranscript()
        }
    }

    private func refreshLatestTranscript() {
        refreshRecordingState()

        guard let latest = store.latestTranscript() else {
            latestTranscriptID = nil
            insertButton.isEnabled = false
            if latestRecordingPhase == .idle {
                updateAutomaticStatus("No shared transcript yet.")
            }
            return
        }

        latestTranscriptID = latest.id
        insertButton.isEnabled = latestRecordingPhase != .recording && latestRecordingPhase != .transcribing
        previewLabel.text = latest.text

        if latestRecordingPhase == .idle || latestRecordingPhase == .ready {
            updateAutomaticStatus("Ready from \(latest.modelName).")
        }
    }

    private func refreshRecordingState() {
        let state = store.latestRecordingState()
        latestRecordingPhase = state.phase

        switch state.phase {
        case .recording:
            configureRecordButton(title: "Stop", imageName: "stop.fill", style: .danger, isEnabled: true)
            insertButton.isEnabled = false
            updateAutomaticStatus("Recording. Tap Stop when done.")
        case .transcribing:
            configureRecordButton(title: "Working", imageName: "waveform", style: .plain, isEnabled: false)
            insertButton.isEnabled = false
            updateAutomaticStatus("Transcribing locally...")
        case .ready:
            configureRecordButton(title: "Record", imageName: "mic.fill", style: .prominent, isEnabled: true)
            updateAutomaticStatus(state.message)
        case .failed:
            configureRecordButton(title: "Record", imageName: "mic.fill", style: .prominent, isEnabled: true)
            updateAutomaticStatus(state.message)
        case .idle:
            configureRecordButton(title: "Record", imageName: "mic.fill", style: .prominent, isEnabled: true)
        }
    }

    private func configureRecordButton(
        title: String,
        imageName: String?,
        style: ButtonStyle,
        isEnabled: Bool
    ) {
        recordButton.configuration = buttonConfiguration(title: title, imageName: imageName, style: style)
        recordButton.isEnabled = isEnabled
    }

    @objc private func openRecorder() {
        if latestRecordingPhase == .recording {
            store.requestStopRecordingFromKeyboard()
            setManualStatus("Stopping and transcribing...")
            return
        }

        store.requestRecordingFromKeyboard()
        setManualStatus("Opening My Own Voice...")

        guard let url = URL(string: "\(SharedAppConfig.recorderURLScheme)://\(SharedAppConfig.recorderURLHost)") else {
            setManualStatus("Recorder URL is invalid.")
            return
        }

        extensionContext?.open(url) { [weak self] didOpen in
            DispatchQueue.main.async {
                guard let self else { return }

                if didOpen {
                    self.setManualStatus("Recording starts in My Own Voice.")
                    return
                }

                if self.openURLThroughApplicationRuntime(url, completion: { didOpen in
                    self.setManualStatus(didOpen ? "Recording starts in My Own Voice." : "Open My Own Voice to start.")
                }) {
                    self.setManualStatus("Switching to My Own Voice...")
                    _ = self.openURLThroughResponderChain(url)
                } else {
                    _ = self.openURLThroughResponderChain(url)
                    self.setManualStatus("Open My Own Voice to start.")
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self,
                  self.statusLabel.text == "Opening My Own Voice..." else {
                return
            }

            if self.openURLThroughApplicationRuntime(url, completion: { didOpen in
                self.setManualStatus(didOpen ? "Recording starts in My Own Voice." : "Open My Own Voice to start.")
            }) {
                self.setManualStatus("Switching to My Own Voice...")
                _ = self.openURLThroughResponderChain(url)
            } else {
                _ = self.openURLThroughResponderChain(url)
                self.setManualStatus("Open My Own Voice to start.")
            }
        }
    }

    private func setManualStatus(_ text: String, duration: TimeInterval = 8) {
        manualStatusExpiresAt = Date().addingTimeInterval(duration)
        statusLabel.text = text
    }

    private func updateAutomaticStatus(_ text: String) {
        if let manualStatusExpiresAt, manualStatusExpiresAt > Date() {
            return
        }

        manualStatusExpiresAt = nil
        statusLabel.text = text
    }

    private func openURLThroughResponderChain(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:")
        let startingResponders: [UIResponder] = [view, self]

        for startingResponder in startingResponders {
            var responder: UIResponder? = startingResponder

            while let currentResponder = responder {
                if currentResponder.responds(to: selector) {
                    _ = currentResponder.perform(selector, with: url)
                    return true
                }

                responder = currentResponder.next
            }
        }

        return false
    }

    private func openURLThroughApplicationRuntime(
        _ url: URL,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard let applicationClass = NSClassFromString("UIApplication") as? NSObject.Type else {
            return false
        }

        let sharedApplicationSelector = NSSelectorFromString("sharedApplication")
        guard applicationClass.responds(to: sharedApplicationSelector),
              let application = applicationClass
            .perform(sharedApplicationSelector)?
            .takeUnretainedValue() as? NSObject else {
            return false
        }

        let modernOpenURLSelector = NSSelectorFromString("openURL:options:completionHandler:")
        if application.responds(to: modernOpenURLSelector),
           let implementation = application.method(for: modernOpenURLSelector) {
            typealias OpenURLIMP = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject) -> Void
            let openURL = unsafeBitCast(implementation, to: OpenURLIMP.self)
            let completionBlock: @convention(block) (Bool) -> Void = { didOpen in
                DispatchQueue.main.async {
                    completion(didOpen)
                }
            }

            openURL(
                application,
                modernOpenURLSelector,
                url as NSURL,
                [:] as NSDictionary,
                unsafeBitCast(completionBlock, to: AnyObject.self)
            )
            return true
        }

        return false
    }

    @objc private func insertLatestTranscript() {
        refreshLatestTranscript()
        guard let latest = store.latestTranscript(), !latest.text.isEmpty else {
            setManualStatus("No transcript to insert.")
            return
        }

        textDocumentProxy.insertText(latest.text)
        setManualStatus("Inserted.")
    }

    @objc private func insertKey(_ sender: UIButton) {
        guard let key = sender.configuration?.title else { return }
        textDocumentProxy.insertText(key.lowercased())
    }

    @objc private func insertSpace() {
        textDocumentProxy.insertText(" ")
    }

    @objc private func insertReturn() {
        textDocumentProxy.insertText("\n")
    }

    @objc private func deleteBackward() {
        textDocumentProxy.deleteBackward()
    }
}

private enum ButtonStyle {
    case plain
    case prominent
    case danger
}
