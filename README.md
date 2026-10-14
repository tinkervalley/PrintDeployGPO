# PrintDeployGPO

A printer deployment tool with native Windows and Mac configuration GUIs and a Windows PowerShell 5.1 deployment engine for silent, repeatable GPO deployment. It installs machine-wide queues for all users, without a print server. Supports driverless IPP/IPPS and signed Type 3/Type 4 TCP/IP driver packages. There are no external PowerShell module dependencies beyond the Windows inbox PrintManagement and DISM modules.

## Configure

1. Copy this project to a Windows administrator workstation. Run `Launch-Configurator.cmd`, or:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\PrinterDeployment.ps1
   ```

2. Choose a deployment folder, ideally a dedicated UNC path such as `\\fileserver\Software\Printers`. A local folder is allowed for staging. Use a UNC path when creating the GPO; mapped drives are unavailable to SYSTEM.
3. Architecture is detected per selected driver. Importing an INF lists the union of x64 and ARM64 model names, and the editor shows the architectures declared for the selected name. One deployment folder can serve x64 and ARM64 clients: IPP printers are architecture-independent. At deployment, each packaged INF is checked for the exact selected driver name in the client's native architecture. Incompatible selections are skipped and reported as **Unsupported architecture**; they do not block compatible queues or cause stale cleanup of those configured printers. Type 3 and Type 4 drivers both require native-compatible packages; driverless IPP is the shared path. A single printer can select separate packages and model names for each architecture, as described below. Run 64-bit PowerShell on clients.
4. Add an **IPP** printer by entering only its IP address or hostname, choosing **ipp** or **ipps**, and entering its subpath (default `/ipp`). The GUI builds the full URL and uses port **631** automatically for either protocol. Enable **Use custom port** for a printer advertising a different port, such as IPPS on 443. A leading slash is added to the subpath if omitted. IPv6 addresses work with or without brackets. Existing saved URLs, including custom ports and HTTP(S) schemes, are preserved when editing without endpoint changes. IPPS requires a trusted certificate matching the hostname. The correct resource path is printer-specific.
5. For a **Type3** or **Type4** printer, enter its IP address/hostname and RAW TCP port (usually 9100). Choose **Import driver package**, select the complete extracted vendor package folder, then an INF inside that folder. The tool copies the entire folder into `Drivers\<unique-id>`, preserving manifests, catalogs, binaries and subfolders. Choose the exact detected driver name from the dropdown. EXE/MSI/ZIP packages must be extracted first. To use different packages on different clients, select **x64** in the driver package target, choose its **Type3** or **Type4** package type and import/select its driver; repeat for **ARM64** on the same printer. Each target retains its own package, INF, model name and type. **Shared/default** is optional and acts as the fallback where there is no architecture override. You can also use just the two overrides with no shared package.
6. Configure cleanup if needed, validate, then **Save deployment bundle**. This exports `Install-PrinterDeploymentTask.ps1` for Computer Startup (one SYSTEM task) and `Report-UserPrinters.ps1` for User Logon (no additional task). Both accept blank GPO parameters. Deploy the user logon script to collect old shared-printer connections and apply selected user removals. The GPO deployment tab explains how to install it. Save writes the configuration last, after copying the scripts and resources.

Configuration does not install printers on the administrator workstation. The GUI requires write access to the deployment folder but does not itself require elevation. Changing folders copies configured packages and keeps the original bundle. Opening an existing `printers.json` preserves its deployment identity. Preserve that identity across updates so local ownership records continue to work.

The GUI launcher sets `-ExecutionPolicy Bypass` for that PowerShell process only. This lets the downloaded application open on workstations with the default Restricted execution policy, without changing CurrentUser or LocalMachine settings. A policy enforced through Group Policy still takes precedence. The generated GPO task and startup script continue to follow your organization's deployment execution policy.

If Windows still reports **running scripts is disabled on this system**, run `Get-ExecutionPolicy -List` in Windows PowerShell. If `MachinePolicy` or `UserPolicy` is Restricted, your administrator must permit execution through **Administrative Templates > Windows Components > Windows PowerShell > Turn on Script Execution**. If policy requires AllSigned, sign the entry script, its PowerShell modules and the generated startup script with a trusted certificate. A process-level option cannot override these managed policies. See [Microsoft's execution-policy guidance](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1).

The resulting folder contains:

```text
Printers\
  PrinterDeployment.ps1
  Launch-Configurator.cmd
  Install-PrinterDeploymentTask.ps1
  Report-UserPrinters.ps1
  printers.json
  GPO-Setup.txt
  README.md
  Templates\
    Install-PrinterDeploymentTask.ps1.template
    Report-UserPrinters.ps1.template
  Modules\
    PrinterDeployment.Discovery.psm1
    PrinterDeployment.Core.psm1
    PrinterDeployment.Deploy.psm1
    PrinterDeployment.Gui.psm1
    PrinterDeployment.Clients.psm1
  Drivers\
    <package-id>\<complete vendor package>
  Client Logs\
    PC001\latest.json
    PC001\<timestamp>-<run-id>.json
    PC001--user-<sid-hash>\latest.json
