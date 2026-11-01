import AppKit

/// A menu row that runs a closure; `on` shows the checkmark. `target` is the item itself, weak in AppKit, so no cycle.
@MainActor final class Row: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, on: Bool = false, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = on ? .on : .off
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { run() }
}
