import UIKit

final class ShareViewController: UIViewController {
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var coordinator: ShareSubmissionCoordinator?
    private var repository: AppGroupQueueRepository?
    private let clock: ShareMonotonicClock = SystemMonotonicClock()
    /// Which links were found, who decides between them and which deadline the
    /// submission inherits. This controller only draws the answer.
    private lazy var flow = ShareFlowCoordinator(clock: clock)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        loadSharedItems()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 0, height: 320)
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.text = "WebTag Share"
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        statusLabel.text = "正在读取分享内容"
        closeButton.configuration = .bordered()
        closeButton.configuration?.title = "关闭"
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeButton.accessibilityIdentifier = "share.close"
        stackView.axis = .vertical
        stackView.spacing = 14
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(statusLabel)
        stackView.addArrangedSubview(closeButton)
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stackView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 18),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -18),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 18),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -18),
            stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -36),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    private func loadSharedItems() {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        // Started before the first await: every representation is in flight
        // while the collector waits, so one stuck provider costs the others
        // nothing.
        flow.start(items: ShareFlowCoordinator.attachments(of: items))
        Task {
            let collection = await self.flow.collect()
            await MainActor.run {
                self.render(self.flow.presentation(for: collection.candidates))
            }
        }
    }

    /// Draws whatever the flow decided. Every branch here is a UIKit
    /// consequence; the decision itself was already made, and tested.
    private func render(_ presentation: ShareFlowCoordinator.Presentation) {
        switch presentation {
        case .noCandidate:
            statusLabel.text = "没找到链接"
        case .automatic(let request):
            submit(request)
        case .selection(let candidates):
            statusLabel.text = "选择要收藏的链接"
            let buttons = candidates.indices.compactMap { index -> UIButton? in
                guard let label = ShareCandidatePresenter.displayLabel(candidates, at: index),
                      let request = flow.selection(candidates, at: index) else { return nil }
                let button = UIButton(type: .system)
                button.configuration = .bordered()
                button.configuration?.title = label
                button.configuration?.titleLineBreakMode = .byTruncatingMiddle
                button.titleLabel?.adjustsFontForContentSizeCategory = true
                button.titleLabel?.numberOfLines = 2
                button.titleLabel?.lineBreakMode = .byTruncatingMiddle
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
                button.accessibilityLabel = label
                // The label is only ever shown; what is submitted is the row's
                // own value, never something rebuilt from the label.
                button.addAction(
                    UIAction { [weak self] _ in self?.submit(request) },
                    for: .touchUpInside
                )
                return button
            }
            buttons.forEach { stackView.insertArrangedSubview($0, at: stackView.arrangedSubviews.count - 1) }
        }
    }

    private func submit(_ candidate: ShareFlowCoordinator.SubmissionRequest) {
        guard let request = flow.beginSubmission(candidate) else { return }
        statusLabel.text = "正在收藏"
        closeButton.isEnabled = false
        Task {
            do {
                let repo = try AppGroupQueueRepository()
                self.repository = repo
                let session = try repo.activeSessionIdentity()
                let keychain = KeychainCredentialStore()
                let storedConfiguration = try keychain.loadConfig()
                guard let session, session.canWrite,
                      let storedConfiguration,
                      storedConfiguration.identity == session else {
                    await self.showTerminal("请先打开 WebTag 完成设置", complete: false)
                    return
                }
                let submission = ShareSubmissionCoordinator(
                    repository: repo,
                    credentials: keychain,
                    background: BackgroundUploadSessionController.shared,
                    clock: self.clock
                )
                self.coordinator = submission
                BackgroundUploadSessionController.shared.taskCompletionHandler = { result in
                    await submission.handleBackgroundCompletion(result)
                }
                let outcome = await submission.submit(
                    url: request.value,
                    identity: session,
                    interactionDeadline: request.deadline
                )
                let message = ShareTerminalMessage.of(outcome)
                await self.showTerminal(message.text, complete: message.completesRequest)
            } catch {
                await self.showTerminal("提交失败", complete: false)
            }
        }
    }

    @MainActor
    private func showTerminal(_ text: String, complete: Bool) async {
        statusLabel.text = text
        closeButton.isEnabled = true
        if complete {
            try? await Task.sleep(nanoseconds: 300_000_000)
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    @objc private func close() { extensionContext?.cancelRequest(withError: NSError(domain: "WebTagShare", code: 1)) }
}
