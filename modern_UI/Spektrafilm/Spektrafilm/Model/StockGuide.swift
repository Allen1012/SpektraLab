//  StockGuide.swift — what the film and paper cards say (PRD/PRD-胶片指南卡片与风格.md).
//
//  The data is generated into `StockCatalog.json` by `Tools/gen-catalog.py`
//  from three sources: the hand-written copy (`modern_UI/stock_guide.json`),
//  the measured traits (`modern_UI/stock_traits.json`) and the designer's
//  illustrations (`modern_UI/stock_art/`). Nothing here renders anything: a
//  card is read-only and costs no engine work (PRD R1).

import Foundation

/// The card copy for one stock, and whether its owner has approved it.
struct StockGuide: Codable, Hashable, Sendable {
    let status: String
    let en: String
    let zh: String

    /// A draft is shown with a badge, in builds where the guide is on at all.
    var isDraft: Bool { status != "approved" }

    /// The summary in the interface language, or nil when none is written yet
    /// (PRD Q11 leaves Verita 200D's empty for the owner).
    @MainActor var summary: String? {
        let s = L(en, zh: zh)
        return s.isEmpty ? nil : s
    }
}

/// One measured number and its place among the catalogue's stocks.
struct StockTrait: Codable, Hashable, Sendable {
    let value: Double
    /// 1…5, linear over the measured range of the same stage (films or papers).
    let level: Int?
}

/// The traits `engine/tests/stock_traits.py` measured. A film is measured with
/// its default paper, a paper with a reference film (`measuredWith`).
struct StockTraits: Codable, Hashable, Sendable {
    let contrast: StockTrait?
    let saturation: StockTrait?
    let latitude: StockTrait?
    let grain: StockTrait?
    let measuredWith: String?
}

/// The filter's vocabulary (PRD §4.2), in the order the chips show it.
enum FilmScene: String, CaseIterable, Identifiable, Sendable {
    case portrait, landscape, everyday, lowLight, tungsten, cinematic, vintage, bw

    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .portrait: L("Portrait", zh: "人像")
        case .landscape: L("Landscape", zh: "风景")
        case .everyday: L("Everyday", zh: "街拍日常")
        case .lowLight: L("Low Light", zh: "弱光夜景")
        case .tungsten: L("Tungsten", zh: "室内灯光")
        case .cinematic: L("Cinematic", zh: "电影感")
        case .vintage: L("Vintage", zh: "复古怀旧")
        case .bw: L("B&W", zh: "黑白")
        }
    }
}

extension Stock {
    /// The scene tags as the filter's cases; an unknown tag is dropped.
    var scenes: [FilmScene] { (tags ?? []).compactMap(FilmScene.init(rawValue:)) }

    var artURL: URL? {
        art.flatMap { StockCatalog.bundle.url(forResource: $0, withExtension: nil, subdirectory: "Resources/StockArt") }
    }

    /// A colour negative, the one kind whose rendered grain does not yet vary
    /// by stock (PRD §3.6, research/colour-film-granularity.md §3).
    var isColourNegative: Bool { isFilm && !isPositive && !isMonochrome }

    /// What the card's second line says: the kind, then the speed.
    @MainActor var kindLine: String {
        var parts: [String] = []
        if isPaper {
            parts.append(isMonochrome ? L("Black-and-white paper", zh: "黑白相纸")
                         : isCine ? L("Release print film", zh: "电影拷贝片")
                         : L("Colour paper", zh: "彩色相纸"))
        } else if isMonochrome {
            parts.append(L("Black-and-white negative", zh: "黑白负片"))
        } else if isCine {
            parts.append(illuminant == "T" ? L("Tungsten motion-picture negative", zh: "灯光型电影负片")
                         : L("Daylight motion-picture negative", zh: "日光型电影负片"))
        } else if isPositive {
            parts.append(L("Slide film", zh: "反转片"))
        } else {
            parts.append(L("Colour negative", zh: "彩色负片"))
        }
        if let iso { parts.append("ISO \(iso)") }
        if let push { parts.append(L("pushed \(push) stop\(push == 1 ? "" : "s")", zh: "增感 \(push) 档")) }
        return parts.joined(separator: " · ")
    }

    /// The row's system tooltip: the card in one sentence (PRD §3.7).
    @MainActor var guideHelp: String { guide?.summary ?? "" }
}

extension StockCatalog {
    /// The film groups with only `scene`'s films in them — and the selected
    /// film, which never disappears from the list (PRD §4.3). A group left
    /// empty is dropped, as `FilmSection` already drops empty groups.
    func filmGroups(scene: FilmScene?, keeping selected: String?) -> [(title: String, films: [Stock])] {
        guard let scene else { return filmGroups }
        return filmGroups.map { group in
            (group.title, group.films.filter { $0.scenes.contains(scene) || $0.id == selected })
        }.filter { !$0.films.isEmpty }
    }

    /// The films whose default paper is `paper`: the paper card's pairings.
    func films(printingOn paper: String) -> [Stock] {
        filmsForPicker.filter { $0.targetPrint == paper }
    }
}

extension FilmParams {
    /// The film list's rule, as a value: what choosing film `id` does.
    ///
    /// It used to live only in `Session.selectFilmStock` and
    /// `Session.applyFilmStageRule`, which change the frame on the canvas. A
    /// style is applied to frames that are not on the canvas too, so the rule
    /// has to be something a sidecar on disk can go through as well
    /// (PRD §10, acceptance A10).
    ///
    /// - The film's declared paper is taken, unless the paper is already it.
    /// - Silver film needs silver paper and colour needs colour; a pairing that
    ///   cannot print falls back to the film's declared paper.
    /// - A slide film is scanned. Its paper is left where it was, so going back
    ///   to a negative restores it.
    func choosingFilm(_ id: String, in catalog: StockCatalog) -> FilmParams {
        var p = self
        p.filmStock = id
        let film = catalog.stock(id)
        if let target = film?.targetPrint, catalog.stock(target) != nil,
           !catalog.isDeclaredPairing(film: id, paper: p.printStock) {
            p.printStock = target
        }
        if !catalog.canPrint(film: id, on: p.printStock) {
            p.printStock = film?.targetPrint ?? FilmParams.default.printStock
        }
        if film?.isPositive ?? false { p.scanFilm = true }
        return p
    }
}
