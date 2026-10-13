//  StyleTests.swift — built-in and saved styles (PRD/PRD-胶片指南卡片与风格.md §5).
//
//  Sidecar in, Sidecar out, as `SettingsClipboardTests` is. The store is only
//  ever given a temporary URL: a test on the real path would rewrite the
//  person's own styles (AGENTS.md trap 24's rule, for a file).
import ImageIO
import UniformTypeIdentifiers
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

    /// A10, second half: a built-in style is the same as choosing its film
    /// and its paper in the two lists and setting the effects by hand, from
    /// every state a frame can start in.
    func testABuiltInStyleIsChoosingItByHand() {
        let session = Session(styleStore: StyleStore(url: storeURL))
        let printing = FilmParams.default
        var scanning = FilmParams.default; scanning.scanFilm = true
        var intermediate = FilmParams.default; intermediate.digitalIntermediate = true
        var silver = FilmParams.default
        silver.filmStock = "kodak_tri_x_400"; silver.printStock = "ilford_multigrade_iv_rc"
        for start in [printing, scanning, intermediate, silver] {
            for style in BuiltInStyle.all {
                session.params = start
                session.selectFilmStock(style.film)
                if !(catalog.stock(style.film)?.isPositive ?? false) {
                    // Clicking the paper row: the style's, or the one the
                    // film list just chose.
                    session.selectPrintStock(style.paper ?? session.params.printStock)
                }
                var byHand = session.params
                byHand.grainActive = style.grainActive
                byHand.halationActive = style.halationActive
                byHand.glareActive = style.glareActive
                byHand.effects = style.effects
                var target = Sidecar(); target.params = start
                // Both through `resolved`: the session fills the film edge's
                // text and framing in for the frame it holds, whoever chose
                // the film, and resolving twice is resolving once.
                XCTAssertEqual(session.resolved(style.applied(to: target, catalog: catalog).params),
                               session.resolved(byHand),
                               "\(style.id) from \(start.filmStock)/\(start.printStock)")
            }
        }
    }

    /// A5 and A10's last clause: a style applied to three picked frames writes
    /// the two that are not on the canvas to disk, marks them for a new
    /// develop, and gives them what the canvas frame got.
    ///
    /// The frames are written here rather than copied from the camera
    /// fixtures, which this checkout may not have (AGENTS.md trap 26): what is
    /// tested is where settings go, not what a photograph looks like.
    func testAStyleOnThreePickedFramesWritesAllThree() async throws {
        let urls = try (0..<3).map { i -> URL in
            let sub = dir.appending(path: "frame-\(i)")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let url = sub.appending(path: "frame.tif")
            try writeGrey(to: url)
            return url
        }
        addTeardownBlock { for url in urls { try? FileManager.default.removeItem(at: Sidecar.url(for: url)) } }
        let (a, b, c) = (urls[0], urls[1], urls[2])
        let s = Session(styleStore: StyleStore(url: storeURL))
        s.open(urls: urls)
        try await waitUntil("the engine to warm up") { s.serviceReady }
        s.click(a)
        try await waitUntil("a to decode") { s.selection == a && s.decoded != nil }
        // A frame with no sidecar stops at the decode until it is asked to
        // print, as `SettingsClipboardSessionTests` asks it.
        s.requestPrint()
        try await settle(s)
        s.click(b, command: true)
        s.click(c, command: true)
        XCTAssertEqual(Set(s.styleTargets), Set(urls))
        let style = try XCTUnwrap(BuiltInStyle.all.first { $0.id == "classic_bw" })
        XCTAssertNil(s.styleBlockedReason)
        s.applyStyle(.builtIn(style))
        XCTAssertEqual(s.params.filmStock, style.film, "the canvas frame")
        for url in [b, c] {
            let saved = try XCTUnwrap(Sidecar.load(for: url), "\(url.path) has no sidecar")
            XCTAssertEqual(saved.state, .stale, url.path)
            XCTAssertEqual(s.frameStates[url], .stale, url.path)
            // The fields a built-in style owns, as the canvas frame has them.
            XCTAssertEqual(saved.params.filmStock, s.params.filmStock)
            XCTAssertEqual(saved.params.printStock, s.params.printStock)
            XCTAssertEqual(saved.params.scanFilm, s.params.scanFilm)
            XCTAssertEqual(saved.params.digitalIntermediate, s.params.digitalIntermediate)
            XCTAssertEqual(saved.params.grainActive, s.params.grainActive)
            XCTAssertEqual(saved.params.halationActive, s.params.halationActive)
            XCTAssertEqual(saved.params.glareActive, s.params.glareActive)
            XCTAssertEqual(saved.params.effects, s.params.effects)
        }
        // Nothing left in flight when the session goes away.
        try await settle(s)
    }

    /// `SettingsClipboardSessionTests.settle`: the develop, then the render
    /// its trailing request starts.
    private func settle(_ s: Session) async throws {
        try await waitUntil("the develop", timeout: 90, state: {
            "status=\(s.status) busy=\(s.busy) pending=\(s.scheduler.pending) "
            + "session=\(String(describing: s.serviceSessionIDForExport)) ready=\(s.serviceReady) "
            + "decoded=\(s.decoded != nil) state=\(String(describing: s.frameStates[s.selection ?? URL(fileURLWithPath: "/")]))"
        }) {
            s.serviceSessionIDForExport != nil && !s.busy && !s.scheduler.pending
        }
        try await Task.sleep(for: .milliseconds(800))
        try await waitUntil("the queue to drain", timeout: 30) { !s.busy && !s.scheduler.pending }
    }

    /// A small 16-bit grey TIFF, enough for the app to open and develop.
    private func writeGrey(to url: URL) throws {
        let (w, h) = (96, 64)
        var pixels = [UInt16](repeating: 0x5000, count: w * h * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 0xFFFF }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                | CGBitmapInfo.byteOrder16Little.rawValue)
        let image = try pixels.withUnsafeMutableBytes { raw -> CGImage in
            let ctx = try XCTUnwrap(CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 16,
                                              bytesPerRow: w * 8, space: space, bitmapInfo: info.rawValue))
            return try XCTUnwrap(ctx.makeImage())
        }
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func waitUntil(_ what: String, timeout: Double = 30, state: () -> String = { "" },
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for \(what) \(state())")
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
