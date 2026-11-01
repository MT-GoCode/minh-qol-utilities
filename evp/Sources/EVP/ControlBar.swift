import AppKit
import EVPCore

/// The strip below the video: progress, time, transport buttons, speed, volume, full screen. Items that do not fit
/// fold into the `…` menu, least important first. It shows what the player reports and sends every user action out
/// as a `Command`.
final class ControlBar: NSView {
    private static let margin: CGFloat = 12
    private static let gap: CGFloat = 6
    private static let rowY: CGFloat = 8
    private static let rowHeight: CGFloat = 28
    private static let overflowWidth: CGFloat = 28
    private static let timeFieldWidth: CGFloat = 54
    private static let durationWidth: CGFloat = 72
    private static let scrubHeight: CGFloat = 26

    /// One foldable control, its width and the equivalent `…` menu entry.
    private final class Item {
        let view: NSView
        let width: CGFloat
        let menuItem: NSMenuItem
        var visible = true

        init(view: NSView, width: CGFloat, menuItem: NSMenuItem) {
            (self.view, self.width, self.menuItem) = (view, width, menuItem)
        }
    }

    var onCommand: ((Command) -> Void)?
    /// The lines of the audio or subtitle menu, asked for each time one opens.
    var trackItems: ((Track.Kind) throws -> [TrackMenuItem])?
    /// The pointer over the progress strip (see `ScrubBar.onHover`).
    var onScrubHover: (((fraction: Double, top: NSPoint)?) -> Void)? {
        get { scrub.onHover }
        set { scrub.onHover = newValue }
    }

