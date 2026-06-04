---
external help file: Get-TeamsPrivateChannelComplianceMap-help.xml
Module Name: Get-TeamsPrivateChannelComplianceMap
online version: https://github.com/dgoldman-msft/Get-TeamsPrivateChannelComplianceMap
schema: 2.0.0
---

# Get-TeamsPrivateChannelComplianceMap

## SYNOPSIS

Maps one or more Teams custodians' private channel memberships to eDiscovery content locations to close the compliance gap created by MC1134737.

## SYNTAX

### Interactive (default)

```powershell
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
    [<CommonParameters>]
```

### Credential

```powershell
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
```

### ServicePrincipal

```powershell
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
    [<CommonParameters>]
```

### AccessTokens

```powershell
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
    [<CommonParameters>]
```

### ManagedIdentity

```powershell
Get-TeamsPrivateChannelComplianceMap
    -ManagedIdentity
    [-UserPrincipalName <String[]>]
    [-LoggingDirectory <String>]
    [-StayConnected]
    [-ExportToCsv]
    [-MediumDetails]
    [-FullDetails]
    [-HoldSummary]
    [<CommonParameters>]
```

**Alias:** `GTPCCM`

## DESCRIPTION

Microsoft Message Center notification **MC1134737** changed where Teams private channel messages are stored for compliance purposes, beginning in late October 2025.

**Before the migration**, compliance copies of private channel messages were delivered to every individual member's Exchange mailbox. Adding a custodian to a Microsoft Purview eDiscovery hold automatically captured all of their private channel activity.

**After the migration**, those compliance copies are delivered exclusively to the **parent team's Exchange group mailbox**, with the channel name embedded in the message subject. Individual user mailboxes no longer receive private channel messages.

**The problem**: Microsoft Purview's eDiscovery case wizard does not know which private channels a custodian belongs to. If you add a custodian's UPN and accept the suggested data source locations, the wizard will silently miss all post-migration private channel content — because the messages now live in a group mailbox, and files are stored in a dedicated SharePoint site that does not appear when looking up the user.

`Get-TeamsPrivateChannelComplianceMap` closes that gap.

### What the function does

Given one or more custodian UPNs, the function:

1. Checks the tenant-wide MC1134737 migration status via `Get-TenantPrivateChannelMigrationStatus` and identifies any private channels that were **skipped** because no owner was assigned — these are still on the old model and represent active compliance gaps.
2. Retrieves every Teams team the custodian belongs to via `Get-Team -User`.
3. Enumerates all channels in each team via `Get-TeamChannel`.
4. For each private channel, confirms the custodian is actually a member via `Get-TeamChannelUser` (private channel membership is independent of general team membership).
5. Resolves the parent team's Exchange group mailbox address and the dedicated SharePoint site URL for each private channel.
6. Assigns each channel an `MC1134737_Status` and a plain-English `ComplianceTarget` telling legal exactly which data sources to add to the Purview case.
7. Prints a color-coded **MC1134737 Compliance Gap Report** per custodian, with a consolidated summary across all UPNs in the run.
8. When run with `-HoldSummary`, generates a complete **Purview eDiscovery Hold Summary** — a ready-to-action checklist of every location that must be added to the custodian hold, including locations outside the MC1134737 scope.

### Locations this function does not resolve automatically

The function maps private channel compliance locations. The following locations are outside the MC1134737 scope and must be added to every hold regardless:

| Location | Content covered |
| --- | --- |
| **Custodian's Exchange mailbox** | 1:1 chats, group chats, standard and shared channel messages, pre-migration private channel messages |
| **Custodian's OneDrive** | Files shared in chats and meetings |
| **Parent team's SharePoint site** | Standard channel file storage (separate from private channel SharePoint sites) |

Use `-HoldSummary` to have the function generate this checklist automatically for each custodian.

### Ownerless channels — critical coverage gap

