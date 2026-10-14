import Foundation
import CryptoKit

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try condition() == false { throw DeploymentError(message) } }
func expectError(_ body: () throws -> Void) throws { do { try body() } catch { return }; throw DeploymentError("Expected an error.") }

@main struct ModelTests {
    static func main() {
        do { try run(); print("All 12 Mac model checks passed.") } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-mac-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = DeploymentModel(); try model.create(in: root)
        let endpoint = IppEndpoint(host: "192.0.2.55", scheme: "ipp", path: "/ipp", port: 631)
        try expect(try endpoint.address() == "ipp://192.0.2.55:631/ipp", "IPP default failed.")
        try expect(try IppEndpoint(host: "2001:db8::55", scheme: "ipps", path: "ipp/print", port: 443).address() == "ipps://[2001:db8::55]:443/ipp/print", "IPv6/custom port failed.")
        try expectError { _ = try IppEndpoint(host: "printer.example.com:631", scheme: "ipp", path: "/ipp", port: 631).address() }
        print("PASS IPP defaults, IPv6 and host validation")
        for relative in ["../escape", "Drivers/../escape", "C:\\outside", "/tmp/outside", "Drivers/test:stream"] { try expectError { _ = try DeploymentModel.resource(root, relative) } }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: root)
        try expectError { _ = try DeploymentModel.resource(root, "linked/file") }; print("PASS resource containment and linked resources")
        var printer: JSON = ["Name": "Office", "Kind": "IPP", "Address": try endpoint.address(), "PortNumber": 9100, "Location": "Office", "Comment": "", "PackagePath": "", "InfPath": "", "DriverName": "", "ExtraPrinterField": "Preserve me"]
        model.printers = [printer]; model.config["FutureField"] = ["Enabled": true]; let id = text(model.config, "DeploymentId"); try model.save()
        let reloaded = DeploymentModel(); try reloaded.open(root.appendingPathComponent("printers.json")); try reloaded.save()
        try expect(text(reloaded.config, "DeploymentId") == id && text(reloaded.printers[0], "ExtraPrinterField") == "Preserve me" && reloaded.config["FutureField"] != nil, "Unknown fields or identity lost."); print("PASS JSON round-trip and unknown field preservation")
        try Data("{}".utf8).write(to: root.appendingPathComponent("printers.json"), options: .atomic); try expectError { try model.save() }; print("PASS concurrent changes reject overwrite")
        try expectError { try reloaded.create(in: root) }; print("PASS new deployment refuses existing identity")
        let vendor = root.appendingPathComponent("Vendor source"); try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        let inf = vendor.appendingPathComponent("printer.inf")
        let contents = """
        [Version]
        Class=Printer
        ClassVer=4.0 ; Type4
        [Manufacturer]
        %Vendor%=Models,NTamd64,NTamd64.10.0,NTarm64
        [Models.NTamd64]
        %Model%=Install,ID
        "Printer; equals = and comma, name"=Install,ID2 ; comment
        [Models.NTamd64.10.0]
        "OS model"=Install,ID3
        [Models.NTarm64]
        "ARM model"=Install,ID4
        [Strings.0409]
        Model="Fallback"
        [Strings]
        Vendor="Vendor"
        Model="Neutral driver"
        """
        try contents.data(using: .utf16)!.write(to: inf)
        let values = try INFModels.read(inf, architecture: "x64", type: 4)
        try expect(values.count == 3 && values.contains("Neutral driver") && values.contains("Printer; equals = and comma, name"), "INF parsing failed.")
        try expect(try INFModels.read(inf, architecture: "ARM64", type: 4) == ["ARM model"], "INF architecture failed.")
        try expectError { _ = try INFModels.read(inf, architecture: "x64", type: 3) }; print("PASS UTF16 INF model strings, punctuation and architecture")
        let type3 = vendor.appendingPathComponent("legacy.inf"); try Data(contents.replacingOccurrences(of: "ClassVer=4.0 ; Type4", with: "").utf8).write(to: type3)
        try expect(try INFModels.read(type3, architecture: "x64", type: 3).count == 3, "Type3 models missing."); print("PASS explicit Type3 support")
        let staging = root.appendingPathComponent("Staging"); try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let deployment = DeploymentModel(); try deployment.create(in: staging)
        let imported = try deployment.importPackage(vendor, inf: inf, type: 4)
        printer.merge(["Name": "Type4", "Kind": "Type4", "Address": "192.0.2.56", "PackagePath": imported.0, "InfPath": imported.1, "DriverName": "Neutral driver"]) { _, new in new }; deployment.printers = [printer]; try deployment.save()
        try expect(FileManager.default.fileExists(atPath: try DeploymentModel.resource(staging, imported.0 + "\\legacy.inf").path), "Full package was not copied."); print("PASS driver import preserves full package and validates selection")
        let shared: JSON = ["Name": "\\\\domain\\printer", "Type": "Connection", "DriverName": "Legacy", "PortName": "UNC", "Location": ""]
        let local: JSON = ["Name": "PDF", "Type": "Local", "DriverName": "PDF", "PortName": "PORTPROMPT:", "Location": ""]
        func report(_ scope: String, sid: String = "", user: String = "SYSTEM") -> JSON { ["SchemaVersion": 1, "DeploymentId": text(deployment.config, "DeploymentId"), "ComputerName": "PC001", "Scope": scope, "UserSid": sid, "UserName": user, "Result": "Success", "ReportedAt": "2026-10-13T21:00:00.1234567Z", "StartedAt": "2026-10-13T20:59:00Z", "ErrorMessage": "", "InventoryError": "", "ConfigurationHash": String(repeating: "0", count: 64), "Printers": scope == "Machine" ? [local] : [local, shared], "ConfiguredPrinters": [JSON](), "RemovalResults": [JSON]()] }
        let machine = report("Machine"), alice = report("UserConnection", sid: "S-1-5-21-1-2-3-1001", user: "DOMAIN\\Alice"), bob = report("UserConnection", sid: "S-1-5-21-1-2-3-1002", user: "DOMAIN\\Bob")
        let combined = DeploymentModel.combine([machine, alice, bob]); try expect(combined.count == 1 && combined[0].entries.count == 3 && combined[0].userCount == 2, "Inventories were duplicated or users merged."); print("PASS combined computer/user inventories")
        let entry = combined[0].entries.first { $0.owner == "DOMAIN\\Bob" }!; try deployment.selectRemoval(entry, selected: true); let requestID = text(deployment.removals[0], "Id"); try deployment.selectRemoval(entry, selected: true)
        try expect(deployment.removals.count == 1 && text(deployment.removals[0], "Id") == requestID && deployment.matchingRequests(alice).isEmpty, "Request scopes or stable IDs lost.")
        try deployment.save(); print("PASS scoped removal requests are Windows-compatible and one-shot")
        let logs = staging.appendingPathComponent("Client Logs/PC001"); try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true); try jsonData(machine).write(to: logs.appendingPathComponent("latest.json"))
        let broken = staging.appendingPathComponent("Client Logs/BROKEN"); try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true); try Data("{ malformed json".utf8).write(to: broken.appendingPathComponent("latest.json"))
        try expect(try deployment.loadReports().count == 1 && deployment.warnings.count == 1, "Malformed report filtering failed."); print("PASS bounded client report loading skips malformed data")
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        try deployment.publish(from: source, windowsRoot: "\\\\server\\Office's Share\\Printers")
        let script = try String(contentsOf: staging.appendingPathComponent("Install-PrinterDeploymentTask.ps1"), encoding: .utf8)
        try expect(script.contains("$root = '\\\\server\\Office''s Share\\Printers'") && script.contains(text(deployment.config, "DeploymentId")), "Exported UNC path or deployment identity changed.")
        try expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("Report-UserPrinters.ps1").path), "Missing user script.")
        try expectError { try deployment.publish(from: source, windowsRoot: "/Volumes/Share") }; print("PASS Windows bundle exports shared templates with literal UNC paths")
        if let output = ProcessInfo.processInfo.environment["PD_MAC_TEST_OUTPUT"] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: output), withIntermediateDirectories: true)
            try jsonData(deployment.config).write(to: URL(fileURLWithPath: output).appendingPathComponent("printers.json"))
            try FileManager.default.copyItem(at: staging.appendingPathComponent("Drivers"), to: URL(fileURLWithPath: output).appendingPathComponent("Drivers"))
        }
    }
}
