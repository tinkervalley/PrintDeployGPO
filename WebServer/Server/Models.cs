using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace PrintDeploy.Web;
public sealed class ServerOptions {
    public int Port { get; set; } = 3000;
    public string PublicUrl { get; set; } = "http://printdeploy.example.com:3000";
    public string DataDirectory { get; set; } = "";
    public string AdminGroupSid { get; set; } = "";
    public string DomainController { get; set; } = "";
    public string HttpsCertificateThumbprint { get; set; } = "";
    public bool DevelopmentMode { get; set; }
    public string PowerShellPath { get; set; } = "";
}
public sealed record DeploymentSettings(Guid DeploymentId, string PublicUrl, int PollMinutes = 60, bool RemoveStaleManaged = true, bool RequireKnownComputer = true);
public sealed record DriverModel(string Name, string[] Architectures);
public sealed record InfCatalog(string Path, int DriverType, DriverModel[] Models);
public sealed record DriverPackage(Guid Id, string Name, string Sha256, long Size, InfCatalog[] Infs);
public sealed record DriverAssignment(Guid PackageId, string InfPath, string DriverName, string Kind);
public sealed record PrinterDefinition {
    public Guid Id { get; init; } = Guid.NewGuid();
    public string Name { get; init; } = "";
    public string Kind { get; init; } = "IPP";
    public string Address { get; init; } = "";
    public int PortNumber { get; init; } = 9100;
    public string Location { get; init; } = "";
    public string Comment { get; init; } = "";
    public bool Enabled { get; init; } = true;
    public bool AllComputers { get; init; } = true;
    public bool IncludeChildOus { get; init; } = true;
    public string[] OrganizationalUnits { get; init; } = [];
    public Dictionary<string, DriverAssignment> Drivers { get; init; } = [];
}
public sealed record DirectoryComputer(string Name, string DistinguishedName, Guid ObjectId);
public sealed record DirectoryOu(string Name, string DistinguishedName);
public sealed record RemovalRequest(Guid Id, string ComputerName, string Scope, string UserSid, string Name, string DriverName, string PortName, string RequestedAt);
public sealed record RemovalSelection(string ComputerName, string Scope, string UserSid, string Name, string DriverName, string PortName, bool Selected);
public sealed record StoredReport(Guid ClientId, string ComputerName, string Scope, string UserSid, string ReceivedAt, JsonElement Report);
public sealed record DeploymentState(long Revision, DeploymentSettings Settings, List<PrinterDefinition> Printers, List<DriverPackage> Packages, List<RemovalRequest> Removals);
public sealed record SignedEnvelope(string Payload, string Signature);
public sealed record DownloadFile(string Path, string Hash, long Size);
public sealed record DownloadPackage(Guid Id, string Hash, long Size);
public sealed record TaskDefinition(string Name, string Description, int PollMinutes);
public sealed record BootstrapManifest(int SchemaVersion, Guid DeploymentId, string Nonce, string IssuedAt, TaskDefinition Task, DownloadFile[] Files);
public sealed record ClientPlan(int SchemaVersion, Guid DeploymentId, Guid ClientId, string ComputerName, string Nonce, string IssuedAt, string? DistinguishedName, JsonElement Configuration, DownloadPackage[] Packages);
public static class Json {
    public static readonly JsonSerializerOptions Options = new() { PropertyNamingPolicy = null, PropertyNameCaseInsensitive = false, WriteIndented = false };
    public static string Serialize<T>(T value) => JsonSerializer.Serialize(value, Options);
    public static T Deserialize<T>(string text) => JsonSerializer.Deserialize<T>(text, Options) ?? throw new InvalidDataException("Empty JSON.");
}
public static class Rules {
    public static bool ComputerName(string name) => Regex.IsMatch(name, @"\A[A-Za-z0-9][A-Za-z0-9-]{0,62}\z");
    public static string Text(string value, int max = 200) {
        if (string.IsNullOrWhiteSpace(value) || value.Length > max || value.Any(char.IsControl)) throw new InvalidDataException("Invalid or empty text field.");
        return value;
    }
    public static Uri ServerUri(string value) {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https") || uri.UserInfo != "" || uri.Query != "" || uri.Fragment != "" || uri.AbsolutePath != "/" || uri.HostNameType == UriHostNameType.Unknown)
            throw new InvalidDataException("Use a server URL such as http://printdeploy.example.com:3000, without a path or credentials.");
        return uri;
    }
    public static string RelativePath(string value) {
        var path = value.Replace('\\', '/');
        if (string.IsNullOrEmpty(path) || path.Length > 220 || path.StartsWith('/') || path.Split('/').Any(p => p is "" or "." or ".." || p.EndsWith('.') || p.EndsWith(' ') || p.Any(c => char.IsControl(c) || ":*?\"<>|".Contains(c)) || Regex.IsMatch(p, @"\A(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)", RegexOptions.IgnoreCase)))
            throw new InvalidDataException("Invalid package path.");
        return path;
    }
    public static string Hash(byte[] data) => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
    public static string HashFile(string path) { using var stream = File.OpenRead(path); return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant(); }
    public static string[] DnParts(string dn) {
        var result = new List<string>(); var start = 0; var escaped = false;
        for (var i = 0; i < dn.Length; i++) {
            if (escaped) { escaped = false; continue; }
            if (dn[i] == '\\') { escaped = true; continue; }
            if (dn[i] == ',') { result.Add(dn[start..i].Trim()); start = i + 1; }
        }
        if (escaped) throw new InvalidDataException("Invalid distinguished name escape.");
        result.Add(dn[start..].Trim());
        if (result.Count < 2 || result.Any(x => !x.Contains('=') || x.Length < 3)) throw new InvalidDataException("Invalid distinguished name.");
        return result.ToArray();
    }
    public static bool InOu(string computerDn, string ouDn, bool children) {
        var computer = DnParts(computerDn); var ou = DnParts(ouDn);
        if (computer.Length <= ou.Length || (!children && computer.Length != ou.Length + 1)) return false;
        return computer[^ou.Length..].SequenceEqual(ou, StringComparer.OrdinalIgnoreCase);
    }
    public static bool Applies(PrinterDefinition printer, DirectoryComputer? computer) => printer.Enabled && (printer.AllComputers || computer is not null && printer.OrganizationalUnits.Any(ou => InOu(computer.DistinguishedName, ou, printer.IncludeChildOus)));
    public static void ValidatePrinter(PrinterDefinition p, IReadOnlyList<DriverPackage> packages) {
        Text(p.Name); if (p.Id == Guid.Empty || p.Location is null || p.Comment is null || p.Drivers is null || p.OrganizationalUnits is null || p.Location.Length > 500 || p.Comment.Length > 1000) throw new InvalidDataException("Invalid printer fields.");
        if (!p.AllComputers && p.OrganizationalUnits.Length == 0) throw new InvalidDataException("Choose at least one OU or target all computers.");
        foreach (var ou in p.OrganizationalUnits) { Text(ou, 2000); if (!DnParts(ou)[0].StartsWith("OU=", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Target must be an organizational unit."); }
        if (p.Kind == "IPP") {
            if (!Uri.TryCreate(p.Address, UriKind.Absolute, out var uri) || uri.Scheme is not ("ipp" or "ipps" or "http" or "https") || uri.Host == "" || uri.UserInfo != "" || uri.Fragment != "") throw new InvalidDataException("Invalid IPP URL.");
        } else if (p.Kind is "Type3" or "Type4") {
            if (Uri.CheckHostName(p.Address) == UriHostNameType.Unknown || p.Address.Any(c => char.IsWhiteSpace(c) || "/@?#".Contains(c)) || p.PortNumber is < 1 or > 65535 || p.Drivers.Count == 0) throw new InvalidDataException("Invalid TCP endpoint or missing driver assignment.");
            foreach (var (target, driver) in p.Drivers) {
                if (target is not ("Shared" or "x64" or "ARM64") || driver is null || driver.Kind is not ("Type3" or "Type4")) throw new InvalidDataException("Invalid architecture or driver type.");
                var package = packages.SingleOrDefault(x => x.Id == driver.PackageId) ?? throw new InvalidDataException("Driver package does not exist.");
                var inf = package.Infs.SingleOrDefault(x => x.Path == RelativePath(driver.InfPath) && x.DriverType == int.Parse(driver.Kind[4..])) ?? throw new InvalidDataException("INF does not match the selected package/type.");
                var model = inf.Models.SingleOrDefault(x => x.Name.Equals(driver.DriverName, StringComparison.OrdinalIgnoreCase)) ?? throw new InvalidDataException("Choose a detected driver model.");
                if (target != "Shared" && !model.Architectures.Contains(target)) throw new InvalidDataException("Driver model does not support the selected architecture.");
            }
        } else throw new InvalidDataException("Unknown printer type.");
    }
    public static object EnginePrinter(PrinterDefinition p) {
        object Package(DriverAssignment d) => new { d.Kind, PackagePath = "Drivers\\" + d.PackageId, InfPath = "Drivers\\" + d.PackageId + "\\" + d.InfPath.Replace('/', '\\'), d.DriverName };
        var fields = new Dictionary<string, object?> { ["Name"] = p.Name, ["Kind"] = p.Kind, ["Address"] = p.Address, ["PortNumber"] = p.PortNumber, ["Location"] = p.Location, ["Comment"] = p.Comment, ["PackagePath"] = "", ["InfPath"] = "", ["DriverName"] = "" };
        if (p.Kind != "IPP") {
            if (p.Drivers.TryGetValue("Shared", out var shared)) { fields["Kind"] = shared.Kind; fields["PackagePath"] = "Drivers\\" + shared.PackageId; fields["InfPath"] = "Drivers\\" + shared.PackageId + "\\" + shared.InfPath.Replace('/', '\\'); fields["DriverName"] = shared.DriverName; }
            var variants = p.Drivers.Where(x => x.Key != "Shared").ToDictionary(x => x.Key, x => Package(x.Value));
            if (variants.Count > 0) fields["DriverPackages"] = variants;
        }
        return fields;
    }
}
