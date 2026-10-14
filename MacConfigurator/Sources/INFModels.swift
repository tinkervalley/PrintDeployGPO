import Foundation

struct DriverModel {
    let name: String
    var architectures: [String]
}

enum INFModels {
    static func catalog(_ url: URL, type: Int) throws -> [DriverModel] {
        var entries = [String: DriverModel]()
        for architecture in ["x64", "ARM64"] {
            let names: [String]
            do { names = try read(url, architecture: architecture, type: type) }
            catch { if error.localizedDescription.hasPrefix("No \(architecture) driver names found") { continue }; throw error }
            for name in names {
                let key = name.lowercased()
                if entries[key] == nil { entries[key] = DriverModel(name: name, architectures: []) }
                entries[key]?.architectures.append(architecture)
            }
        }
        guard !entries.isEmpty else { throw DeploymentError("No x64 or ARM64 models found in the selected INF.") }
        return entries.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    static func uncomment(_ line: String) -> String {
        var quoted = false, result = ""
        for character in line {
            if character == "\"" { quoted.toggle() }
            if character == ";" && !quoted { break }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func tokens(_ value: String) -> [String] {
        var quoted = false, result = [String](), current = ""
        for character in value {
            if character == "\"" { quoted.toggle() }
            if character == "," && !quoted { result.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else { current.append(character) }
        }
        result.append(current.trimmingCharacters(in: .whitespaces)); return result
    }
    static func expand(_ value: String, strings: [String: String]) throws -> String {
        var result = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")).replacingOccurrences(of: "\"\"", with: "\"")
        let expression = try NSRegularExpression(pattern: "%([^%]+)%")
        for _ in 0..<10 {
            let found = expression.matches(in: result, range: NSRange(result.startIndex..., in: result))
            if found.isEmpty { return result }
            for match in found.reversed() {
                guard let keyRange = Range(match.range(at: 1), in: result), let range = Range(match.range, in: result), let replacement = strings[String(result[keyRange]).lowercased()] else { throw DeploymentError("Unresolved INF string in \(value).") }
                result.replaceSubrange(range, with: replacement)
            }
        }
        throw DeploymentError("Recursive INF string reference.")
    }
    static func read(_ url: URL, architecture: String, type: Int) throws -> [String] {
        let data = try Data(contentsOf: url)
        let content: String?
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { content = String(data: data, encoding: .utf16) }
        else { content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) }
        guard let content = content else { throw DeploymentError("Cannot decode driver INF.") }
        var sections = [String: [String]](), section = "", pending = ""
        for raw in content.replacingOccurrences(of: "\u{feff}", with: "").components(separatedBy: .newlines) {
            let line = pending + uncomment(raw)
            if line.hasSuffix("\\") { pending = String(line.dropLast()); continue }; pending = ""
            if line.isEmpty { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") { section = String(line.dropFirst().dropLast()).lowercased(); if sections[section] == nil { sections[section] = [] } }
            else if !section.isEmpty { sections[section, default: []].append(line) }
        }
        guard let versionLines = sections["version"], let manufacturers = sections["manufacturer"] else { throw DeploymentError("Not a printer INF.") }
        func pair(_ line: String) -> (String, String)? {
            var quoted = false
            for index in line.indices {
                if line[index] == "\"" { quoted.toggle() }
                if line[index] == "=" && !quoted { return (String(line[..<index]).trimmingCharacters(in: .whitespaces), String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)) }
            }
            return nil
        }
        var version = [String: String](), strings = [String: String]()
        for line in versionLines { if let (key, value) = pair(line) { version[key.lowercased()] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) } }
        guard same(version["class"] ?? "", "Printer") else { throw DeploymentError("Select an INF with Class=Printer.") }
        if type == 4 && version["classver"] != "4.0" { throw DeploymentError("Select a Type 4 INF with ClassVer=4.0.") }
        if type == 3 && version["classver"] != nil && version["classver"] != "3.0" { throw DeploymentError("Select a Type 3 INF without ClassVer=4.0.") }
        for name in ["strings.0409", "strings"] { for line in sections[name] ?? [] { if let (key, value) = pair(line) { strings[key.lowercased()] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).replacingOccurrences(of: "\"\"", with: "\"") } } }
        var selected = [String](); let decoration = architecture == "ARM64" ? "ntarm64" : "ntamd64"
        for line in manufacturers {
            guard let (_, value) = pair(line) else { continue }
            let parts = tokens(value); let base = try expand(parts[0], strings: strings).lowercased()
            if parts.count == 1 { selected.append(base) }
            for suffix in parts.dropFirst() {
                let suffix = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
                if suffix == decoration || suffix.hasPrefix(decoration + ".") || suffix == "nt" { selected.append(base + "." + suffix) }
            }
        }
        var result = [String]()
        for section in selected { for line in sections[section] ?? [] {
            if let (name, _) = pair(line) { let model = try expand(name, strings: strings); if !model.isEmpty && !result.contains(where: { same($0, model) }) { result.append(model) } }
        } }
        guard !result.isEmpty else { throw DeploymentError("No \(architecture) driver names found in this INF.") }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
