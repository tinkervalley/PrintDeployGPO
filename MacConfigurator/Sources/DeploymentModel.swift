import Foundation
import CryptoKit
import CoreFoundation
import Darwin

typealias JSON = [String: Any]
struct DeploymentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
func text(_ object: JSON, _ key: String) -> String { object[key] as? String ?? "" }
func objects(_ object: JSON, _ key: String) -> [JSON] { object[key] as? [JSON] ?? [] }
func flag(_ object: JSON, _ key: String) -> Bool { object[key] as? Bool ?? false }
func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
func nonzeroUUID(_ value: String) -> Bool { UUID(uuidString: value) != nil && value.lowercased() != "00000000-0000-0000-0000-000000000000" }
func jsonData(_ object: JSON) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) }
func readJSONBytes(_ url: URL, limit: Int = 4 * 1024 * 1024) throws -> Data {
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey])
    guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? limit + 1) <= limit else {
        throw DeploymentError("Linked, oversized or non-file JSON resource: \(url.lastPathComponent)")
    }
    let data = try Data(contentsOf: url)
    guard data.count <= limit else { throw DeploymentError("JSON exceeds the size limit.") }
    return data
}
func readJSON(_ url: URL, limit: Int = 4 * 1024 * 1024) throws -> JSON {
    guard let object = try JSONSerialization.jsonObject(with: readJSONBytes(url, limit: limit)) as? JSON else { throw DeploymentError("Expected a JSON object.") }
    return object
}
func validHost(_ value: String) -> Bool {
    if value.contains(":") {
        let parts = value.split(separator: "%", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.count == 1 || matches(String(parts[1]), "^[A-Za-z0-9_.-]+$") else { return false }
        var address = in6_addr()
        return String(parts[0]).withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }
    return !value.isEmpty && value.count <= 253 && value.split(separator: ".", omittingEmptySubsequences: false).enumerated().allSatisfy { index, part in
        (part.isEmpty && index == value.split(separator: ".", omittingEmptySubsequences: false).count - 1 && value.hasSuffix(".")) ||
        (!part.isEmpty && part.count <= 63 && matches(String(part), "^[A-Za-z0-9_][A-Za-z0-9_-]*$") && !part.hasSuffix("-"))
    }
}

struct IppEndpoint: Equatable {
    var host: String
    var scheme: String
    var path: String
    var port: Int
    static func defaultPort(_ scheme: String) -> Int { scheme == "https" ? 443 : (scheme == "http" ? 80 : 631) }
    static func parse(_ address: String) throws -> IppEndpoint {
        guard let url = URLComponents(string: address), let scheme = url.scheme?.lowercased(),
              ["ipp", "ipps", "http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { throw DeploymentError("Invalid IPP address.") }
        return IppEndpoint(host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), scheme: scheme,
                           path: (url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath) + (url.percentEncodedQuery.map { "?" + $0 } ?? ""),
                           port: url.port ?? defaultPort(scheme))
    }
    func address() throws -> String {
        let host = self.host.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard validHost(host), !matches(host, "[\\s/@?#\\\\]"), !host.contains("://"),
              ["ipp", "ipps", "http", "https"].contains(scheme), (1...65535).contains(port) else {
            throw DeploymentError("Enter only an IP address or hostname, and a port between 1 and 65535.")
        }
        let bracketed = host.contains(":") ? "[\(host)]" : host
        var path = self.path.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { path = "/ipp" }
        guard !path.hasPrefix("//"), !matches(path, "[\\s#\\\\]"), !path.contains("://") else { throw DeploymentError("Enter a subpath such as /ipp/print, without a URL or fragment.") }
        if !path.hasPrefix("/") { path = "/" + path }
        let address = "\(scheme)://\(bracketed):\(port)\(path)"
        let parsed = try Self.parse(address)
        guard parsed.host == host, parsed.port == port else { throw DeploymentError("Invalid IP address or hostname.") }
        return address
    }
}

struct InventoryEntry {
    let printer: JSON
    let report: JSON
    var owner: String { text(report, "Scope") == "Machine" ? "Computer" : text(report, "UserName") }
    var canRemove: Bool { (text(report, "Scope") == "Machine") != (text(printer, "Type") == "Connection") }
}
struct ComputerInventory {
    let name: String
    let reports: [JSON]
    let entries: [InventoryEntry]
    var machine: JSON? { reports.first { text($0, "Scope") == "Machine" } }
    var userCount: Int { reports.filter { text($0, "Scope") == "UserConnection" }.count }
}

final class DeploymentModel {
    var config: JSON = DeploymentModel.freshConfig()
    var root: URL?
    var configURL: URL?
    private var baseline: Data?
    var savedAt: Date?
    var dirty = false
    var warnings = [String]()
    var printers: [JSON] { get { objects(config, "Printers") } set { config["Printers"] = newValue; if newValue.contains(where: { $0["DriverPackages"] != nil }) { config["SchemaVersion"] = 2 }; dirty = true } }
    var removals: [JSON] { get { objects(config, "ClientRemovals") } set { config["ClientRemovals"] = newValue; dirty = true } }
    static func freshConfig() -> JSON {
        ["SchemaVersion": 1, "DeploymentId": UUID().uuidString.lowercased(), "Architecture": "x64", "Printers": [JSON](), "ClientRemovals": [JSON](),
         "Cleanup": ["RemoveStaleManaged": false, "CleanupUserConnections": false, "LegacyPrinterNames": [String]()]]
    }
    static func configurationContentHash(_ config: JSON) -> String {
        func encode(_ value: Any) -> String {
            if value is NSNull { return "z" }
            if let value = value as? String { return "s\(value.utf8.count):" + value }
            if let value = value as? NSNumber {
                if CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue ? "b1" : "b0" }
                return "n" + NSDecimalNumber(decimal: value.decimalValue).stringValue + ";"
            }
            if let value = value as? JSON {
                let keys = value.keys.filter { $0 != "RequestedAt" }.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
                return "o\(keys.count):" + keys.map { encode($0) + encode(value[$0]!) }.joined()
            }
            if let value = value as? [Any] { return "a\(value.count):" + value.map(encode).joined() }
            preconditionFailure("Configuration must contain only JSON values.")
        }
        return SHA256.hash(data: Data(("PDConfig1:" + encode(config)).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func configurationStatus(_ report: JSON?, config: JSON, unsaved: Bool = false) -> String {
        if unsaved { return "Unsaved changes" }
        guard let report = report else { return "No computer report" }
        let hash = text(report, "ConfigurationContentHash")
        guard !hash.isEmpty else { return "Not compared" }
        return hash == configurationContentHash(config) ? "Current" : "Update pending"
    }
    static func printerStatusText(_ status: String) -> String {
        ["Installed": "Installed and verified", "Missing": "Configured queue missing", "Needs reconciliation": "Present; settings not verified", "Unknown": "Inventory unavailable", "Unsupported architecture": "Skipped; no compatible driver"][status] ?? status
    }
    static func reportErrorExplanation(_ message: String) -> String {
        let message = message.lowercased()
        if message.contains("specified printer already exists") || message.contains("0x8007070a") || message.contains("0x800700b7") {
            return "Windows reported a printer/device registration conflict while adding a queue. This is not confirmation that the requested queue is installed. Check the per-printer verification below and review older copies in Reported printers."
        }
        if message.contains("exists outside this tool's management") || message.contains("name conflict:") { return "A same-name queue is present, but this deployment could not verify its connection/ownership. Review its driver and port before renaming or removing an old copy." }
        return ""
    }
    func open(_ url: URL) throws {
        let data = try readJSONBytes(url)
        guard let candidate = try JSONSerialization.jsonObject(with: data) as? JSON else { throw DeploymentError("Expected a configuration JSON object.") }
        try Self.validate(candidate, root: url.deletingLastPathComponent(), resources: false)
        config = candidate; root = url.deletingLastPathComponent(); configURL = url; baseline = data
        savedAt = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate; dirty = false
    }
    func create(in folder: URL) throws {
        let target = folder.appendingPathComponent("printers.json")
        guard !FileManager.default.fileExists(atPath: target.path) else { throw DeploymentError("This folder already contains printers.json. Open that configuration to preserve its deployment identity.") }
        config = Self.freshConfig(); root = folder; configURL = target; baseline = nil; savedAt = nil; dirty = true
    }
    static func resource(_ root: URL, _ relative: String) throws -> URL {
        let relative = relative.replacingOccurrences(of: "\\", with: "/")
        guard !relative.isEmpty, !relative.hasPrefix("/"), !matches(relative, "[:*?]"), !relative.split(separator: "/").contains("..") else { throw DeploymentError("Resource must stay inside the deployment folder: \(relative)") }
        let base = root.standardizedFileURL
        var current = base
        if (try? base.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw DeploymentError("Linked deployment folders are not supported.") }
        for part in relative.split(separator: "/") {
            current.appendPathComponent(String(part))
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw DeploymentError("Linked resources are not supported: \(relative)") }
        }
        guard current.standardizedFileURL.path.hasPrefix(base.path + "/") else { throw DeploymentError("Resource escapes the deployment folder.") }
        return current
    }
    static func resolvedDriver(_ printer: JSON, architecture: String) -> JSON {
        guard text(printer, "Kind") != "IPP", let variants = printer["DriverPackages"] as? JSON, let package = variants[architecture] as? JSON else { return printer }
        var result = printer
        for key in ["PackagePath", "InfPath", "DriverName"] { result[key] = package[key] }
        if let kind = package["Kind"] { result["Kind"] = kind }
        return result
    }
    static func driverSummary(_ printer: JSON) -> String {
        if text(printer, "Kind") == "IPP" { return "Microsoft IPP Class Driver" }
        var parts = [String]()
        if !text(printer, "DriverName").isEmpty { parts.append("Shared: " + text(printer, "DriverName")) }
        for architecture in ["x64", "ARM64"] {
            if let package = (printer["DriverPackages"] as? JSON)?[architecture] as? JSON { parts.append(architecture + ": " + text(package, "DriverName")) }
        }
        return parts.joined(separator: "; ")
    }
    static func validatePackage(_ package: JSON, root: URL, kind: String, architecture: String? = nil, resources: Bool) throws {
        let kind = package["Kind"] as? String ?? kind
        guard ["Type3", "Type4"].contains(kind) else { throw DeploymentError("Package type must be Type3 or Type4.") }
        for key in ["PackagePath", "InfPath", "DriverName"] { guard let value = package[key] as? String, !value.isEmpty else { throw DeploymentError("Missing driver package field: \(key)") } }
        let packagePath = text(package, "PackagePath"), infPath = text(package, "InfPath"), driver = text(package, "DriverName")
        guard matches(packagePath, "(?i)^Drivers[/\\\\]") else { throw DeploymentError("Driver packages must be under Drivers in the deployment folder.") }
        let folder = try resource(root, packagePath), inf = try resource(root, infPath)
        guard inf.path.hasPrefix(folder.path + "/"), inf.pathExtension.lowercased() == "inf" else { throw DeploymentError("INF must be inside its package.") }
        if resources {
            try rejectLinks(in: folder)
            let catalog = try INFModels.catalog(inf, type: kind == "Type3" ? 3 : 4)
            guard let entry = catalog.first(where: { same($0.name, driver) }) else { throw DeploymentError("Driver name is absent from the selected INF: \(driver)") }
            if let architecture = architecture, !entry.architectures.contains(architecture) { throw DeploymentError("Selected driver does not declare \(architecture) model support.") }
        }
    }
    static func validate(_ config: JSON, root: URL, resources: Bool = true) throws {
        guard [1, 2].contains(config["SchemaVersion"] as? Int ?? 0), nonzeroUUID(text(config, "DeploymentId")), ["x64", "ARM64"].contains(text(config, "Architecture")),
              let printers = config["Printers"] as? [JSON], let cleanup = config["Cleanup"] as? JSON, let names = cleanup["LegacyPrinterNames"] as? [String] else {
            throw DeploymentError("Not a supported PrintDeployGPO configuration (schema 1 or 2).")
        }
        for key in ["RemoveStaleManaged", "CleanupUserConnections"] {
            guard let value = cleanup[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw DeploymentError("Cleanup flags must be booleans.") }
        }
        var seen = Set<String>()
        for printer in printers {
            for key in ["Name", "Kind", "Address", "Location", "Comment", "PackagePath", "InfPath", "DriverName"] {
                guard printer[key] is String else { throw DeploymentError("Missing printer field: \(key)") }
            }
            let name = text(printer, "Name"), kind = text(printer, "Kind")
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty, name.utf16.count <= 200, !matches(name, "[\\x00-\\x1f]"), seen.insert(name.lowercased()).inserted else { throw DeploymentError("Empty, invalid or duplicate printer name: \(name)") }
            if kind == "IPP" { _ = try IppEndpoint.parse(text(printer, "Address")) }
            else if ["Type3", "Type4"].contains(kind) {
                guard validHost(text(printer, "Address")), let port = printer["PortNumber"] as? Int, (1...65535).contains(port) else { throw DeploymentError("Invalid TCP host or port for \(name).") }
                let shared = ["PackagePath", "InfPath", "DriverName"].contains { !text(printer, $0).isEmpty }
                if shared { try validatePackage(printer, root: root, kind: kind, resources: resources) }
                var count = 0
                if let raw = printer["DriverPackages"] {
                    guard config["SchemaVersion"] as? Int == 2, let variants = raw as? JSON else { throw DeploymentError("Architecture-specific packages require schema 2 and a package object.") }
                    for (architecture, rawPackage) in variants {
                        guard ["x64", "ARM64"].contains(architecture), let package = rawPackage as? JSON else { throw DeploymentError("DriverPackages keys must be x64 or ARM64 package objects.") }
                        try validatePackage(package, root: root, kind: kind, architecture: architecture, resources: resources); count += 1
                    }
                }
                guard shared || count > 0 else { throw DeploymentError("Select at least one driver package for \(name).") }
            } else { throw DeploymentError("Unknown printer type: \(kind)") }
        }
        for architecture in ["x64", "ARM64"] {
            var versions = [String: String]()
            for printer in printers where text(printer, "Kind") != "IPP" {
                let resolved = resolvedDriver(printer, architecture: architecture), name = text(resolved, "DriverName").lowercased(), kind = text(resolved, "Kind")
                if name.isEmpty { continue }
                if let previous = versions[name], previous != kind { throw DeploymentError("A driver cannot be both Type3 and Type4 on \(architecture): \(name)") }; versions[name] = kind
            }
        }
        for name in names {
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !matches(name, "[\\x00-\\x1f*?\\[\\]]"), !seen.contains(name.lowercased()) else { throw DeploymentError("Legacy cleanup requires exact, unconfigured printer names.") }
        }
        if config["ClientRemovals"] != nil && !(config["ClientRemovals"] is [JSON]) { throw DeploymentError("ClientRemovals must be an array.") }
        var ids = Set<String>(); var targets = Set<String>()
        for request in objects(config, "ClientRemovals") {
            let id = text(request, "Id"), scope = text(request, "Scope"), sid = text(request, "UserSid"), name = text(request, "Name")
            guard nonzeroUUID(id), ids.insert(id.lowercased()).inserted, matches(text(request, "ComputerName"), "^[A-Za-z0-9][A-Za-z0-9-]{0,62}$"),
                  (scope == "Machine" && sid.isEmpty) || (scope == "UserConnection" && matches(sid, "^S-1-[0-9]+(-[0-9]+)+$")), !seen.contains(name.lowercased()) else { throw DeploymentError("Invalid or conflicting client removal request.") }
            for key in ["Name", "DriverName", "PortName"] { guard !text(request, key).trimmingCharacters(in: .whitespaces).isEmpty, !matches(text(request, key), "[\\x00-\\x1f]") else { throw DeploymentError("Invalid removal request field: \(key)") } }
            let target = [text(request, "ComputerName"), scope, sid, name].joined(separator: "|").lowercased()
            guard targets.insert(target).inserted else { throw DeploymentError("Duplicate removal target.") }
        }
    }
    static func rejectLinks(in folder: URL) throws {
        let attributes = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw DeploymentError("Missing or linked driver package folder.") }
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey], errorHandler: { _, _ in false }) else { throw DeploymentError("Cannot read package folder.") }
        for case let file as URL in walker { if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw DeploymentError("Driver package contains a symbolic link.") } }
    }
    func importPackage(_ source: URL, inf: URL, type: Int) throws -> (String, String, [String]) {
        guard let root = root else { throw DeploymentError("Open or create a deployment first.") }
        guard inf.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/") else { throw DeploymentError("Choose an INF inside the selected complete vendor package.") }
        try Self.rejectLinks(in: source)
        let models = try INFModels.catalog(inf, type: type).map { $0.name }
        let relative = "Drivers\\" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let destination = try Self.resource(root, relative)
        guard !destination.path.hasPrefix(source.standardizedFileURL.path + "/") else { throw DeploymentError("Deployment folder cannot be inside the source package.") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        return (relative, relative + "\\" + String(inf.path.dropFirst(source.path.count + 1)).replacingOccurrences(of: "/", with: "\\"), models)
    }
    func save() throws {
        if printers.contains(where: { $0["DriverPackages"] != nil }) { config["SchemaVersion"] = 2 }
        guard let root = root, let url = configURL else { throw DeploymentError("Open or create a deployment first.") }
        try Self.validate(config, root: root)
        if FileManager.default.fileExists(atPath: url.path) {
            guard let baseline = baseline, try Data(contentsOf: url) == baseline else { throw DeploymentError("The configuration changed on disk. Reopen it before saving to avoid overwriting another administrator's changes.") }
        } else if baseline != nil { throw DeploymentError("The configuration was deleted or the share disconnected. Reopen it before saving.") }
        _ = try Self.resource(root, url.lastPathComponent)
        let data = try jsonData(config)
        try data.write(to: url, options: .atomic)
        baseline = data; savedAt = Date(); dirty = false
    }
    func matchingRequests(_ report: JSON) -> [JSON] {
        removals.filter { same(text($0, "ComputerName"), text(report, "ComputerName")) && text($0, "Scope") == text(report, "Scope") && text($0, "UserSid") == text(report, "UserSid") }
    }
    func selectRemoval(_ entry: InventoryEntry, selected: Bool) throws {
        let report = entry.report, printer = entry.printer, name = text(printer, "Name")
        guard same(text(report, "DeploymentId"), text(config, "DeploymentId")), entry.canRemove else { throw DeploymentError("This queue needs a report from its matching computer/user context.") }
        guard !printers.contains(where: { same(text($0, "Name"), name) }) else { throw DeploymentError("Remove this printer from the Printers configuration first, so deployment does not reinstall it.") }
        let existing = matchingRequests(report).first { same(text($0, "Name"), name) }
        var others = removals.filter { request in !(same(text(request, "ComputerName"), text(report, "ComputerName")) && text(request, "Scope") == text(report, "Scope") && text(request, "UserSid") == text(report, "UserSid") && same(text(request, "Name"), name)) }
        if selected { others.append(existing ?? ["Id": UUID().uuidString.lowercased(), "ComputerName": text(report, "ComputerName"), "Scope": text(report, "Scope"), "UserSid": text(report, "UserSid"), "Name": name, "DriverName": text(printer, "DriverName"), "PortName": text(printer, "PortName"), "RequestedAt": ISO8601DateFormatter().string(from: Date())]) }
        removals = others
    }
    func loadReports() throws -> [ComputerInventory] {
        warnings = []
        guard let root = root else { throw DeploymentError("Open or create a deployment first.") }
        let logs = try Self.resource(root, "Client Logs")
        guard FileManager.default.fileExists(atPath: logs.path) else { return [] }
        var reports = [JSON]()
        for folder in try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            do {
                let path = try Self.resource(root, "Client Logs/\(folder.lastPathComponent)/latest.json")
                guard FileManager.default.fileExists(atPath: path.path) else { continue }
                let report = try readJSON(path)
                if !same(text(report, "DeploymentId"), text(config, "DeploymentId")) { continue }
                try Self.validateReport(report, folder: folder.lastPathComponent)
                reports.append(report)
            } catch { warnings.append("\(folder.lastPathComponent): \(error.localizedDescription)") }
        }
        return Self.combine(reports)
    }
    static func validateReport(_ report: JSON, folder: String) throws {
        let computer = text(report, "ComputerName"), scope = text(report, "Scope"), sid = text(report, "UserSid")
        guard matches(computer, "^[A-Za-z0-9][A-Za-z0-9-]{0,62}$"), report["SchemaVersion"] as? Int == 1,
              ["Success", "Failed"].contains(text(report, "Result")), report["Printers"] is [JSON], report["ConfiguredPrinters"] is [JSON], report["RemovalResults"] is [JSON],
              Self.date(text(report, "ReportedAt")) != nil, matches(text(report, "ConfigurationHash"), "^[0-9a-f]{64}$") else { throw DeploymentError("Invalid report format.") }
        if report["ConfigurationContentHash"] != nil && !matches(text(report, "ConfigurationContentHash"), "^[0-9a-f]{64}$") { throw DeploymentError("Invalid report content revision.") }
        let expected: String
        if scope == "Machine" && sid.isEmpty { expected = computer.uppercased() }
        else if scope == "UserConnection" && matches(sid, "^S-1-[0-9]+(-[0-9]+)+$") {
            let hash = SHA256.hash(data: Data(sid.utf8)).map { String(format: "%02x", $0) }.joined()
            expected = computer.uppercased() + "--user-" + hash.prefix(16)
        } else { throw DeploymentError("Invalid report identity.") }
        guard same(expected, folder) else { throw DeploymentError("Report identity does not match its folder.") }
        for key in ["UserName", "StartedAt", "ErrorMessage", "InventoryError"] { guard report[key] is String else { throw DeploymentError("Invalid report metadata.") } }
        for printer in objects(report, "Printers") { for key in ["Name", "Type", "DriverName", "PortName", "Location"] { guard printer[key] is String else { throw DeploymentError("Invalid printer inventory.") } } }
        for result in objects(report, "ConfiguredPrinters") { guard result["Name"] is String, ["Installed", "Missing", "Unknown", "Needs reconciliation", "Unsupported architecture"].contains(text(result, "Status")) else { throw DeploymentError("Invalid configured printer status.") } }
        for result in objects(report, "RemovalResults") { guard UUID(uuidString: text(result, "Id")) != nil, result["Name"] is String, result["Message"] is String, ["Pending", "Completed", "Changed", "Removed", "NotFound", "Planned", "Failed"].contains(text(result, "Status")) else { throw DeploymentError("Invalid removal result.") } }
    }
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func combine(_ reports: [JSON]) -> [ComputerInventory] {
        Dictionary(grouping: reports, by: { text($0, "ComputerName").uppercased() }).keys.sorted().map { computer in
            let contexts = reports.filter { same(text($0, "ComputerName"), computer) }.sorted { text($0, "Scope") + text($0, "UserName") < text($1, "Scope") + text($1, "UserName") }
            let machine = contexts.first { text($0, "Scope") == "Machine" }
            var entries = [InventoryEntry]()
            for report in contexts { for printer in objects(report, "Printers") {
                if text(report, "Scope") == "UserConnection" && text(printer, "Type") != "Connection", let machine = machine,
                   objects(machine, "Printers").contains(where: { same(text($0, "Name"), text(printer, "Name")) && same(text($0, "DriverName"), text(printer, "DriverName")) && same(text($0, "PortName"), text(printer, "PortName")) }) { continue }
                if text(report, "Scope") == "Machine" && text(printer, "Type") == "Connection", contexts.contains(where: { text($0, "Scope") == "UserConnection" && objects($0, "Printers").contains(where: { text($0, "Type") == "Connection" && same(text($0, "Name"), text(printer, "Name")) }) }) { continue }
                entries.append(InventoryEntry(printer: printer, report: report))
            } }
            return ComputerInventory(name: computer, reports: contexts, entries: entries)
        }
    }
    func publish(from source: URL, windowsRoot: String) throws {
        guard let root = root else { throw DeploymentError("Open or create a deployment first.") }
        guard configURL?.lastPathComponent == "printers.json" else { throw DeploymentError("To export a deployment bundle, open or create printers.json in the final deployment folder. Use Save JSON to edit this named configuration copy.") }
        guard matches(windowsRoot, "^\\\\\\\\[^\\\\]+\\\\[^\\\\]+"), !matches(windowsRoot, "[\"\\r\\n]") else { throw DeploymentError("Enter the final Windows UNC folder, such as \\\\fileserver\\Software\\Printers.") }
        if printers.contains(where: { $0["DriverPackages"] != nil }) { config["SchemaVersion"] = 2 }
        try Self.validate(config, root: root)
        let files = ["PrinterDeployment.ps1", "Launch-Configurator.cmd", "README.md", "Modules/PrinterDeployment.Core.psm1", "Modules/PrinterDeployment.Clients.psm1", "Modules/PrinterDeployment.Deploy.psm1", "Modules/PrinterDeployment.Gui.psm1", "Modules/PrinterDeployment.Discovery.psm1", "Templates/Install-PrinterDeploymentTask.ps1.template", "Templates/Report-UserPrinters.ps1.template"]
        for file in files { _ = try Self.resource(root, file); guard FileManager.default.fileExists(atPath: source.appendingPathComponent(file).path) else { throw DeploymentError("Application bundle is missing \(file). Rebuild or download the full app.") } }
        // Preflight concurrent changes before publishing scripts; save performs the check again.
        if let url = configURL, FileManager.default.fileExists(atPath: url.path) {
            let disk = try Data(contentsOf: url)
            guard baseline != nil && disk == baseline else { throw DeploymentError("Configuration changed on disk. Reopen it before publishing.") }
        }
        for file in files {
            let destination = try Self.resource(root, file)
            let original = source.appendingPathComponent(file)
            if original.standardizedFileURL != destination.standardizedFileURL {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: original).write(to: destination, options: .atomic)
            }
        }
        // Trim trailing separators only; preserve the UNC's leading double backslash.
        let rootLiteral = "'" + windowsRoot.replacingOccurrences(of: "\\+$", with: "", options: .regularExpression).replacingOccurrences(of: "'", with: "''") + "'"
        for name in ["Install-PrinterDeploymentTask.ps1", "Report-UserPrinters.ps1"] {
            let template = try String(contentsOf: source.appendingPathComponent("Templates/\(name).template"), encoding: .utf8)
            let generated = template.replacingOccurrences(of: "__PDT_ROOT_LITERAL__", with: rootLiteral).replacingOccurrences(of: "__PDT_DEPLOYMENT_ID__", with: text(config, "DeploymentId"))
            try Data(generated.utf8).write(to: Self.resource(root, name), options: .atomic)
        }
        let logs = try Self.resource(root, "Client Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try save()
        let guide = "Computer GPO > Startup > PowerShell Scripts: Install-PrinterDeploymentTask.ps1 (blank parameters; one SYSTEM task).\r\nUser GPO > Logon > PowerShell Scripts: Report-UserPrinters.ps1 (blank parameters; no extra task).\r\nWindows folder: \(windowsRoot)\r\nSet Client Logs NTFS permissions from Windows and SMB Change for reporting computers/users.\r\nSign the generated scripts if required by policy.\r\n"
        try Data(guide.utf8).write(to: Self.resource(root, "GPO-Setup.txt"), options: .atomic)
    }
}
