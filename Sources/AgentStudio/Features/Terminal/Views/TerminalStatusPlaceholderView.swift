import AppKit

@MainActor
enum TerminalStatusPlaceholderMode: Equatable {
    case preparing
    case failedToStart
}

@MainActor
final class TerminalStatusPlaceholderView: PaneView {
    private let title: String
    private let startupOverlay = SurfaceStartupOverlayView()
    private let errorOverlay = SurfaceErrorOverlayView()
    private(set) var mode: TerminalStatusPlaceholderMode

    var onRetryRequested: ((UUID) -> Void)?

    init(
        paneId: UUID,
        title: String,
        mode: TerminalStatusPlaceholderMode
    ) {
        self.title = title
        self.mode = mode
        super.init(paneId: paneId)
        setupSubviews()
        render(mode: mode)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    var shouldRetryCreationWhenBoundsChange: Bool {
        mode == .preparing
    }

    func configure(mode: TerminalStatusPlaceholderMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        render(mode: mode)
    }

    private func setupSubviews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        startupOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(startupOverlay)
        NSLayoutConstraint.activate([
            startupOverlay.topAnchor.constraint(equalTo: topAnchor),
            startupOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            startupOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            startupOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        errorOverlay.translatesAutoresizingMaskIntoConstraints = false
        errorOverlay.onRestart = { [weak self] in
            guard let self else { return }
            self.onRetryRequested?(self.paneId)
        }
        addSubview(errorOverlay)
        NSLayoutConstraint.activate([
            errorOverlay.topAnchor.constraint(equalTo: topAnchor),
            errorOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            errorOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            errorOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func render(mode: TerminalStatusPlaceholderMode) {
        switch mode {
        case .preparing:
            errorOverlay.hide()
            startupOverlay.showPreparing()
        case .failedToStart:
            startupOverlay.hide()
            errorOverlay.configure(health: .unhealthy(reason: .initializationFailed))
        }
    }
}
