//  FilmGuideTests.swift — the film and paper cards' data and the scene filter
//  (PRD/PRD-胶片指南卡片与风格.md §3–4). No window and no engine: everything
//  here is the generated catalogue and pure functions over it.
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
