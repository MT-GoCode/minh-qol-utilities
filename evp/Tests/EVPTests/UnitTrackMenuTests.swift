import EVPCore
import XCTest

final class UnitTrackMenuTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    private func track(_ id: Int, _ kind: Track.Kind, language: String? = nil, title: String? = nil, selected: Bool = false) -> Track {
        Track(id: id, kind: kind, language: language, title: title, selected: selected)
    }

    func testAudioMenuListsAudioTracksWithTheSelectedOneChecked() {
        let tracks = [track(1, .video), track(1, .audio, language: "eng", selected: true), track(2, .audio, language: "fra", title: "Commentary"), track(1, .sub, language: "eng")]
        XCTAssertEqual(TrackMenu.items(for: .audio, in: tracks, locale: english), [
            TrackMenuItem(title: "English", trackID: 1, isChecked: true),
            TrackMenuItem(title: "French - Commentary", trackID: 2, isChecked: false),
        ])
    }

    func testSubtitleMenuStartsWithOffAndChecksItWhenNothingShows() {
        let tracks = [track(1, .sub, language: "eng"), track(2, .sub, language: "spa")]
        XCTAssertEqual(TrackMenu.items(for: .sub, in: tracks, locale: english), [
            TrackMenuItem(title: "Off", trackID: nil, isChecked: true),
            TrackMenuItem(title: "English", trackID: 1, isChecked: false),
            TrackMenuItem(title: "Spanish", trackID: 2, isChecked: false),
        ])
        let showing = [track(1, .sub, language: "eng"), track(2, .sub, language: "spa", selected: true)]
        XCTAssertEqual(TrackMenu.items(for: .sub, in: showing, locale: english).map(\.isChecked), [false, false, true])
    }

    func testTracksThatSayNothingAreNumberedByPosition() {
        let tracks = [track(3, .audio), track(7, .audio, title: "Director")]
        XCTAssertEqual(TrackMenu.items(for: .audio, in: tracks, locale: english).map(\.title), ["Track 1", "Director"])
    }

    func testAnUnknownLanguageCodeIsShownAsItIs() {
        XCTAssertEqual(TrackMenu.items(for: .audio, in: [track(1, .audio, language: "zzz")], locale: english).first?.title, "zzz")
    }

    func testAudioMenuHasNoOffLineAndAnEmptyFileHasNoLines() {
        XCTAssertEqual(TrackMenu.items(for: .audio, in: [], locale: english), [])
        XCTAssertEqual(TrackMenu.items(for: .sub, in: [], locale: english), [TrackMenuItem(title: "Off", trackID: nil, isChecked: true)])
    }
}
