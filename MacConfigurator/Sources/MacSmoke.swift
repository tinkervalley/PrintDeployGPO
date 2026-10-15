import AppKit
import CryptoKit

enum MacSmoke {
    static func run() throws {
        let model = DeploymentModel(), root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-mac-smoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        try model.create(in: root)
        let editor = PrinterEditor(model: model)
        editor.name.stringValue = "Office"; editor.host.stringValue = "192.0.2.55"
        let printer = try editor.makePrinter()
        guard text(printer, "Address") == "ipp://192.0.2.55:631/ipp" else { throw DeploymentError("Mac editor did not build default IPP URL.") }
        editor.kind.selectItem(withTitle: "Type3"); editor.kindChanged()
        guard editor.port.stringValue == "9100" && editor.protocolRow.isHidden else { throw DeploymentError("Mac Type3 fields failed.") }
        editor.kind.selectItem(withTitle: "IPP"); editor.kindChanged()
        guard editor.port.stringValue == "631" && editor.driverRow.isHidden else { throw DeploymentError("Mac IPP fields failed.") }
        var custom = printer; custom["Address"] = "ipps://PRINTER.example.com:443/ipp/print"; custom["UnknownField"] = "Keep"
        let existing = PrinterEditor(model: model, printer: custom)
        guard text(try existing.makePrinter(), "Address") == text(custom, "Address"), text(try existing.makePrinter(), "UnknownField") == "Keep" else { throw DeploymentError("Mac editor rewrote unchanged endpoint or unknown fields.") }
        let txt: [String: Data] = ["rp": Data("ipp/print".utf8), "ty": Data("Test model".utf8), "note": Data("Office".utf8)]
        guard let discovered = DiscoveredPrinter.make(name: "Found printer", host: "printer.local.", ipv4: "192.0.2.55", type: "_ipps._tcp.", port: 443, txt: txt), discovered.address == "printer.local", discovered.path == "/ipp/print", discovered.model == "Test model" else { throw DeploymentError("Discovery lost advertised IPPS host or TXT details.") }
        editor.applyDiscovery(discovered)
        guard text(try editor.makePrinter(), "Address") == "ipps://printer.local:443/ipp/print", editor.name.stringValue == "Office", editor.customPort.state == .on, editor.port.isEnabled else { throw DeploymentError("Discovered IPPS endpoint did not fill the editor or overwrote the queue name.") }
        guard let raw = DiscoveredPrinter.make(name: "RAW printer", host: "printer.local.", ipv4: "192.0.2.55", type: "_pdl-datastream._tcp.", port: 9101, txt: [:]) else { throw DeploymentError("RAW discovery failed.") }
        editor.kind.selectItem(withTitle: "Type3"); editor.kindChanged(); editor.applyDiscovery(raw)
        guard editor.kind.titleOfSelectedItem == "Type3", editor.host.stringValue == "192.0.2.55", editor.port.stringValue == "9101" else { throw DeploymentError("RAW discovery lost the driver's type or advertised port.") }
        guard DiscoveredPrinter.make(name: "Bad", host: "printer.local", type: "_ipp._tcp.", port: 631, txt: ["rp": Data("ipp#fragment".utf8)]) == nil else { throw DeploymentError("Unsafe discovered path accepted.") }
        let discovery = PrinterDiscoveryDialog(); discovery.replace([discovered, raw], status: "Synthetic endpoints")
        discovery.table.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); discovery.select()
        guard discovery.result?.key == discovered.key, discovery.table.rows.count == 2 else { throw DeploymentError("Discovery picker returned the wrong endpoint.") }
        discovery.window.close()
        editor.kind.selectItem(withTitle: "IPP"); editor.kindChanged()
        model.printers = [printer]; try model.save()
        let source = Bundle.main.resourceURL?.appendingPathComponent("WindowsBundle") ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let controller = ConfiguratorController(source: source); try controller.model.open(root.appendingPathComponent("printers.json")); controller.loadControls()
        guard controller.tabs.numberOfTabViewItems == 4, controller.printerTable.rows.count == 1 else { throw DeploymentError("Mac tabs or existing configuration failed to load.") }
        let local: JSON = ["Name": "Office", "Type": "Local", "DriverName": "Microsoft IPP Class Driver", "PortName": "IPP", "Location": ""]
        let shared: JSON = ["Name": "\\\\domain\\printer", "Type": "Connection", "DriverName": "Legacy", "PortName": "UNC", "Location": ""]
        let sid = "S-1-5-21-1-2-3-1001"
        func report(_ scope: String) -> JSON {
            ["SchemaVersion": 1, "DeploymentId": text(model.config, "DeploymentId"), "ComputerName": "PC001", "Scope": scope, "UserSid": scope == "Machine" ? "" : sid, "UserName": scope == "Machine" ? "SYSTEM" : "DOMAIN\\Alice", "Result": "Success", "ReportedAt": "2026-10-13T21:00:00Z", "StartedAt": "2026-10-13T20:59:00Z", "ErrorMessage": "", "InventoryError": "", "ConfigurationHash": String(repeating: "0", count: 64), "ConfigurationContentHash": DeploymentModel.configurationContentHash(controller.model.config), "Printers": scope == "Machine" ? [local] : [local, shared], "ConfiguredPrinters": scope == "Machine" ? [["Name": "Office", "Status": "Installed"], ["Name": "Legacy", "Status": "Unsupported architecture"]] : [JSON](), "RemovalResults": [JSON]()]
        }
        let hash = SHA256.hash(data: Data(sid.utf8)).map { String(format: "%02x", $0) }.joined()
        for (folder, scope) in [("PC001", "Machine"), ("PC001--user-" + String(hash.prefix(16)), "UserConnection")] {
            let destination = root.appendingPathComponent("Client Logs/\(folder)"); try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try jsonData(report(scope)).write(to: destination.appendingPathComponent("latest.json"))
        }
        controller.refreshReports()
        guard controller.computerTable.rows.count == 1, controller.inventoryTable.rows.count == 2, let userRow = controller.entries.firstIndex(where: { text($0.report, "Scope") == "UserConnection" }) else { throw DeploymentError("Native Mac inventory did not combine computer/user reports.") }
        guard controller.computerTable.rows[0]["Status"] == "Completed", controller.computerTable.rows[0]["Configuration"] == "Current", controller.detail.string.contains("Installed and verified") else { throw DeploymentError("Last run and content revision are not independently displayed.") }
        let column = controller.inventoryTable.table.tableColumns.first { $0.identifier.rawValue == "Remove" }!
        guard let checkbox = controller.inventoryTable.tableView(controller.inventoryTable.table, viewFor: column, row: userRow) as? NSButton else { throw DeploymentError("Native inventory removal control is missing.") }
        checkbox.performClick(nil)
        guard controller.model.removals.count == 1, text(controller.model.removals[0], "UserSid") == sid else { throw DeploymentError("Native inventory checkbox lost its user scope.") }
        guard controller.computerTable.rows[0]["Configuration"] == "Unsaved changes" else { throw DeploymentError("Editing left the configuration column showing Current.") }
        try controller.model.save()
        var conflict = report("Machine"); conflict["Result"] = "Failed"; conflict["ErrorMessage"] = "Printer 'Office': The specified printer already exists."
        conflict["ConfiguredPrinters"] = [["Name": "Office", "Status": "Missing"]]
        try jsonData(conflict).write(to: root.appendingPathComponent("Client Logs/PC001/latest.json")); controller.refreshReports()
        guard controller.computerTable.rows[0]["Status"] == "Needs attention", controller.computerTable.rows[0]["Configuration"] == "Current", controller.detail.string.contains("not confirmation"), controller.detail.string.contains("Configured queue missing") else { throw DeploymentError("Existing-device conflicts are not clearly separated from configuration currency.") }
        let vendor = root.appendingPathComponent("Drivers/test"); try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        let inf = "[Version]\nClass=Printer\nClassVer=4.0\n[Manufacturer]\nVendor=Models,NTamd64,NTarm64\n[Models.NTamd64]\n\"Shared\"=Install,ID\n[Models.NTarm64]\n\"Shared\"=Install,ID\n\"ARM-only\"=Install,ARMID\n"
        try Data(inf.utf8).write(to: vendor.appendingPathComponent("printer.inf"))
        let driverPrinter: JSON = ["Name": "ARM queue", "Kind": "Type4", "Address": "192.0.2.59", "PortNumber": 9100, "Location": "", "Comment": "", "PackagePath": "Drivers\\test", "InfPath": "Drivers\\test\\printer.inf", "DriverName": "arm-ONLY"]
        let driverEditor = PrinterEditor(model: model, printer: driverPrinter)
        guard driverEditor.driver.itemTitles.count == 2, driverEditor.support.stringValue.contains("ARM64"), !driverEditor.support.stringValue.contains("x64,") else { throw DeploymentError("Native ARM-only driver label failed.") }
        driverEditor.driver.selectItem(withTitle: "Shared"); driverEditor.driverChanged()
        guard driverEditor.support.stringValue.contains("x64, ARM64") else { throw DeploymentError("Native driver support did not update with selection.") }
        _ = try driverEditor.makePrinter(); driverEditor.dialog.close()
        try Data(inf.replacingOccurrences(of: "ClassVer=4.0", with: "").utf8).write(to: vendor.appendingPathComponent("legacy.inf"))
        var nativePrinter = driverPrinter; nativePrinter.merge(["PackagePath": "", "InfPath": "", "DriverName": "", "DriverPackages": [
            "x64": ["Kind": "Type3", "PackagePath": "Drivers\\test", "InfPath": "Drivers\\test\\legacy.inf", "DriverName": "Shared"],
            "ARM64": ["Kind": "Type4", "PackagePath": "Drivers\\test", "InfPath": "Drivers\\test\\printer.inf", "DriverName": "ARM-only"]
        ]]) { _, new in new }
        let nativeEditor = PrinterEditor(model: model, printer: nativePrinter)
        guard nativeEditor.packageTarget.titleOfSelectedItem == "x64", nativeEditor.packageKind.titleOfSelectedItem == "Type3", nativeEditor.driver.itemTitles == ["Shared"] else { throw DeploymentError("Native x64 package or model filtering failed.") }
        nativeEditor.packageTarget.selectItem(withTitle: "ARM64"); nativeEditor.packageTargetChanged()
        guard nativeEditor.packageKind.titleOfSelectedItem == "Type4", nativeEditor.driver.titleOfSelectedItem == "ARM-only" else { throw DeploymentError("Native ARM64 slot was overwritten by x64.") }
        nativeEditor.driver.selectItem(withTitle: "Shared"); nativeEditor.driverChanged()
        nativeEditor.packageTarget.selectItem(withTitle: "x64"); nativeEditor.packageTargetChanged()
        nativeEditor.packageTarget.selectItem(withTitle: "ARM64"); nativeEditor.packageTargetChanged()
        let savedNative = try nativeEditor.makePrinter(), savedPackages = savedNative["DriverPackages"] as? JSON ?? [:]
        guard nativeEditor.driver.titleOfSelectedItem == "Shared", text(savedPackages["x64"] as? JSON ?? [:], "Kind") == "Type3", text(savedPackages["ARM64"] as? JSON ?? [:], "Kind") == "Type4", text(savedNative, "DriverName").isEmpty else { throw DeploymentError("Native slot switching/save lost independent packages.") }
        guard text((nativePrinter["DriverPackages"] as? JSON)?["ARM64"] as? JSON ?? [:], "DriverName") == "ARM-only" else { throw DeploymentError("Editing changed the original before saving.") }
        nativeEditor.dialog.close()
        controller.window.contentView?.layoutSubtreeIfNeeded()
        if let directory = ProcessInfo.processInfo.environment["PD_MAC_SCREENSHOTS"] {
            let destination = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            controller.tabs.selectTabViewItem(at: 1); controller.window.contentView?.layoutSubtreeIfNeeded()
            for (view, name) in [(controller.window.contentView!, "computer-status"), (editor.dialog.contentView!, "ipp-editor")] {
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw DeploymentError("Could not render Mac UI.") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { throw DeploymentError("Could not encode Mac UI image.") }
                try data.write(to: destination.appendingPathComponent(name + ".png"))
            }
        }
        controller.model.dirty = false; controller.window.close(); editor.dialog.close(); existing.dialog.close()
    }
}
