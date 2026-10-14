import AppKit
import UniformTypeIdentifiers

final class ActionButton: NSButton {
    var invoke: (() -> Void)?
    convenience init(_ title: String, _ action: @escaping () -> Void) {
        self.init(frame: .zero); self.title = title; bezelStyle = .rounded; target = self; self.action = #selector(fire); invoke = action
    }
    @objc private func fire() { invoke?() }
}
func label(_ value: String, bold: Bool = false) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: value); field.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13); return field
}
func stack(_ views: [NSView], vertical: Bool = false) -> NSStackView {
    let view = NSStackView(views: views); view.orientation = vertical ? .vertical : .horizontal; view.alignment = vertical ? .leading : .centerY; view.spacing = 10; return view
}
func fill(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
    parent.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset), child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset), child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset), child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)])
}
func errorAlert(_ error: Error) {
    let alert = NSAlert(); alert.messageText = "PrintDeployGPO"; alert.informativeText = error.localizedDescription; alert.alertStyle = .warning; alert.runModal()
}

final class DataTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    let scroll = NSScrollView()
    var rows = [[String: String]]()
    var selectionChanged: (() -> Void)?
    var toggle: ((Int, Bool) -> Void)?
    var removable: ((Int) -> Bool)?
    init(_ columns: [(String, String, CGFloat)]) {
        super.init()
        for (id, title, width) in columns { let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; column.minWidth = id == "Remove" ? 55 : 70; table.addTableColumn(column) }
        table.dataSource = self; table.delegate = self; table.rowHeight = 32; table.usesAlternatingRowBackgroundColors = true; table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.style = .inset
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0 && row < rows.count, let column = tableColumn else { return nil }
        let key = column.identifier.rawValue
        if key == "Remove" {
            let button = ActionButton("") { [weak self] in guard let self = self else { return }; self.toggle?(row, self.rows[row][key] != "1") }
            button.setButtonType(.switch); button.state = rows[row][key] == "1" ? .on : .off; button.isEnabled = removable?(row) ?? false; button.toolTip = rows[row]["Status"]
            return button
        }
        let field = NSTextField(labelWithString: rows[row][key] ?? ""); field.lineBreakMode = .byTruncatingTail; field.toolTip = field.stringValue; return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanged?() }
    func replace(_ rows: [[String: String]], selected: Int = -1) {
        self.rows = rows; table.reloadData()
        if selected >= 0 && selected < rows.count { table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
    }
}

