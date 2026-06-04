# Get-TeamsPrivateChannelComplianceMap

Microsoft Message Center notification **MC1134737** changed where Teams private channel messages are stored for compliance purposes, beginning in late October 2025.

**Before the migration**, compliance copies of private channel messages were delivered to every individual member's Exchange mailbox. Adding a custodian to a Microsoft Purview eDiscovery hold automatically captured all of their private channel activity.

**After the migration**, those compliance copies are delivered exclusively to the **parent team's Exchange group mailbox**, with the channel name embedded in the message subject. Individual user mailboxes no longer receive private channel messages.

**The problem**: Microsoft Purview's eDiscovery case wizard does not know which private channels a custodian belongs to. If you add a custodian's UPN and accept the suggested data source locations, the wizard will silently miss all post-migration private channel content — because the messages now live in a group mailbox, and files are stored in a dedicated SharePoint site that does not appear when looking up the user.

This module closes that gap. Given one or more custodian UPNs, it:

1. Checks the tenant-wide MC1134737 migration status and identifies any private channels that were **skipped** because no owner was assigned — these are still on the old model and represent active compliance gaps.
2. Retrieves every Teams team the custodian belongs to.
3. Enumerates all channels in each team.
4. Confirms the custodian is actually a member of each private channel (private channel membership is independent of general team membership).
5. Resolves the parent team's Exchange group mailbox address and the dedicated SharePoint site URL for each private channel.
6. Assigns each channel an **MC1134737_Status** and a plain-English **ComplianceTarget** telling legal exactly which data sources to add to the Purview case.
7. Prints a color-coded **MC1134737 Compliance Gap Report** per custodian, with a consolidated summary across all UPNs in the run.
8. Optionally generates a **Purview eDiscovery Hold Summary** (`-HoldSummary`) — a complete, ready-to-action checklist of every location to add to the custodian hold, including standard channel group mailboxes, constructed (or Graph-resolved) parent team SharePoint URLs, and always-required custodian locations.
   Add `-ResolveSharePointUrls` to resolve parent team SharePoint URLs authoritatively via Microsoft Graph instead of constructing them from the group mailbox MailNickName.

## Locations this tool does not resolve automatically

The tool maps private channel compliance locations. The following locations are outside the MC1134737 scope and must be added to every hold regardless:

| Location | Content covered |
| --- | --- |
| **Custodian's Exchange mailbox** | 1:1 chats, group chats, standard and shared channel messages, pre-migration private channel messages |
| **Custodian's OneDrive** | Files shared in chats and meetings |
| **Parent team's SharePoint site** | Standard channel file storage (separate from private channel SharePoint sites) |

Use **`-HoldSummary`** to have the tool generate this checklist automatically for each custodian.

## Ownerless channels — critical coverage gap

When a private channel has no assigned owner, Microsoft skips it during migration. That channel continues to deliver compliance copies to the **individual Exchange mailboxes of all current channel members** — not to the group mailbox. This tool identifies every ownerless channel the custodian belongs to and flags it as a critical gap. However, because the content is distributed across all member mailboxes, you must also add every other current member's mailbox to the hold. To unblock migration and consolidate compliance to the group mailbox going forward, assign an owner to the channel using `Add-TeamChannelUser -User <upn> -Role Owner`.

## Using -HoldSummary

Running with `-HoldSummary` produces a per-custodian checklist organized into five sections:

| Section | What to do in Purview |
| --- | --- |
| **Always required** — Exchange mailbox and OneDrive | Add as **custodian data sources** |
| **Critical — ownerless channels** | Add all current member mailboxes; assign owner to unblock migration |
| **Private channel Exchange locations** — group mailboxes, deduplicated per team | Add as **non-custodial data sources** |
| **Private channel SharePoint locations** — one URL per channel, labelled by status | Add as **non-custodial data sources** |
| **Standard/Shared channel Exchange locations** — group mailboxes, deduplicated per team | Add as **non-custodial data sources** |
| **Parent team SharePoint** — `[Constructed]` from MailNickName, or `[Graph-resolved]` with `-ResolveSharePointUrls` | Add as **non-custodial data sources** |

## Requirements

- PowerShell 7.1 or later
- `MicrosoftTeams` module (installed automatically if not present)
- An active Microsoft Teams connection — the function connects automatically
- The account used must have **Teams Administrator** or **Global Administrator** to call `Get-TenantPrivateChannelMigrationStatus`
- For ServicePrincipal auth: MicrosoftTeams 4.7.1-preview or later
- For ManagedIdentity auth: MicrosoftTeams 5.8.1-preview or later

