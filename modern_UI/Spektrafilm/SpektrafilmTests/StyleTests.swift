//  StyleTests.swift — built-in and saved styles (PRD/PRD-胶片指南卡片与风格.md §5).
//
//  Sidecar in, Sidecar out, as `SettingsClipboardTests` is. The store is only
//  ever given a temporary URL: a test on the real path would rewrite the
//  person's own styles (AGENTS.md trap 24's rule, for a file).
import XCTest

@MainActor
final class StyleTests: XCTestCase {
    private let catalog = StockCatalog.shared
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "StyleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var storeURL: URL { dir.appending(path: "styles.json") }

    // MARK: - built in

    func testEveryBuiltInStyleIsAvailable() {
        for style in BuiltInStyle.all {
            XCTAssertNil(style.unavailableReason(in: catalog), style.id)
        }
    }

    func testBuiltInIDsAndNamesAreUnique() {
        XCTAssertEqual(Set(BuiltInStyle.all.map(\.id)).count, BuiltInStyle.all.count)
        XCTAssertEqual(Set(BuiltInStyle.all.map(\.nameEN)).count, BuiltInStyle.all.count)
        XCTAssertEqual(Set(BuiltInStyle.all.map(\.nameZH)).count, BuiltInStyle.all.count)
    }

    /// PRD A4: a built-in style writes the film, the paper and the effect
    /// switches and strengths, and nothing else — not the exposure, not the
    /// white balance, not the film format, not the crop.
    func testBuiltInStylesTouchOnlyTheirFields() {
        var base = Sidecar()
        base.params.exposureCompensationEV = 1.5
        base.params.extendedDynamicRange = true
        for style in BuiltInStyle.all {
            let out = style.applied(to: base, catalog: catalog)
            var reverted = out
            reverted.params.filmStock = base.params.filmStock
            reverted.params.printStock = base.params.printStock
            reverted.params.scanFilm = base.params.scanFilm
            reverted.params.digitalIntermediate = base.params.digitalIntermediate
            reverted.params.grainActive = base.params.grainActive
            reverted.params.halationActive = base.params.halationActive
            reverted.params.glareActive = base.params.glareActive
            reverted.params.effects = base.params.effects
            XCTAssertEqual(reverted, base, "\(style.id) wrote a field it does not own")
            XCTAssertEqual(out.params.filmStock, style.film, style.id)
        }
    }

    /// Whatever the frame was on, a built-in style leaves it printing on a
    /// paper its film can print on, or scanning a slide film.
    func testBuiltInStylesPrintOrScan() {
        var dii = Sidecar(); dii.params.digitalIntermediate = true
        var scan = Sidecar(); scan.params.scanFilm = true
        for start in [Sidecar(), dii, scan] {
            for style in BuiltInStyle.all {
                let p = style.applied(to: start, catalog: catalog).params
                if catalog.stock(style.film)?.isPositive ?? false {
                    XCTAssertTrue(p.scanFilm, style.id)
                } else {
                    XCTAssertFalse(p.scanFilm, style.id)
                    XCTAssertFalse(p.digitalIntermediate, style.id)
                    XCTAssertTrue(catalog.canPrint(film: p.filmStock, on: p.printStock), style.id)
                    if let paper = style.paper { XCTAssertEqual(p.printStock, paper, style.id) }
                }
            }
        }
    }

    // MARK: - saved

    /// PRD R7: applying a saved style is exactly a paste of the same groups.
    func testAUserStyleIsAPaste() {
        var source = Sidecar()
        source.params.filmStock = "kodak_ektar_100"
        source.params.exposureCompensationEV = -0.7
        var target = Sidecar()
        target.params.exposureCompensationEV = 2
        for groups: Set<ClipboardGroup> in [[.exposure], [.filmAndPaper], [.filmAndPaper, .filmEffects]] {
            let style = UserStyle(name: "x", groups: groups, from: source)
            let clip = SettingsClip(groups: groups, settings: source, sourceName: "x")
            XCTAssertEqual(style.applied(to: target), clip.applied(to: target), "\(groups)")
        }
    }

    /// PRD §5.5: nothing outside the ticked groups is kept in the file.
    func testAUserStyleKeepsNothingOutsideItsGroups() {
        var source = Sidecar()
        source.params.exposureCompensationEV = -0.7
        source.params.filmStock = "kodak_ektar_100"
        let style = UserStyle(name: "x", groups: [.filmAndPaper], from: source)
        XCTAssertEqual(style.settings.params.filmStock, "kodak_ektar_100")
        XCTAssertEqual(style.settings.params.exposureCompensationEV, Sidecar().params.exposureCompensationEV)
    }

    func testTheStoreRoundTrips() throws {
        let store = StyleStore(url: storeURL)
        try store.add(name: "Mine", groups: [.exposure, .whiteBalance], from: Sidecar())
        let again = StyleStore(url: storeURL)
        XCTAssertEqual(again.styles, store.styles)
        XCTAssertNil(again.problem)
    }

    func testNamesAreTrimmedAndUnique() throws {
        let store = StyleStore(url: storeURL)
        XCTAssertEqual(try store.add(name: "  Mine ", groups: [.exposure], from: Sidecar()).name, "Mine")
        for taken in ["mine", "MINE ", BuiltInStyle.all[0].nameEN, BuiltInStyle.all[0].nameZH] {
            XCTAssertThrowsError(try store.add(name: taken, groups: [.exposure], from: Sidecar())) {
                XCTAssertEqual($0 as? StyleStore.Failure, .duplicateName, taken)
            }
        }
        XCTAssertThrowsError(try store.add(name: "   ", groups: [.exposure], from: Sidecar())) {
            XCTAssertEqual($0 as? StyleStore.Failure, .emptyName)
        }
        XCTAssertEqual(store.styles.count, 1)
    }

    func testRenameAndDelete() throws {
        let store = StyleStore(url: storeURL)
        let a = try store.add(name: "A", groups: [.exposure], from: Sidecar())
        let b = try store.add(name: "B", groups: [.exposure], from: Sidecar())
        XCTAssertThrowsError(try store.rename(a.id, to: "b"))
        try store.rename(a.id, to: "a")   // its own name in another case is not a clash
        XCTAssertEqual(StyleStore(url: storeURL).styles.map(\.name), ["a", "B"])
        store.delete(b.id)
        XCTAssertEqual(StyleStore(url: storeURL).styles.map(\.name), ["a"])
    }

    /// An unreadable file is reported and moved aside before the next save,
    /// never overwritten: it may be the only copy of someone's styles.
    func testAnUnreadableFileIsSetAsideNotOverwritten() throws {
        try Data("not json".utf8).write(to: storeURL)
        let store = StyleStore(url: storeURL)
        XCTAssertNotNil(store.problem)
        XCTAssertTrue(store.styles.isEmpty)
        try store.add(name: "New", groups: [.exposure], from: Sidecar())
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("styles.unreadable-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try String(contentsOf: dir.appending(path: aside[0]), encoding: .utf8), "not json")
        XCTAssertEqual(StyleStore(url: storeURL).styles.map(\.name), ["New"])
    }
}