When a private channel has no assigned owner, Microsoft skips it during migration. That channel continues to deliver compliance copies to the **individual Exchange mailboxes of all current channel members** — not to the group mailbox. This function identifies every ownerless channel the custodian belongs to and flags it as a critical gap. Because the content is distributed across all member mailboxes, you must also add every other current member's mailbox to the hold. To unblock migration and consolidate compliance to the group mailbox going forward, assign an owner using `Add-TeamChannelUser -User <upn> -Role Owner`.

### Using -HoldSummary

Running with `-HoldSummary` produces a per-custodian checklist organized into five sections:

| Section | What to do in Purview |
| --- | --- |
| **Always required** — Exchange mailbox and OneDrive | Add as **custodian data sources** |
| **Critical — ownerless channels** | Add all current member mailboxes; assign owner to unblock migration |
| **Private channel Exchange locations** — group mailboxes, deduplicated per team | Add as **non-custodial data sources** |
| **Private channel SharePoint locations** — one URL per channel, labelled by status | Add as **non-custodial data sources** |
| **Add manually — parent team SharePoint** | Resolve in Teams admin center; add as **non-custodial data source** |

### Display modes

| Mode | Output |
| --- | --- |
| *(default)* | Per-user gap report sections + one summary line per UPN |
| `-MediumDetails` | Adds a consolidated six-column table after the summaries |
| `-FullDetails` | Adds a full `Format-List` of every property after the summaries |
| `-HoldSummary` | Adds a per-custodian Purview hold location checklist after the summaries |

## PARAMETERS

### -UserPrincipalName

One or more UPNs of the custodians to investigate, e.g. `jdoe@contoso.com`. Accepts an array — each UPN is processed in sequence within the same Teams session. Prompted interactively if omitted; invalid UPNs are flagged and re-prompted until all entries are valid.

| Attribute | Value |
| --- | --- |
| Type | `String[]` |
| Position | Named |
| Required | No |
| Default | *(interactive prompt)* |
| Accept pipeline input | No |

### -LoggingDirectory

Directory where the timestamped log file (and optional CSV) are written.

| Attribute | Value |
| --- | --- |
| Type | `String` |
| Position | Named |
| Required | No |
| Default | `$env:TEMP\Get-TeamsPrivateChannelComplianceMap` |
| Accept pipeline input | No |

### -TenantId

Tenant ID or domain (e.g. `contoso.onmicrosoft.com`). Mandatory for the `ServicePrincipal` parameter set; optional for Interactive, Credential, and AccessTokens.

| Attribute | Value |
| --- | --- |
| Type | `String` |
| Parameter sets | Interactive, Credential, ServicePrincipal *(mandatory)*, AccessTokens |
| Required | **Yes** for ServicePrincipal; No for others |

### -UseDeviceAuthentication

*(Interactive set)* Use device-code flow instead of a browser pop-up. Useful for headless or remote sessions such as Azure Automation or SSH.

| Attribute | Value |
| --- | --- |
| Type | `Switch` |
| Parameter set | `Interactive` |
| Required | No |

### -TeamsAdminCredential

*(Credential set)* `PSCredential` for organizational-ID accounts without MFA. Create with `Get-Credential`.

| Attribute | Value |
| --- | --- |
| Type | `PSCredential` |
| Parameter set | `Credential` |
| Required | **Yes** |

### -ApplicationId

*(ServicePrincipal set)* Azure app registration Application (client) ID. Requires MicrosoftTeams 4.7.1-preview or later.

| Attribute | Value |
| --- | --- |
| Type | `String` |
| Parameter set | `ServicePrincipal` |
| Required | **Yes** |

### -CertificateThumbprint

*(ServicePrincipal set)* Thumbprint of the certificate in the local cert store. Provide this or `-Certificate`.

| Attribute | Value |
| --- | --- |
| Type | `String` |
| Parameter set | `ServicePrincipal` |
| Required | No *(one of -CertificateThumbprint or -Certificate is required)* |

### -Certificate