## Installation

Copy the `Get-TeamsPrivateChannelComplianceMap` folder (containing the `1.0` subfolder) into one of the directories listed in `$env:PSModulePath`, for example:

```
C:\Users\<you>\Documents\PowerShell\Modules\Get-TeamsPrivateChannelComplianceMap\1.0\
```

**If you downloaded a ZIP from GitHub**, Windows marks the extracted files as coming from the internet. You must unblock them before importing, otherwise PowerShell will refuse to load the module under a `RemoteSigned` execution policy with an error similar to:

```text
Import-Module: File ...\Get-TeamsPrivateChannelComplianceMap.psm1 cannot be loaded.
The file is not digitally signed. You cannot run this script on the current system.
```

Run `Unblock-File` against the extracted folder, then import. Replace the path with wherever you extracted the ZIP:

```powershell
# Step 1 — remove the internet-origin mark from all extracted files
Get-ChildItem 'C:\temp\teams2\Get-TeamsPrivateChannelComplianceMap-main' -Recurse | Unblock-File

# Step 2 — import the module
Import-Module 'C:\temp\teams2\Get-TeamsPrivateChannelComplianceMap-main\1.0\Get-TeamsPrivateChannelComplianceMap.psd1'
```

Then import it by name:

```powershell
Import-Module Get-TeamsPrivateChannelComplianceMap
```

Or import directly from a cloned repository:

```powershell
git clone https://github.com/dgoldman-msft/Get-TeamsPrivateChannelComplianceMap.git
Import-Module .\Get-TeamsPrivateChannelComplianceMap\1.0\Get-TeamsPrivateChannelComplianceMap.psd1
```

> **Note:** Files cloned via `git` do not carry the internet-origin mark and do not require `Unblock-File`.

The function is also available via the alias `GTPCCM` once the module is imported.

## Syntax

```
Get-TeamsPrivateChannelComplianceMap
    [-UserPrincipalName <String[]>]
    [-LoggingDirectory <String>]
    [-TenantId <String>]
    [-UseDeviceAuthentication]
    [-StayConnected]
    [-ExportToCsv]
    [-MediumDetails]
    [-FullDetails]
    [-HoldSummary]
    [-ResolveSharePointUrls]
    [<CommonParameters>]

Get-TeamsPrivateChannelComplianceMap
    -TeamsAdminCredential <PSCredential>
    [-UserPrincipalName <String[]>]
    [-LoggingDirectory <String>]
    [-TenantId <String>]
    [-StayConnected]
    [-ExportToCsv]
    [-MediumDetails]
    [-FullDetails]
    [-HoldSummary]
    [<CommonParameters>]

Get-TeamsPrivateChannelComplianceMap
    -ApplicationId <String>
    -TenantId <String>
    [-CertificateThumbprint <String>]
    [-Certificate <X509Certificate2>]
    [-UserPrincipalName <String[]>]
    [-LoggingDirectory <String>]
    [-StayConnected]
    [-ExportToCsv]
    [-MediumDetails]
    [-FullDetails]
    [-HoldSummary]
    [-ResolveSharePointUrls]
    [<CommonParameters>]

Get-TeamsPrivateChannelComplianceMap
    -AccessTokens <String[]>
    [-UserPrincipalName <String[]>]
    [-LoggingDirectory <String>]
    [-TenantId <String>]
    [-StayConnected]
    [-ExportToCsv]
    [-MediumDetails]
    [-FullDetails]
    [-HoldSummary]
    [-ResolveSharePointUrls]
    [<CommonParameters>]

Get-TeamsPrivateChannelComplianceMap
    -ManagedIdentity
    [-UserPrincipalName <String[]>]
    [-LoggingDirectory <String>]
    [-StayConnected]
    [-ExportToCsv]
    [-MediumDetails]
    [-FullDetails]
    [-HoldSummary]
    [-ResolveSharePointUrls]
    [<CommonParameters>]
```

## Parameters

