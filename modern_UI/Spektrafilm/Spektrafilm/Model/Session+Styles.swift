//  Session+Styles.swift — applying and saving styles (PRD/PRD-胶片指南卡片与风格.md §5).
//
//  A style goes where a paste goes and the way a paste goes: the frame on the
//  canvas live and undoably, every other picked frame on disk at once
//  (`writeSettingsLive` / `writeSettingsOffline`, the clipboard's own two
//  halves). There is no second write path to drift from the clipboard's.

import Foundation

extension Session {
    /// Who a style is applied to: exactly who a paste goes to (PRD R4).
    var styleTargets: [URL] { pasteTargets }

    /// Why no style can be applied right now, or nil (PRD R10).
    var styleBlockedReason: String? {
        if batchExporting { return L("A batch export is running.", zh: "正在批量导出。") }
        if selection == nil { return L("Open a photo first.", zh: "请先打开一张照片。") }
        return nil
    }

    func applyStyle(_ style: Style) {
        guard let open = selection, !batchExporting else { return }
        if let why = style.unavailableReason(in: catalog) { status = why; return }
        let catalog = self.catalog
        let transform: (Sidecar) -> Sidecar = { style.applied(to: $0, catalog: catalog) }
        let targets = styleTargets
        var written = 0, failed = 0
        for url in targets where url != open {
            switch writeSettingsOffline(to: url, operation: "style", transform) {
            case .written: written += 1
            case .failed: failed += 1
            case .unchanged: break
            }
        }
        if targets.contains(open), writeSettingsLive(groups: style.liveGroups, transform) { written += 1 }
        let name = style.name
        if failed > 0 {
            status = String(format: L("“%@”: %d written, %d failed.", zh: "“%@”：写入 %d 张，失败 %d 张。"),
                            name, written, failed)
        } else if written == 0 {
            status = String(format: L("“%@”: the frames already have this style.", zh: "“%@”：这些照片已经是这个风格。"),
                            name)
        } else {
            status = String(format: L("“%@” applied to %d frame(s).", zh: "已将“%@”应用到 %d 张照片。"),
                            name, written)
        }
    }

    /// Save the ticked groups of the frame on the canvas as a style (PRD §5.4).
    func saveStyle(named name: String, groups: Set<ClipboardGroup>) throws {
        guard selection != nil else { return }
        let style = try styleStore.add(name: name, groups: groups, from: sidecar)
        status = String(format: L("Saved style “%@”.", zh: "已保存风格“%@”。"), style.name)
    }
}