*(ServicePrincipal set)* `X509Certificate2` object loaded from a `.pfx` file. Provide this or `-CertificateThumbprint`.

| Attribute | Value |
| --- | --- |
| Type | `X509Certificate2` |
| Parameter set | `ServicePrincipal` |
| Required | No *(one of -CertificateThumbprint or -Certificate is required)* |

### -AccessTokens

*(AccessTokens set)* Two-element array. Index `[0]` = MS Graph token. Index `[1]` = Skype and Teams Tenant Admin API token.

| Attribute | Value |
| --- | --- |
| Type | `String[]` |
| ValidateCount | 2, 2 |
| Parameter set | `AccessTokens` |
| Required | **Yes** |

### -ManagedIdentity

*(ManagedIdentity set)* Connect using the Azure managed service identity assigned to the current host. Requires MicrosoftTeams 5.8.1-preview or later.

| Attribute | Value |
| --- | --- |
| Type | `Switch` |
| Parameter set | `ManagedIdentity` |
| Required | **Yes** |

### -StayConnected

When specified, the Microsoft Teams session is NOT disconnected after the function completes. If an active Teams session is already detected (via `Get-CsTenant`), `Connect-MicrosoftTeams` is skipped entirely — no re-authentication prompt. Useful when chaining multiple Teams operations or running the function repeatedly.

| Attribute | Value |
| --- | --- |
| Type | `Switch` |
| Required | No |

### -ExportToCsv

When specified, all collected records are exported to a timestamped CSV file in `-LoggingDirectory` named `ComplianceMap_yyyyMMdd_HHmmss.csv`.

| Attribute | Value |
| --- | --- |
| Type | `Switch` |
| Required | No |

### -MediumDetails

When specified, a consolidated six-column table is printed after the per-user gap reports and summary lines: `UserPrincipalName`, `TeamName`, `GroupMailbox`, `ChannelName`, `MC1134737_Status`, `ComplianceTarget`. Covers all UPNs processed in the run. Cannot be combined with `-FullDetails`.

| Attribute | Value |
| --- | --- |
| Type | `Switch` |
| Required | No |

### -FullDetails

When specified, every property of every record is printed as a `Format-List` after the per-user gap reports and summary lines. Covers all UPNs processed in the run. Cannot be combined with `-MediumDetails`.

| Attribute | Value |
| --- | --- |
| Type | `Switch` |
| Required | No |

### -HoldSummary

When specified, prints a per-custodian **Purview eDiscovery Hold Summary** after the MC1134737 gap reports. The summary consolidates every location that must be added to the custodian hold in Microsoft Purview:

- **ALWAYS REQUIRED** — the custodian's Exchange mailbox and OneDrive (add as custodian data sources).
- **CRITICAL** — any `OwnerlessPending` channels still on the old model, whose compliance copies remain in individual member mailboxes.
- **PRIVATE CHANNEL — EXCHANGE** — parent team group mailboxes for all migrated/pending private channels, deduplicated per team (add as non-custodial data sources).
- **PRIVATE CHANNEL — SHAREPOINT** — dedicated SharePoint site URL for each private channel, labelled by status.
- **ADD MANUALLY** — a list of teams for which the parent team SharePoint site (standard channel file storage) must be looked up manually in the Teams admin center.

OneDrive URLs are constructed from the UPN and may need verification for tenants that use custom SharePoint domain names.

| Attribute | Value |
| --- | --- |
| Type | `Switch` |
| Required | No |

## EXAMPLES

### Example 1 — Interactive browser/MFA, single user

```powershell
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com
```

### Example 2 — Multiple custodians in one run

```powershell
Get-TeamsPrivateChannelComplianceMap `
    -UserPrincipalName jdoe@contoso.com, jane@contoso.com, bob@contoso.com
```

### Example 3 — Medium details table

```powershell
Get-TeamsPrivateChannelComplianceMap `
    -UserPrincipalName jdoe@contoso.com, jane@contoso.com `
    -MediumDetails
