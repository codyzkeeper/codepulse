import AppKit
import SwiftUI

/// AppKit-backed reorderable list. SwiftUI's List/onMove has no reliable
/// drag source on macOS when embedded in a Form, so this keeps the drag/drop
/// contract in NSTableView while leaving each row's controls SwiftUI-native.
struct LabelPriorityList: NSViewRepresentable {
    @Binding var rules: [ActionLabelRuleConfiguration]
    let labelCatalog: [GitHubLabelCatalogEntry]
    let setNotificationLevel: (NotificationLevel, String) -> Void
    let remove: (String) -> Void
    let save: () -> Void

    /// Applies NSTableView's proposed destination-row semantics to a stable
    /// value. Keeping this pure makes the boundary behavior testable without
    /// requiring a live drag session.
    static func reordered(
        _ rules: [ActionLabelRuleConfiguration],
        from source: Int,
        to proposedDestination: Int
    ) -> [ActionLabelRuleConfiguration] {
        guard rules.indices.contains(source) else { return rules }
        var result = rules
        var destination = max(0, min(proposedDestination, result.count))
        if source < destination { destination -= 1 }
        guard source != destination else { return result }
        let moved = result.remove(at: source)
        result.insert(moved, at: destination)
        return result
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            rules: $rules,
            labelCatalog: labelCatalog,
            setNotificationLevel: setNotificationLevel,
            remove: remove,
            save: save
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = 46
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.addTableColumn(NSTableColumn(identifier: Coordinator.columnID))
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.registerForDraggedTypes([.string])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.rules = $rules
        context.coordinator.labelCatalog = labelCatalog
        context.coordinator.setNotificationLevel = setNotificationLevel
        context.coordinator.remove = remove
        context.coordinator.save = save
        (scrollView.documentView as? NSTableView)?.reloadData()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let columnID = NSUserInterfaceItemIdentifier("label-priority")

        var rules: Binding<[ActionLabelRuleConfiguration]>
        var labelCatalog: [GitHubLabelCatalogEntry]
        var setNotificationLevel: (NotificationLevel, String) -> Void
        var remove: (String) -> Void
        var save: () -> Void

        init(
            rules: Binding<[ActionLabelRuleConfiguration]>,
            labelCatalog: [GitHubLabelCatalogEntry],
            setNotificationLevel: @escaping (NotificationLevel, String) -> Void,
            remove: @escaping (String) -> Void,
            save: @escaping () -> Void
        ) {
            self.rules = rules
            self.labelCatalog = labelCatalog
            self.setNotificationLevel = setNotificationLevel
            self.remove = remove
            self.save = save
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rules.wrappedValue.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard rules.wrappedValue.indices.contains(row) else { return nil }
            let rule = rules.wrappedValue[row]
            let catalogEntry = labelCatalog.first { $0.key == rule.id }
            let rowView = LabelPriorityRow(
                rule: rule,
                catalogEntry: catalogEntry,
                setNotificationLevel: setNotificationLevel,
                remove: remove
            )
            let hostingView = NSHostingView(rootView: rowView)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            return hostingView
        }

        func tableView(
            _ tableView: NSTableView,
            pasteboardWriterForRow row: Int
        ) -> NSPasteboardWriting? {
            guard rules.wrappedValue.indices.contains(row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(String(row), forType: .string)
            return item
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation operation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard info.draggingPasteboard.string(forType: .string) != nil else { return [] }
            tableView.setDropRow(max(0, min(row, rules.wrappedValue.count)), dropOperation: .above)
            return .move
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard let sourceString = info.draggingPasteboard.string(forType: .string),
                  let source = Int(sourceString),
                  rules.wrappedValue.indices.contains(source) else { return false }

            let reordered = LabelPriorityList.reordered(
                rules.wrappedValue,
                from: source,
                to: row
            )
            guard reordered != rules.wrappedValue else { return true }
            rules.wrappedValue = reordered
            save()
            tableView.reloadData()
            return true
        }
    }
}

private struct LabelPriorityRow: View {
    let rule: ActionLabelRuleConfiguration
    let catalogEntry: GitHubLabelCatalogEntry?
    let setNotificationLevel: (NotificationLevel, String) -> Void
    let remove: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .help("Drag to change menu-bar dot priority")
            Circle()
                .fill(color(for: catalogEntry?.colorHex))
                .frame(width: 10, height: 10)
            Text(rule.labelName)
                .lineLimit(1)
            if catalogEntry == nil {
                Text("Unavailable")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            Menu {
                ForEach(NotificationLevel.allCases, id: \.self) { level in
                    Button {
                        setNotificationLevel(level, rule.id)
                    } label: {
                        if level == rule.notificationLevel {
                            Label(level.displayName, systemImage: "checkmark")
                        } else {
                            Text(level.displayName)
                        }
                    }
                }
            } label: {
                Label(rule.notificationLevel.displayName, systemImage: "bell")
                    .frame(minWidth: 105, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .help("Choose notification behavior for \(rule.labelName)")
            Button { remove(rule.id) } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove label")
        }
        .padding(.horizontal, 10)
    }

    private func color(for hex: String?) -> Color {
        guard let hex, let value = Int(hex, radix: 16) else { return .secondary }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
