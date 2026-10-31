import Foundation

/// One line of the audio or subtitle menu. `trackID` is nil for the "Off" line.
public struct TrackMenuItem: Equatable {
    public let title: String
    public let trackID: Int?
    public let isChecked: Bool

    public init(title: String, trackID: Int?, isChecked: Bool) { (self.title, self.trackID, self.isChecked) = (title, trackID, isChecked) }
}

public enum TrackMenu {
    /// The menu of `kind`: one line per track of that kind, the playing one checked; subtitles also get "Off" first,
    /// checked when no subtitle is showing.
    public static func items(for kind: Track.Kind, in tracks: [Track], locale: Locale = .current) -> [TrackMenuItem] {
        let ofKind = tracks.filter { $0.kind == kind }
        var items = ofKind.enumerated().map { index, track in
            TrackMenuItem(title: title(of: track, position: index + 1, locale: locale), trackID: track.id, isChecked: track.selected)
        }
        if kind == .sub { items.insert(TrackMenuItem(title: "Off", trackID: nil, isChecked: !ofKind.contains { $0.selected }), at: 0) }
        return items
    }

    /// `English`, `English - Commentary`, `Commentary`, or `Track 2` when the file says nothing.
    static func title(of track: Track, position: Int, locale: Locale) -> String {
        let language = track.language.map { locale.localizedString(forLanguageCode: $0) ?? $0 }
        let parts = [language, track.title].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Track \(position)" : parts.joined(separator: " - ")
    }
}