final class PrinterEditor: NSObject, NSWindowDelegate {
    let model: DeploymentModel
    let original: JSON
    let originalEndpoint: IppEndpoint?
    let dialog = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let name = NSTextField(), host = NSTextField(), path = NSTextField(string: "/ipp"), port = NSTextField(string: "631"), location = NSTextField(), comment = NSTextField()
    let kind = NSPopUpButton(), scheme = NSPopUpButton(), driver = NSPopUpButton()
    let packageLabel = NSTextField(wrappingLabelWithString: "Import the full extracted vendor package.")
    var packagePath = "", infPath = ""
    let customPort = NSButton(checkboxWithTitle: "Custom port", target: nil, action: nil)
    var result: JSON?
    var tcpPort = "9100", ippPort = "631", lastKind = ""
    var protocolRow: NSView!, pathRow: NSView!, packageRow: NSView!, driverRow: NSView!
    init(model: DeploymentModel, printer: JSON? = nil) {
        self.model = model; original = printer ?? [:]; originalEndpoint = try? IppEndpoint.parse(text(printer ?? [:], "Address")); super.init()
        dialog.title = printer == nil ? "Add printer" : "Edit printer"; dialog.isReleasedWhenClosed = false; dialog.delegate = self
        kind.addItems(withTitles: ["IPP", "Type4", "Type3"]); scheme.addItems(withTitles: ["ipp", "ipps"])
        func row(_ title: String, _ field: NSView) -> NSView {
            let caption = label(title); caption.widthAnchor.constraint(equalToConstant: 150).isActive = true
            let row = stack([caption, field]); field.widthAnchor.constraint(greaterThanOrEqualToConstant: 370).isActive = true; return row
        }
        let portField = stack([customPort, port]); port.widthAnchor.constraint(equalToConstant: 100).isActive = true
        protocolRow = row("Protocol", scheme); pathRow = row("Subpath", path)
        let importButton = ActionButton("Import driver package…") { [weak self] in self?.importDriver() }
        packageRow = row("Driver package", stack([packageLabel, importButton], vertical: true)); driverRow = row("Driver name", driver)
        let hint = label("Enter only an IP address or hostname. IPP/IPPS use port 631 automatically. For IPPS, use a hostname matching a trusted printer certificate.")
        hint.textColor = .secondaryLabelColor
        let save = ActionButton("Save printer") { [weak self] in self?.save() }; save.keyEquivalent = "\r"
        let cancel = ActionButton("Cancel") { [weak self] in NSApp.stopModal(withCode: .cancel); self?.dialog.orderOut(nil) }; cancel.keyEquivalent = "\u{1b}"
        let body = stack([row("Printer name", name), row("Connection", kind), row("IP / hostname", host), protocolRow, pathRow, row("Port", portField), row("Location", location), row("Comment", comment), packageRow, driverRow, hint, stack([cancel, save])], vertical: true)
        body.spacing = 14; fill(body, in: dialog.contentView!, inset: 22)
        name.stringValue = text(original, "Name"); host.stringValue = text(original, "Address"); location.stringValue = text(original, "Location"); comment.stringValue = text(original, "Comment")
        packagePath = text(original, "PackagePath"); infPath = text(original, "InfPath")
        if let endpoint = originalEndpoint {
            host.stringValue = endpoint.host; path.stringValue = endpoint.path
            if !scheme.itemTitles.contains(endpoint.scheme) { scheme.addItem(withTitle: endpoint.scheme) }; scheme.selectItem(withTitle: endpoint.scheme)
            port.stringValue = String(endpoint.port); ippPort = port.stringValue; customPort.state = endpoint.port == IppEndpoint.defaultPort(endpoint.scheme) ? .off : .on
        }
        if !text(original, "Kind").isEmpty { kind.selectItem(withTitle: text(original, "Kind")) }
        if text(original, "Kind") != "IPP", let number = original["PortNumber"] as? Int { tcpPort = String(number) }
        kind.target = self; kind.action = #selector(kindChanged); scheme.target = self; scheme.action = #selector(protocolChanged); customPort.target = self; customPort.action = #selector(protocolChanged)
        kindChanged()
        if !infPath.isEmpty, text(original, "Kind") != "IPP", let root = model.root {
            do { let values = try INFModels.read(DeploymentModel.resource(root, infPath), architecture: text(model.config, "Architecture"), type: kind.titleOfSelectedItem == "Type3" ? 3 : 4); driver.addItems(withTitles: values); driver.selectItem(withTitle: text(original, "DriverName")); packageLabel.stringValue = infPath }
            catch { packageLabel.stringValue = "Package needs attention: \(error.localizedDescription)" }
        }
    }
    @objc func kindChanged() {
        if lastKind == "IPP" { ippPort = port.stringValue } else if !lastKind.isEmpty { tcpPort = port.stringValue }
        let current = kind.titleOfSelectedItem ?? "IPP", ipp = current == "IPP"
        if !lastKind.isEmpty && lastKind != "IPP" && current != "IPP" && lastKind != current { packagePath = ""; infPath = ""; driver.removeAllItems(); packageLabel.stringValue = "Import a package for \(current)." }
        protocolRow.isHidden = !ipp; pathRow.isHidden = !ipp; packageRow.isHidden = ipp; driverRow.isHidden = ipp; customPort.isHidden = !ipp
        port.stringValue = ipp ? ippPort : tcpPort; port.isEnabled = !ipp || customPort.state == .on; lastKind = current
    }
    @objc func protocolChanged() {
        if kind.titleOfSelectedItem == "IPP" { port.isEnabled = customPort.state == .on; if !port.isEnabled { port.stringValue = String(IppEndpoint.defaultPort(scheme.titleOfSelectedItem ?? "ipp")) } }
    }
    func importDriver() {
        let folder = NSOpenPanel(); folder.canChooseDirectories = true; folder.canChooseFiles = false; folder.prompt = "Choose package"; folder.message = "Choose the complete extracted vendor driver folder."
        guard folder.runModal() == .OK, let source = folder.url else { return }
        let picker = NSOpenPanel(); picker.directoryURL = source; picker.allowedContentTypes = [UTType(filenameExtension: "inf") ?? .data]; picker.message = "Select the printer INF inside this package."
        guard picker.runModal() == .OK, let inf = picker.url else { return }
        do { let imported = try model.importPackage(source, inf: inf, type: kind.titleOfSelectedItem == "Type3" ? 3 : 4); packagePath = imported.0; infPath = imported.1; packageLabel.stringValue = infPath; driver.removeAllItems(); driver.addItems(withTitles: imported.2) } catch { errorAlert(error) }
    }
    func makePrinter() throws -> JSON {
        var printer = original
        let kind = self.kind.titleOfSelectedItem ?? "IPP"
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var address = trim(host.stringValue)
        guard let portNumber = Int(port.stringValue), (1...65535).contains(portNumber) else { throw DeploymentError("Port must be between 1 and 65535.") }
        if kind == "IPP" {
            let endpoint = IppEndpoint(host: address, scheme: scheme.titleOfSelectedItem ?? "ipp", path: path.stringValue, port: portNumber)
            address = endpoint == originalEndpoint ? text(original, "Address") : try endpoint.address()
        }
        printer.merge(["Name": trim(name.stringValue), "Kind": kind, "Address": address, "PortNumber": portNumber, "Location": trim(location.stringValue), "Comment": trim(comment.stringValue), "PackagePath": packagePath, "InfPath": infPath, "DriverName": driver.titleOfSelectedItem ?? ""]) { _, new in new }
        guard let root = model.root else { throw DeploymentError("Open a deployment first.") }
        var validation = DeploymentModel.freshConfig(); validation["Architecture"] = model.config["Architecture"]; validation["Printers"] = [printer]
        try DeploymentModel.validate(validation, root: root); return printer
    }
    func save() { do { result = try makePrinter(); NSApp.stopModal(withCode: .OK); dialog.orderOut(nil) } catch { errorAlert(error) } }
    func run() -> JSON? { dialog.center(); dialog.makeKeyAndOrderFront(nil); _ = NSApp.runModal(for: dialog); dialog.orderOut(nil); return result }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if NSApp.modalWindow === dialog { NSApp.stopModal(withCode: .cancel) }; return true }
}

