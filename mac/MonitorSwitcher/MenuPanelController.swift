import Cocoa

/// 自绘下拉面板。用 NSPopover 承载，以便实现原生 NSMenu 做不到的
/// 分组标题字号、选项缩进与勾选样式。
final class MenuPanelController: NSViewController {

    struct Row {
        enum Kind {
            case header      // 分组标题：小字、灰色
            case option      // 可选项：正常字号、缩进、可勾选
            case info        // 只读状态行
            case separator
        }

        let kind: Kind
        let title: String
        var checked: Bool = false
        var enabled: Bool = true
        var value: Int = 0
    }

    var onSelect: ((Int) -> Void)?

    private let stack = NSStackView()
    private var rows: [Row] = []

    private let panelWidth: CGFloat = 280
    private let optionIndent: CGFloat = 26
    private let headerIndent: CGFloat = 12

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 120))

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
        ])

        self.view = container
    }

    func update(_ newRows: [Row]) {
        rows = newRows
        rebuild()
    }

    private func rebuild() {
        for sub in stack.arrangedSubviews {
            stack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }

        for row in rows {
            switch row.kind {
            case .header:
                let label = NSTextField(labelWithString: row.title)
                label.font = NSFont.systemFont(ofSize: 11, weight: .regular)
                label.textColor = .secondaryLabelColor
                stack.addArrangedSubview(wrap(label, top: 8, bottom: 3, left: headerIndent, height: nil))

            case .info:
                let label = NSTextField(labelWithString: row.title)
                label.font = NSFont.systemFont(ofSize: 11, weight: .regular)
                label.textColor = .secondaryLabelColor
                stack.addArrangedSubview(wrap(label, top: 3, bottom: 3, left: headerIndent, height: nil))

            case .separator:
                let box = NSBox()
                box.boxType = .separator
                box.translatesAutoresizingMaskIntoConstraints = false
                let holder = NSView()
                holder.translatesAutoresizingMaskIntoConstraints = false
                holder.addSubview(box)
                NSLayoutConstraint.activate([
                    box.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 10),
                    box.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -10),
                    box.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                    holder.heightAnchor.constraint(equalToConstant: 9),
                    holder.widthAnchor.constraint(equalToConstant: panelWidth)
                ])
                stack.addArrangedSubview(holder)

            case .option:
                let button = NSButton(title: row.title, target: self, action: #selector(optionTapped(_:)))
                button.tag = row.value
                button.isBordered = false
                button.bezelStyle = .regularSquare
                button.alignment = .left
                button.font = NSFont.systemFont(ofSize: 13, weight: .regular)
                button.contentTintColor = row.enabled ? NSColor.labelColor : NSColor.tertiaryLabelColor
                button.isEnabled = row.enabled
                button.imagePosition = .imageLeading
                if row.checked, let img = NSImage(systemSymbolName: "checkmark",
                                                  accessibilityDescription: "selected") {
                    img.size = NSSize(width: 11, height: 9)
                    button.image = img
                } else {
                    button.image = NSImage(size: NSSize(width: 11, height: 9))
                }
                stack.addArrangedSubview(wrap(button, top: 0, bottom: 0, left: optionIndent, height: 26))
            }
        }
    }

    private func wrap(_ inner: NSView, top: CGFloat, bottom: CGFloat, left: CGFloat, height: CGFloat?) -> NSView {
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        inner.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(inner)

        NSLayoutConstraint.activate([
            holder.widthAnchor.constraint(equalToConstant: panelWidth),
            inner.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: left),
            inner.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -10),
            inner.topAnchor.constraint(equalTo: holder.topAnchor, constant: top),
            inner.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -bottom)
        ])

        if let h = height {
            holder.heightAnchor.constraint(equalToConstant: h).isActive = true
        }

        return holder
    }

    @objc private func optionTapped(_ sender: NSButton) {
        onSelect?(sender.tag)
    }
}