```

Package paths in JSON are relative to this folder. Validation rejects absolute resource paths, traversal, missing packages, symbolic links/junctions, unsupported drivers, duplicate queue names and cleanup names that conflict with configured printers. Cancelled imports may leave unreferenced package folders; these are not deployed. The tool does not delete unused packages automatically.

The INF reader supports neutral/en-US string tables, quoted names, comments, continuations and manufacturer model sections for x64 and ARM64, including OS-decorated sections. Both GUIs show the selected model's architecture declarations. This describes INF model support, not proof that a package's binaries, OS version constraints or signatures will work on a particular client. The legacy JSON Architecture field is retained for compatibility but no longer filters driver names or limits deployment. The dropdown is a list of candidate model names; Windows still decides whether a model's OS decoration applies on a particular client. Localized-only or unusually structured vendor INFs may need a different vendor package. All packaged INFs must declare `Class=Printer`. Type 4 requires `ClassVer=4.0`; Type 3 accepts an absent `ClassVer` or `ClassVer=3.0` and rejects Type 4 packages. Select the corresponding type explicitly before importing. Changing a package target between Type 3 and Type 4 clears that target's package selection. Changing the printer connection type clears the shared package on a direct Type3/Type4 change; explicit architecture overrides retain their own types. Vendor EXE/MSI installers and co-installer workflows are not executed. Windows independently enforces package signatures and compatibility during installation.

## Discover network printers

In either printer editor, click **Discover…** next to the address field. The picker scans for advertised **IPP**, **IPPS** and **RAW TCP/IP** endpoints on the administrator's local network. Select a row and click **Use selected printer**. It fills the address/hostname, protocol, advertised port, IPP resource path and location; the advertised name fills an empty queue name. A printer advertising both IPP and IPPS may have a row for each endpoint so you can choose which to use.

IPP/IPPS endpoints select the IPP connection type. RAW endpoints use Type4 by default and preserve Type3 if already selected. Discovery does not select or download a vendor driver: import the Type3/Type4 package and choose its model afterwards. Advertised model text helps identify the printer, but is not an INF driver name. IPPS keeps the advertised hostname for certificate matching; other endpoints prefer an advertised IPv4 address when available, otherwise their hostname. Review detected settings before saving.

Discovery uses [Bonjour/DNS-SD service advertisements](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/NetServices/Articles/NetServicesArchitecture.html), including the `rp` TXT key for the IPP path. The Windows picker sends bounded [one-shot mDNS queries](https://www.rfc-editor.org/rfc/rfc6762.html#section-6.7) on active IPv4 multicast interfaces (about seven seconds); the Mac picker uses the built-in Bonjour browser (eight seconds). Both run in the configuration GUI only; clients deploy the saved endpoints without scanning. Neither picker installs printers.

This discovers advertised services rather than sweeping every IP address. Printers on other VLANs, IPv6-only segments in the Windows picker, or networks blocking mDNS may not appear. Legacy devices without Bonjour/mDNS advertisements must be entered manually. Enable Bonjour/AirPrint on the printer where available and allow local-network access when macOS prompts. **Scan again** refreshes results; Cancel stops the scan. The scan does not change firewall rules or network settings.

## Separate packages on one printer

Use one queue name and TCP/IP endpoint, then configure **x64** and **ARM64** targets in the printer editor. An explicit native override takes precedence over **Shared/default**. Each override may choose a different driver name and driver type, including Type3 on x64 and Type4 on ARM64. The client stages/registers only the resolved native driver; IPP still needs no packages. If there is no native override or compatible shared package, the queue is reported as **Unsupported architecture**.

Both GUIs automatically save these configurations with `SchemaVersion: 2` and a `DriverPackages` object keyed by `x64` and/or `ARM64`. Existing configurations without overrides remain compatible with schema 1. Update the deployment engine before rolling out architecture overrides: use **Save deployment bundle** with the updated configurator. **Save JSON** alone does not update the PowerShell engine. Older engines/configurators reject schema 2 to prevent silently discarding or ignoring architecture selections. The deployment folder, queue entry, scheduled task and existing GPO scripts can stay the same.

For example, one Type4 queue can contain the following driver settings (the complete extracted packages must exist under those paths):

```json
"PackagePath": "",
"InfPath": "",
"DriverName": "",
"DriverPackages": {
  "x64": {
    "Kind": "Type3",
    "PackagePath": "Drivers\\vendor-x64",
    "InfPath": "Drivers\\vendor-x64\\printer.inf",
    "DriverName": "Vendor Legacy Driver"
  },
  "ARM64": {
    "Kind": "Type4",
    "PackagePath": "Drivers\\vendor-arm64",
    "InfPath": "Drivers\\vendor-arm64\\printer.inf",
    "DriverName": "Vendor ARM64 Driver"
  }
}
```

## Mac configurator

The native **PrintDeployGPO.app** supports macOS 13 or later on Apple Silicon and Intel. It opens and edits the same `printers.json` used by Windows, preserves `DeploymentId` and unknown JSON fields, reads the same Client Logs snapshots, and writes the same scoped one-shot removal requests. It does not install printers on the Mac.

1. Mount your Windows share in Finder using **Go > Connect to Server**, for example `smb://fileserver/Software`. Open the deployment's `printers.json` from that mounted share in the Mac app.
2. Add/edit IPP printers or import complete Type 3/Type 4 packages and select detected INF driver names. The editor automatically scans x64 and ARM64 models and shows support for the selected driver; IPP deploys to both architectures and incompatible packaged drivers are skipped on clients.
3. Use **Computers** to review combined computer/user inventories and schedule removals. The existing SYSTEM task and user logon script still collect reports and apply changes on Windows.
4. **Save JSON** updates the opened configuration without copying scripts. **Save deployment bundle** also copies the Windows engine and exports both GPO scripts from the same templates used by the Windows GUI. For bundle export, open or create the canonical `printers.json` in the final folder and enter its **Windows UNC folder**, such as `\\fileserver\Software\Printers`. The Mac-mounted `/Volumes/...` path is used for local access only and never embedded in the GPO scripts. The UNC mapping is saved in this Mac's app preferences.
5. Configure SMB and NTFS permissions from Windows. The Mac app can create Client Logs but cannot apply the Windows public-report ACL. Use **Set public log access** in the Windows GUI or apply the documented server permissions yourself. Sign generated scripts if required by your organization.