final class ConfiguratorController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    let model = DeploymentModel()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    let folderLabel = NSTextField(labelWithString: "Open printers.json from a local folder or a Finder-mounted SMB share.")
    let status = NSTextField(labelWithString: "Ready")
    let windowsRoot = NSTextField(), architecture = NSPopUpButton()
    let tabs = NSTabView()
    let printerTable = DataTable([("Name", "Printer", 220), ("Kind", "Type", 80), ("Address", "Endpoint", 330), ("Driver", "Driver", 220), ("Location", "Location", 130)])
    let computerTable = DataTable([("Name", "Computer", 160), ("Status", "Status", 250), ("Installed", "Deployed", 110), ("Users", "User reports", 110), ("Reported", "Latest report", 250)])
    let inventoryTable = DataTable([("Remove", "Remove", 60), ("Name", "Printer", 230), ("Owner", "Installed for", 170), ("Driver", "Driver", 200), ("Port", "Port", 150), ("Status", "Removal status", 230)])
    let requestTable = DataTable([("Name", "Printer", 240), ("Owner", "Installed for", 180), ("Status", "Status", 120), ("Message", "Last result", 460)])
    let detail = NSTextField(wrappingLabelWithString: "User connections appear after the user logon script uploads a report.")
    let stale = NSButton(checkboxWithTitle: "Remove printers previously managed by this deployment when they leave the configuration", target: nil, action: nil)
    let userCleanup = NSButton(checkboxWithTitle: "Remove listed legacy names from user connections too (does not enable reporting)", target: nil, action: nil)
    let legacy = NSTextView()
    var computers = [ComputerInventory](), entries = [InventoryEntry](), selectedRequests = [JSON]()
    var loading = false
    let source: URL
    init(source: URL) {
        self.source = source; super.init()
        window.title = "PrintDeployGPO"; window.minSize = NSSize(width: 950, height: 680); window.delegate = self; window.isReleasedWhenClosed = false
        let title = label("PrintDeployGPO", bold: true); title.font = .boldSystemFont(ofSize: 23)
        let subtitle = label("Manage Windows printer deployments from your Mac."); subtitle.textColor = .secondaryLabelColor
        let top = stack([title, subtitle, ActionButton("Open JSON…") { [weak self] in self?.chooseOpen() }, ActionButton("New deployment…") { [weak self] in self?.createDeployment() }])
        architecture.addItems(withTitles: ["x64", "ARM64"]); architecture.target = self; architecture.action = #selector(settingsChanged)
        windowsRoot.placeholderString = "\\\\fileserver\\Software\\Printers"; windowsRoot.delegate = self
        let settings = stack([label("Driver models"), architecture, label("Windows UNC folder"), windowsRoot]); windowsRoot.widthAnchor.constraint(greaterThanOrEqualToConstant: 450).isActive = true
        let bottom = stack([ActionButton("Save JSON") { [weak self] in self?.save(export: false) }, ActionButton("Save deployment bundle") { [weak self] in self?.save(export: true) }, ActionButton("Validate") { [weak self] in self?.validate() }, ActionButton("Reload") { [weak self] in self?.reload() }])
        let body = stack([top, folderLabel, settings, tabs, bottom, status], vertical: true); body.spacing = 14
        fill(body, in: window.contentView!, inset: 20)
        for view in [top, folderLabel, settings, tabs, bottom, status] { view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 410).isActive = true
        tabs.setContentHuggingPriority(.defaultLow, for: .vertical)
        status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingMiddle; folderLabel.lineBreakMode = .byTruncatingMiddle
        addPrinterTab(); addComputerTab(); addDeploymentTab(); addCleanupTab()
        printerTable.selectionChanged = { }; computerTable.selectionChanged = { [weak self] in self?.showComputer() }
        inventoryTable.removable = { [weak self] row in guard let self = self, self.entries.indices.contains(row) else { return false }; return self.entries[row].canRemove && !self.model.printers.contains { same(text($0, "Name"), text(self.entries[row].printer, "Name")) } }
        inventoryTable.toggle = { [weak self] row, value in
            guard let self = self, self.entries.indices.contains(row) else { return }
            do { try self.model.selectRemoval(self.entries[row], selected: value); self.showComputer(); self.updateStatus("Removal selections changed. Save JSON or the deployment bundle to publish.") } catch { errorAlert(error) }
        }
        stale.target = self; stale.action = #selector(settingsChanged); userCleanup.target = self; userCleanup.action = #selector(settingsChanged)
        NotificationCenter.default.addObserver(self, selector: #selector(legacyChanged), name: NSText.didChangeNotification, object: legacy)
    }
    func addTab(_ title: String, _ body: NSView) { let item = NSTabViewItem(identifier: title); item.label = title; let holder = NSView(); fill(body, in: holder, inset: 16); item.view = holder; tabs.addTabViewItem(item) }
    func addPrinterTab() {
        let actions = stack([ActionButton("Add printer…") { [weak self] in self?.editPrinter(new: true) }, ActionButton("Edit…") { [weak self] in self?.editPrinter(new: false) }, ActionButton("Stop deploying") { [weak self] in self?.removePrinter() }])
        let body = stack([printerTable.scroll, actions], vertical: true); printerTable.scroll.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true; printerTable.scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        addTab("Printers", body)
    }
    func addComputerTab() {
        let nested = NSTabView(); let inventoryItem = NSTabViewItem(identifier: "inventory"); inventoryItem.label = "Reported printers"; inventoryItem.view = inventoryTable.scroll
        let requestsItem = NSTabViewItem(identifier: "requests"); requestsItem.label = "Removal requests"
        let clear = ActionButton("Clear selected request") { [weak self] in self?.clearRequest() }
        let requestBody = stack([requestTable.scroll, clear], vertical: true); requestTable.scroll.widthAnchor.constraint(equalTo: requestBody.widthAnchor).isActive = true; requestTable.scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true; requestsItem.view = requestBody
        nested.addTabViewItem(inventoryItem); nested.addTabViewItem(requestsItem)
        let hint = label("Select a computer, then check unwanted printers. Removal runs on the next SYSTEM task or the owning user's next logon."); hint.textColor = .secondaryLabelColor
        let body = stack([stack([ActionButton("Refresh computers") { [weak self] in self?.refreshReports() }, ActionButton("Open Client Logs in Finder") { [weak self] in self?.showLogs() }]), computerTable.scroll, detail, nested, hint], vertical: true)
        computerTable.scroll.heightAnchor.constraint(equalToConstant: 140).isActive = true; detail.heightAnchor.constraint(lessThanOrEqualToConstant: 85).isActive = true; nested.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        for view in [computerTable.scroll, detail, nested, hint] { view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        addTab("Computers", body)
    }
    func addCleanupTab() {
        legacy.isRichText = false; legacy.font = .monospacedSystemFont(ofSize: 13, weight: .regular); legacy.isAutomaticQuoteSubstitutionEnabled = false
        let scroll = NSScrollView(); scroll.documentView = legacy; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let hint = label("Use Computers for one-time removals. These advanced rules remove exact legacy names on every run. Remove obsolete printer GPO mappings so deleted queues are not recreated.")
        let body = stack([hint, stale, userCleanup, label("Legacy printer names, one per line; no wildcards:"), scroll], vertical: true)
        scroll.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true; hint.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        addTab("Advanced cleanup", body)
    }
    func addDeploymentTab() {
        let steps = label("1. Mount the share in Finder (Go → Connect to Server → smb://server/share). Open its printers.json, or create a deployment folder.\n\n2. Enter that folder's Windows UNC path above, then Save deployment bundle.\n\n3. Add Install-PrinterDeploymentTask.ps1 to Computer GPO → Startup → PowerShell Scripts. Leave parameters blank. It creates ONE SYSTEM scheduled task.\n\n4. Add Report-UserPrinters.ps1 to User GPO → Logon → PowerShell Scripts. Leave parameters blank. It creates NO task and reports each user's shared-printer connections.\n\n5. In Computers, refresh reports and select unwanted queues. Save your changes. Stop deploying managed printers before selecting them for removal.\n\nIPP printers work on x64 and ARM64. Driver models selects which INF names to browse; clients check their native architecture and skip incompatible packages. Both GUIs edit the same schema and preserve DeploymentId. Use one administrator at a time; saving checks for concurrent file changes.")
        let permissions = label("Configure SMB and NTFS permissions from Windows: reporting computers/users need SMB Change, NTFS Read on scripts/config/drivers, and write/create-own-folder access only inside Client Logs. The Mac app creates that folder but cannot apply the Windows public log ACL. Use the Windows GUI's Set public log access button or configure the ACL on the server. Sign exported scripts if your policy requires it.")
        permissions.textColor = .secondaryLabelColor
        let body = stack([label("One scheduled task, plus a user logon script", bold: true), steps, permissions], vertical: true)
        steps.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true; permissions.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        addTab("Deployment", body)
    }
    func discardChanges() -> Bool {
        if !model.dirty { return true }
        let alert = NSAlert(); alert.messageText = "Discard unsaved changes?"; alert.informativeText = "Your printer and removal edits have not been saved."; alert.addButton(withTitle: "Keep editing"); alert.addButton(withTitle: "Discard changes")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func chooseOpen() { let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; guard panel.runModal() == .OK, let url = panel.url else { return }; open(url) }
    func open(_ url: URL) {
        guard discardChanges() else { return }
        do { try model.open(url); loadControls(); refreshReports() } catch { errorAlert(error) }
    }
    func createDeployment() {
        guard discardChanges() else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "Use folder"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do { try model.create(in: folder); loadControls(); refreshReports(); updateStatus("New deployment. Enter the Windows UNC folder before exporting a bundle.") } catch { errorAlert(error) }
    }
    func loadControls() {
        loading = true; architecture.selectItem(withTitle: text(model.config, "Architecture")); let cleanup = model.config["Cleanup"] as? JSON ?? [:]
        stale.state = flag(cleanup, "RemoveStaleManaged") ? .on : .off; userCleanup.state = flag(cleanup, "CleanupUserConnections") ? .on : .off; legacy.string = (cleanup["LegacyPrinterNames"] as? [String] ?? []).joined(separator: "\n")
        folderLabel.stringValue = model.configURL?.path ?? "No deployment open"
        windowsRoot.stringValue = model.root.flatMap { UserDefaults.standard.string(forKey: "UNC:" + $0.path) } ?? inferredUNC()
        loading = false; refreshPrinters(); updateStatus("Configuration loaded. Deployment identity preserved.")
    }
    func inferredUNC() -> String {
        guard let root = model.root, let source = try? String(contentsOf: root.appendingPathComponent("Install-PrinterDeploymentTask.ps1"), encoding: .utf8),
              let expression = try? NSRegularExpression(pattern: "(?m)^\\s*\\$root = '((?:[^']|'')*)'\\r?$"), let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), let range = Range(match.range(at: 1), in: source) else { return "" }
        return String(source[range]).replacingOccurrences(of: "''", with: "'")
    }
    @objc func settingsChanged() { if loading { return }; model.config["Architecture"] = architecture.titleOfSelectedItem; var cleanup = model.config["Cleanup"] as? JSON ?? [:]; cleanup["RemoveStaleManaged"] = stale.state == .on; cleanup["CleanupUserConnections"] = userCleanup.state == .on; cleanup["LegacyPrinterNames"] = legacy.string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }; model.config["Cleanup"] = cleanup; model.dirty = true; updateStatus("Unsaved configuration changes.") }
    @objc func legacyChanged() { settingsChanged() }
    func controlTextDidChange(_ obj: Notification) { updateStatus("Windows UNC path is used for bundle exports and stored locally on this Mac.") }
    func updateStatus(_ message: String) { status.stringValue = message; window.isDocumentEdited = model.dirty; window.representedURL = model.configURL }
    func refreshPrinters() { printerTable.replace(model.printers.map { ["Name": text($0, "Name"), "Kind": text($0, "Kind"), "Address": text($0, "Address"), "Driver": text($0, "Kind") == "IPP" ? "Microsoft IPP Class Driver" : text($0, "DriverName"), "Location": text($0, "Location")] }) }
    func editPrinter(new: Bool) {
        guard model.root != nil else { errorAlert(DeploymentError("Open or create a deployment first.")); return }
        let row = printerTable.table.selectedRow; if !new && !model.printers.indices.contains(row) { return }
        let editor = PrinterEditor(model: model, printer: new ? nil : model.printers[row])
        if let printer = editor.run() {
            var values = model.printers
            if values.enumerated().contains(where: { ($0.offset != row || new) && same(text($0.element, "Name"), text(printer, "Name")) }) { errorAlert(DeploymentError("A printer with that name already exists.")); return }
            if new { values.append(printer) } else { values[row] = printer }; model.printers = values; refreshPrinters(); showComputer(); updateStatus("Printer updated. Save to publish.")
        }
    }
    func removePrinter() { let row = printerTable.table.selectedRow; guard model.printers.indices.contains(row) else { return }; var values = model.printers; let name = text(values.remove(at: row), "Name"); model.printers = values; refreshPrinters(); showComputer(); updateStatus("Stopped deploying \(name). Select its reported queues in Computers to remove them, or use stale managed cleanup.") }
    func save(export: Bool) {
        do {
            if export { try model.publish(from: source, windowsRoot: windowsRoot.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
            else { try model.save() }
            if let root = model.root { UserDefaults.standard.set(windowsRoot.stringValue, forKey: "UNC:" + root.path) }
            updateStatus(export ? "Deployment bundle and both GPO scripts saved. Configure Client Logs permissions from Windows." : "JSON saved. Windows clients apply changes on their next run.")
        } catch { errorAlert(error) }
    }
    func validate() { do { guard let root = model.root else { throw DeploymentError("Open a deployment first.") }; try DeploymentModel.validate(model.config, root: root); updateStatus("Configuration, package paths and selected driver names are valid.") } catch { errorAlert(error) } }
    func reload() { if let url = model.configURL { open(url) } }
    func refreshReports() {
        do {
            let selected = computers.indices.contains(computerTable.table.selectedRow) ? computers[computerTable.table.selectedRow].name : ""
            computers = try model.loadReports()
            computerTable.replace(computers.map { computer in
                var status = computer.reports.contains { text($0, "Result") == "Failed" } ? "Failed" : "Success"
                let skipped = computer.machine.map { objects($0, "ConfiguredPrinters").filter { text($0, "Status") == "Unsupported architecture" }.count } ?? 0
                if skipped > 0 { status += " / \(skipped) architecture skipped" }
                if computer.machine == nil { status += " / no computer report" }; if computer.userCount == 0 { status += " / user inventory missing" }
                if let savedAt = model.savedAt, computer.reports.contains(where: { (DeploymentModel.date(text($0, "ReportedAt")) ?? .distantPast) < savedAt }) { status += " / older than configuration" }
                let machine = computer.machine, count = machine.map { objects($0, "ConfiguredPrinters").count } ?? 0, installed = machine.map { objects($0, "ConfiguredPrinters").filter { text($0, "Status") == "Installed" }.count } ?? 0
                let latest = computer.reports.map { text($0, "ReportedAt") }.sorted().last ?? ""
                return ["Name": computer.name, "Status": status, "Installed": machine == nil ? "No report" : "\(installed)/\(count)", "Users": String(computer.userCount), "Reported": latest]
            }, selected: computers.firstIndex { $0.name == selected } ?? (computers.isEmpty ? -1 : 0))
            showComputer(); updateStatus("\(computers.count) computers loaded. \(model.warnings.count) invalid reports skipped.")
            if !model.warnings.isEmpty { detail.stringValue += "\nSkipped reports: " + model.warnings.joined(separator: "; ") }
        } catch { errorAlert(error) }
    }
    func showComputer() {
        let row = computerTable.table.selectedRow
        guard computers.indices.contains(row) else { entries = []; selectedRequests = []; inventoryTable.replace([]); requestTable.replace([]); return }
        let computer = computers[row]; entries = computer.entries; selectedRequests = []
        inventoryTable.replace(entries.map { entry in
            let request = model.matchingRequests(entry.report).first { same(text($0, "Name"), text(entry.printer, "Name")) }
            let managed = model.printers.contains { same(text($0, "Name"), text(entry.printer, "Name")) }
            let result = request.flatMap { request in objects(entry.report, "RemovalResults").first { same(text($0, "Id"), text(request, "Id")) } }
            let state = managed ? "Stop deploying first" : (!entry.canRemove ? "Needs matching context" : (result.map { text($0, "Status") } ?? (request == nil ? "" : "Pending next run")))
            return ["Remove": request == nil ? "0" : "1", "Name": text(entry.printer, "Name"), "Owner": entry.owner, "Driver": text(entry.printer, "DriverName"), "Port": text(entry.printer, "PortName"), "Status": state]
        })
        var rows = [[String: String]]()
        for report in computer.reports { for request in model.matchingRequests(report) {
            selectedRequests.append(request)
            let result = objects(report, "RemovalResults").first { same(text($0, "Id"), text(request, "Id")) }
            rows.append(["Name": text(request, "Name"), "Owner": text(report, "Scope") == "Machine" ? "Computer" : text(report, "UserName"), "Status": result.map { text($0, "Status") } ?? "Pending next run", "Message": result.map { text($0, "Message") } ?? "Saved requests apply on the next run in this context."])
        } }
        requestTable.replace(rows)
        detail.stringValue = computer.reports.map { "\(text($0, "Scope") == "Machine" ? "Computer" : text($0, "UserName")): \(text($0, "Result")) • \(text($0, "ReportedAt")) \(text($0, "ErrorMessage")) \(text($0, "InventoryError"))" }.joined(separator: "\n")
        if computer.userCount == 0 { detail.stringValue += "\nAdd Report-UserPrinters.ps1 to the USER logon GPO to collect shared-printer connections." }
    }
    func clearRequest() { let row = requestTable.table.selectedRow; guard selectedRequests.indices.contains(row) else { return }; let id = text(selectedRequests[row], "Id"); model.removals = model.removals.filter { !same(text($0, "Id"), id) }; showComputer(); updateStatus("Request cleared. Save to publish.") }
    func showLogs() { if let root = model.root { NSWorkspace.shared.open(root.appendingPathComponent("Client Logs")) } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if discardChanges() { model.dirty = false; return true }; return false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: ConfiguratorController!
    var startupURL: URL?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let source = Bundle.main.resourceURL?.appendingPathComponent("WindowsBundle") ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        controller = ConfiguratorController(source: source)
        let menu = NSMenu(); let applicationItem = NSMenuItem(); menu.addItem(applicationItem); let applicationMenu = NSMenu(); applicationItem.submenu = applicationMenu
        applicationMenu.addItem(withTitle: "Quit PrintDeployGPO", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); editItem.title = "Edit"; let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu; menu.addItem(editItem)
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] { editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key) }
        NSApp.mainMenu = menu; controller.window.center(); controller.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if let url = startupURL { controller.open(url) }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) { if let path = filenames.first { let url = URL(fileURLWithPath: path); if controller != nil { controller.open(url) } else { startupURL = url } }; sender.reply(toOpenOrPrint: .success) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { controller == nil || controller.discardChanges() ? .terminateNow : .terminateCancel }
}

@main struct ConfiguratorApp {
    static func main() {
        let application = NSApplication.shared
        if CommandLine.arguments.contains("--smoke-test") {
            do { try MacSmoke.run(); print("Mac GUI smoke checks passed."); exit(0) } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        application.setActivationPolicy(.regular)
        let delegate = AppDelegate(); if let path = CommandLine.arguments.dropFirst().first { delegate.startupURL = URL(fileURLWithPath: path) }
        application.delegate = delegate; application.run(); withExtendedLifetime(delegate) {}
    }
}
