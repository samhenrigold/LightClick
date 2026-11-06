import AppKit
import InstallerKit
import MachineKit

extension ConfigurationWindow {
    func makeGeneralPage() -> NSView {
        let guest = machine.guest
        let name = NSTextField(string: machine.pendingName ?? machine.name)
        name.identifier = NSUserInterfaceItemIdentifier("Name")
        name.delegate = self
        name.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let identityImage =
            NSImage(named: guest + "Roundel") ?? NSImage(named: guest + "ProductIcon") ?? NSImage(named: guest + "Icon")
            ?? NSApp.applicationIconImage
        let mark = NSImageView()
        mark.image = identityImage
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.widthAnchor.constraint(equalToConstant: 24).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let system = Guest(rawValue: guest)?.systemName ?? "Mac OS"
        let identity = NSStackView(views: [mark, NSTextField(labelWithString: system)])
        identity.spacing = 8
        let description = NSScrollView()
        description.borderType = .bezelBorder
        description.hasVerticalScroller = true
        description.autohidesScrollers = true
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 54))
        editor.font = .systemFont(ofSize: 13)
        editor.isRichText = false
        editor.textContainerInset = NSSize(width: 4, height: 4)
        editor.delegate = self
        editor.string = editable["Description"] as? String ?? ""
        description.documentView = editor
        editor.autoresizingMask = .width
        descriptionEditor = editor
        description.widthAnchor.constraint(equalToConstant: 472).isActive = true
        description.heightAnchor.constraint(equalToConstant: 58).isActive = true
        let descriptionLabel = NSTextField(labelWithString: "Description:")
        let grid = settingsGrid(
            [
                [NSGridCell.emptyContentView, identity], [NSTextField(labelWithString: "Name:"), name],
                [descriptionLabel, description]
            ], columnSpacing: 8, rowSpacing: 12)
        grid.column(at: 0).width = 80
        grid.column(at: 1).xPlacement = .leading
        grid.row(at: 2).yPlacement = .top
        let caption = grid.cell(atColumnIndex: 0, rowIndex: 2)
        caption.yPlacement = .none
        caption.customPlacementConstraints = [descriptionLabel.topAnchor.constraint(equalTo: description.topAnchor)]
        let divider = NSBox()
        divider.boxType = .separator
        let storageView = makeStorageOverview()
        let location = NSStackView(views: [settingsText("Location:"), button("Show in Finder", #selector(reveal))])
        location.spacing = 12
        let column = settingsColumn([grid, divider, storageView, location])
        divider.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        storageView.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    private func makeStorageOverview() -> NSView {
        func bytes(_ value: UInt64?) -> String {
            guard storage != nil, let value else { return "Calculating…" }
            return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
        }
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 4
        bar.layer?.cornerCurve = .continuous
        bar.layer?.masksToBounds = true
        let diskColor = NSColor(srgbRed: 0.29, green: 0.67, blue: 0.91, alpha: 1)
        let otherColor = NSColor(srgbRed: 0.73, green: 0.48, blue: 0.83, alpha: 1)
        let disk = NSView()
        let other = NSView()
        disk.wantsLayer = true
        other.wantsLayer = true
        disk.layer?.backgroundColor = diskColor.cgColor
        other.layer?.backgroundColor = otherColor.cgColor
        for part in [disk, other] {
            part.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(part)
        }
        let share = (storage ?? PackageStorage()).diskShare
        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 20),
            disk.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            disk.widthAnchor.constraint(equalTo: bar.widthAnchor, multiplier: share),
            disk.topAnchor.constraint(equalTo: bar.topAnchor),
            disk.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            other.leadingAnchor.constraint(equalTo: disk.trailingAnchor),
            other.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            other.topAnchor.constraint(equalTo: bar.topAnchor),
            other.bottomAnchor.constraint(equalTo: bar.bottomAnchor)
        ])
        let parts: [(NSColor, String, UInt64?)] = [
            (diskColor, "Hard Disks", storage?.diskBytes), (otherColor, "Miscellaneous", storage?.otherBytes)
        ]
        let legends = parts.map { color, title, value in
            let swatch = NSView()
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = color.cgColor
            swatch.widthAnchor.constraint(equalToConstant: 11).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 11).isActive = true
            let text = settingsColumn([settingsText(title, heading: true), settingsText(bytes(value))], spacing: 1)
            let legend = NSStackView(views: [swatch, text])
            legend.alignment = .top
            legend.spacing = 8
            return legend
        }
        let legend = NSStackView(views: legends)
        legend.spacing = 20
        legend.distribution = .fillEqually
        let right = settingsColumn([bar, legend], spacing: 12)
        bar.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        legend.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        let total = settingsText("Total size\n\(bytes(storage.map { $0.diskBytes + $0.otherBytes }))")
        total.alignment = .right
        total.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let row = NSStackView(views: [total, right])
        row.alignment = .top
        row.spacing = 8
        right.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -88).isActive = true
        return row
    }

    @objc func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([machine.url])
    }
}