    private let scrub = ScrubBar()
    private let timeField = TimeField()
    private let durationLabel = ControlBar.label(" / 0:00", id: "duration", width: ControlBar.durationWidth, font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular))
    private let feedbackLabel = ControlBar.label("", id: "feedback", width: 0, font: .systemFont(ofSize: 12))
    private let playPause = CommandButton(title: "▶", command: .action(.playPause), id: "play-pause")
    private let overflowButton = NSButton(title: "…", target: nil, action: nil)
    private let overflowMenu = NSMenu()
    private let volumeSlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let speedButton = CommandButton(title: "1.0x", command: .action(.speedReset), id: "speed")

    // The foldable items by where they sit (left to right in each group) and in the order they are kept.
    private var beforePlay: [Item] = []
    private var afterPlay: [Item] = []
    private var farRight: [Item] = []
    private var keepFirst: [Item] = []
    private var seekItems: [(item: Item, sign: String, step: KeyPath<Settings, Double>)] = []

    init(settings: Settings) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        feedbackLabel.alignment = .center
        feedbackLabel.textColor = .secondaryLabelColor
        playPause.target = self
        playPause.action = #selector(commandChosen)
        overflowButton.target = self
        overflowButton.action = #selector(showOverflow)
        overflowButton.frame.size.width = Self.overflowWidth
        overflowButton.setAccessibilityIdentifier("overflow")
        volumeSlider.setAccessibilityIdentifier("volume")
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        scrub.onSeek = { [weak self] in self?.onCommand?(.seekFraction($0)) }
        timeField.onSubmit = { [weak self] in self?.onCommand?(.seek($0)) }
        [scrub, timeField, durationLabel, feedbackLabel, playPause, overflowButton].forEach(addSubview)

        func seek(_ sign: String, _ step: KeyPath<Settings, Double>, _ action: Action, _ id: String) -> Item {
            let seek = item(CommandButton(title: "", command: .action(action), id: id), width: 40, menuTitle: "", command: .action(action))
            seekItems.append((seek, sign, step))
            return seek
        }
        let back5 = seek("-", \.seekShortSeconds, .seekBackShort, "back-short")
        let forward5 = seek("+", \.seekShortSeconds, .seekForwardShort, "forward-short")
        let back10 = seek("-", \.seekLongSeconds, .seekBackLong, "back-long")
        let forward10 = seek("+", \.seekLongSeconds, .seekForwardLong, "forward-long")
        let speed = item(speedButton, width: 52, menuTitle: "Reset Speed", command: .action(.speedReset))
        let volume = item(volumeSlider, width: 96, menuTitle: "Volume Up", command: .action(.volumeUp))
        let fullscreen = item(CommandButton(title: "⛶", command: .action(.fullscreen), id: "fullscreen"), width: 32,
                              menuTitle: "Enter Full Screen", command: .action(.fullscreen))
        let screenshot = item(CommandButton(symbol: "camera", label: "Copy Screenshot", command: .action(.screenshot), id: "screenshot"), width: 32,
                              menuTitle: "Copy Screenshot", command: .action(.screenshot))
        let subtitles = trackItem(.sub, symbol: "captions.bubble", title: "Subtitles", id: "subtitle-tracks")
        let audio = trackItem(.audio, symbol: "waveform", title: "Audio Track", id: "audio-tracks")
        beforePlay = [back10, back5]
        afterPlay = [forward5, forward10]
        farRight = [subtitles, audio, screenshot, speed, volume, fullscreen]
        keepFirst = [back5, forward5, back10, forward10, speed, volume, fullscreen, screenshot, subtitles, audio]
        keepFirst.forEach { addSubview($0.view) }
        overflowMenu.items = keepFirst.map(\.menuItem)
        apply(settings)
    }

    /// Titles that show a setting: the seek buttons say their step ("-5", "+10").
    func apply(_ settings: Settings) {
        for (item, sign, step) in seekItems {
            let title = "\(sign)\(String(format: "%g", settings[keyPath: step]))"
            (item.view as? NSButton)?.title = title
            item.menuItem.title = "Seek \(title) s"
        }
    }

    required init?(coder: NSCoder) { fatalError("ControlBar is created in code") }

    // MARK: Shown from the player

    func setTime(_ seconds: Double) {
        timeField.show(seconds: seconds)
        scrub.fraction = scrub.duration > 0 ? seconds / scrub.duration : 0
    }

    func setDuration(_ seconds: Double) {
        scrub.duration = seconds
        durationLabel.stringValue = " / \(TimeFormat.format(seconds))"
    }
    func setPaused(_ paused: Bool) { playPause.title = paused ? "▶" : "⏸" }
    func setSpeed(_ speed: Double) { speedButton.title = PlaybackLimits.label(speed: speed) }
    func setVolume(_ volume: Double) { volumeSlider.doubleValue = volume }
    func showFeedback(_ text: String) { feedbackLabel.stringValue = text }

    /// Narrowest bar that still shows the time, play/pause and the `…` menu.
    var minimumWidth: CGFloat { Self.margin * 2 + essentialWidth - Self.margin + Self.gap + Self.overflowWidth }

    private var essentialWidth: CGFloat { Self.margin + Self.timeFieldWidth + Self.durationWidth + Self.gap + playPause.frame.width }

    // MARK: Layout

    override func layout() {
        super.layout()
        scrub.frame = NSRect(x: Self.margin, y: Self.rowY + Self.rowHeight + 6, width: max(bounds.width - 2 * Self.margin, 0), height: Self.scrubHeight)
        let kept = BarLayout.visibleCount(available: bounds.width - Self.margin, essentialWidth: essentialWidth,
                                          foldableWidths: keepFirst.map(\.width), gap: Self.gap, overflowWidth: Self.overflowWidth)
        for (index, item) in keepFirst.enumerated() {
            item.visible = index < kept
            item.view.isHidden = !item.visible
            item.menuItem.isHidden = item.visible
        }
        overflowButton.isHidden = kept == keepFirst.count

        var x = Self.margin
        func place(_ view: NSView, width: CGFloat) {
            view.frame = NSRect(x: x, y: Self.rowY, width: width, height: Self.rowHeight)
            x += width + Self.gap
        }
        timeField.frame = NSRect(x: x, y: Self.rowY + 4, width: Self.timeFieldWidth, height: 20)
        durationLabel.frame = NSRect(x: x + Self.timeFieldWidth, y: Self.rowY + 4, width: Self.durationWidth, height: 20)
        x += Self.timeFieldWidth + Self.durationWidth + Self.gap
        for item in beforePlay where item.visible { place(item.view, width: item.width) }
        place(playPause, width: playPause.frame.width)
        for item in afterPlay where item.visible { place(item.view, width: item.width) }

        var right = bounds.width - Self.margin
        if !overflowButton.isHidden {
            right -= Self.overflowWidth
            overflowButton.frame = NSRect(x: right, y: Self.rowY, width: Self.overflowWidth, height: Self.rowHeight)
            right -= Self.gap
        }
        for item in farRight.reversed() where item.visible {
            right -= item.width
            item.view.frame = NSRect(x: right, y: Self.rowY, width: item.width, height: Self.rowHeight)
            right -= Self.gap
        }
        feedbackLabel.frame = NSRect(x: x, y: Self.rowY + 4, width: max(right - x + Self.gap, 0), height: 18)
    }

    // MARK: Actions

    @objc private func commandChosen(_ sender: AnyObject) {
        if let command = (sender as? CommandButton)?.command ?? (sender as? CommandMenuItem)?.command { onCommand?(command) }
    }

    @objc private func volumeChanged(_ sender: NSSlider) { onCommand?(.setVolume(sender.doubleValue)) }

    @objc private func showOverflow(_ sender: NSButton) {
        for item in overflowMenu.items { if let kind = (item as? TrackMenuEntry)?.kind, let menu = item.submenu { fillTracks(menu, kind) } }
        overflowMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func showTracks(_ sender: TrackButton) {
        let menu = NSMenu()
        fillTracks(menu, sender.kind)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    /// One line per track, the playing one checked; choosing one sends `.selectTrack`.
    private func fillTracks(_ menu: NSMenu, _ kind: Track.Kind) {
        menu.removeAllItems()
        do {
            let lines = try trackItems?(kind) ?? []
            for line in lines {
                let item = CommandMenuItem(title: line.title, command: .selectTrack(kind, line.trackID))
                item.target = self
                item.action = #selector(commandChosen)
                item.state = line.isChecked ? .on : .off
                menu.addItem(item)
            }
            if lines.isEmpty { menu.addItem(withTitle: "None in this file", action: nil, keyEquivalent: "") }
        } catch {
            menu.addItem(withTitle: "Error: \(error)", action: nil, keyEquivalent: "")
        }
    }

    // MARK: Building

    private func item(_ view: NSView, width: CGFloat, menuTitle: String, command: Command) -> Item {
        (view as? NSControl).map { $0.target = self }
        if let button = view as? CommandButton { button.action = #selector(commandChosen) }
        let menuItem = CommandMenuItem(title: menuTitle, command: command)
        menuItem.target = self
        menuItem.action = #selector(commandChosen)
        return Item(view: view, width: width, menuItem: menuItem)
    }

    private func trackItem(_ kind: Track.Kind, symbol: String, title: String, id: String) -> Item {
        let button = TrackButton(kind: kind, symbol: symbol, label: title, id: id)
        button.target = self
        button.action = #selector(showTracks)
        let entry = TrackMenuEntry(kind: kind, title: title)
        entry.submenu = NSMenu(title: title)
        return Item(view: button, width: 32, menuItem: entry)
    }

    private static func label(_ text: String, id: String, width: CGFloat, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .white
        label.setAccessibilityIdentifier(id)
        label.frame.size.width = width
        return label
    }
}

/// A button that knows which command it sends.
final class CommandButton: NSButton {
    let command: Command

    init(title: String, command: Command, id: String) {
        self.command = command
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .accessoryBarAction
        setAccessibilityIdentifier(id)
        frame.size.width = 32
    }

    /// A button drawn with an SF Symbol; `label` is what VoiceOver and the tooltip say.
    convenience init(symbol: String, label: String, command: Command, id: String) {
        self.init(title: "", command: command, id: id)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        imagePosition = .imageOnly
        toolTip = label
    }

    required init?(coder: NSCoder) { fatalError("CommandButton is created in code") }
}

/// The audio or subtitle button: opens the menu of that kind of track.
final class TrackButton: NSButton {
    let kind: Track.Kind

    init(kind: Track.Kind, symbol: String, label: String, id: String) {
        self.kind = kind
        super.init(frame: .zero)
        title = ""
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        imagePosition = .imageOnly
        toolTip = label
        bezelStyle = .accessoryBarAction
        setAccessibilityIdentifier(id)
    }

    required init?(coder: NSCoder) { fatalError("TrackButton is created in code") }
}

/// The `…` menu's line for the audio or subtitle tracks; its submenu is filled when the `…` menu opens.
final class TrackMenuEntry: NSMenuItem {
    let kind: Track.Kind

    init(kind: Track.Kind, title: String) {
        self.kind = kind
        super.init(title: title, action: nil, keyEquivalent: "")
    }

    required init(coder: NSCoder) { fatalError("TrackMenuEntry is created in code") }
}

final class CommandMenuItem: NSMenuItem {
    let command: Command

    init(title: String, command: Command) {
        self.command = command
        super.init(title: title, action: nil, keyEquivalent: "")
    }

    required init(coder: NSCoder) { fatalError("CommandMenuItem is created in code") }
}
