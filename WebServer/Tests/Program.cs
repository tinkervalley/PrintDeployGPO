using PrintDeploy.Web;
using System.IO.Compression;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
var passed = 0;
void Check(bool value, string message) { if (!value) throw new Exception(message); passed++; Console.WriteLine("PASS " + message); }
void Reject(Action action, string message) { try { action(); } catch (Exception) { passed++; Console.WriteLine("PASS " + message); return; } throw new Exception("Expected rejection: " + message); }
var root = Path.Combine(Path.GetTempPath(), "pd-web-tests-" + Guid.NewGuid()); Directory.CreateDirectory(root);
try {
    var options = new ServerOptions { DataDirectory = root, PublicUrl = "http://localhost:3000" }; var directory = new DevelopmentDirectory();
    var store = new Store(options); var settings = store.Settings();
    Check(settings.DeploymentId != Guid.Empty && store.Revision() == 1, "Local SQLite creates a persistent deployment identity");
    Check(new Store(options).Settings().DeploymentId == settings.DeploymentId, "Reopening the database preserves identity");
    var ipp = new PrinterDefinition { Name = "Office", Address = "ipp://192.0.2.55:631/ipp/print", OrganizationalUnits = [] };
    Rules.ValidatePrinter(ipp, []); store.SavePrinter(ipp, 1);
    Reject(() => Rules.ValidatePrinter(ipp with { OrganizationalUnits = null! }, []), "Malformed null assignment fields cannot enter stored configuration");
    Reject(() => store.SavePrinter(ipp with { Name = "Concurrent" }, 1), "Stale administrator revision cannot overwrite data");
    Reject(() => store.SavePrinter(ipp with { Id = Guid.NewGuid(), Name = "office" }, store.Revision()), "Case-insensitive duplicate queue names rejected");
    var scoped = ipp with { Id = Guid.NewGuid(), Name = "Scoped", AllComputers = false, OrganizationalUnits = ["OU=Workstations,DC=example,DC=test"] };
    Check(Rules.Applies(scoped, directory.Computer("DEV-PC")) && !Rules.Applies(scoped, null), "OU rules use server-resolved computer membership");
    Check(Rules.InOu("CN=A,OU=Child,OU=Workstations,DC=example,DC=test", scoped.OrganizationalUnits[0], true) && !Rules.InOu("CN=A,OU=Child,OU=Workstations,DC=example,DC=test", scoped.OrganizationalUnits[0], false), "Child OU matching can be enabled or disabled");
    Check(!Rules.InOu("CN=A,OU=NotWorkstations,DC=example,DC=test", scoped.OrganizationalUnits[0], true), "OU name suffixes do not create false matches");
    Check(Rules.InOu(@"CN=A,OU=Sales\, West,DC=example,DC=test", @"OU=Sales\, West,DC=example,DC=test", false), "Escaped commas in distinguished names are preserved");
    Check(!AdminAccess.Allowed(new ClaimsPrincipal(new ClaimsIdentity()), directory.AdminGroupSid), "Anonymous identities cannot administer the server");
    Check(!AdminAccess.Allowed(new ClaimsPrincipal(new ClaimsIdentity([new Claim(ClaimTypes.Name, "DOMAIN\\User")], "test")), directory.AdminGroupSid), "An authenticated non-admin is denied");
    Check(AdminAccess.Allowed(new ClaimsPrincipal(new ClaimsIdentity([new Claim(ClaimTypes.GroupSid, directory.AdminGroupSid)], "test")), directory.AdminGroupSid), "Expected group SID authorizes a domain admin");
    foreach (var path in new[] { "../outside.inf", "C:/driver.inf", "folder/file:stream", "Drivers/CON.inf", "folder/../escape", "//server/share", "trailing./file" }) Reject(() => Rules.RelativePath(path), "Unsafe path rejected: " + path);
    var zipPath = Path.Combine(root, "bad.zip"); using (var zip = ZipFile.Open(zipPath, ZipArchiveMode.Create)) { using var writer = new StreamWriter(zip.CreateEntry("../outside.inf").Open()); writer.Write("bad"); }
    Reject(() => Packages.Extract(zipPath, Path.Combine(root, "extracted")), "ZIP traversal cannot escape package storage");
    File.Delete(zipPath); using (var zip = ZipFile.Open(zipPath, ZipArchiveMode.Create)) { zip.CreateEntry("Printer.inf"); zip.CreateEntry("printer.inf"); }
    Reject(() => Packages.Extract(zipPath, Path.Combine(root, "duplicates")), "Windows case-insensitive ZIP collisions rejected on every platform");
    var package = new DriverPackage(Guid.NewGuid(), "test.zip", new string('a', 64), 100, [new("printer.inf", 3, [new("Legacy x64", ["x64"])]), new("arm.inf", 4, [new("ARM driver", ["ARM64"])])]);
    var tcp = ipp with { Kind = "Type4", Address = "192.0.2.56", Drivers = new() { ["x64"] = new(package.Id, "printer.inf", "Legacy x64", "Type3"), ["ARM64"] = new(package.Id, "arm.inf", "ARM driver", "Type4") } };
    Rules.ValidatePrinter(tcp, [package]); Check(true, "One queue accepts independent native types and model names");
    Reject(() => Rules.ValidatePrinter(tcp with { Drivers = new() { ["ARM64"] = tcp.Drivers["x64"] } }, [package]), "Architecture mismatch rejected before publishing assignments");
    var engine = JsonSerializer.SerializeToElement(Rules.EnginePrinter(tcp), Json.Options);
    Check(engine.GetProperty("DriverPackages").GetProperty("x64").GetProperty("Kind").GetString() == "Type3" && engine.GetProperty("DriverPackages").GetProperty("ARM64").GetProperty("Kind").GetString() == "Type4", "HTTP printer records translate to the existing deployment schema");
    using var delivery = new Delivery(store, directory); var nonce = Guid.NewGuid().ToString("N"); var envelope = delivery.Bootstrap(nonce);
    using var rsa = RSA.Create(); rsa.ImportFromPem(File.ReadAllText(Path.Combine(root, "signing-key.pem")));
    var bytes = Convert.FromBase64String(envelope.Payload); var signature = Convert.FromBase64String(envelope.Signature);
    Check(rsa.VerifyData(bytes, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1), "Bootstrap signature verifies with the pinned server key");
    bytes[0] ^= 1; Check(!rsa.VerifyData(bytes, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1), "Tampered bootstrap cannot pass signature verification");
    Reject(() => delivery.Plan("DEV-PC*)(objectClass=*)", Guid.NewGuid(), nonce), "LDAP filter injection in claimed computer names rejected");
    Reject(() => delivery.Plan("UNKNOWN-PC", Guid.NewGuid(), nonce), "Unknown computers receive no destructive empty configuration by default");
    store.SavePrinter(scoped, store.Revision()); var plan = delivery.Plan("DEV-PC", Guid.NewGuid(), nonce);
    Check(plan.Configuration.GetProperty("Printers").GetArrayLength() == 2 && plan.DistinguishedName == directory.Computer("DEV-PC")!.DistinguishedName, "Plan returns global and matching OU printers");
    var startup = delivery.StartupScript(); Check(startup.Contains(delivery.PublicKeyXml) && startup.Contains("/client/bootstrap") && !startup.Contains("__TRANSPORT__"), "Generated standalone startup pins the key and downloads the task definition");
    var user = delivery.StartupScript(true); Check(user.Contains("-Mode CleanupUser") && !user.Contains("Register-PDWTask $server $root"), "Optional user logon reports connections without registering another task");
    store.SelectRemoval(new("DEV-PC", "Machine", "", "Old queue", "Old driver", "Old port", true), store.Revision()); var request = store.Removals("DEV-PC")[0];
    store.SelectRemoval(new("DEV-PC", "Machine", "", "Old queue", "Old driver", "Old port", true), store.Revision()); Check(store.Removals("DEV-PC")[0].Id == request.Id, "Removal requests retain one-shot IDs across repeated selections");
    var capacity = new Store(new ServerOptions { DataDirectory = Path.Combine(root, "capacity"), PublicUrl = options.PublicUrl }); var reportClient = Guid.NewGuid();
    using (var db = new Microsoft.Data.Sqlite.SqliteConnection("Data Source=" + Path.Combine(capacity.Root, "printdeploy.sqlite"))) {
        db.Open(); using var command = db.CreateCommand(); command.CommandText = "WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i<4999) INSERT INTO reports(client,scope,sid,computer,received,body) SELECT $client,'UserConnection','S-1-5-21-'||i,'DEV-PC','now','{}' FROM n"; command.Parameters.AddWithValue("$client", reportClient.ToString()); command.ExecuteNonQuery();
    }
    var boundedReport = new StoredReport(reportClient, "DEV-PC", "UserConnection", "S-1-5-21-5000", DateTimeOffset.UtcNow.ToString("o"), JsonSerializer.SerializeToElement(new { }));
    Reject(() => capacity.SaveReport(boundedReport), "A known client cannot bypass report capacity by inventing user SIDs");
    capacity.SaveReport(boundedReport with { UserSid = "S-1-5-21-0" }); Check(true, "Existing inventory can still refresh at report capacity");
    File.WriteAllText(Path.Combine(root, "startup.ps1"), startup); Console.WriteLine($"All {passed} web model checks passed.");
} finally { Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools(); Directory.Delete(root, true); }
