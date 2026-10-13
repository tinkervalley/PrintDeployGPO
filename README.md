# PrintDeployGPO

A Windows PowerShell 5.1 tool with a Windows Forms configuration GUI and a silent, repeatable GPO deployment mode. It installs machine-wide queues for all users, without a print server. There are no external PowerShell module dependencies beyond the Windows inbox PrintManagement and DISM modules.

## Configure

1. Copy this project to a Windows administrator workstation. Run `Launch-Configurator.cmd`, or:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\PrinterDeployment.ps1
   ```

2. Choose a deployment folder, ideally a dedicated UNC path such as `\\fileserver\Software\Printers`. A local folder is allowed for staging. Use a UNC path when creating the GPO; mapped drives are unavailable to SYSTEM.
3. Choose the target architecture, x64 or ARM64. Use a separate configuration/share subfolder for each architecture. Run the native 64-bit PowerShell host on clients.
4. Add an **IPP** printer using the full URL from its documentation, for example `ipp://10.20.30.40:631/ipp/print` or `ipps://printer.example.com:443/ipp/print`. The resource path and port are printer-specific. IPPS requires a certificate the client trusts and a hostname matching that certificate.
5. For a **Type4** printer, enter its IP address/hostname and RAW TCP port (usually 9100). Choose **Import driver package**, select the complete extracted vendor package folder, then an INF inside that folder. The tool copies the entire folder into `Drivers\<unique-id>`, preserving manifests, catalogs, binaries and subfolders. Choose the exact detected driver name from the dropdown. EXE/MSI/ZIP packages must be extracted first.
6. Configure cleanup if needed, validate, then **Save deployment bundle**. This also exports `Install-PrinterDeploymentTask.ps1`, a standalone GPO startup script that registers the deployment task. The GPO deployment tab explains how to install it. Save writes the configuration last, after copying the scripts and resources.

Configuration does not install printers on the administrator workstation. The GUI requires write access to the deployment folder but does not itself require elevation. Changing folders copies configured packages and keeps the original bundle. Opening an existing `printers.json` preserves its deployment identity. Preserve that identity across updates so local ownership records continue to work.

The GUI launcher sets `-ExecutionPolicy Bypass` for that PowerShell process only. This lets the downloaded application open on workstations with the default Restricted execution policy, without changing CurrentUser or LocalMachine settings. A policy enforced through Group Policy still takes precedence. The generated GPO task and startup script continue to follow your organization's deployment execution policy.

