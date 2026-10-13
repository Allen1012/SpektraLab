//  Style.swift — a look applied in one click (PRD/PRD-胶片指南卡片与风格.md §5).
//
//  A style is an **edit** recipe, the same kind of thing as the settings
//  clipboard, and it is applied the way a paste is: to every picked frame,
//  live and undoable on the canvas, on disk for the rest. There are two kinds:
//
//  - **Built in.** A film, optionally its paper, and the whole effects block.
//    Nothing else: not the film format (a property of the photograph — the
//    same style on 135 and 120 would otherwise give different grain), not the
//    exposure, white balance, placement, masks, geometry, Post-Dev, Film Edge
//    or Date Back (PRD §5.3).
//  - **The person's own.** A settings clip saved under a name: the ticked
//    clipboard groups and the frame's settings in them. RFC-027's paste rules
//    hold — a style carries settings, never solved numbers (PRD §5.4), which is
//    what the settings-clipboard PRD §7 reserved this shape for.
//
//  `applied(to:catalog:)` is Sidecar in, Sidecar out, so what a style *means*
//  is testable without a window, an engine or a file.

import Foundation

/// One of the looks the app ships (PRD appendix D).
struct BuiltInStyle: Identifiable, Sendable {
    let id: String
    let nameEN: String
    let nameZH: String
    let summaryEN: String
    let summaryZH: String
    let film: String
    /// Nil prints on the film's declared paper; ignored for a slide film.
    var paper: String? = nil
    var effects = EffectStrengths()
    var grainActive = true
    var halationActive = true
    var glareActive = true

    @MainActor var name: String { L(nameEN, zh: nameZH) }
    @MainActor var summary: String { L(summaryEN, zh: summaryZH) }

    /// The draft list (PRD appendix D, Q6). Every strength is the default: the
    /// first version tells the looks apart by film and paper alone.
    static let all: [BuiltInStyle] = [
        .init(id: "natural_portrait", nameEN: "Natural Portrait", nameZH: "自然人像",
              summaryEN: "Natural skin tones, wide latitude.", summaryZH: "肤色自然，宽容度大。",
              film: "kodak_portra_400", paper: "kodak_portra_endura"),
        .init(id: "soft_portrait", nameEN: "Soft Portrait", nameZH: "柔和人像",
              summaryEN: "Lower contrast, softer.", summaryZH: "反差更低、更柔和。",
              film: "kodak_portra_160", paper: "kodak_portra_endura"),
        .init(id: "airy", nameEN: "Airy", nameZH: "清淡色调",
              summaryEN: "Light colour leaning cyan-green.", summaryZH: "偏青绿的清淡色调。",
              film: "fujifilm_pro_400h", paper: "fujifilm_crystal_archive_typeii"),
        .init(id: "vivid_landscape", nameEN: "Vivid Landscape", nameZH: "浓郁风景",
              summaryEN: "Fine grain, rich colour.", summaryZH: "颗粒细、色彩浓。",
              film: "kodak_ektar_100", paper: "kodak_ultra_endura"),
        .init(id: "slide_landscape", nameEN: "Slide Landscape", nameZH: "反转片风光",
              summaryEN: "High saturation, high contrast, scanned without a paper.",
              summaryZH: "高饱和、高反差，直接扫描，不经相纸。",
              film: "fujifilm_velvia_100"),
        .init(id: "warm_vintage", nameEN: "Warm Vintage", nameZH: "复古暖调",
              summaryEN: "The warmth of an old snapshot.", summaryZH: "偏暖的老照片味道。",
              film: "kodak_gold_200", paper: "kodak_portra_endura"),
        .init(id: "cinema_day", nameEN: "Cinema Day", nameZH: "电影感·日景",
              summaryEN: "A motion-picture negative on a release print.", summaryZH: "电影负片加放映拷贝。",
              film: "kodak_vision3_250d", paper: "kodak_2383"),
        .init(id: "cinema_night", nameEN: "Cinema Night", nameZH: "电影感·夜景",
              summaryEN: "A tungsten motion-picture negative, for night and interiors.",
              summaryZH: "灯光型电影负片，适合夜景和室内。",
              film: "kodak_vision3_500t", paper: "kodak_2383"),
        neonNight,
        .init(id: "classic_bw", nameEN: "Classic B&W", nameZH: "经典黑白",
              summaryEN: "Visible grain, bold contrast.", summaryZH: "颗粒感和反差鲜明。",
              film: "kodak_tri_x_400", paper: "ilford_multigrade_iv_rc"),
        .init(id: "fine_bw", nameEN: "Fine B&W", nameZH: "细腻黑白",
              summaryEN: "Fine grain, clean tones.", summaryZH: "颗粒细、影调干净。",
              film: "kodak_tmax_100", paper: "ilford_multigrade_iv_rc"),
    ]

