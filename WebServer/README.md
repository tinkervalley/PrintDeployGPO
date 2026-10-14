# PrintDeploy Web (separate Windows service)

This edition lives entirely under `WebServer/`. It uses a Windows service on port **3000**, a web administration UI, local SQLite storage and HTTP client delivery. It does not depend on the original PrintDeploy SMB share or replace that deployment automatically.

## What it does

- A master printer list supports IPP/IPPS and packaged Type3/Type4 TCP/IP printers.
- Each queue can use a shared package and independent x64/ARM64 overrides. Upload a ZIP of the complete extracted vendor package, choose its type, then select a detected INF/model. The editor shows INF-declared architecture support.
- Printers target all eligible computers or selected Active Directory OUs, optionally including child OUs. The server resolves OU membership from the claimed computer name; the client never supplies the OU.
- A generated, standalone computer-startup GPO script downloads a **signed task definition** and verified client scripts. It registers **one SYSTEM task**. The task polls the server for a signed printer plan, caches driver packages locally, runs the existing IPP-first deployment engine and posts its inventory/results over HTTP.
- Computer and optional user inventories appear in the web UI. Administrators can schedule exact, fingerprint-checked one-shot removals. The optional user-logon GPO script creates no task.
- Admin sign-in uses Windows Negotiate authentication. The default allowed group is the hosting AD domain's **Domain Admins** SID (`<domain SID>-512`). Passwords are handled by Windows; the app does not collect/store them. A configured `AdminGroupSid` can instead allow an approved delegated printer-administrator group.

## Identity and trust

Client routes intentionally require **no authentication**, as requested. A locally generated client GUID and a claimed computer name identify reports; they do not authenticate the machine. A caller can claim another computer name and retrieve that computer's printer assignments or forge reports. OU targeting is a distribution rule, **not an access-control boundary**. The UI labels client identity as unverified. Anonymous endpoints cannot modify the master list, OU rules, packages, removal requests or server settings.

The exported GPO script pins this server's RSA public key. The bootstrap and task verify signed responses, request nonces, deployment identity, response age and file/package hashes before executing downloaded code. This prevents tampering/replay by an intermediary that does not hold the signing key. Protect the original GPO script and server's private signing key. **HTTPS is recommended** for administrator authentication, metadata/report confidentiality and protection against authentication relay. HTTP on port 3000 is supported, and client content is still signature-checked. The application does not weaken signature checks or automatically trust vendor certificates.

## Install on a Windows server

Use a domain-joined Windows server supported by .NET 10. Build with the **.NET 10 SDK** on a build machine; the published server is self-contained and does not require a separate runtime installation.

```powershell
.\WebServer\scripts\Publish-Server.ps1 -Runtime win-x64
```

Copy the resulting `WebServer\dist\win-x64` folder to local server storage, for example `C:\Program Files\PrintDeployWeb`. Run elevated on the server:

```powershell
.\Install-Server.ps1 -ApplicationDirectory 'C:\Program Files\PrintDeployWeb' `
  -PublicUrl 'http://printdeploy.example.com:3000' -Port 3000
```

The installer runs the service as **NETWORK SERVICE**, protects the application and local data directories, and opens TCP 3000 on the **Domain** firewall profile. The computer/service identity needs AD read access; do not run the service as Domain Admin. It installs no printers on the server. `-WhatIf` previews service installation. The default data folder is `%ProgramData%\PrintDeployWebServer`.

For HTTPS, place an appropriate server certificate with its private key in Local Computer → Personal, grant NETWORK SERVICE access to the private key, and supply:

```powershell
.\Install-Server.ps1 -ApplicationDirectory 'C:\Program Files\PrintDeployWeb' `
  -PublicUrl 'https://printdeploy.example.com:3000' -Port 3000 `
  -HttpsCertificateThumbprint 'YOUR_CERTIFICATE_THUMBPRINT'