| Parameter | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `-UserPrincipalName` | String[] | No | — | One or more UPNs to investigate. Accepts an array; each is processed in sequence. Prompted interactively if omitted; invalid UPNs are re-prompted. |
| `-LoggingDirectory` | String | No | `$env:TEMP\Get-TeamsPrivateChannelComplianceMap` | Directory for timestamped log files (created automatically if absent). |
| `-TenantId` | String | No* | — | Tenant ID or domain. Mandatory for ServicePrincipal; optional for other sets. |
| `-UseDeviceAuthentication` | Switch | No | `$false` | Use device-code flow instead of a browser pop-up (Interactive set only). |
| `-TeamsAdminCredential` | PSCredential | Yes* | — | PSCredential for org-ID accounts without MFA (Credential set). |
| `-ApplicationId` | String | Yes* | — | Azure app registration client ID (ServicePrincipal set). |
| `-CertificateThumbprint` | String | No* | — | Certificate thumbprint from the local cert store (ServicePrincipal set). |
| `-Certificate` | X509Certificate2 | No* | — | Certificate object from a .pfx file (ServicePrincipal set). |
| `-AccessTokens` | String[2] | Yes* | — | Two-element array: `[0]` MS Graph token, `[1]` Skype/Teams Admin API token (AccessTokens set). |
| `-ManagedIdentity` | Switch | Yes* | — | Connect via Azure managed service identity (ManagedIdentity set). |
| `-StayConnected` | Switch | No | `$false` | Keep the Teams session open after the function completes. If a session is already active (detected via `Get-CsTenant`), reconnection is skipped entirely. |
| `-ExportToCsv` | Switch | No | `$false` | Export all collected records to a timestamped CSV file in `-LoggingDirectory`. |
| `-MediumDetails` | Switch | No | `$false` | After the per-user gap reports, print a consolidated six-column table for all UPNs. |
| `-FullDetails` | Switch | No | `$false` | After the per-user gap reports, print all properties as `Format-List` for all UPNs. |
| `-HoldSummary` | Switch | No | `$false` | After the gap reports, print a per-custodian Purview eDiscovery hold location checklist. |
| `-ResolveSharePointUrls` | Switch | No | `$false` | When used with `-HoldSummary`, queries Microsoft Graph (`GET /groups/{id}/sites/root`) for authoritative parent team SharePoint URLs. Resolved once per team in the scan loop and stored in `ParentTeamSharePointUrl` on every record — so the CSV export and dashboard both show the resolved URL. Requires `Sites.Read.All`. Falls back to constructed URL on failure. Not supported with PSCredential. |

\* Required for the relevant parameter set only.

## Examples

### 1. Interactive browser/MFA — single custodian

```powershell
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com
```

### 2. Multiple custodians in one run

```powershell
Get-TeamsPrivateChannelComplianceMap `
    -UserPrincipalName jdoe@contoso.com, jane@contoso.com, bob@contoso.com
```

### 3. Consolidated table after gap reports

```powershell
Get-TeamsPrivateChannelComplianceMap `
    -UserPrincipalName jdoe@contoso.com, jane@contoso.com `
    -MediumDetails
```

### 4. Full property list after gap reports

```powershell
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com -FullDetails
```

### 5. Device-code flow for headless sessions

```powershell
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
    -UseDeviceAuthentication -TenantId contoso.onmicrosoft.com
```

### 6. PSCredential authentication

```powershell
$cred = Get-Credential
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
    -TeamsAdminCredential $cred
```

### 7. Service principal — certificate thumbprint

```powershell
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
    -ApplicationId '00000000-0000-0000-0000-000000000000' `
    -TenantId 'contoso.onmicrosoft.com' `
    -CertificateThumbprint 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
```

### 8. Service principal — certificate object

```powershell
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
    'C:\certs\app.pfx', (Read-Host -AsSecureString 'PFX password'))
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
    -ApplicationId '00000000-0000-0000-0000-000000000000' `
    -TenantId 'contoso.onmicrosoft.com' `
    -Certificate $cert
```

### 9. Pre-acquired access tokens

```powershell
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
    -AccessTokens @($graphToken, $teamsToken)
```

### 10. Managed identity with custom log directory

```powershell
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
    -ManagedIdentity -LoggingDirectory 'D:\ComplianceLogs'
```

### 11. Export to CSV

```powershell
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com -ExportToCsv
```

### 12. Stay connected across multiple runs

```powershell
# First run — authenticates and leaves the session open
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com -StayConnected

# Second run — detects existing session and skips re-authentication
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jane@contoso.com -StayConnected

