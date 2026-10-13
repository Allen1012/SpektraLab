//  StyleStore.swift — the person's own styles, in a JSON file they can open.
//
//  `~/Library/Application Support/SpektraLab/styles.json`, on the rules the
//  export recipes keep (`ExportRecipeStore`): written atomically, read once,
//  and **never fatal** (PRD §5.5). A file that cannot be read leaves only the
//  built-in styles and says so; it is set aside, not overwritten, the first
//  time a style is saved, so a hand-edited file with a typo is not lost.

import Foundation
import Observation

@MainActor
@Observable
final class StyleStore {
    private(set) var styles: [UserStyle] = []
    /// Set when the file could not be read or written, for the section to show.
    private(set) var problem: String?

    static let url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "SpektraLab").appending(path: "styles.json")

    /// Injectable: a test that used the real path would rewrite the person's
    /// own styles, which is not a thing a test may do.
    let url: URL
    /// The file did not parse; set it aside before the first save.
    private var unreadable = false

    private struct File: Codable {
        var version = 1
        var styles: [UserStyle]
    }

    enum Failure: Error, Equatable {
        case emptyName, duplicateName
    }

    init(url: URL = StyleStore.url) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
            styles = file.styles
        } catch {
            unreadable = true
            problem = L("Your saved styles could not be read; only the built-in ones are shown.",
                        zh: "无法读取已保存的风格，只显示内置风格。")
        }
    }

    /// Save a style from the frame's settings. The name must be new among
    /// the built-in styles and the person's own, in either language.
    @discardableResult
    func add(name: String, groups: Set<ClipboardGroup>, from sidecar: Sidecar) throws -> UserStyle {
        let trimmed = try validated(name, except: nil)
        let style = UserStyle(name: trimmed, groups: groups, from: sidecar)
        styles.append(style)
        save()
        return style
    }

    func rename(_ id: UUID, to name: String) throws {
        let trimmed = try validated(name, except: id)
        guard let i = styles.firstIndex(where: { $0.id == id }) else { return }
        styles[i].name = trimmed
        save()
    }

    func delete(_ id: UUID) {
        styles.removeAll { $0.id == id }
        save()
    }

    private func validated(_ name: String, except id: UUID?) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyName }
        let key = trimmed.lowercased()
        let taken = BuiltInStyle.all.flatMap { [$0.nameEN, $0.nameZH] }
            + styles.filter { $0.id != id }.map(\.name)
        guard !taken.contains(where: { $0.lowercased() == key }) else { throw Failure.duplicateName }
        return trimmed
    }

    private func save() {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if unreadable, fm.fileExists(atPath: url.path) {
                let stamp = Int(Date().timeIntervalSince1970)
                let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
                try fm.moveItem(at: url, to: aside)
            }
            unreadable = false
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(File(styles: styles)).write(to: url, options: .atomic)
            problem = nil
        } catch {
            problem = L("Your styles could not be saved: \(error.localizedDescription)",
                        zh: "风格保存失败：\(error.localizedDescription)")
        }
    }
}
