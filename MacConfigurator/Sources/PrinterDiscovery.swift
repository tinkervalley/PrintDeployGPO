import AppKit

struct DiscoveredPrinter {
    let name: String, host: String, address: String, protocolName: String, path: String, model: String, location: String
    let port: Int
    var key: String { "\(host.lowercased()):\(port):\(protocolName):\(path)" }
    static func make(name: String, host: String, ipv4: String? = nil, type: String, port: Int, txt: [String: Data]) -> DiscoveredPrinter? {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard validHost(host), (1...65535).contains(port), ["_ipp._tcp.", "_ipps._tcp.", "_pdl-datastream._tcp."].contains(type) else { return nil }
        func value(_ key: String) -> String { String(data: txt[key] ?? Data(), encoding: .utf8) ?? "" }
        func clean(_ string: String) -> String { String(string.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(200)) }
        let proto = type == "_ipps._tcp." ? "ipps" : type == "_ipp._tcp." ? "ipp" : "raw"
        let resource = value("rp"), path = resource.isEmpty ? "/ipp" : "/" + resource.drop(while: { $0 == "/" })
        guard path.count <= 1024, !path.contains("#"), !path.contains("?"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return DiscoveredPrinter(name: clean(name), host: host, address: proto == "ipps" ? host : ipv4 ?? host, protocolName: proto, path: path, model: clean(value("ty")), location: clean(value("note")), port: port)
    }
}

final class PrinterDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var changed: (([DiscoveredPrinter], String) -> Void)?
    private var browsers = [NetServiceBrowser](), services = [String: NetService](), results = [String: DiscoveredPrinter]()
    private var failures = [String](), deadline: Timer?, active = false
    func start() {
        stop(); active = true; results = [:]; failures = []
        changed?([], "Searching the local network for advertised IPP, IPPS and RAW printers…")
        for type in ["_ipp._tcp.", "_ipps._tcp.", "_pdl-datastream._tcp."] {
            let browser = NetServiceBrowser(); browser.delegate = self; browser.schedule(in: .main, forMode: .common); browsers.append(browser)
            browser.searchForServices(ofType: type, inDomain: "local.")
        }
        let timer = Timer(timeInterval: 8, repeats: false) { [weak self] _ in self?.finish() }; deadline = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stop() {
        active = false; deadline?.invalidate(); deadline = nil
        for browser in browsers { browser.stop(); browser.remove(from: .main, forMode: .common); browser.delegate = nil }
        for service in services.values { service.stop(); service.remove(from: .main, forMode: .common); service.delegate = nil }
        browsers = []; services = [:]
    }
    private func finish() {
        let values = snapshot(); stop()
        let message = values.isEmpty ? "No advertised printers found. Check local-network permission, Bonjour/mDNS and network isolation, or enter the printer manually." : "\(values.count) advertised endpoints found. Select one to fill the printer editor."
        changed?(values, failures.isEmpty ? message : message + " Some discovery services could not start.")
    }
    private func snapshot() -> [DiscoveredPrinter] { results.values.sorted { ($0.name, $0.protocolName) < ($1.name, $1.protocolName) } }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard active, services.count < 128 else { return }
        let key = service.name + "|" + service.type + "|" + service.domain
        guard services[key] == nil else { return }
        services[key] = service; service.delegate = self; service.schedule(in: .main, forMode: .common); service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) { failures.append("Browse failed"); changed?(snapshot(), "Discovery could not start for a service. Check local-network permission and your network connection.") }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard active, let host = sender.hostName else { return }
        var ipv4: String?
        for address in sender.addresses ?? [] {
            address.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, raw.count >= MemoryLayout<sockaddr_in>.size, base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family == sa_family_t(AF_INET) else { return }
                var value = base.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)) != nil { ipv4 = String(cString: buffer) }
            }
            if ipv4 != nil { break }
        }
        let txt = sender.txtRecordData().map { NetService.dictionary(fromTXTRecord: $0) } ?? [:]
        guard let printer = DiscoveredPrinter.make(name: sender.name, host: host, ipv4: ipv4, type: sender.type, port: sender.port, txt: txt) else { return }
        results[printer.key] = printer; changed?(snapshot(), "Searching… \(results.count) advertised endpoints found.")
    }
    deinit { stop() }
}

final class PrinterDiscoveryDialog: NSObject, NSWindowDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 470), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    let table = DataTable([("Name", "Printer", 210), ("Protocol", "Protocol", 75), ("Address", "Address / hostname", 200), ("Port", "Port", 60), ("Path", "IPP path", 140), ("Model", "Advertised model", 180)])
    let status = label(""), scanner = PrinterDiscovery()
    var printers = [DiscoveredPrinter](), result: DiscoveredPrinter?
    override init() {
        super.init(); window.title = "Discover network printers"; window.isReleasedWhenClosed = false; window.delegate = self; window.minSize = NSSize(width: 780, height: 420)
        let hint = label("Discovery searches the local network using Bonjour/mDNS. Printers on other VLANs or without advertisements may need manual entry. Type3/Type4 drivers must still be selected manually.")
        let rescan = ActionButton("Scan again") { [weak self] in self?.scanner.start() }
        let cancel = ActionButton("Cancel") { [weak self] in self?.close() }; cancel.keyEquivalent = "\u{1b}"
        let use = ActionButton("Use selected printer") { [weak self] in self?.select() }; use.keyEquivalent = "\r"
        let body = stack([hint, table.scroll, status, stack([rescan, cancel, use])], vertical: true)
        fill(body, in: window.contentView!, inset: 20); table.scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        for view in body.arrangedSubviews { view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        scanner.changed = { [weak self] printers, message in self?.replace(printers, status: message) }
    }
    func replace(_ values: [DiscoveredPrinter], status: String) {
        let selected = printers.indices.contains(table.table.selectedRow) ? printers[table.table.selectedRow].key : ""
        printers = values; table.replace(values.map { ["Name": $0.name, "Protocol": $0.protocolName.uppercased(), "Address": $0.address, "Port": String($0.port), "Path": $0.protocolName == "raw" ? "" : $0.path, "Model": $0.model] }, selected: values.firstIndex { $0.key == selected } ?? -1)
        self.status.stringValue = status
    }
    func select() { let row = table.table.selectedRow; guard printers.indices.contains(row) else { status.stringValue = "Select a detected printer first."; return }; result = printers[row]; close() }
    func close() { scanner.stop(); if NSApp.modalWindow === window { NSApp.stopModal() }; window.orderOut(nil) }
    func run() -> DiscoveredPrinter? { window.center(); window.makeKeyAndOrderFront(nil); scanner.start(); _ = NSApp.runModal(for: window); scanner.stop(); window.orderOut(nil); return result }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return true }
}
