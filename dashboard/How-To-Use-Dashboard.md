# How to Use the Teams Private Channel Compliance Dashboard

## Overview

The Teams Private Channel Compliance Dashboard is a browser-based tool that lets compliance officers and security analysts investigate the MC1134737 compliance gap for one or more Microsoft Teams custodians without running PowerShell directly. It invokes the `Get-TeamsPrivateChannelComplianceMap` PowerShell module in the background and presents the results in a structured, analyst-friendly interface.

---

## Prerequisites

| Requirement | Details |
| --- | --- |
| Python 3.11 or later | [python.org/downloads](https://www.python.org/downloads/) |
| PowerShell 7.1 or later | [aka.ms/powershell](https://aka.ms/powershell) — must be available as `pwsh` on PATH |
| MicrosoftTeams module | Installed automatically by the PowerShell module on first run |
| Teams Administrator or Global Administrator | Required to call `Get-TenantPrivateChannelMigrationStatus` |

---

## Starting the Dashboard

1. Open a terminal and navigate to the `dashboard` folder:

   ```powershell
   cd C:\path\to\Get-TeamsPrivateChannelComplianceMap\dashboard
   ```

2. Install Python dependencies (first time only):

   ```powershell
   pip install -r requirements.txt
   ```

3. Start the dashboard:

   ```powershell
   python -m streamlit run app.py
   ```

4. The dashboard opens automatically in your default browser at `http://localhost:8501`. If it does not open, navigate to that URL manually.

---

## Sidebar — Configuration

The sidebar on the left controls all settings before you run a scan.

### Module manifest path

The path to `Get-TeamsPrivateChannelComplianceMap.psd1` is auto-detected relative to `app.py`. A green **Module found ✓** message confirms the module is in place. If the path is wrong, update it manually.

### Log / CSV output directory

The directory where the PowerShell module writes its timestamped log files and CSV exports. Defaults to `%TEMP%\Get-TeamsPrivateChannelComplianceMap`. Change this if you want results written to a specific location (e.g. a shared compliance drive).

### Authentication method

Select the method that matches your environment:

| Method | When to use |
| --- | --- |
| **Interactive (browser / MFA)** | Default. Opens a browser pop-up for MFA sign-in. |
| **Device Code** | Headless or remote sessions (Azure Automation, SSH). A code is displayed in the Raw Log tab — enter it at `microsoft.com/devicelogin`. |
| **PSCredential** | Org-ID accounts without MFA. Not recommended on shared machines. |
| **Service Principal** | Automated or unattended runs. Requires Application ID, Tenant ID, and certificate thumbprint. |
| **Managed Identity** | Azure-hosted environments with a managed identity assigned. |

For Interactive and Device Code, entering a **Tenant ID or domain** (e.g. `contoso.onmicrosoft.com`) is optional but recommended for multi-tenant environments.

### Switches

| Switch | Default | Description |
| --- | --- | --- |
| **-HoldSummary** | On | Generates the per-custodian Purview eDiscovery hold location checklist |
| **-MediumDetails** | Off | Adds a 6-column compliance table to the Raw Log output |
| **-FullDetails** | Off | Adds a full property list to the Raw Log output |
| **-ExportToCsv** | On | Exports all records to a CSV file — **required for the Records Table and Gap Analysis tabs** |
| **-StayConnected** | Off | Keeps the Teams session open after the scan — useful when running multiple scans back to back |

---

## Running a Scan

1. Enter one or more custodian UPNs in the **UPNs to investigate** box — one per line, or comma-separated:

   ```text
   jdoe@contoso.com
   jane@contoso.com
   bob@contoso.com
   ```

2. Click **▶ Run Compliance Scan**.

3. The **PowerShell script** expander below the button shows the exact command being run (collapsed by default — click to expand). Passwords are automatically redacted.

4. A **Live PowerShell output** expander shows streaming progress as the scan runs (collapsed by default — expand if you need to monitor activity or troubleshoot).

5. Once the scan completes, a green **✅ Scan complete** message appears. If the scan fails, a red error message is shown — check the Raw Log tab for details.

---

## Reading the Results

### Compliance Summary

Appears immediately below the run button after every scan. This is the primary view for analysts.

- **Red banner** — one or more private channels have `OwnerlessPending` status. These channels were skipped during MC1134737 migration and compliance copies are still in individual member mailboxes. Immediate action is required.
- **Green banner** — no ownerless gaps detected for the scanned custodians.

**Per-custodian action table:**

| Column | Description |
| --- | --- |
| Custodian | The custodian UPN |
| Private Channels | Total number of private channels found |
| Migrated | Channels successfully moved to the new group mailbox model |
| ⚠️ Ownerless | Channels skipped during migration (critical gaps) |
| Pending | Channels not yet processed |
| Unknown | Channels where status could not be determined |
| Action Required | Traffic-light action for this custodian |

**Action Required values:**

| Indicator | Meaning |
| --- | --- |
| 🔴 | Assign channel owner(s) — add all current member mailboxes to the hold |
| 🟡 | Verify migration status before finalising the hold |
| 🟢 | Add group mailbox and SharePoint locations to the hold |
| ℹ️ | No private channels found — standard hold applies |

---

### Tab: 🔍 Gap Analysis

Visual breakdown of MC1134737 status across all scanned custodians.

- **KPI tiles** — total records, private channels, custodians, and ownerless gap count at a glance
- **Status pie chart** — proportion of channels by MC1134737_Status
- **Per-custodian bar chart** — stacked bar showing the status breakdown per UPN
- **Critical gap detail table** — if any ownerless channels exist, they are listed with their Team name, Channel name, ChannelThreadId, and GroupId for use in remediation

> Requires **-ExportToCsv** to be enabled.

---

### Tab: 📊 Records Table

Full filterable table of every record collected during the scan.

- Filter by **UPN**, **MC1134737_Status**, and/or **Team name** using the dropdowns
- The table shows: UPN, Team, Channel, Status, Membership Type, User Role, Group Mailbox, SharePoint URL, and Compliance Target
- Use **⬇️ Download filtered CSV** to export the current filtered view for legal review

> Requires **-ExportToCsv** to be enabled.

---

### Tab: 🏛️ Hold Summary

Purview eDiscovery hold location checklist, generated when **-HoldSummary** is enabled.

**Top section** — the raw hold summary block from the PowerShell output, showing the five sections exactly as they appear in the console.

**Bottom section** — structured per-custodian breakdown rendered as expandable cards, one per UPN:

| Section | What to add in Purview |
| --- | --- |
| Always required | Exchange mailbox and OneDrive — add as **custodian data sources** |
| Critical — ownerless channels | Listed per channel with remediation step |
| Private channel Exchange locations | Group mailboxes, deduplicated per team — add as **non-custodial data sources** |
| Private channel SharePoint locations | One URL per channel, labelled by status — add as **non-custodial data sources** |
| Add manually — parent team SharePoint | Team names only — look up the SharePoint URL in the Teams admin center |

---

### Tab: 🖥️ Raw Log

Full PowerShell console output from the scan. Useful for administrators troubleshooting errors or reviewing detailed activity.

The output is wrapped in a collapsible expander (expanded by default when you open the tab). Click the header to collapse it.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `pwsh not found` error | PowerShell 7.1+ is not installed or not on PATH | Install from [aka.ms/powershell](https://aka.ms/powershell) |
| `Module manifest not found` in sidebar | Path to `.psd1` is wrong | Update the path in the sidebar |
| No data in Records Table or Gap Analysis | `-ExportToCsv` is disabled | Enable **-ExportToCsv** in the sidebar |
| Authentication browser window does not open | Browser blocked pop-up | Allow pop-ups for `localhost`, or switch to Device Code flow |
| Device Code — where to enter the code | Code is in the live output expander | Expand **Live PowerShell output** during the run; go to `microsoft.com/devicelogin` |
| Scan completes but Hold Summary tab is empty | `-HoldSummary` is disabled | Enable **-HoldSummary** in the sidebar |
| `Import-Module: file is not digitally signed` | Module downloaded as ZIP without unblocking | Run `Get-ChildItem <extracted-folder> -Recurse \| Unblock-File` then restart the dashboard |

---

## Tips for Security Analysts

- **Start with the Compliance Summary** — the action table tells you everything you need to know at a glance. 🔴 rows require immediate action before the hold is complete.
- **OwnerlessPending channels are the highest priority** — compliance copies for these channels are distributed across all current member mailboxes. You must add every member's mailbox to the hold, not just the custodian's.
- **Use Gap Analysis to brief stakeholders** — the pie and bar charts are suitable for including in a compliance review presentation.
- **Use the Hold Summary tab when creating the Purview case** — work through each custodian card top to bottom and add each listed location to the case before marking it complete.
- **Export from Records Table for audit trail** — the filtered CSV download provides a timestamped record of what was found for a specific custodian or channel.
