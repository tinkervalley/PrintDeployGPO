using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
namespace PrintDeploy.Web;
public sealed class Delivery : IDisposable {
    readonly RSA key; readonly Store store; readonly IComputerDirectory directory;
    readonly Dictionary<string, string> files = new(StringComparer.Ordinal);
    public string PublicKeyXml { get; }
    public string KeyFingerprint { get; }
    public DownloadFile[] ManifestFiles { get; }
    public Delivery(Store store, IComputerDirectory directory) {
        this.store = store; this.directory = directory;
        var path = Path.Combine(store.Root, "signing-key.pem"); key = RSA.Create(3072);
        if (File.Exists(path)) key.ImportFromPem(File.ReadAllText(path));
        else { using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None); var bytes = Encoding.ASCII.GetBytes(key.ExportPkcs8PrivateKeyPem()); file.Write(bytes); }
        var p = key.ExportParameters(false);
        PublicKeyXml = "<RSAKeyValue><Modulus>" + Convert.ToBase64String(p.Modulus!) + "</Modulus><Exponent>" + Convert.ToBase64String(p.Exponent!) + "</Exponent></RSAKeyValue>";
        KeyFingerprint = Rules.Hash(key.ExportSubjectPublicKeyInfo());
        var content = new List<DownloadFile>();
        foreach (var relative in new[] { "PrinterDeployment.ps1", "Modules/PrinterDeployment.Core.psm1", "Modules/PrinterDeployment.Clients.psm1", "Modules/PrinterDeployment.Deploy.psm1" }) Add("engine/" + relative, Path.Combine(AppContext.BaseDirectory, "engine", relative.Replace('/', Path.DirectorySeparatorChar)));
        foreach (var relative in new[] { "Transport.psm1", "Invoke-PrintDeployWeb.ps1" }) Add("client/" + relative, Path.Combine(AppContext.BaseDirectory, "client", relative));
        ManifestFiles = content.ToArray();
        void Add(string relative, string file) { var hash = Rules.HashFile(file); files[hash] = file; content.Add(new(relative, hash, new FileInfo(file).Length)); }
    }
    public string? FileForHash(string hash) => files.GetValueOrDefault(hash);
    public SignedEnvelope Sign<T>(T value) {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, Json.Options);
        byte[] signature; lock (key) signature = key.SignData(bytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        return new(Convert.ToBase64String(bytes), Convert.ToBase64String(signature));
    }
    public SignedEnvelope Bootstrap(string nonce) {
        CheckNonce(nonce); var settings = store.Settings();
        return Sign(new BootstrapManifest(1, settings.DeploymentId, nonce, DateTimeOffset.UtcNow.ToString("o"), new("PrintDeployWeb-" + settings.DeploymentId, "PrintDeploy Web; DeploymentId=" + settings.DeploymentId, settings.PollMinutes), ManifestFiles));
    }
    public ClientPlan Plan(string computerName, Guid clientId, string nonce) {
        CheckNonce(nonce); if (!Rules.ComputerName(computerName) || clientId == Guid.Empty) throw new InvalidDataException("Invalid client identity.");
        var state = store.Snapshot(); var settings = state.Settings; var computer = directory.Computer(computerName);
        if (computer is null && settings.RequireKnownComputer) throw new InvalidDataException("Computer is absent or disabled in Active Directory. Existing queues will be retained.");
        var desired = state.Printers.Where(p => Rules.Applies(p, computer)).ToArray();
        var engine = desired.Select(Rules.EnginePrinter).ToArray();
        // Detect driver-type conflicts for each native architecture before publishing a plan.
        foreach (var architecture in new[] { "x64", "ARM64" }) {
            var types = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var printer in desired.Where(p => p.Kind != "IPP")) {
                var assignment = printer.Drivers.GetValueOrDefault(architecture) ?? printer.Drivers.GetValueOrDefault("Shared"); if (assignment is null) continue;
                if (types.TryGetValue(assignment.DriverName, out var previous) && previous != assignment.Kind) throw new InvalidDataException("A selected driver name has conflicting types for " + architecture + ".");
                types[assignment.DriverName] = assignment.Kind;
            }
        }
        var requests = state.Removals.Where(r => r.ComputerName.Equals(computerName, StringComparison.OrdinalIgnoreCase) && !desired.Any(p => p.Name.Equals(r.Name, StringComparison.OrdinalIgnoreCase))).ToArray();
        var config = JsonSerializer.SerializeToElement(new { SchemaVersion = 2, settings.DeploymentId, Architecture = "x64", Cleanup = new { settings.RemoveStaleManaged, LegacyPrinterNames = Array.Empty<string>(), CleanupUserConnections = false }, Printers = engine, ClientRemovals = requests }, Json.Options);
        var packages = state.Packages; var ids = desired.SelectMany(p => p.Kind == "IPP" ? [] : p.Drivers.Values.Select(d => d.PackageId)).Distinct().ToArray();
        var downloads = ids.Select(id => { var package = packages.Single(p => p.Id == id); return new DownloadPackage(id, package.Sha256, package.Size); }).ToArray();
        return new(1, settings.DeploymentId, clientId, computerName.ToUpperInvariant(), nonce, DateTimeOffset.UtcNow.ToString("o"), computer?.DistinguishedName, config, downloads);
    }
    public string StartupScript(bool user = false) {
        var template = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "client", user ? "Report-UserPrinters.ps1.template" : "Startup.ps1.template"));
        var transport = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "client", "Transport.psm1"));
        var settings = store.Settings();
        return template.Replace("__TRANSPORT__", transport.Replace("Export-ModuleMember -Function *-PDW*", ""))
            .Replace("__SERVER__", "'" + settings.PublicUrl.Replace("'", "''") + "'")
            .Replace("__PUBLIC_KEY__", "'" + PublicKeyXml + "'").Replace("__DEPLOYMENT_ID__", settings.DeploymentId.ToString());
    }
    public static void CheckNonce(string nonce) { if (!System.Text.RegularExpressions.Regex.IsMatch(nonce, @"\A[0-9a-f]{32}\z")) throw new InvalidDataException("Invalid request nonce."); }
    public void Dispose() => key.Dispose();
}
