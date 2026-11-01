import AppKit
import TECore

/// The font-size menu row: an integer slider over fontSizeRange, its value, and the config file's error when it is invalid.
@MainActor
public final class FontSizeItem: NSObject {
    public let item = NSMenuItem()
    private let slider = NSSlider(), value = NSTextField(labelWithString: ""), problem = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let config: ConfigStore
    private let sizes = AsyncStream<Int>.makeStream(of: Int.self, bufferingPolicy: .bufferingNewest(1))

    public init(config: ConfigStore) async {
        self.config = config
        super.init()
        let title = NSTextField(labelWithString: "Font size")
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        value.alignment = .right
        value.identifier = NSUserInterfaceItemIdentifier("fontSize.value")
        problem.identifier = NSUserInterfaceItemIdentifier("fontSize.error")
        problem.textColor = .systemRed
        problem.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        problem.maximumNumberOfLines = 0
        problem.preferredMaxLayoutWidth = 208
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(moved)
        let row = NSStackView(views: [title, value])
        stack.setViews([row, slider, problem], in: .leading)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)
        NSLayoutConstraint.activate([row.widthAnchor.constraint(equalToConstant: 208), slider.widthAnchor.constraint(equalToConstant: 208)])
        item.view = stack
        let changes = await config.changes()
        let values = sizes.stream
        await show()
        Task { [weak self] in for await _ in changes { await self?.show() } }
        Task { [weak self] in for await v in values { await self?.write(v) } }
    }

    private func show(_ failure: String? = nil) async {
        let c = await config.current, stored = await config.error
        let e = failure ?? stored
        slider.minValue = Double(c.fontSizeRange.lowerBound)
        slider.maxValue = Double(c.fontSizeRange.upperBound)
        if NSEvent.pressedMouseButtons & 1 == 0 {
            slider.doubleValue = Double(c.fontSize)
            value.stringValue = "\(c.fontSize)"
        }
        problem.stringValue = e.map { "config.json: \($0)" } ?? ""
        problem.isHidden = e == nil
        stack.frame.size = stack.fittingSize
    }

    @objc private func moved() {
        let v = Int(slider.doubleValue.rounded())
        slider.doubleValue = Double(v)
        value.stringValue = "\(v)"
        sizes.continuation.yield(v)
    }

    private func write(_ size: Int) async {
        do { try await config.update { $0.fontSize = size } } catch { await show("\(error)") }
    }
}