# Clean up when done
Disconnect-MicrosoftTeams
```

### 13. Use the GTPCCM alias

```powershell
GTPCCM -UserPrincipalName jdoe@contoso.com
```

### 14. Interactive prompt — no UPN supplied

```powershell
Get-TeamsPrivateChannelComplianceMap
```

Prompts for one or more comma-separated UPNs. Invalid UPNs are rejected and re-prompted.

### 15. Purview eDiscovery Hold Summary

```powershell
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com -HoldSummary
```

After the MC1134737 gap report, prints a consolidated hold location checklist for each custodian:

- **ALWAYS REQUIRED** — Exchange mailbox and OneDrive (custodian data sources in Purview)
- **CRITICAL** — OwnerlessPending channels that are still on the old model (individual member mailboxes)
- **PRIVATE CHANNEL — EXCHANGE** — parent team group mailboxes for migrated/pending channels (deduplicated per team)
- **PRIVATE CHANNEL — SHAREPOINT** — dedicated SharePoint site URL for each private channel
- **ADD MANUALLY** — parent team SharePoint sites for standard channel file storage (URLs not resolved by this function)

Can be combined with `-ExportToCsv` or `-StayConnected`.

## Output

Each record is a `PSCustomObject` tagged with the TypeName `TeamsPrivateChannelComplianceMap.Record`. Core properties are always present.

### Core properties

| Property | Description |
| --- | --- |
| `UserPrincipalName` | The custodian's UPN |
| `TeamName` | Display name of the parent team |
| `GroupId` | Azure AD group GUID of the parent team |
| `GroupMailbox` | Exchange group mailbox of the parent team — eDiscovery Exchange location post-migration |
| `ChannelName` | Display name of the channel |
| `ChannelThreadId` | Unique channel thread ID (`19:xxx@thread.tacv2`) |
| `MembershipType` | `Standard`, `Private`, or `Shared` |
| `IsPrivateChannel` | `$true` for private channels |
| `SharePointSiteUrl` | Dedicated SharePoint site URL (private channels only) — eDiscovery file location |
| `ParentTeamSharePointUrl` | Parent team SharePoint URL — Graph-resolved (`[Graph-resolved]`) or constructed from `GroupMailbox` MailNickName (`[Constructed]`). Included in the CSV export and used by the dashboard Hold Summary tab. |
| `UserRole` | `Owner` or `Member` within this channel |
| `MC1134737_Status` | Compliance status — see values below |
| `ComplianceTarget` | Plain-English eDiscovery data source to add to the case |

### MC1134737_Status values

| Value | Meaning | eDiscovery action |
| --- | --- | --- |
| `NotApplicable` | Standard or Shared channel — not affected | Standard eDiscovery approach applies |
| `Migrated` | Fully migrated to new compliance model | Search `GroupMailbox` (filter subject by channel name) + `SharePointSiteUrl` |
| `OwnerlessPending` | **CRITICAL GAP** — channel skipped (no owner assigned) | Search individual user mailboxes; assign owner via `Add-TeamChannelUser` to unblock |
| `MigrationPending` | Not yet processed | Verify current state before eDiscovery |
| `NotStarted` | Migration has not begun for this tenant | Individual user mailboxes still apply |
| `Unknown` | Migration status could not be retrieved | Review logs and rerun |

## eDiscovery Hold Coverage

This tool maps the locations for the custodian's **private channel content** only. For a complete Purview eDiscovery hold you must also add the following locations manually — they are outside the scope of MC1134737 and are not enumerated by this function. Use **`-HoldSummary`** to have the function generate this checklist automatically for each custodian.

| Location | Content covered | How to find it |
| --- | --- | --- |
| Custodian's Exchange mailbox | 1:1 chats, group chats, standard and shared channel messages where the user is a participant, pre-migration private channel messages | Add the custodian UPN as an Exchange custodian data source in the Purview case |
| Custodian's OneDrive | Files shared in chats and meetings | Add the custodian UPN as a OneDrive custodian data source in the Purview case |
| Parent team's SharePoint site | Standard channel file storage (separate from the private channel SharePoint site returned in `SharePointSiteUrl`) | Look up the team's SharePoint URL in the Teams admin center or via `Get-Team` |

### OwnerlessPending channels

When a private channel has `MC1134737_Status = OwnerlessPending`, the migration was skipped because no owner was assigned. Messages for that channel remain in **individual member mailboxes** — not in a group mailbox. This tool identifies the channel and flags the custodian, but it **does not enumerate all other channel members**. For complete hold coverage of an ownerless channel you must also add the mailboxes of every current member. Assign an owner via `Add-TeamChannelUser -User <upn> -Role Owner` to unblock migration and consolidate the compliance location.

## Logging

Every run writes a timestamped log file to `-LoggingDirectory` (default: `$env:TEMP\Get-TeamsPrivateChannelComplianceMap`). Log files are named `Logging_yyyyMMdd_HHmmss.txt` so runs never share or overwrite each other.

- Every activity line is prefixed with a timestamp.
- Each collected record is written to the log with one property per line.
- A separator line marks the start and end of every run.
- The full log file path is printed to the console in Cyan at the end of each run.
- When `-ExportToCsv` is specified, a matching `ComplianceMap_yyyyMMdd_HHmmss.csv` is written to the same directory.

## Console output

| Mode | Output |
| --- | --- |
| Default | Per-user `Results for:` line during scan, then per-user MC1134737 gap report sections and one summary line per UPN in the `end` block |
| `-MediumDetails` | All of the above, plus a consolidated six-column table (`UserPrincipalName`, `TeamName`, `GroupMailbox`, `ChannelName`, `MC1134737_Status`, `ComplianceTarget`) printed after the summary lines |
| `-FullDetails` | All of the above, plus all record properties printed as `Format-List` after the summary lines |
| `-HoldSummary` | All of the above, plus a per-custodian Purview hold location checklist (Exchange mailbox, OneDrive, private channel Exchange + SharePoint, standard/shared channel Exchange, and parent team SharePoint URLs) |
| `-ResolveSharePointUrls` | When combined with `-HoldSummary`, replaces `[Constructed]` parent team SharePoint URLs with Graph-resolved `[Graph-resolved]` URLs via `GET /groups/{id}/sites/root`. Requires `Sites.Read.All`. |

## Get-Help

Full parameter and example documentation is available via:

```powershell
Get-Help Get-TeamsPrivateChannelComplianceMap -Full
Get-Help Get-TeamsPrivateChannelComplianceMap -Examples
```

## Required Permissions

### Microsoft Teams Role

The account running this function must have one of:

- ✅ Teams Administrator
- ✅ Global Administrator

### Why elevated permissions are required

`Get-TenantPrivateChannelMigrationStatus` is a tenant-scoped cmdlet that returns the MC1134737 migration state and the list of ownerless channels that were skipped during migration. It requires tenant administrator access and is not available to standard users.

### Assigning the minimum role

To assign only the Teams Administrator role in the Microsoft 365 admin center:

1. Go to **Users > Active users**
2. Select the user
3. Go to **Manage roles > Admin center access**
4. Assign **Teams Administrator**

## Dashboard

A Python/Streamlit web dashboard is included in the `dashboard/` folder. Enter custodian UPNs in a browser, run the PowerShell module, and review results across five tabs. Settings are persisted to `dashboard_settings.json` (excluded from git) so preferences survive restarts.

### Prerequisites

- Python 3.11 or later
- PowerShell 7.1 or later (available as `pwsh` on PATH)

### Install and run

```powershell
cd dashboard
pip install -r requirements.txt
python -m streamlit run app.py
```

Streamlit opens the dashboard automatically at `http://localhost:8501`.