Only one administrator should edit a deployment at a time. The Mac app checks the exact on-disk configuration before saving and refuses to overwrite concurrent edits; reopen the file and reapply your changes. Save checks resources and writes JSON atomically. JSON copies with another filename can be edited using Save JSON; bundle exports require `printers.json`. The Mac report view labels snapshots older than the configuration file's modification time, rather than trying to reproduce PowerShell's JSON revision hash.

To build locally, install Xcode Command Line Tools (or Xcode), then double-click `Launch-Mac-Configurator.command`. It builds a universal app at `MacConfigurator/build/PrintDeployGPO.app` and opens it. No PowerShell, Python, Node or external libraries are required to run the built app. To build without opening it:

```bash
bash MacConfigurator/build.sh
```

GitHub Actions builds a downloadable universal app ZIP under the **Mac verification** run's artifacts. Builds are ad hoc signed, without Developer ID signing or notarization; macOS may require approval to open an app downloaded from GitHub. Local builds avoid downloaded-file quarantine. Deployment-folder contents, real configurations and client logs are never packaged into the app.

## Pilot before rolling out

On an elevated Windows PowerShell window on a test client:

```powershell
$bundle = '\\fileserver\Software\Printers'
& "$bundle\PrinterDeployment.ps1" -Mode Validate -ConfigPath "$bundle\printers.json"
& "$bundle\PrinterDeployment.ps1" -Mode Deploy -ConfigPath "$bundle\printers.json" -WhatIf
& "$bundle\PrinterDeployment.ps1" -Mode Deploy -ConfigPath "$bundle\printers.json"
```