```

### Example 4 — Full details list

```powershell
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com -FullDetails
```

### Example 5 — Device-code flow

```powershell
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
    -UseDeviceAuthentication -TenantId contoso.onmicrosoft.com
```

### Example 6 — PSCredential

```powershell
$cred = Get-Credential
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
    -TeamsAdminCredential $cred
```

### Example 7 — Service principal (certificate thumbprint)

```powershell
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
    -ApplicationId '00000000-0000-0000-0000-000000000000' `
    -TenantId 'contoso.onmicrosoft.com' `
    -CertificateThumbprint 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
```

### Example 8 — Service principal (certificate object)

```powershell
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
    'C:\certs\app.pfx', (Read-Host -AsSecureString 'PFX password'))

Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
    -ApplicationId '00000000-0000-0000-0000-000000000000' `
    -TenantId 'contoso.onmicrosoft.com' `
    -Certificate $cert
```

### Example 9 — Pre-acquired access tokens

```powershell
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
    -AccessTokens @($graphToken, $teamsToken)
```

### Example 10 — Managed identity

```powershell
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
    -ManagedIdentity -LoggingDirectory 'D:\ComplianceLogs'
```

### Example 11 — Export to CSV

```powershell
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com -ExportToCsv
```

### Example 12 — Stay connected across multiple runs

```powershell
# First run — authenticates and leaves the session open
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com -StayConnected

# Second run — detects the existing session and skips re-authentication
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jane@contoso.com -StayConnected

