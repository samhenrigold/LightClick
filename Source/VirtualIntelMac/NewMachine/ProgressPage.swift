import AppKit
import InstallerKit
import MachineKit

/// A job's download and preparation page. Each run gets a fresh one.
final class ProgressPage: AssistantPage {
    let status = assistantText("Preparing your Mac…", size: 13)
    let detail = assistantText("Estimating remaining time…", size: 12)
    let bar = NSProgressIndicator()
    let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    init(job: CreationJob, fraction: Double) {
        super.init(frame: NSRect(origin: .zero, size: assistantSize))
        let artwork = InstallerArtwork()
        artwork.wallpaper = NSImage(named: job.guest.rawValue + "Wallpaper")
        addArtwork(artwork)
        detail.textColor = .secondaryLabelColor
        detail.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let title = assistantText(
            SetupCopy.progressTitle(job.guest, usingExistingInstaller: job.sourceInstaller != nil), size: 27,
            weight: .semibold)
        let (heading, _, _) = assistantHeading(title: title, guest: job.guest)
        let intro = assistantText("", size: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.lineBreakMode = .byWordWrapping
        intro.attributedStringValue = NSAttributedString(
            string: SetupCopy.progressIntro(job),
            attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
            ])
        // AppKit can animate a reused indicator from the preceding job's end value, so this is a new one with its
        // starting value set before it's attached.
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = fraction
        let stack = NSStackView(views: [heading, intro, status, bar, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        addAssistantSubview(stack)
        stack.setCustomSpacing(28, after: intro)
        stack.setCustomSpacing(4, after: status)
        stack.setCustomSpacing(4, after: bar)
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 432),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10)
        ])
        addFooter(leading: nil, trailing: [cancelButton, pauseButton])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ phase: CreationPhase) {
        pauseButton.title = phase.pauseButtonTitle
        pauseButton.isEnabled = phase.allowsPauseAndCancel
        cancelButton.isEnabled = phase.allowsPauseAndCancel
    }
}