If Windows still reports **running scripts is disabled on this system**, run `Get-ExecutionPolicy -List` in Windows PowerShell. If `MachinePolicy` or `UserPolicy` is Restricted, your administrator must permit execution through **Administrative Templates > Windows Components > Windows PowerShell > Turn on Script Execution**. If policy requires AllSigned, sign the entry script, its PowerShell modules and the generated startup script with a trusted certificate. A process-level option cannot override these managed policies. See [Microsoft's execution-policy guidance](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1).

The resulting folder contains:

```text
Printers\
  PrinterDeployment.ps1
  Launch-Configurator.cmd
  Install-PrinterDeploymentTask.ps1
  printers.json
  GPO-Setup.txt
  README.md
  Modules\
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

The INF reader supports neutral/en-US string tables, quoted names, comments, continuations and manufacturer model sections for the selected architecture, including OS-decorated sections. The dropdown is a list of candidate model names; Windows still decides whether a model's OS decoration applies on a particular client. Localized-only or unusually structured vendor INFs may need a different vendor package. The INF must declare `Class=Printer` and `ClassVer=4.0`. Windows independently enforces package signatures and compatibility during installation.

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

Type 4 deployment first checks `Get-PrinterDriver`. An existing driver of that exact name must have `MajorVersion=4`. Otherwise the tool stages the selected INF with `pnputil /add-driver`, locates the matching INF in the Driver Store using DISM and its SHA-256 hash, and registers the selected name with `Add-PrinterDriver`. It does not disable signature checks, modify Point and Print policy, or update an already registered driver version. Driver package upgrades should be piloted and handled as a separate administrative change.

Type 4 queues use RAW TCP/IP, with SNMP disabled. Ports are named from a hash of the endpoint and port, and reused on subsequent runs. LPR, WSD, printer sharing, default-printer preferences, duplex/color presets and targeting by user/site are outside this initial version. Use GPO OU/security filtering to target the appropriate computer groups.

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

Windows Protected Print Mode blocks third-party printer drivers. A mixed IPP/Type4 deployment therefore requires a policy compatible with the Type4 printers; the tool does not change that policy. An existing same-name driver of Type 3 is rejected, and a driver-staging reboot requirement returns failure before cleanup so the task can retry after a restart.

## Removing old printers

Cleanup is disabled by default. Two independent controls are available:

- **Exact legacy printer names:** one name per line, such as `Old Accounting Printer (Copy 1)`. No wildcard matching. A name in this list is removed on every run if present, so this also removes a legacy queue that another policy recreates. Remove obsolete GPO printer mappings or they can reappear.
- **Stale managed printers:** remove queues previously installed by this deployment when their names leave the configuration. Ownership records must still match the queue's observed name, driver and port. Unrelated PDF, USB and manually installed printers are preserved unless explicitly named in the legacy list.

Cleanup runs after validation, name/port conflict checks, required Type 4 driver registration and an inventory export, but before installing configured queues. It is not a transaction: a later unreachable IPP device or queue failure can leave named legacy printers removed. Pilot with `-WhatIf` and retain a working printing path during migration. Never use a broad “delete all printers” script on production clients.

The SYSTEM task installs and cleans up machine queues. It does **not** see or remove connections in other users' profiles. For old shared-printer connections, enable **Allow named per-user connections**, list their exact names (often `\\oldprintserver\queue`), and add the same script to **User Configuration > Policies > Windows Settings > Scripts > Logon > PowerShell Scripts** with:

```text
-Mode CleanupUser -ConfigPath "\\fileserver\Software\Printers\printers.json"
```

This separate mode runs as the current user, installs no printers/drivers, and removes visible `Type=Connection` queues named in the legacy list or selected in that user's client report. It also reports that user's printer inventory even when legacy cleanup is disabled. It can be previewed with `-WhatIf`. It does not edit offline user hives or remove user-local direct-IP queues. Check `Get-Printer | Select Name,Type,DriverName,PortName` within each relevant user context to identify exact legacy names.

## Client Logs and removal selections

Saving the bundle creates a **Client Logs** folder inside the chosen deployment folder. On Windows, first creation applies NTFS permissions for authenticated accounts to read reports, create their own report directories, and modify the contents of directories they own. SYSTEM, server Administrators and the account saving the bundle have full control. The GUI's **Clients and inventories > Set public log access** button reapplies this policy to the log folder only. It does not change SMB share permissions or permissions on the scripts/configuration. It replaces the log folder's ACL; explicitly protected child ACLs may still need a server administrator to repair them.

“Public” means readable by authenticated domain accounts, including ordinary users; anonymous guest access is not configured. Computers write as their domain computer accounts when running as SYSTEM. Users write as themselves in user-logon mode. Ensure SMB Change access and pilot uploads from both contexts. Accounts can create report folders and modify their own contents, but cannot modify other reporters' existing folders. Reports are client-submitted information and can be spoofed; they are not authoritative device attestation. Removal instructions are stored in administrator-controlled `printers.json`, never read from the public report folder by the deployment engine.

Each normal deployment writes:

- A printer inventory captured before changes, and the printer inventory after the run.
- The run result, errors, timestamps and verification results for desired queues.
- The outcome of each client-specific removal request.
- An individual JSON history file and a replaceable `latest.json` used by the GUI.

The machine task reports queues visible to SYSTEM. Deploy **CleanupUser** as a user logon script to see shared-printer connections in each user's context; these appear as separate rows for the same computer. Names, drivers, ports and locations are reported; queued document contents are not collected. Reports are organized by computer name (and user SID hash for user contexts), so use separate deployment folders for domains that reuse computer names. Only clients that have successfully uploaded at least one report appear; this is not an Active Directory computer inventory or a live connection to clients.

To review and clean up:

1. Open the GUI for the saved configuration and select **Clients and inventories**.
2. Click **Refresh client reports**, then select a client/context row. Review its last-report time, overall result, installed/desired count and extra queues. A changed configuration is labelled **changes pending** until that context reports the new revision.
3. Check **Remove** beside an extra printer, then **Save deployment bundle**. The request applies only to that computer and, for connections, the specific user SID. Desired printers cannot be selected until removed from the desired configuration.
4. On the next deployment run (or the selected user's next logon), the client compares the queue's exact name, driver and port with the selected snapshot. A mismatch produces **Changed** and leaves the queue intact. Other printers are still attempted.
5. Refresh reports after the next run. The **Removal requests** subtab shows Pending, Removed, NotFound, Completed, Changed or Failed. This also lets you clear requests whose printers have already disappeared from the current inventory.

Selected removals are **one-shot**, unlike the legacy-name list. Successful removal, or a queue already absent, records a receipt on that client. Subsequent runs do not remove a newly recreated queue with that old request. Clear the old request, save, and select/save again to issue a new request after reviewing a new report. Removing local receipt files loses this protection. User receipts and the local last report are under `%LOCALAPPDATA%\PrinterDeploymentTool\<DeploymentId>`; machine receipts remain in the protected managed state directory.

`-WhatIf` neither consumes requests nor writes client reports. If upload fails, the latest report is retained locally as `last-report.json` where local state storage was available, and the run returns failure so the scheduled task can retry. An earlier deployment failure is preserved if reporting also fails. The next successful run uploads a fresh report; old local reports are not automatically replayed. If the script cannot start, cannot read/validate its configuration, or cannot reach the report share, the GUI cannot show a fresh report. Check scheduled-task history and local logs in that case. History files are retained until an administrator archives/deletes them; no retention cleanup runs automatically. The GUI skips malformed, linked or oversized reports (over 4 MB).

## State, failures and recovery

Logs, queue inventories and managed ownership state are local under `%ProgramData%\PrinterDeploymentTool\<DeploymentId>`. These directories are restricted to SYSTEM/Administrators. The tool refuses state directories owned by other users or pointing through a reparse point. Treat ownership state as administrator-controlled data.

- Exit **0** means the run completed; **1** means validation, registration, cleanup or installation failed.
- A machine-wide mutex prevents concurrent runs of the same deployment. Independent failures are logged while remaining configured printers are attempted.
- Existing compatible managed queues are reused. Type4 driver/endpoint changes update the queue. An IPP URL change recreates the managed queue, with best-effort restoration on discovery failure.
- A same-name queue outside this tool's ownership is rejected before cleanup, except for an exactly matching Type4 queue on the tool's expected port. Rename the conflicting queue or the configured queue. The tool does not silently take over arbitrary IPP printers.
- Inventories record names, ports, drivers and basic metadata; they are **not** complete backups of print preferences, permissions, jobs or defaults. Recreate a removed legacy queue from your former GPO/package if necessary. Queue replacement/removal can discard queued jobs.
- Driver packages and unused ports are retained. The script does not uninstall drivers or remove Windows' own printer resources.

Keep `DeploymentId` and local `state.json` when updating a deployment. Removing state loses managed ownership and can cause name conflicts. Review logs on a test client before troubleshooting with manual state deletion. Save bundle updates while deployments are not running; script/module file copying is not an atomic release operation. JSON saves are atomic, and packages use unique directories.

## Validation included in this project

```powershell
powershell.exe -NoProfile -File .\tests\Run-Tests.ps1
```

The dependency-free tests parse every PowerShell source, exercise INF detection, path containment and cleanup selection, and use mocked Windows print commands to test deployment behavior. The tests can run under PowerShell 7 on macOS/Linux. They do not prove Windows API behavior, driver signatures, printer discovery or the Windows Forms layout. A real Windows pilot remains required.

The client tests also cover before/after report uploads, error reporting, one-time removal receipts, computer/user scoping, changed-queue protection, corrupt report handling and local report retention when uploading fails. Pilot the NTFS log-folder permissions and SMB access on a Windows file server with actual computer and user accounts.

## Microsoft references

- [Add-Printer and its IPP parameter set](https://learn.microsoft.com/en-us/powershell/module/printmanagement/add-printer)
- [Microsoft IPP Class Driver and IPP URLs](https://learn.microsoft.com/en-us/universal-print/fundamentals/universal-print-connector-with-ipp)
- [Type 4 INF requirements](https://learn.microsoft.com/en-us/windows-hardware/drivers/print/v4-driver-inf)
- [PnPUtil staging syntax](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax)
- [Add-PrinterDriver and Driver Store INF paths](https://learn.microsoft.com/en-us/powershell/module/printmanagement/add-printerdriver)
- [Startup scripts run as Local System](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/dn789196(v=ws.11))
- [Windows Protected Print Mode for enterprises](https://learn.microsoft.com/en-us/windows/modern-print/windows-protected-print-mode/windows-protected-print-mode-for-enterprises)