```

Set DNS so the public hostname resolves to this server. When using a DNS alias with Kerberos, register its HTTP SPN on the server computer account, for example `setspn -S HTTP/printdeploy.example.com DOMAIN\SERVERNAME$`. Make the browser treat the service as an intranet site for integrated sign-in. With a dedicated service account/gMSA, configure the account, directory permissions, key access and SPNs accordingly. Do not place a generic reverse proxy in front of Negotiate unless it preserves the required connection affinity.

Open the server URL, click **Sign in with Windows**, and use a domain-admin Windows session/account. Other authenticated users receive no administrator access. Mac browsers can use domain Kerberos/Negotiate where configured; this is not a web password form.

The server invokes native Windows PowerShell 5.1 only to inspect uploaded INFs. The parser script/module must meet your execution-policy requirements. Vendor EXE/MSI installers are never run. Windows verifies catalog signatures and package compatibility on the client; an HP signed publisher may still need to be explicitly deployed to Local Computer Trusted Publishers.

## Configure and deploy

1. Set the public URL, poll interval (default **60 minutes**) and cleanup options in Settings.
2. Add IPP printers by host, protocol, port and path (default `/ipp`). For legacy printers, upload the complete vendor ZIP in Driver packages and select its detected model(s) in the printer editor.
3. Assign printers globally or select OUs. Use GPO security/OU filtering to control which computers receive the bootstrap. **Preview assignments** shows the server's AD lookup and desired queues for a computer name.
4. Download **Install-PrintDeployWebTask.ps1** from GPO deployment. Copy it to Computer Configuration → Policies → Windows Settings → Scripts → Startup → PowerShell Scripts. Parameters are blank. Sign it if your policy requires signing.
5. The bootstrap downloads the signed task/client definition and stores code under `%ProgramData%\PrintDeployWeb\<DeploymentId>`. One SYSTEM task runs about one minute later, at future startups, and at the poll interval. Clients authenticate neither configuration nor report requests.
6. For user printer connections, optionally deploy **Report-PrintDeployWebUserPrinters.ps1** as a user-logon GPO script, with parameters blank. The computer bootstrap must run once first. This reports/removes only the signed-in user's connections and adds no task.
7. Use Computers & logs to review reports and schedule removals. Remove a printer from desired assignments before scheduling its reported queue's deletion. Removal requests preserve their IDs so client receipts remain one-shot.

After preflight validation/conflict checks, clients install IPP queues first. Vendor failure retains successful IPP queues and reports the overall failure. Cleanup is deferred if vendor staging fails. By default, stale **managed** queues are removed when a computer's desired assignments change, including moves between OUs; unrelated printers are preserved. You can disable this in Settings. Unknown/disabled computer names are rejected by default. Directory/network failures stop the plan fetch and retain current queues, rather than running a destructive empty plan.

Package uploads are capped at 256 MB compressed / 1 GB extracted, with bounded file counts and traversal/link/collision checks. Packages are stored on the server's local disk, outside the web root. Clients cache the referenced packages once (including both configured architecture variants for full configuration validation) and register only their native driver's model. Task policy follows the domain's PowerShell execution policy; no `ExecutionPolicy Bypass` is added. If AllSigned is required, sign the published client `.ps1`/`.psm1` files before starting/restarting the server so their final hashes are included in manifests.

Changing the server URL or rotating its signing key requires regenerated GPO scripts. Poll changes are picked up during subsequent task runs. Retiring the GPO does not remove an already installed task; retire it explicitly. Keep the deployment ID and signing key stable across server updates. Migration from the original share deployment requires a pilot: this edition has its own deployment ID/ownership records and will refuse to take over same-name IPP queues it does not own. Do not delete old state or existing working queues indiscriminately.

## Backups and updates

Stop the service before a file-level backup or update. Back up the entire protected data folder: SQLite database, uploaded package archives/files and signing key. Restore all together with the same permissions and deployment ID. Do not commit real databases, private keys, packages or reports to Git. The application's code directory is separate from data; replacing a published build preserves the data folder. SQLite is stored locally, never on SMB. Administrator writes use revision checks to avoid overwriting concurrent changes. Client reports are bounded and latest snapshots are keyed by client ID, scope and user SID.

## Development and verification

Production hosting requires Windows. A loopback-only demo is available for local development with a synthetic AD directory (`DEV-PC` in `OU=Workstations,DC=example,DC=test`). It is enabled **only** when both `DevelopmentMode=true` and `ASPNETCORE_ENVIRONMENT=Development` are set, and forcibly binds localhost. It is never enabled by the installer/default settings.

```bash
ASPNETCORE_ENVIRONMENT=Development \
PrintDeploy__DevelopmentMode=true \
PrintDeploy__DataDirectory=/tmp/printdeploy-demo \
PrintDeploy__PublicUrl=http://localhost:3000 \
dotnet run --project WebServer/Server/PrintDeploy.Web.csproj
```

Run model checks with `dotnet run --project WebServer/Tests/PrintDeploy.Web.Tests.csproj`. HTTP integration tests use an isolated local server and synthetic packages/reports. PowerShell transport checks verify signatures, nonce/identity binding, paths and generated scripts. These do not prove real AD/Negotiate behavior or printer installation: pilot the Windows service, Domain Admin authorization, OU moves, task registration, HTTPS, vendor trust and reporting on actual clients before rollout.

References: [Windows authentication](https://learn.microsoft.com/en-us/aspnet/core/security/authentication/windowsauth), [Windows service hosting](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/windows-service), [trusted driver publishers](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/trusted-publishers-certificate-store).