`Validate` checks JSON and packaged resources without installing anything. `-WhatIf` lists proposed actions and checks local name/port conflicts, without writing logs/state, staging drivers or changing printers. It cannot prove that a driver will install or an IPP printer will answer discovery. Run the actual deployment twice on a pilot, print test pages for both types, and verify that the second run creates no duplicate queues. Test cleanup with a disposable legacy queue. Also test the scheduled task as SYSTEM to verify computer-account share access.

IPP uses `Add-Printer -IppURL`; Windows creates the IPP port through directed discovery. `DriverName` cannot be combined with `IppURL` in that command's parameter set. After discovery the tool checks the queue and, if necessary, selects **Microsoft IPP Class Driver**. The printer must support the Windows IPP/Mopria printing path. Capability detection fails before cleanup if the Windows build does not expose `IppURL`.

Packaged Type 3/Type 4 deployment first checks `Get-PrinterDriver`. An existing driver of that exact name must match `MajorVersion=3` or `MajorVersion=4` respectively. Otherwise the tool stages the selected INF with `pnputil /add-driver`, locates the matching INF in the Driver Store using DISM and its SHA-256 hash, and registers the selected name with `Add-PrinterDriver`. It does not disable signature checks, modify Point and Print policy, or update an already registered driver version. Driver package upgrades should be piloted and handled as a separate administrative change.

Type 3/Type 4 queues use RAW TCP/IP, with SNMP disabled. Ports are named from a hash of the endpoint and port, and reused on subsequent runs. LPR, WSD, printer sharing, default-printer preferences, duplex/color presets and targeting by user/site are outside this initial version. Use GPO OU/security filtering to target the appropriate computer groups.

## GPO: scheduled task recommended

The GUI now exports a startup script that creates the scheduled task for you:

1. Choose the final **UNC** deployment folder and save the bundle in the GUI.
2. In Group Policy, open **Computer Configuration > Policies > Windows Settings > Scripts (Startup/Shutdown) > Startup > PowerShell Scripts**.
3. Click **Show Files**, copy the generated `Install-PrinterDeploymentTask.ps1` from the deployment folder into that GPO folder, and add it as a startup script. Leave the script parameters blank.
4. If your execution policy requires signing, sign the generated file after export and before installing it in the GPO. Target the GPO at the intended computer OU/groups.

The generated file is standalone and embeds the deployment folder and identity; it does not need the Modules folder or printer packages beside it in SYSVOL. It registers/updates `PrinterDeploymentTool-<DeploymentId>` as SYSTEM with highest privileges. The task runs one minute after registration (to cover the first boot), one minute after future startups, and daily at noon. It retries failures every five minutes, three times, ignores simultaneous starts, runs after missed starts and allows battery operation. Registration itself needs no access to the deployment share; the task reads that share when it runs. GPO must still be able to run the copied startup script.

Repeated startup runs update the same task. A same-name task with an unrelated description is rejected. Editing `printers.json` on the share requires no GPO change. If the share path or DeploymentId changes, export again and replace the startup script in the GPO. A bundle saved to a local staging path must be re-exported from its final UNC folder before rollout. Removing the GPO does not automatically remove the installed task: explicitly delete the task using GPO Preferences or `Unregister-ScheduledTask` when retiring a deployment, and remove the startup script first so it does not recreate the task.

On an elevated Windows pilot, you can preview registration by running the exported startup script with `-WhatIf`. Then run it normally and check the resulting task's action, triggers and run history.

