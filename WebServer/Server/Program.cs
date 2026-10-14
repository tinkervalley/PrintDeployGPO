using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Negotiate;
using Microsoft.AspNetCore.Antiforgery;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Options;
using PrintDeploy.Web;
using System.Net;
using System.Security.Claims;
using System.Security.Cryptography.X509Certificates;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.RateLimiting;

var builder = WebApplication.CreateBuilder(args);
builder.Configuration.AddJsonFile("appsettings.Local.json", optional: true, reloadOnChange: false);
var options = builder.Configuration.GetSection("PrintDeploy").Get<ServerOptions>() ?? new();
if (options.Port is < 1 or > 65535) throw new InvalidDataException("Invalid listening port.");
if (options.DevelopmentMode && !builder.Environment.IsDevelopment()) throw new InvalidDataException("DevelopmentMode is allowed only with ASPNETCORE_ENVIRONMENT=Development and loopback binding.");
if (!OperatingSystem.IsWindows() && !options.DevelopmentMode) throw new PlatformNotSupportedException("Production PrintDeploy Web requires a domain-joined Windows server.");
if (options.DevelopmentMode && options.DataDirectory == "") throw new InvalidDataException("Development requires an explicit temporary DataDirectory.");
builder.Host.UseWindowsService(o => o.ServiceName = "PrintDeployWeb");
builder.WebHost.ConfigureKestrel(server => {
    server.Limits.MaxRequestBodySize = Packages.MaxZipBytes + 1024 * 1024;
    if (options.DevelopmentMode) server.ListenLocalhost(options.Port);
    else if (options.HttpsCertificateThumbprint != "") {
        using var certificates = new X509Store(StoreName.My, StoreLocation.LocalMachine); certificates.Open(OpenFlags.ReadOnly);
        var cert = certificates.Certificates.Find(X509FindType.FindByThumbprint, options.HttpsCertificateThumbprint, validOnly: true).OfType<X509Certificate2>().FirstOrDefault(c => c.HasPrivateKey) ?? throw new InvalidDataException("HTTPS certificate/private key not found in Local Computer\\Personal.");
        server.ListenAnyIP(options.Port, listen => listen.UseHttps(cert));
    } else server.ListenAnyIP(options.Port);
});
builder.Services.AddSingleton(options);
builder.Services.AddSingleton<Store>();
if (options.DevelopmentMode) builder.Services.AddSingleton<IComputerDirectory, DevelopmentDirectory>();
else if (OperatingSystem.IsWindows()) builder.Services.AddSingleton<IComputerDirectory, ActiveDirectory>();
builder.Services.AddSingleton<Delivery>(); builder.Services.AddSingleton<IPackageCatalog, PowerShellCatalog>(); builder.Services.AddSingleton<Packages>();
builder.Services.Configure<FormOptions>(o => o.MultipartBodyLengthLimit = Packages.MaxZipBytes + 1024 * 1024);
builder.Services.ConfigureHttpJsonOptions(o => { o.SerializerOptions.PropertyNamingPolicy = null; o.SerializerOptions.PropertyNameCaseInsensitive = false; });
if (options.DevelopmentMode) builder.Services.AddAuthentication("Development").AddScheme<AuthenticationSchemeOptions, DevelopmentAuthentication>("Development", _ => { });
else builder.Services.AddAuthentication(NegotiateDefaults.AuthenticationScheme).AddNegotiate();
builder.Services.AddAuthorization(o => o.AddPolicy("DomainAdmins", p => p.RequireAuthenticatedUser().RequireAssertion(context => {
    var http = context.Resource as HttpContext; if (http is null || context.User.Identity?.IsAuthenticated != true) return false;
    var directory = http.RequestServices.GetRequiredService<IComputerDirectory>(); return AdminAccess.Allowed(context.User, directory.AdminGroupSid);
})));
builder.Services.AddAntiforgery(o => { o.HeaderName = "X-CSRF-Token"; o.Cookie.Name = "PrintDeploy-CSRF"; o.Cookie.HttpOnly = true; o.Cookie.SameSite = SameSiteMode.Strict; o.Cookie.SecurePolicy = CookieSecurePolicy.SameAsRequest; });
builder.Services.AddRateLimiter(o => {
    o.RejectionStatusCode = 429;
    o.AddPolicy("Clients", context => RateLimitPartition.GetFixedWindowLimiter(context.Connection.RemoteIpAddress?.ToString() ?? "unknown", _ => new FixedWindowRateLimiterOptions { PermitLimit = 120, Window = TimeSpan.FromMinutes(1), QueueLimit = 0 }));
});
var app = builder.Build();
_ = app.Services.GetRequiredService<Delivery>(); // Ensure the key, database and published client bundle exist before listening.
app.Use(async (context, next) => {
    context.Response.Headers["X-Content-Type-Options"] = "nosniff";
    context.Response.Headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'";
    context.Response.Headers["Referrer-Policy"] = "no-referrer";
    if (context.Request.Path.StartsWithSegments("/api") || context.Request.Path.StartsWithSegments("/client")) context.Response.Headers.CacheControl = "no-store";
    try { await next(); }
    catch (Exception error) when (!context.Response.HasStarted) {
        var code = error is ConflictException ? 409 : error is InvalidDataException or JsonException or BadHttpRequestException or ArgumentException or KeyNotFoundException or FormatException or OverflowException ? 400 : error is AntiforgeryValidationException ? 403 : error is SqliteException db && db.SqliteErrorCode == 19 ? 409 : 503;
        context.Response.StatusCode = code;
        var message = code == 503 ? "Server operation failed. Check the server log and Active Directory connectivity; clients will retain their current queues." : error is SqliteException ? "A printer with that name already exists." : error.Message;
        if (code == 503) app.Logger.LogError(error, "PrintDeploy request failed: {Path}", context.Request.Path);
        await context.Response.WriteAsJsonAsync(new { Error = message });
    }
});
app.UseDefaultFiles(); app.UseStaticFiles(); app.UseRateLimiter(); app.UseAuthentication(); app.UseAuthorization();
var admin = app.MapGroup("/api/admin").RequireAuthorization("DomainAdmins");
admin.AddEndpointFilter(async (invocation, next) => {
    if (HttpMethods.IsPost(invocation.HttpContext.Request.Method) || HttpMethods.IsPut(invocation.HttpContext.Request.Method) || HttpMethods.IsDelete(invocation.HttpContext.Request.Method))
        await invocation.HttpContext.RequestServices.GetRequiredService<IAntiforgery>().ValidateRequestAsync(invocation.HttpContext);
    return await next(invocation);
});
admin.MapGet("/session", (HttpContext context, IAntiforgery csrf, Delivery delivery) => new { User = context.User.Identity?.Name, CsrfToken = csrf.GetAndStoreTokens(context).RequestToken, delivery.KeyFingerprint, DevelopmentMode = options.DevelopmentMode });
admin.MapGet("/state", (HttpContext context, Store store) => { var state = store.Snapshot(); context.Response.Headers.ETag = "\"" + state.Revision + "\""; return state; });
admin.MapGet("/ous", (IComputerDirectory directory) => directory.OrganizationalUnits());
admin.MapGet("/clients", (Store store) => store.Reports());
admin.MapGet("/preview", (string computerName, Store store, Delivery delivery) => delivery.Plan(computerName, Guid.NewGuid(), Guid.NewGuid().ToString("N")));
admin.MapPut("/printers/{id:guid}", (Guid id, PrinterDefinition printer, HttpContext context, Store store) => {
    if (printer.Id != id) throw new InvalidDataException("Printer identity changed."); Rules.ValidatePrinter(printer, store.Packages()); store.SavePrinter(printer, Revision(context)); return Results.Ok();
});
admin.MapDelete("/printers/{id:guid}", (Guid id, HttpContext context, Store store) => { store.DeletePrinter(id, Revision(context)); return Results.Ok(); });
admin.MapPut("/settings", (DeploymentSettings settings, HttpContext context, Store store) => { store.SaveSettings(settings, Revision(context)); return Results.Ok(); });
admin.MapPost("/packages", async (HttpContext context, Packages packages) => {
    var revision = Revision(context); var form = await context.Request.ReadFormAsync(context.RequestAborted); var file = form.Files.GetFile("Package") ?? throw new InvalidDataException("Upload a ZIP containing the complete extracted driver package.");
    if (!int.TryParse(form["DriverType"], out var type)) throw new InvalidDataException("Choose Type3 or Type4.");
    await using var stream = file.OpenReadStream(); var package = await packages.Import(stream, Path.GetFileName(file.FileName), type, revision, context.RequestAborted); return Results.Ok(package);
});
admin.MapPost("/removals", (RemovalSelection selection, HttpContext context, Store store, Delivery delivery) => {
    if (selection.Selected && delivery.Plan(selection.ComputerName, Guid.NewGuid(), Guid.NewGuid().ToString("N")).Configuration.GetProperty("Printers").EnumerateArray().Any(p => p.GetProperty("Name").GetString()!.Equals(selection.Name, StringComparison.OrdinalIgnoreCase)))
        throw new InvalidDataException("Remove this queue from the desired printer assignments before scheduling its deletion.");
    store.SelectRemoval(selection, Revision(context)); return Results.Ok();
});
admin.MapGet("/startup.ps1", (Delivery delivery) => Results.File(System.Text.Encoding.UTF8.GetBytes(delivery.StartupScript()), "text/plain", "Install-PrintDeployWebTask.ps1"));
admin.MapGet("/user-logon.ps1", (Delivery delivery) => Results.File(System.Text.Encoding.UTF8.GetBytes(delivery.StartupScript(true)), "text/plain", "Report-PrintDeployWebUserPrinters.ps1"));
var clients = app.MapGroup("/client").AllowAnonymous().RequireRateLimiting("Clients");
clients.MapGet("/bootstrap", (string nonce, Delivery delivery) => delivery.Bootstrap(nonce));
clients.MapGet("/plan", (string computerName, Guid clientId, string nonce, Delivery delivery) => delivery.Sign(delivery.Plan(computerName, clientId, nonce)));
clients.MapGet("/files/{hash}", (string hash, Delivery delivery) => delivery.FileForHash(hash) is string file ? Results.File(file, "application/octet-stream", enableRangeProcessing: false) : Results.NotFound());
clients.MapGet("/packages/{id:guid}/{hash}", (Guid id, string hash, Packages packages) => packages.Archive(id, hash) is string file ? Results.File(file, "application/zip", enableRangeProcessing: false) : Results.NotFound());
clients.MapPost("/reports", async (HttpContext context, Store store) => {
    if (context.Request.ContentLength > 1024 * 1024) throw new InvalidDataException("Report exceeds 1 MB.");
    using var memory = new MemoryStream(); var buffer = new byte[16384]; int count;
    while ((count = await context.Request.Body.ReadAsync(buffer, context.RequestAborted)) > 0) { if (memory.Length + count > 1024 * 1024) throw new InvalidDataException("Report exceeds 1 MB."); memory.Write(buffer, 0, count); }
    using var document = JsonDocument.Parse(memory.ToArray()); var body = document.RootElement;
    var id = body.GetProperty("ClientId").GetGuid(); var computer = body.GetProperty("ComputerName").GetString() ?? ""; var report = body.GetProperty("Report"); var settings = store.Settings();
    if (id == Guid.Empty || !Rules.ComputerName(computer) || report.GetProperty("DeploymentId").GetGuid() != settings.DeploymentId || report.GetProperty("ComputerName").GetString() != computer || report.GetProperty("SchemaVersion").GetInt32() != 1) throw new InvalidDataException("Invalid report identity.");
    var scope = report.GetProperty("Scope").GetString() ?? ""; var sid = report.GetProperty("UserSid").GetString() ?? "";
    if (scope is not ("Machine" or "UserConnection") || (scope == "Machine" && sid != "") || (scope == "UserConnection" && !Regex.IsMatch(sid, @"\AS-1-\d+(-\d+)+\z")) || report.GetProperty("Result").GetString() is not ("Success" or "Failed")) throw new InvalidDataException("Invalid report scope or result.");
    foreach (var field in new[] { "Printers", "ConfiguredPrinters", "RemovalResults" }) { var value = report.GetProperty(field); if (value.ValueKind != JsonValueKind.Array || value.GetArrayLength() > 2000) throw new InvalidDataException("Invalid report inventory."); }
    foreach (var printer in report.GetProperty("Printers").EnumerateArray()) { Rules.Text(printer.GetProperty("Name").GetString() ?? ""); Rules.Text(printer.GetProperty("DriverName").GetString() ?? ""); Rules.Text(printer.GetProperty("PortName").GetString() ?? "", 500); if (printer.GetProperty("Type").GetString() is not ("Local" or "Connection")) throw new InvalidDataException("Invalid inventory type."); }
    store.SaveReport(new(id, computer.ToUpperInvariant(), scope, sid, DateTimeOffset.UtcNow.ToString("o"), report.Clone())); return Results.Ok(new { Accepted = true });
});
app.MapGet("/health", () => Results.Ok(new { Status = "Ready" })).AllowAnonymous();
app.Run();
static long Revision(HttpContext context) {
    var value = context.Request.Headers.IfMatch.ToString().Trim('"');
    if (!long.TryParse(value, out var revision) || revision < 1) throw new InvalidDataException("Supply the current If-Match revision."); return revision;
}
public sealed class DevelopmentAuthentication(IOptionsMonitor<AuthenticationSchemeOptions> options, ILoggerFactory logger, UrlEncoder encoder) : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder) {
    protected override Task<AuthenticateResult> HandleAuthenticateAsync() {
        if (Context.Connection.RemoteIpAddress is not null && !IPAddress.IsLoopback(Context.Connection.RemoteIpAddress)) return Task.FromResult(AuthenticateResult.Fail("Development authentication is loopback-only."));
        var identity = new ClaimsIdentity([new Claim(ClaimTypes.Name, "DEVELOPMENT\\DemoAdmin"), new Claim(ClaimTypes.NameIdentifier, "development"), new Claim(ClaimTypes.GroupSid, "S-1-5-21-100-200-300-512")], Scheme.Name);
        return Task.FromResult(AuthenticateResult.Success(new(new ClaimsPrincipal(identity), Scheme.Name)));
    }
}
