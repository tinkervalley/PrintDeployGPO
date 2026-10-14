using Microsoft.Data.Sqlite;
using System.Text.Json;
namespace PrintDeploy.Web;
public sealed class ConflictException : Exception { public ConflictException() : base("Another administrator changed the data. Reload and try again.") { } }
public sealed class Store {
    readonly string connectionString;
    public string Root { get; }
    public Store(ServerOptions options) {
        Root = Path.GetFullPath(options.DataDirectory == "" ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "PrintDeployWebServer") : options.DataDirectory);
        Directory.CreateDirectory(Root); Directory.CreateDirectory(Path.Combine(Root, "packages"));
        connectionString = new SqliteConnectionStringBuilder { DataSource = Path.Combine(Root, "printdeploy.sqlite"), DefaultTimeout = 30 }.ToString();
        using var db = Open();
        Execute(db, null, "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL, settings TEXT NOT NULL); CREATE TABLE IF NOT EXISTS printers (id TEXT PRIMARY KEY, name TEXT NOT NULL COLLATE NOCASE UNIQUE, body TEXT NOT NULL); CREATE TABLE IF NOT EXISTS packages (id TEXT PRIMARY KEY, body TEXT NOT NULL); CREATE TABLE IF NOT EXISTS removals (id TEXT PRIMARY KEY, computer TEXT NOT NULL COLLATE NOCASE, scope TEXT NOT NULL, sid TEXT NOT NULL, name TEXT NOT NULL COLLATE NOCASE, body TEXT NOT NULL, UNIQUE(computer,scope,sid,name)); CREATE TABLE IF NOT EXISTS reports (client TEXT NOT NULL, scope TEXT NOT NULL, sid TEXT NOT NULL, computer TEXT NOT NULL, received TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY(client,scope,sid)); CREATE TABLE IF NOT EXISTS history (id INTEGER PRIMARY KEY AUTOINCREMENT, received TEXT NOT NULL, body TEXT NOT NULL);");
        Execute(db, null, "INSERT OR IGNORE INTO state(id,revision,settings) VALUES(1,1,$settings)", ("$settings", Json.Serialize(new DeploymentSettings(Guid.NewGuid(), Rules.ServerUri(options.PublicUrl).GetLeftPart(UriPartial.Authority)))));
    }
    SqliteConnection Open() { var db = new SqliteConnection(connectionString); db.Open(); return db; }
    static void Execute(SqliteConnection db, SqliteTransaction? tx, string sql, params (string, object)[] values) { using var cmd = db.CreateCommand(); cmd.Transaction = tx; cmd.CommandText = sql; foreach (var (name, value) in values) cmd.Parameters.AddWithValue(name, value); cmd.ExecuteNonQuery(); }
    static List<T> Read<T>(SqliteConnection db, string sql, params (string, object)[] values) => Read<T>(db, null, sql, values);
    static List<T> Read<T>(SqliteConnection db, SqliteTransaction? tx, string sql, params (string, object)[] values) { using var cmd = db.CreateCommand(); cmd.Transaction = tx; cmd.CommandText = sql; foreach (var (name, value) in values) cmd.Parameters.AddWithValue(name, value); using var reader = cmd.ExecuteReader(); var list = new List<T>(); while (reader.Read()) list.Add(Json.Deserialize<T>(reader.GetString(0))); return list; }
    public DeploymentState Snapshot() {
        using var db = Open(); using var tx = db.BeginTransaction(deferred: true);
        using var cmd = db.CreateCommand(); cmd.Transaction = tx; cmd.CommandText = "SELECT revision FROM state WHERE id=1"; var revision = (long)cmd.ExecuteScalar()!;
        var state = new DeploymentState(revision, Read<DeploymentSettings>(db, tx, "SELECT settings FROM state WHERE id=1")[0], Read<PrinterDefinition>(db, tx, "SELECT body FROM printers ORDER BY name"), Read<DriverPackage>(db, tx, "SELECT body FROM packages ORDER BY id"), Read<RemovalRequest>(db, tx, "SELECT body FROM removals"));
        tx.Commit(); return state;
    }
    public long Revision() { using var db = Open(); using var cmd = db.CreateCommand(); cmd.CommandText = "SELECT revision FROM state WHERE id=1"; return (long)cmd.ExecuteScalar()!; }
    public DeploymentSettings Settings() { using var db = Open(); return Read<DeploymentSettings>(db, "SELECT settings FROM state WHERE id=1")[0]; }
    public List<PrinterDefinition> Printers() { using var db = Open(); return Read<PrinterDefinition>(db, "SELECT body FROM printers ORDER BY name"); }
    public List<DriverPackage> Packages() { using var db = Open(); return Read<DriverPackage>(db, "SELECT body FROM packages ORDER BY id"); }
    public List<RemovalRequest> Removals(string? computer = null) { using var db = Open(); return computer is null ? Read<RemovalRequest>(db, "SELECT body FROM removals") : Read<RemovalRequest>(db, "SELECT body FROM removals WHERE computer=$computer", ("$computer", computer)); }
    public List<StoredReport> Reports() { using var db = Open(); return Read<StoredReport>(db, "SELECT body FROM reports ORDER BY computer,scope,sid LIMIT 5000"); }
    void Mutate(long revision, Action<SqliteConnection, SqliteTransaction> action) {
        using var db = Open(); using var tx = db.BeginTransaction(); using var cmd = db.CreateCommand(); cmd.Transaction = tx; cmd.CommandText = "SELECT revision FROM state WHERE id=1";
        if ((long)cmd.ExecuteScalar()! != revision) throw new ConflictException();
        action(db, tx); Execute(db, tx, "UPDATE state SET revision=revision+1 WHERE id=1"); tx.Commit();
    }
    public void SavePrinter(PrinterDefinition printer, long revision) => Mutate(revision, (db, tx) => Execute(db, tx, "INSERT INTO printers(id,name,body) VALUES($id,$name,$body) ON CONFLICT(id) DO UPDATE SET name=excluded.name,body=excluded.body", ("$id", printer.Id.ToString()), ("$name", printer.Name), ("$body", Json.Serialize(printer))));
    public void DeletePrinter(Guid id, long revision) => Mutate(revision, (db, tx) => Execute(db, tx, "DELETE FROM printers WHERE id=$id", ("$id", id.ToString())));
    public void SaveSettings(DeploymentSettings settings, long revision) {
        if (settings.DeploymentId != Settings().DeploymentId || settings.PollMinutes is < 15 or > 1440) throw new InvalidDataException("Deployment identity is fixed; polling must be 15–1440 minutes.");
        Rules.ServerUri(settings.PublicUrl);
        Mutate(revision, (db, tx) => Execute(db, tx, "UPDATE state SET settings=$body WHERE id=1", ("$body", Json.Serialize(settings))));
    }
    public void AddPackage(DriverPackage package, long revision) => Mutate(revision, (db, tx) => Execute(db, tx, "INSERT INTO packages(id,body) VALUES($id,$body)", ("$id", package.Id.ToString()), ("$body", Json.Serialize(package))));
    public void SelectRemoval(RemovalSelection selection, long revision) {
        if (!Rules.ComputerName(selection.ComputerName) || selection.Scope is not ("Machine" or "UserConnection") || (selection.Scope == "Machine" && selection.UserSid != "") || (selection.Scope == "UserConnection" && !System.Text.RegularExpressions.Regex.IsMatch(selection.UserSid, @"\AS-1-\d+(-\d+)+\z"))) throw new InvalidDataException("Invalid removal identity.");
        Rules.Text(selection.Name); Rules.Text(selection.DriverName); Rules.Text(selection.PortName, 500);
        var request = new RemovalRequest(Guid.NewGuid(), selection.ComputerName.ToUpperInvariant(), selection.Scope, selection.UserSid, selection.Name, selection.DriverName, selection.PortName, DateTimeOffset.UtcNow.ToString("o"));
        Mutate(revision, (db, tx) => {
            if (!selection.Selected) Execute(db, tx, "DELETE FROM removals WHERE computer=$computer AND scope=$scope AND sid=$sid AND name=$name", ("$computer", request.ComputerName), ("$scope", request.Scope), ("$sid", request.UserSid), ("$name", request.Name));
            else Execute(db, tx, "INSERT OR IGNORE INTO removals(id,computer,scope,sid,name,body) VALUES($id,$computer,$scope,$sid,$name,$body)", ("$id", request.Id.ToString()), ("$computer", request.ComputerName), ("$scope", request.Scope), ("$sid", request.UserSid), ("$name", request.Name), ("$body", Json.Serialize(request)));
        });
    }
    public void SaveReport(StoredReport report) {
        using var db = Open(); using var tx = db.BeginTransaction();
        using var count = db.CreateCommand(); count.Transaction = tx; count.CommandText = "SELECT COUNT(*) FROM reports WHERE NOT (client=$client AND scope=$scope AND sid=$sid)"; count.Parameters.AddWithValue("$client", report.ClientId.ToString()); count.Parameters.AddWithValue("$scope", report.Scope); count.Parameters.AddWithValue("$sid", report.UserSid);
        if ((long)count.ExecuteScalar()! >= 5000) throw new InvalidDataException("Report capacity reached.");
        Execute(db, tx, "INSERT INTO reports(client,scope,sid,computer,received,body) VALUES($client,$scope,$sid,$computer,$received,$body) ON CONFLICT(client,scope,sid) DO UPDATE SET computer=excluded.computer,received=excluded.received,body=excluded.body", ("$client", report.ClientId.ToString()), ("$scope", report.Scope), ("$sid", report.UserSid), ("$computer", report.ComputerName), ("$received", report.ReceivedAt), ("$body", Json.Serialize(report)));
        Execute(db, tx, "INSERT INTO history(received,body) VALUES($received,$body); DELETE FROM history WHERE id NOT IN (SELECT id FROM history ORDER BY id DESC LIMIT 10000)", ("$received", report.ReceivedAt), ("$body", Json.Serialize(report))); tx.Commit();
    }
}