For manual task creation instead, use **Computer Configuration > Preferences > Control Panel Settings > Scheduled Tasks**, creating a **Task (At least Windows 7)**:

- Run as **NT AUTHORITY\SYSTEM**, with highest privileges, whether or not a user is logged on.
- Trigger **At startup**, delayed one minute. Add a daily trigger if configuration updates should apply without a reboot.
- Enable running after a missed start, and restart on failure every five minutes, three times.
- Choose **Do not start a new instance** if it is already running.
- Program: `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`
- Arguments:

  ```text
  -NoProfile -NonInteractive -File "\\fileserver\Software\Printers\PrinterDeployment.ps1" -Mode Deploy -ConfigPath "\\fileserver\Software\Printers\printers.json"
  ```

Configure the task to run on the intended computers. The deployment script also retries reading/validating the share three times, twenty seconds apart, configurable with `-RetryCount` and `-RetrySeconds`. If PowerShell cannot load the script from an unavailable share at all, only the scheduled task's restart policy can retry. Saving the GUI bundle only exports the installer; the task is registered when that exported startup script runs on each client.

A **computer startup script** is a simpler alternative on always-connected desktops: **Computer Configuration > Policies > Windows Settings > Scripts (Startup/Shutdown) > Startup > PowerShell Scripts**. Use the UNC script name and parameters `-Mode Deploy -ConfigPath "\\fileserver\Software\Printers\printers.json"`. Enable **Always wait for the network at computer startup and logon**. Startup runs as SYSTEM, which has permission to register drivers. A user logon script is unsuitable for driver installation.

Give reporting computer accounts (typically **Domain Computers**) **Change** at the SMB share level, but only **Read/Execute** on the deployment root, scripts, drivers and `printers.json` at the NTFS level. Reporting users need the same combination if the user-logon mode is deployed. Effective permissions combine share and NTFS permissions: the share-level Change permission allows writes that NTFS permits inside `Client Logs`; it must not be accompanied by NTFS write access to the deployment files. Restrict modification of those files to deployment administrators. Use script signing and the execution policy required by your organization. Deployment commands follow that policy; only the interactive GUI launcher sets a process-level Bypass policy.

Windows Protected Print Mode blocks third-party printer drivers. A mixed IPP/Type3/Type4 deployment therefore requires a policy compatible with the packaged drivers; the tool does not change that policy. An existing same-name driver of the wrong major version is rejected, and a driver-staging reboot requirement returns failure before cleanup so the task can retry after a restart.

## Removing old printers

Cleanup is disabled by default. Two independent controls are available:

- **Exact legacy printer names:** one name per line, such as `Old Accounting Printer (Copy 1)`. No wildcard matching. A name in this list is removed on every run if present, so this also removes a legacy queue that another policy recreates. Remove obsolete GPO printer mappings or they can reappear.
- **Stale managed printers:** remove queues previously installed by this deployment when their names leave the configuration. Ownership records must still match the queue's observed name, driver and port. Unrelated PDF, USB and manually installed printers are preserved unless explicitly named in the legacy list.

Cleanup runs after validation, name/port conflict checks, required packaged-driver registration and an inventory export, but before installing configured queues. It is not a transaction: a later unreachable IPP device or queue failure can leave named legacy printers removed. Pilot with `-WhatIf` and retain a working printing path during migration. Never use a broad “delete all printers” script on production clients.

The SYSTEM task installs and cleans up machine queues. It does **not** see or remove connections in other users' profiles. For old shared-printer connections, add the exported **Report-UserPrinters.ps1** to **User Configuration > Policies > Windows Settings > Scripts > Logon > PowerShell Scripts**, with blank parameters. This creates no scheduled task. The legacy-cleanup checkbox does not enable reporting; leave it off for inventory alone. To remove exact legacy names on every logon, enable the checkbox in **Advanced cleanup** and list those names. Alternatively, add `PrinterDeployment.ps1` directly to the User Logon GPO with:

```text
-Mode CleanupUser -ConfigPath "\\fileserver\Software\Printers\printers.json"
```