    /// 500T with its anti-halation layer removed (PRD Q7). `EffectStrengths`
    /// records why this is the large lever: on a night frame 0.07 % of pixels
    /// moved with the film's own layer and 10 % without it.
    private static let neonNight: BuiltInStyle = {
        var s = BuiltInStyle(id: "neon_night", nameEN: "Neon Night", nameZH: "霓虹夜景",
                             summaryEN: "The anti-halation layer removed: lights glow.",
                             summaryZH: "去掉防光晕层，灯光周围有明显辉光。",
                             film: "kodak_vision3_500t", paper: "kodak_2383")
        s.effects.antihalationRemoved = true
        return s
    }()

    /// What this style writes, and nothing else (PRD §5.3, R5, R6).
    func applied(to target: Sidecar, catalog: StockCatalog) -> Sidecar {
        var out = target
        var p = out.params.choosingFilm(film, in: catalog)
        if !(catalog.stock(film)?.isPositive ?? false) {
            // Choosing the paper, as the paper list does (`selectPrintStock`):
            // a print, not a scan and not the Digital Intermediate.
            if let paper, catalog.stock(paper) != nil, catalog.canPrint(film: film, on: paper) {
                p.printStock = paper
            }
            p.scanFilm = false
            p.digitalIntermediate = false
        }
        p.grainActive = grainActive
        p.halationActive = halationActive
        p.glareActive = glareActive
        p.effects = effects
        out.params = p
        return out
    }

    /// Why this style cannot be applied here, or nil when it can (PRD R12).
    @MainActor func unavailableReason(in catalog: StockCatalog) -> String? {
        guard catalog.stock(film) != nil else {
            return L("Its film is not available in this build.", zh: "它的胶片在这个版本里不可用。")
        }
        if let paper, !(catalog.stock(film)?.isPositive ?? false) {
            guard catalog.stock(paper) != nil, catalog.canPrint(film: film, on: paper) else {
                return L("Its paper is not available in this build.", zh: "它的相纸在这个版本里不可用。")
            }
        }
        return nil
    }
}

/// A style the person saved: the ticked clipboard groups of one frame.
struct UserStyle: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var groups: Set<ClipboardGroup>
    /// The groups' fields of the frame it was saved from, written over a blank
    /// sidecar: nothing outside the groups is kept — not the crop, not the
    /// file it came from (PRD §5.5).
    var settings: Sidecar
    var created = Date()

    init(name: String, groups: Set<ClipboardGroup>, from sidecar: Sidecar) {
        self.name = name
        self.groups = groups
        self.settings = SettingsClip(groups: groups, settings: sidecar, sourceName: "").applied(to: Sidecar())
    }

    /// Exactly a paste of the same groups (PRD R7).
    func applied(to target: Sidecar) -> Sidecar {
        SettingsClip(groups: groups, settings: settings, sourceName: name).applied(to: target)
    }

    /// Why this style cannot be applied here, or nil when it can.
    @MainActor func unavailableReason(in catalog: StockCatalog) -> String? {
        guard groups.contains(.filmAndPaper) else { return nil }
        let p = settings.params
        guard catalog.stock(p.filmStock) != nil else {
            return L("Its film is not available in this build.", zh: "它的胶片在这个版本里不可用。")
        }
        if !p.scanFilm, !p.digitalIntermediate,
           catalog.stock(p.printStock) == nil || !catalog.canPrint(film: p.filmStock, on: p.printStock) {
            return L("Its paper is not available in this build.", zh: "它的相纸在这个版本里不可用。")
        }
        return nil
    }

    /// The row's second line: which groups it carries.
    @MainActor var groupsLine: String {
        ClipboardGroup.allCases.filter(groups.contains).map(\.title).joined(separator: " · ")
    }
}

/// Either kind, for the one place both are applied.
enum Style: Sendable {
    case builtIn(BuiltInStyle)
    case user(UserStyle)

    func applied(to target: Sidecar, catalog: StockCatalog) -> Sidecar {
        switch self {
        case .builtIn(let s): s.applied(to: target, catalog: catalog)
        case .user(let s): s.applied(to: target)
        }
    }

    /// The groups whose side effects the live write must run: a built-in style
    /// changes the film and paper and the effects strengths, never the film
    /// format, so it needs none of Film Effects' (`recomputeFilmFormat`).
    var liveGroups: Set<ClipboardGroup> {
        switch self {
        case .builtIn: [.filmAndPaper]
        case .user(let s): s.groups
        }
    }

    @MainActor var name: String {
        switch self {
        case .builtIn(let s): s.name
        case .user(let s): s.name
        }
    }

    @MainActor func unavailableReason(in catalog: StockCatalog) -> String? {
        switch self {
        case .builtIn(let s): s.unavailableReason(in: catalog)
        case .user(let s): s.unavailableReason(in: catalog)
        }
    }
}
