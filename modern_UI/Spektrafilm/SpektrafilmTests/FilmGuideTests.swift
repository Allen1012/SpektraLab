//  FilmGuideTests.swift — the film and paper cards' data and the scene filter
//  (PRD/PRD-胶片指南卡片与风格.md §3–4). No window and no engine: everything
//  here is the generated catalogue and pure functions over it.
import AppKit
import SwiftUI
import XCTest

@MainActor
final class FilmGuideTests: XCTestCase {
    private let catalog = StockCatalog.shared

    /// `gen-catalog.py` folds `stock_guide.json` in; a stock it missed would
    /// show a card with no words.
    func testEveryStockHasAGuideEntry() {
        for stock in catalog.stocks {
            XCTAssertNotNil(stock.guide, "\(stock.id) has no guide entry")
        }
    }

    /// The generator refuses an unknown tag; this pins that the app's
    /// vocabulary is the generator's, so no tag is silently dropped.
    func testTagsStayInsideTheVocabulary() {
        for stock in catalog.stocks {
            XCTAssertEqual(stock.scenes.count, stock.tags?.count ?? 0,
                           "\(stock.id) has a tag outside FilmScene: \(stock.tags ?? [])")
        }
    }

    func testPapersCarryNoSceneTags() {
        for stock in catalog.stocks where stock.isPaper {
            XCTAssertTrue(stock.scenes.isEmpty, "\(stock.id) is a paper with scene tags")
        }
    }

    /// A chip that empties the list would be a chip that lies.
    func testEverySceneHasAFilm() {
        for scene in FilmScene.allCases {
            let films = catalog.filmGroups(scene: scene, keeping: nil).flatMap { $0.films }
            XCTAssertFalse(films.isEmpty, "no film for \(scene)")
        }
    }

    /// PRD §4.3: the film in use never disappears, and an emptied group is
    /// not drawn as a bare caption.
    func testFilteringKeepsTheFilmInUseAndDropsEmptyGroups() {
        let kept = "kodak_portra_400"
        for scene in FilmScene.allCases {
            let groups = catalog.filmGroups(scene: scene, keeping: kept)
            XCTAssertFalse(groups.contains { $0.films.isEmpty }, "\(scene) left an empty group")
            let films = groups.flatMap { $0.films }
            XCTAssertTrue(films.contains { $0.id == kept }, "\(scene) dropped the film in use")
            for film in films where film.id != kept {
                XCTAssertTrue(film.scenes.contains(scene), "\(film.id) is not a \(scene) film")
            }
        }
    }

    func testNoFilterIsTheWholeList() {
        let all = catalog.filmGroups(scene: nil, keeping: nil).flatMap { $0.films }.map(\.id)
        XCTAssertEqual(all, catalog.filmGroups.flatMap { $0.films }.map(\.id))
    }

    /// The traits are absent until `stock_traits.py` has run; where they are
    /// present every level is one of the five dots.
    func testTraitLevelsAreFiveDots() {
        for stock in catalog.stocks {
            guard let t = stock.traits else { continue }
            for trait in [t.contrast, t.saturation, t.latitude, t.grain].compactMap({ $0 }) {
                if let level = trait.level { XCTAssertTrue((1...5).contains(level), "\(stock.id): \(level)") }
            }
        }
    }

    /// PRD §10 / A10: the film list's rule as a value, from every paper a
    /// frame can start on. Whatever it was on, the result prints — or scans,
    /// for a slide film.
    func testChoosingAFilmAlwaysLeavesAPrintablePairing() {
        let papers = catalog.stocks.filter(\.isPaper)
        for film in catalog.filmsForPicker {
            for paper in papers {
                var start = FilmParams.default
                start.printStock = paper.id
                let p = start.choosingFilm(film.id, in: catalog)
                XCTAssertEqual(p.filmStock, film.id)
                XCTAssertTrue(catalog.canPrint(film: film.id, on: p.printStock),
                              "\(film.id) from \(paper.id) landed on \(p.printStock)")
                if film.isPositive { XCTAssertTrue(p.scanFilm, "\(film.id) is a slide film and must scan") }
            }
        }
    }