### Features

| Tab | What it shows |
| --- | --- |
| **🔍 Gap Analysis** | KPI metrics, MC1134737 status pie chart, per-custodian bar chart, ownerless channel critical callout |
| **📊 Records Table** | Filterable table of all records including `ParentTeamSharePointUrl`; download filtered CSV |
| **🏛️ Hold Summary** | Per-custodian Purview hold checklist — Exchange mailbox, OneDrive, private/standard channel Exchange + SharePoint locations |
| **🖥️ Raw Log** | Full timestamped log file from the PowerShell run; download button |
| **🚨 Error Log** | All errors and warnings captured during the scan; download button |

### Sidebar options

- **Module manifest path** — auto-detected relative to `dashboard/app.py`; change if running from a different location
- **Log / CSV output directory** — where the module writes its timestamped log and CSV files
- **Authentication method** — Interactive (browser/MFA), Device Code, PSCredential, Service Principal, or Managed Identity; relevant credential fields appear automatically
- **Switches** — `-HoldSummary`, `-ResolveSharePointUrls` (Graph-resolved parent team SharePoint URLs — requires `Sites.Read.All`), `-MediumDetails`, `-FullDetails`, `-StayConnected`
- **Session panel** — shows Teams session status (🟢 active / ⚫ none); **Disconnect Teams** and **Kill session** buttons

> **Note:** `-ExportToCsv` is always enabled by the dashboard — the CSV is required for the Records Table, Gap Analysis, and Hold Summary tabs.

### Session reuse

The dashboard keeps a single persistent `pwsh -NoExit` process alive for the lifetime of the browser session. On the second and subsequent scans the Teams session is reused automatically — no re-authentication prompt. The session status indicator in the sidebar shows whether a live Teams session is active.

### Note on authentication

For Interactive and Device Code flows, the Microsoft Teams authentication prompt opens in a **separate browser window**. The dashboard remains responsive while waiting. For Device Code, the code appears in the **Raw Log** tab.

## License

© Dave Goldman. All rights reserved. See [LICENSE](LICENSE) for details.

