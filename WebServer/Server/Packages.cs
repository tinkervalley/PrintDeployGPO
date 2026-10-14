using System.Diagnostics;
using System.IO.Compression;
using System.Text.Json;
namespace PrintDeploy.Web;
public interface IPackageCatalog { Task<InfCatalog[]> Read(string folder, int type, CancellationToken cancel); }
public sealed class PowerShellCatalog(ServerOptions options) : IPackageCatalog {
    public async Task<InfCatalog[]> Read(string folder, int type, CancellationToken cancel) {
        var executable = options.PowerShellPath != "" ? options.PowerShellPath : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-File", Path.Combine(AppContext.BaseDirectory, "client", "Read-PackageCatalog.ps1"), "-Root", folder, "-DriverType", type.ToString(), "-CoreModule", Path.Combine(AppContext.BaseDirectory, "engine", "Modules", "PrinterDeployment.Core.psm1") }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidDataException("Could not start PowerShell package inspection.");
        var output = process.StandardOutput.ReadToEndAsync(cancel); var error = process.StandardError.ReadToEndAsync(cancel);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel); timeout.CancelAfter(TimeSpan.FromSeconds(60));
        try { await process.WaitForExitAsync(timeout.Token); } catch { try { process.Kill(true); } catch { } throw new InvalidDataException("Package inspection timed out or was cancelled."); }
        var text = await output; var errors = await error;
        if (process.ExitCode != 0 || text.Length > 4_000_000) throw new InvalidDataException("Package inspection failed: " + errors[..Math.Min(errors.Length, 1200)]);
        return Json.Deserialize<InfCatalog[]>(text);
    }
}
public sealed class Packages(Store store, IPackageCatalog catalog) {
    public const long MaxZipBytes = 256L * 1024 * 1024;
    public static void Extract(string archive, string folder) {
        using var zip = ZipFile.OpenRead(archive);
        if (zip.Entries.Count > 10000) throw new InvalidDataException("Package contains too many files.");
        long total = 0; var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in zip.Entries) {
            var directory = entry.FullName.EndsWith('/') || entry.FullName.EndsWith('\\');
            var name = entry.FullName.TrimEnd('/', '\\'); if (name == "") continue;
            name = Rules.RelativePath(name);
            if (!seen.Add(name) || ((entry.ExternalAttributes >> 16) & 0xF000) == 0xA000 || (entry.ExternalAttributes & 0x400) != 0) throw new InvalidDataException("Duplicate names, links and reparse points are not allowed in packages.");
            total = checked(total + entry.Length); if (total > 1024L * 1024 * 1024 || entry.Length > 256L * 1024 * 1024) throw new InvalidDataException("Extracted package exceeds size limits.");
            var destination = Path.Combine(folder, name.Replace('/', Path.DirectorySeparatorChar));
            if (directory) Directory.CreateDirectory(destination);
            else { Directory.CreateDirectory(Path.GetDirectoryName(destination)!); using var source = entry.Open(); using var target = new FileStream(destination, FileMode.CreateNew, FileAccess.Write); source.CopyTo(target); if (target.Length != entry.Length) throw new InvalidDataException("ZIP file length mismatch."); }
        }
    }
    public async Task<DriverPackage> Import(Stream source, string name, int type, long revision, CancellationToken cancel) {
        if (type is not (3 or 4)) throw new InvalidDataException("Choose Type3 or Type4 before uploading.");
        Rules.Text(name, 150); var id = Guid.NewGuid(); var folder = Path.Combine(store.Root, "packages", id.ToString()); Directory.CreateDirectory(folder);
        var archive = Path.Combine(folder, "package.zip"); var extracted = Path.Combine(folder, "files"); Directory.CreateDirectory(extracted);
        try {
            await using (var target = new FileStream(archive, FileMode.CreateNew, FileAccess.Write)) {
                var buffer = new byte[65536]; long count = 0; int read;
                while ((read = await source.ReadAsync(buffer, cancel)) > 0) { count += read; if (count > MaxZipBytes) throw new InvalidDataException("ZIP exceeds 256 MB."); await target.WriteAsync(buffer.AsMemory(0, read), cancel); }
            }
            Extract(archive, extracted);
            var infs = await catalog.Read(extracted, type, cancel);
            if (infs.Length == 0 || infs.Length > 256) throw new InvalidDataException("No compatible printer INF models were detected.");
            foreach (var inf in infs) { Rules.RelativePath(inf.Path); if (inf.DriverType != type || inf.Models.Length == 0) throw new InvalidDataException("Invalid INF catalog."); }
            var package = new DriverPackage(id, name, Rules.HashFile(archive), new FileInfo(archive).Length, infs);
            store.AddPackage(package, revision); return package;
        } catch { Directory.Delete(folder, true); throw; }
    }
    public string? Archive(Guid id, string hash) {
        var package = store.Packages().SingleOrDefault(p => p.Id == id && p.Sha256 == hash);
        return package is null ? null : Path.Combine(store.Root, "packages", id.ToString(), "package.zip");
    }
}