    /// A10, first half: `choosingFilm` is the film list's rule as it was
    /// before it became a value — `Session.selectFilmStock` followed by
    /// `applyFilmStageRule`, copied here from `main` at 01d32a2 — from every
    /// paper, scan and DI state a frame can be in.
    func testChoosingAFilmIsTheListsRuleAsItWas() {
        func before(_ start: FilmParams, _ id: String) -> FilmParams {
            var p = start
            p.filmStock = id
            if let target = catalog.stock(id)?.targetPrint, catalog.stock(target) != nil,
               !catalog.isDeclaredPairing(film: p.filmStock, paper: p.printStock) {
                p.printStock = target
            }
            if !catalog.canPrint(film: id, on: p.printStock) {
                p.printStock = catalog.stock(id)?.targetPrint ?? FilmParams.default.printStock
            }
            if catalog.stock(id)?.isPositive ?? false, !p.scanFilm { p.scanFilm = true }
            return p
        }
        for film in catalog.filmsForPicker {
            for paper in catalog.stocks where paper.isPaper {
                for (scan, di) in [(false, false), (true, false), (false, true)] {
                    var start = FilmParams.default
                    start.printStock = paper.id; start.scanFilm = scan; start.digitalIntermediate = di
                    XCTAssertEqual(start.choosingFilm(film.id, in: catalog), before(start, film.id),
                                   "\(film.id) from \(paper.id), scan \(scan), DI \(di)")
                }
            }
        }
    }

    // MARK: - traits (PRD §3.5, §6)

    /// `stock_traits.py` has run, so every stock carries its numbers: the
    /// guard PRD §6 asks for, for the traits half. (The art half waits for the
    /// illustrations.)
    func testEveryStockHasItsTraits() {
        for stock in catalog.stocks {
            guard let t = stock.traits else { XCTFail("\(stock.id) has no traits"); continue }
            XCTAssertNotNil(t.contrast?.level, "\(stock.id): contrast")
            XCTAssertNotNil(t.measuredWith, "\(stock.id): measured with what")
            // A silver stock has no saturation; every other one has.
            XCTAssertEqual(t.saturation == nil, stock.isMonochrome, "\(stock.id): saturation")
            if stock.isFilm {
                XCTAssertNotNil(t.grain?.level, "\(stock.id): grain")
                // Measured on the film alone, so a slide's is comparable too.
                XCTAssertNotNil(t.latitude?.level, "\(stock.id): latitude")
            } else {
                XCTAssertNil(t.grain, "\(stock.id): a paper has no grain row")
                XCTAssertNil(t.latitude, "\(stock.id): a paper has no latitude row")
            }
        }
    }

    // MARK: - the card itself (A1, A2)

    /// A1: all 33 cards lay out in both languages at the card's own width.
    /// A2: a card is built from a stock and the catalogue alone — it holds no
    /// `Session`, so it has nothing to write or render with — and drawing the
    /// two sections that show cards leaves the frame's settings as they were.
    func testEveryCardDrawsInBothLanguagesAndChangesNothing() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "FilmGuideTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let session = Session(styleStore: StyleStore(url: dir.appending(path: "styles.json")))
        let before = session.sidecar
        let saved = Localization.shared.language
        defer { Localization.shared.language = saved }
        for setting in LanguageSetting.allCases {
            Localization.shared.language = setting
            for stock in catalog.stocks {
                let view = NSHostingView(rootView: StockCard(stock: stock, catalog: catalog,
                                                             fastFlipLine: "x", note: "y"))
                let size = view.fittingSize
                XCTAssertEqual(size.width, StockCard.width, accuracy: 0.5, "\(stock.id) in \(setting)")
                XCTAssertGreaterThan(size.height, 150, "\(stock.id) in \(setting) drew almost nothing")
            }
            for section in [AnyView(FilmSection(session: session)), AnyView(PrintProfileSection(session: session))] {
                let host = NSHostingView(rootView: section.frame(width: 260))
                host.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
                host.layoutSubtreeIfNeeded()
            }
        }
        XCTAssertEqual(session.sidecar, before)
    }

    /// A film with a declared paper takes it, unless the frame is already on
    /// a declared pairing of that film.
    func testChoosingAFilmTakesItsDeclaredPaper() {
        for film in catalog.filmsForPicker where !film.isPositive {
            guard let target = film.targetPrint, catalog.stock(target) != nil else { continue }
            var start = FilmParams.default
            start.printStock = "__not_a_paper__"
            XCTAssertEqual(start.choosingFilm(film.id, in: catalog).printStock, target, film.id)
        }
    }
}