# Clean up when done
Disconnect-MicrosoftTeams
```

### Example 13 — Use alias

```powershell
GTPCCM -UserPrincipalName jdoe@contoso.com
```

### Example 14 — Interactive prompt (no UPN supplied)

```powershell
Get-TeamsPrivateChannelComplianceMap
```

Prompts for one or more comma-separated UPNs. Invalid UPNs are rejected and re-prompted.

### Example 15 — Purview eDiscovery Hold Summary

```powershell
Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com -HoldSummary
```

After the MC1134737 gap report, prints a consolidated hold location checklist for the custodian. Sections printed:

1. **ALWAYS REQUIRED** — Exchange mailbox and OneDrive (custodian data sources).
2. **CRITICAL — OWNERLESS CHANNELS** — channels still on the old model; listed per channel with remediation step.
3. **PRIVATE CHANNEL — EXCHANGE LOCATIONS** — deduplicated group mailboxes for migrated/pending channels (non-custodial data sources).
4. **PRIVATE CHANNEL — SHAREPOINT LOCATIONS** — one SharePoint URL per private channel, labelled by `MC1134737_Status`.
5. **ADD MANUALLY** — team names whose parent SharePoint site (standard channel files) must be resolved in the Teams admin center.

## OUTPUTS

**None (display only).** Console output is controlled by `-MediumDetails` and `-FullDetails`. Use `-ExportToCsv` to capture all records to a CSV file.

Internally the function builds a collection of `PSCustomObject` records tagged with the TypeName `TeamsPrivateChannelComplianceMap.Record`. Each record contains the following fields:

| Field | Type | Description |
| --- | --- | --- |
| `UserPrincipalName` | String | The investigated custodian's UPN |
| `TeamName` | String | Display name of the parent team |
| `GroupId` | String | Azure AD group GUID of the parent team |
| `GroupMailbox` | String | Exchange group mailbox of the parent team |
| `ChannelName` | String | Display name of the channel |
| `ChannelThreadId` | String | Unique channel thread ID (`19:xxx@thread.tacv2`) |
| `MembershipType` | String | `Standard`, `Private`, or `Shared` |
| `IsPrivateChannel` | Boolean | `$true` for private channels |
| `SharePointSiteUrl` | String | Dedicated SharePoint site URL (private channels only) |
| `UserRole` | String | `Owner` or `Member` |
| `MC1134737_Status` | String | See MC1134737_Status values below |
| `ComplianceTarget` | String | Plain-English eDiscovery data source |

### MC1134737_Status values

| Value | Meaning |
| --- | --- |
| `NotApplicable` | Standard or Shared channel — not affected by the migration |
| `Migrated` | Private channel fully migrated — search the parent group mailbox |
| `OwnerlessPending` | **CRITICAL GAP** — channel skipped (no owner); compliance copies still in individual user mailboxes |
| `MigrationPending` | Private channel not yet processed — verify before eDiscovery |
| `NotStarted` | Migration has not begun for this tenant |
| `Unknown` | Migration status could not be retrieved |

## NOTES

- Alias: `GTPCCM`
- Requires PowerShell 7.1 or later.
- The `MicrosoftTeams` module is installed automatically from PSGallery if not present.
- `Get-TenantPrivateChannelMigrationStatus` requires Teams Administrator or Global Administrator.
- ServicePrincipal auth requires MicrosoftTeams 4.7.1-preview or later.
- ManagedIdentity auth requires MicrosoftTeams 5.8.1-preview or later.
- Each invocation creates a separate timestamped log file in `-LoggingDirectory`.
- Session reuse: when `-StayConnected` is specified and `Get-CsTenant` succeeds, `Connect-MicrosoftTeams` is skipped entirely.
- `-MediumDetails` and `-FullDetails` are mutually exclusive; `-FullDetails` takes precedence if both are supplied.
- `-HoldSummary` can be combined with any other switch (`-MediumDetails`, `-FullDetails`, `-ExportToCsv`, `-StayConnected`).

### eDiscovery hold coverage

This function maps the content locations for the custodian's **private channel content** (MC1134737 scope) only. For a complete Purview eDiscovery hold the following locations must be added manually — they are outside the MC1134737 scope and are not enumerated by this function. Use **`-HoldSummary`** to have the function generate this checklist automatically for each custodian.

| Location | Content covered | How to find it |
| --- | --- | --- |
| Custodian's Exchange mailbox | 1:1 chats, group chats, standard and shared channel messages, pre-migration private channel messages | Add the custodian UPN as an Exchange custodian data source in the Purview case |
| Custodian's OneDrive | Files shared in chats and meetings | Add the custodian UPN as a OneDrive custodian data source in the Purview case |
| Parent team's SharePoint site | Standard channel file storage (separate from the private channel `SharePointSiteUrl`) | Look up the team's SharePoint URL in the Teams admin center or via `Get-Team` |

**OwnerlessPending channels:** When `MC1134737_Status = OwnerlessPending`, migration was skipped because no channel owner is assigned. Messages remain in individual member mailboxes. This function identifies the custodian's channel but does **not** enumerate all other members. For complete hold coverage, add the mailboxes of every current channel member and assign an owner via `Add-TeamChannelUser -User <upn> -Role Owner` to unblock migration.

## RELATED LINKS

- [MC1134737 announcement (Message Center)](https://admin.microsoft.com/adminportal/home#/MessageCenter)
- [Get-TenantPrivateChannelMigrationStatus](https://learn.microsoft.com/en-us/powershell/module/microsoftteams/get-tenantprivatechannelmigrationstatus)
- [Private channels in Microsoft Teams](https://learn.microsoft.com/en-us/microsoftteams/private-channels)
- [Connect-MicrosoftTeams](https://learn.microsoft.com/en-us/powershell/module/microsoftteams/connect-microsoftteams)
- [Get-Team](https://learn.microsoft.com/en-us/powershell/module/microsoftteams/get-team)
- [Get-TeamChannel](https://learn.microsoft.com/en-us/powershell/module/microsoftteams/get-teamchannel)
- [Get-TeamChannelUser](https://learn.microsoft.com/en-us/powershell/module/microsoftteams/get-teamchanneluser)
- [GitHub project](https://github.com/dgoldman-msft/Get-TeamsPrivateChannelComplianceMap)