This separate mode runs as the current user, installs no printers/drivers, and removes visible `Type=Connection` queues named in the legacy list or selected in that user's client report. It also reports that user's printer inventory even when legacy cleanup is disabled. It can be previewed with `-WhatIf`. It does not edit offline user hives or remove user-local direct-IP queues. Check `Get-Printer | Select Name,Type,DriverName,PortName` within each relevant user context to identify exact legacy names. Disable or change the old printer-deployment GPO before removing its queues, otherwise it can recreate them.

## Client Logs and removal selections

Saving the bundle creates a **Client Logs** folder inside the chosen deployment folder. On Windows, first creation applies NTFS permissions for authenticated accounts to read reports, create their own report directories, and modify the contents of directories they own. SYSTEM, server Administrators and the account saving the bundle have full control. The GUI's **Clients and inventories > Set public log access** button reapplies this policy to the log folder only. It does not change SMB share permissions or permissions on the scripts/configuration. It replaces the log folder's ACL; explicitly protected child ACLs may still need a server administrator to repair them.

“Public” means readable by authenticated domain accounts, including ordinary users; anonymous guest access is not configured. Computers write as their domain computer accounts when running as SYSTEM. Users write as themselves in user-logon mode. Ensure SMB Change access and pilot uploads from both contexts. Accounts can create report folders and modify their own contents, but cannot modify other reporters' existing folders. Reports are client-submitted information and can be spoofed; they are not authoritative device attestation. Removal instructions are stored in administrator-controlled `printers.json`, never read from the public report folder by the deployment engine.

Each normal deployment writes:

- A printer inventory captured before changes, and the printer inventory after the run.
- The run result, errors, timestamps and verification results for desired queues.
- The outcome of each client-specific removal request.
- An individual JSON history file and a replaceable `latest.json` used by the GUI.

The machine task reports queues visible to SYSTEM. Deploy **Report-UserPrinters.ps1** as a user logon script to see shared-printer connections in each user's context. The GUI groups snapshots into one row per computer and combines its printers in the **Reported printers** tab, with an **Installed for** column showing Computer or the owning user. Computer queues also visible in user snapshots appear once; connections owned by different users remain separate. A computer with no uploaded user snapshots is marked **user inventory missing**. Only users who have run the logon script are represented; the GUI does not inspect offline profiles. Details show the last report time and result for each context. Names, drivers, ports and locations are reported; queued document contents are not collected. Reports are organized by computer name (and user SID hash for user contexts), so use separate deployment folders for domains that reuse computer names. Only clients that have successfully uploaded at least one report appear; this is not an Active Directory computer inventory or a live connection to clients.

To review and clean up:

1. Open the GUI for the saved configuration and select **Clients and inventories**.
2. Click **Refresh computers**, then select a computer. Review its last-report time, overall result, deployed count and user reports. Select removal checkboxes beside unwanted queues; the GUI routes requests to the owning computer or user. Managed printers must first be removed from the Printers configuration so deployment will not reinstall them. A changed configuration is labelled **changes pending** until that context reports the new revision.
3. Check **Remove** beside an extra printer, then **Save deployment bundle**. The request applies only to that computer and, for connections, the specific user SID. Desired printers cannot be selected until removed from the desired configuration.
4. On the next deployment run (or the selected user's next logon), the client compares the queue's exact name, driver and port with the selected snapshot. A mismatch produces **Changed** and leaves the queue intact. Other printers are still attempted.
5. Refresh reports after the next run. The **Removal requests** subtab shows Pending, Removed, NotFound, Completed, Changed or Failed. This also lets you clear requests whose printers have already disappeared from the current inventory.

Selected removals are **one-shot**, unlike the legacy-name list. Successful removal, or a queue already absent, records a receipt on that client. Subsequent runs do not remove a newly recreated queue with that old request. Clear the old request, save, and select/save again to issue a new request after reviewing a new report. Removing local receipt files loses this protection. User receipts and the local last report are under `%LOCALAPPDATA%\PrinterDeploymentTool\<DeploymentId>`; machine receipts remain in the protected managed state directory.

`-WhatIf` neither consumes requests nor writes client reports. If upload fails, the latest report is retained locally as `last-report.json` where local state storage was available, and the run returns failure so the scheduled task can retry. An earlier deployment failure is preserved if reporting also fails. The next successful run uploads a fresh report; old local reports are not automatically replayed. If the script cannot start, cannot read/validate its configuration, or cannot reach the report share, the GUI cannot show a fresh report. Check scheduled-task history and local logs in that case. History files are retained until an administrator archives/deletes them; no retention cleanup runs automatically. The GUI skips malformed, linked or oversized reports (over 4 MB).

## State, failures and recovery

Logs, queue inventories and managed ownership state are local under `%ProgramData%\PrinterDeploymentTool\<DeploymentId>`. These directories are restricted to SYSTEM/Administrators. The tool refuses state directories owned by other users or pointing through a reparse point. Treat ownership state as administrator-controlled data.

- Exit **0** means the run completed; **1** means validation, registration, cleanup or installation failed.
- A machine-wide mutex prevents concurrent runs of the same deployment. Independent failures are logged while remaining configured printers are attempted.
- Existing compatible managed queues are reused. Type3/Type4 driver/endpoint changes update the queue. An IPP URL change recreates the managed queue, with best-effort restoration on discovery failure.
- A same-name queue outside this tool's ownership is rejected before cleanup, except for an exactly matching Type3/Type4 queue on the tool's expected port. Rename the conflicting queue or the configured queue. The tool does not silently take over arbitrary IPP printers.
- Inventories record names, ports, drivers and basic metadata; they are **not** complete backups of print preferences, permissions, jobs or defaults. Recreate a removed legacy queue from your former GPO/package if necessary. Queue replacement/removal can discard queued jobs.
- Driver packages and unused ports are retained. The script does not uninstall drivers or remove Windows' own printer resources.

Keep `DeploymentId` and local `state.json` when updating a deployment. Removing state loses managed ownership and can cause name conflicts. Review logs on a test client before troubleshooting with manual state deletion. Save bundle updates while deployments are not running; script/module file copying is not an atomic release operation. JSON saves are atomic, and packages use unique directories.

## Validation included in this project

```powershell
powershell.exe -NoProfile -File .\tests\Run-Tests.ps1
```

The dependency-free tests parse every PowerShell source, exercise INF detection, path containment and cleanup selection, and use mocked Windows print commands to test deployment behavior. The tests can run under PowerShell 7 on macOS/Linux. They do not prove Windows API behavior, driver signatures, printer discovery or the Windows Forms layout. A real Windows pilot remains required.

The client tests also cover before/after report uploads, error reporting, one-time removal receipts, computer/user scoping, changed-queue protection, corrupt report handling and local report retention when uploading fails. Pilot the NTFS log-folder permissions and SMB access on a Windows file server with actual computer and user accounts.

For the Mac configuration/model tests, universal build and native GUI smoke checks, run `bash MacConfigurator/test.sh` on a logged-in Mac. Mac-generated JSON and package references are also checked with the PowerShell validator. Both platforms use the committed Templates files for GPO exports.

On Windows PowerShell 5.1, run `powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Run-GuiSmoke.ps1` for GUI smoke checks. These construct the main window, client panel and printer editor using real Windows Forms, verify that each factory returns only its control, switch connection types, and load a saved configuration. No dialogs are displayed and no printers are installed. GitHub Actions runs both suites on Windows after each push. This checks construction and basic control behavior; visual layout and real printer installation still require a Windows pilot.

## Microsoft references

- [Add-Printer and its IPP parameter set](https://learn.microsoft.com/en-us/powershell/module/printmanagement/add-printer)
- [Microsoft IPP Class Driver and IPP URLs](https://learn.microsoft.com/en-us/universal-print/fundamentals/universal-print-connector-with-ipp)
- [Type 4 INF requirements](https://learn.microsoft.com/en-us/windows-hardware/drivers/print/v4-driver-inf)
- [PnPUtil staging syntax](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax)
- [Add-PrinterDriver and Driver Store INF paths](https://learn.microsoft.com/en-us/powershell/module/printmanagement/add-printerdriver)
- [Startup scripts run as Local System](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/dn789196(v=ws.11))
- [Windows Protected Print Mode for enterprises](https://learn.microsoft.com/en-us/windows/modern-print/windows-protected-print-mode/windows-protected-print-mode-for-enterprises)
