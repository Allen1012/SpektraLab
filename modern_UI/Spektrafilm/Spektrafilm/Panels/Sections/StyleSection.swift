//  StyleSection.swift — the left rail's Styles (PRD/PRD-胶片指南卡片与风格.md §5).
//
//  Between the Settings Clipboard and Film: a style is a paste whose clip the
//  app or the person keeps. It goes to the same frames a paste goes to — the
//  frame on the canvas, or every picked frame (`Session.styleTargets`) — and
//  through the same write paths, so it undoes, saves and refuses the same way.
//
//  One click applies, with no confirmation (PRD Q9): ⌘Z takes it back on the
//  canvas, and the status line says how many frames were written.

import SwiftUI

struct StyleSection: View {
    @Bindable var session: Session

    @State private var saving = false
    @State private var newName = ""
    @State private var newGroups: Set<ClipboardGroup> = []
    @State private var saveError: String?
    @State private var renaming: UserStyle?
    @State private var renameText = ""
    @State private var renameError: String?
    @State private var deleting: UserStyle?

    var body: some View {
        PanelSection(L("Styles", zh: "风格"), key: "styles", initiallyExpanded: true) {
            RailRows {
                caption(L("Built in", zh: "内置"))
                ForEach(BuiltInStyle.all) { style in
                    StyleRow(name: style.name, detail: style.summary,
                             reason: reason(.builtIn(style))) {
                        session.applyStyle(.builtIn(style))
                    }
                }
                if !session.styleStore.styles.isEmpty {
                    caption(L("Mine", zh: "我的风格")).padding(.top, 4)
                    ForEach(session.styleStore.styles) { style in
                        StyleRow(name: style.name, detail: style.groupsLine,
                                 reason: reason(.user(style))) {
                            session.applyStyle(.user(style))
                        }
                        .contextMenu {
                            Button(L("Rename…", zh: "重命名…")) {
                                renameText = style.name; renameError = nil; renaming = style
                            }
                            Button(L("Delete…", zh: "删除…"), role: .destructive) { deleting = style }
                        }
                    }
                }
                if session.styleTargets.count > 1 {
                    note(String(format: L("Applies to the %d picked photos.", zh: "将应用到已选的 %d 张照片。"),
                                session.styleTargets.count))
                }
                if let problem = session.styleStore.problem {
                    note(problem).foregroundStyle(Theme.accent)
                }
                HStack {
                    Button { openSave() } label: {
                        Text(L("Save as Style…", zh: "＋ 存为风格"))
                            .font(Theme.Font.value)
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 12)
                            .frame(height: Theme.Metric.controlHeight)
                            .background(Theme.pill, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .rowEnabled(session.styleBlockedReason == nil, because: session.styleBlockedReason ?? "")
                    .help(L("Keep the ticked groups of this photo as a style of your own.",
                            zh: "把这张照片勾选分组的设置存为自己的风格。"))
                    .popover(isPresented: $saving, arrowEdge: .trailing) { saveForm }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
        .alert(L("Rename Style", zh: "重命名风格"),
               isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Name", zh: "名称"), text: $renameText)
            Button(L("Rename", zh: "重命名")) { commitRename() }
            Button(L("Cancel", zh: "取消"), role: .cancel) { renaming = nil }
        } message: {
            if let renameError { Text(renameError) }
        }
        .confirmationDialog(String(format: L("Delete “%@”?", zh: "删除“%@”？"), deleting?.name ?? ""),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L("Delete", zh: "删除"), role: .destructive) {
                if let d = deleting { session.styleStore.delete(d.id) }
                deleting = nil
            }
            Button(L("Cancel", zh: "取消"), role: .cancel) { deleting = nil }
        } message: {
            Text(L("Photos it was applied to keep their settings.", zh: "已应用过的照片会保留各自的设置。"))
        }
    }

    /// Why a row cannot be applied: the session's reason first, then the style's.
    private func reason(_ style: Style) -> String? {
        session.styleBlockedReason ?? style.unavailableReason(in: session.catalog)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.stockGroup)
            .foregroundStyle(Theme.Ink.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.meta)
            .foregroundStyle(Theme.Ink.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Saving

    /// The form starts from the clipboard's boxes, the closest thing the app
    /// has to "what this person means by a look" (PRD §5.4).
    private func openSave() {
        newName = ""
        newGroups = session.clipboardGroups.intersection(ClipboardGroup.offered)
        saveError = nil
        saving = true
    }

    private var saveForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Save as Style", zh: "存为风格"))
                .font(Theme.Font.body.weight(.semibold))
            TextField(L("Name", zh: "名称"), text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commitSave)
            ForEach(ClipboardGroup.offered) { group in
                Toggle(group.title, isOn: Binding(get: { newGroups.contains(group) },
                                                  set: { on in
                                                      if on { newGroups.insert(group) } else { newGroups.remove(group) }
                                                  }))
                    .help(group.help)
            }
            Text(String(format: L("“%@” includes the film format.", zh: "“%@”包含胶片画幅。"),
                        ClipboardGroup.filmEffects.title))
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Ink.tertiary)
            if let saveError {
                Text(saveError).font(Theme.Font.meta).foregroundStyle(Theme.accent)
            }
            HStack {
                Spacer()
                Button(L("Cancel", zh: "取消")) { saving = false }
                    .keyboardShortcut(.cancelAction)
                Button(L("Save", zh: "保存"), action: commitSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newGroups.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private func commitSave() {
        guard !newGroups.isEmpty else { return }
        do {
            try session.saveStyle(named: newName, groups: newGroups)
            saving = false
        } catch {
            saveError = message(for: error)
        }
    }

    private func commitRename() {
        guard let style = renaming else { return }
        do {
            try session.styleStore.rename(style.id, to: renameText)
            renaming = nil
        } catch {
            // An alert closes on any button; the reason goes to the status
            // line rather than vanishing with it.
            session.status = message(for: error)
            renaming = nil
        }
    }

    private func message(for error: Error) -> String {
        switch error as? StyleStore.Failure {
        case .emptyName: L("Give the style a name.", zh: "请输入风格名称。")
        case .duplicateName: L("A style with that name already exists.", zh: "已有同名风格。")
        case nil: error.localizedDescription
        }
    }
}

/// One style: its name, and under it what it is or what it carries.
private struct StyleRow: View {
    let name: String
    let detail: String
    /// Why it cannot be applied, or nil.
    let reason: String?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(Theme.Font.stockItem)
                .foregroundStyle(Theme.Ink.secondary)
            if !detail.isEmpty {
                Text(detail)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Ink.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .rowEnabled(reason == nil, because: reason ?? "")
    }
}
