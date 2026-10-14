using System.DirectoryServices;
using System.Security.Claims;
using System.Security.Principal;
using System.Runtime.Versioning;
namespace PrintDeploy.Web;
public interface IComputerDirectory {
    string AdminGroupSid { get; }
    DirectoryComputer? Computer(string name);
    IReadOnlyList<DirectoryOu> OrganizationalUnits();
}
public sealed class DevelopmentDirectory : IComputerDirectory {
    public string AdminGroupSid => "S-1-5-21-100-200-300-512";
    public DirectoryComputer? Computer(string name) => name.Equals("DEV-PC", StringComparison.OrdinalIgnoreCase) ? new(name.ToUpperInvariant(), "CN=DEV-PC,OU=Workstations,DC=example,DC=test", Guid.Parse("12ad62d4-7f4e-4a5c-b5cc-89412fa57c81")) : null;
    public IReadOnlyList<DirectoryOu> OrganizationalUnits() => [new("Workstations", "OU=Workstations,DC=example,DC=test"), new("Servers", "OU=Servers,DC=example,DC=test")];
}
[SupportedOSPlatform("windows")]
public sealed class ActiveDirectory : IComputerDirectory {
    readonly ServerOptions options;
    readonly object gate = new(); string? adminSid;
    public ActiveDirectory(ServerOptions options) { this.options = options; }
    string Prefix => string.IsNullOrWhiteSpace(options.DomainController) ? "LDAP://" : "LDAP://" + options.DomainController + "/";
    DirectoryEntry Entry(string path) => new(Prefix + path, null, null, AuthenticationTypes.Secure | AuthenticationTypes.Signing | AuthenticationTypes.Sealing);
    string NamingContext() { using var root = Entry("RootDSE"); return (string)root.Properties["defaultNamingContext"].Value!; }
    public string AdminGroupSid {
        get {
            if (!string.IsNullOrWhiteSpace(options.AdminGroupSid)) return new SecurityIdentifier(options.AdminGroupSid).Value;
            lock (gate) { if (adminSid is not null) return adminSid; using var root = Entry(NamingContext()); return adminSid = new SecurityIdentifier((byte[])root.Properties["objectSid"].Value!, 0).Value + "-512"; }
        }
    }
    public DirectoryComputer? Computer(string name) {
        if (!Rules.ComputerName(name)) throw new InvalidDataException("Invalid computer name.");
        using var root = Entry(NamingContext()); using var search = new DirectorySearcher(root) { Filter = "(&(objectCategory=computer)(sAMAccountName=" + name + "$))", ServerTimeLimit = TimeSpan.FromSeconds(10), ClientTimeout = TimeSpan.FromSeconds(15), SizeLimit = 2 };
        search.PropertiesToLoad.AddRange(["name", "distinguishedName", "objectGUID", "userAccountControl"]);
        using var results = search.FindAll(); if (results.Count == 0) return null;
        if (results.Count != 1) throw new InvalidDataException("Computer name is ambiguous in Active Directory.");
        var result = results[0]; var flags = Convert.ToInt32(result.Properties["userAccountControl"][0]); if ((flags & 2) != 0) return null;
        return new((string)result.Properties["name"][0], (string)result.Properties["distinguishedName"][0], new Guid((byte[])result.Properties["objectGUID"][0]));
    }
    public IReadOnlyList<DirectoryOu> OrganizationalUnits() {
        using var root = Entry(NamingContext()); using var search = new DirectorySearcher(root) { Filter = "(objectClass=organizationalUnit)", PageSize = 1000, SizeLimit = 10000, ServerTimeLimit = TimeSpan.FromSeconds(10), ClientTimeout = TimeSpan.FromSeconds(15) };
        search.PropertiesToLoad.AddRange(["name", "distinguishedName"]); using var results = search.FindAll();
        return results.Cast<SearchResult>().Select(r => new DirectoryOu((string)r.Properties["name"][0], (string)r.Properties["distinguishedName"][0])).OrderBy(x => x.DistinguishedName).ToArray();
    }
}
public static class AdminAccess {
    public static bool Allowed(ClaimsPrincipal user, string sid) {
        if (user.Identity?.IsAuthenticated != true) return false;
        if (user.HasClaim(ClaimTypes.GroupSid, sid)) return true;
        if (OperatingSystem.IsWindows() && user.Identity is WindowsIdentity identity) return new WindowsPrincipal(identity).IsInRole(new SecurityIdentifier(sid));
        return false;
    }
}
