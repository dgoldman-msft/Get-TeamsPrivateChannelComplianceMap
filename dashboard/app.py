"""
Teams Private Channel Compliance Dashboard
==========================================
Streamlit web app that invokes Get-TeamsPrivateChannelComplianceMap and
visualises the results in a browser-based dashboard.

Usage
-----
    cd dashboard
    pip install -r requirements.txt
    streamlit run app.py
"""

import glob
import os
import re
import subprocess
from pathlib import Path

import pandas as pd
import plotly.express as px
import streamlit as st

# ── Page config ───────────────────────────────────────────────────────────────
st.set_page_config(
    page_title="Teams Compliance Dashboard",
    page_icon="🔐",
    layout="wide",
    initial_sidebar_state="expanded",
)

# ── Session state defaults ────────────────────────────────────────────────────
_defaults: dict = {
    "output_lines": [],
    "df":           None,
    "csv_path":     None,
    "ran":          False,
    "returncode":   None,
}
for _k, _v in _defaults.items():
    if _k not in st.session_state:
        st.session_state[_k] = _v

# ── Status colours (shared between pie and bar charts) ────────────────────────
STATUS_COLORS: dict[str, str] = {
    "Migrated":         "#2ecc71",
    "OwnerlessPending": "#e74c3c",
    "MigrationPending": "#f39c12",
    "NotApplicable":    "#95a5a6",
    "NotStarted":       "#3498db",
    "Unknown":          "#9b59b6",
}

# ── Sidebar ───────────────────────────────────────────────────────────────────
with st.sidebar:
    st.title("⚙️ Configuration")

    # Auto-detect the module manifest relative to this file's location
    _default_psd1 = str(
        Path(__file__).resolve().parent.parent
        / "1.0"
        / "Get-TeamsPrivateChannelComplianceMap.psd1"
    )
    module_path = st.text_input("Module manifest (.psd1)", value=_default_psd1)
    module_ok = os.path.isfile(module_path)
    if module_ok:
        st.success("Module found ✓")
    else:
        st.error("Module manifest not found — update the path above")

    log_dir = st.text_input(
        "Log / CSV output directory",
        value=os.path.join(
            os.environ.get("TEMP", "C:\\Temp"),
            "Get-TeamsPrivateChannelComplianceMap",
        ),
        help="The module writes timestamped log and CSV files here.",
    )

    st.divider()
    st.subheader("Authentication")

    AUTH_METHODS = [
        "Interactive (browser / MFA)",
        "Device Code",
        "PSCredential",
        "Service Principal",
        "Managed Identity",
    ]
    auth_method = st.selectbox("Method", AUTH_METHODS)

    tenant_id = cred_user = cred_pass = app_id = cert_thumb = ""

    if auth_method in ("Interactive (browser / MFA)", "Device Code"):
        tenant_id = st.text_input(
            "Tenant ID or domain (optional)",
            help="e.g. contoso.onmicrosoft.com",
        )

    if auth_method == "PSCredential":
        st.warning(
            "Password is passed to PowerShell in memory only. "
            "Do not use on shared or unattended machines."
        )
        cred_user = st.text_input("Username (UPN)")
        cred_pass = st.text_input("Password", type="password")

    if auth_method == "Service Principal":
        app_id     = st.text_input("Application (client) ID")
        tenant_id  = st.text_input("Tenant ID or domain")
        cert_thumb = st.text_input("Certificate thumbprint")

    st.divider()
    st.subheader("Switches")

    opt_hold_summary   = st.checkbox(
        "-HoldSummary", value=True,
        help="Generate a per-custodian Purview eDiscovery hold checklist",
    )
    opt_medium_details = st.checkbox(
        "-MediumDetails",
        help="Print a consolidated 6-column table after the gap summaries",
    )
    opt_full_details   = st.checkbox(
        "-FullDetails",
        help="Print all record properties as Format-List after the summaries",
    )
    opt_export_csv     = st.checkbox(
        "-ExportToCsv", value=True,
        help="Export results to CSV — required for table and chart tabs",
    )
    opt_stay_connected = st.checkbox(
        "-StayConnected",
        help="Keep the Teams session open after the run",
    )

# ── Helper functions ──────────────────────────────────────────────────────────

def _ps_quote(value: str) -> str:
    """Single-quote and escape a string for safe PowerShell interpolation."""
    return "'" + value.replace("'", "''") + "'"


# Matches all ANSI/VT100 escape sequences (colours, bold, cursor movement, etc.)
_ANSI_RE = re.compile(r'\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')


def _strip_ansi(text: str) -> str:
    """Remove ANSI escape sequences from a string."""
    return _ANSI_RE.sub('', text)


def build_ps_command(
    upns:          list[str],
    module_path:   str,
    log_dir:       str,
    auth_method:   str,
    tenant_id:     str,
    cred_user:     str,
    cred_pass:     str,
    app_id:        str,
    cert_thumb:    str,
    hold_summary:  bool,
    medium_details: bool,
    full_details:  bool,
    export_csv:    bool,
    stay_connected: bool,
) -> str:
    """Build the PowerShell script that imports the module and runs the scan."""
    upn_array = ", ".join(_ps_quote(u) for u in upns)

    params = [
        f"    UserPrincipalName = @({upn_array})",
        f"    LoggingDirectory  = {_ps_quote(log_dir)}",
    ]
    if export_csv:      params.append("    ExportToCsv       = $true")
    if hold_summary:    params.append("    HoldSummary       = $true")
    if medium_details:  params.append("    MediumDetails     = $true")
    if full_details:    params.append("    FullDetails       = $true")
    if stay_connected:  params.append("    StayConnected     = $true")

    if auth_method == "Device Code":
        params.append("    UseDeviceAuthentication = $true")
        if tenant_id:
            params.append(f"    TenantId = {_ps_quote(tenant_id)}")

    elif auth_method == "PSCredential":
        params.append(
            f"    TeamsAdminCredential = ("
            f"New-Object System.Management.Automation.PSCredential("
            f"{_ps_quote(cred_user)}, "
            f"(ConvertTo-SecureString {_ps_quote(cred_pass)} -AsPlainText -Force)))"
        )

    elif auth_method == "Service Principal":
        params.append(f"    ApplicationId         = {_ps_quote(app_id)}")
        params.append(f"    TenantId              = {_ps_quote(tenant_id)}")
        params.append(f"    CertificateThumbprint = {_ps_quote(cert_thumb)}")

    elif auth_method == "Managed Identity":
        params.append("    ManagedIdentity = $true")

    else:  # Interactive (browser / MFA)
        if tenant_id:
            params.append(f"    TenantId = {_ps_quote(tenant_id)}")

    param_block = "\n".join(params)
    # Preamble:
    #   $PSStyle.OutputRendering = 'PlainText'  — disable ANSI colour codes
    #   [Console]::OutputEncoding / $OutputEncoding — ensure UTF-8
    #   $Host.UI.RawUI.BufferSize.Width = 220    — prevent Format-Table wrapping
    preamble = (
        "$PSStyle.OutputRendering = 'PlainText'\n"
        "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8\n"
        "$OutputEncoding = [System.Text.Encoding]::UTF8\n"
        "try { "
        "  $sz = $Host.UI.RawUI.BufferSize; $sz.Width = 220; "
        "  $Host.UI.RawUI.BufferSize = $sz "
        "} catch {}\n"
    )
    return (
        f"{preamble}"
        f"Import-Module {_ps_quote(module_path)} -Force -ErrorAction Stop\n"
        f"$params = @{{\n{param_block}\n}}\n"
        f"Get-TeamsPrivateChannelComplianceMap @params"
    )


def find_latest_csv(log_dir: str) -> str | None:
    """Return the most recently written ComplianceMap CSV in log_dir."""
    files = glob.glob(os.path.join(log_dir, "ComplianceMap_*.csv"))
    return max(files, key=os.path.getmtime) if files else None


def extract_hold_summary(lines: list[str]) -> list[str]:
    """Extract the PURVIEW EDISCOVERY HOLD SUMMARY block from console output."""
    hold_lines: list[str] = []
    in_block = False
    divider_count = 0
    for ln in lines:
        stripped = ln.strip()
        if "PURVIEW EDISCOVERY HOLD SUMMARY" in ln:
            in_block = True
            divider_count = 0
        if in_block:
            hold_lines.append(ln)
            if stripped.startswith("━") or stripped.startswith("─"):
                divider_count += 1
                if divider_count >= 2:   # closing divider = end of block
                    break
    return hold_lines


def bool_col(series: "pd.Series") -> "pd.Series":
    """Normalise an IsPrivateChannel column regardless of True/False/'True'/'False'."""
    return series.astype(str).str.strip().str.lower() == "true"


# ── Main UI ───────────────────────────────────────────────────────────────────
st.title("🔐 Teams Private Channel Compliance Dashboard")
st.caption(
    "MC1134737 — Maps custodian private channel memberships to "
    "Microsoft Purview eDiscovery hold locations"
)

upns_raw = st.text_area(
    "UPNs to investigate",
    placeholder="jdoe@contoso.com\njane@contoso.com\nbob@contoso.com",
    height=120,
    help="One UPN per line, or comma-separated.",
)

run_btn = st.button("▶  Run Compliance Scan", type="primary", width='stretch')

# ── Run the PowerShell module ─────────────────────────────────────────────────
if run_btn:
    upns = [
        u.strip()
        for u in upns_raw.replace(",", "\n").splitlines()
        if u.strip() and "@" in u
    ]

    if not upns:
        st.error("Enter at least one valid UPN (user@domain.com).")
    elif not module_ok:
        st.error(f"Cannot find module manifest: {module_path}")
    else:
        ps_cmd = build_ps_command(
            upns, module_path, log_dir, auth_method, tenant_id,
            cred_user, cred_pass, app_id, cert_thumb,
            opt_hold_summary, opt_medium_details, opt_full_details,
            opt_export_csv, opt_stay_connected,
        )

        with st.expander("PowerShell script (click to expand)", expanded=False):
            display_cmd = ps_cmd
            if cred_pass:
                display_cmd = display_cmd.replace(cred_pass, "***REDACTED***")
            st.code(display_cmd, language="powershell")

        status_msg = st.info(
            "⏳ Connecting to Microsoft Teams — "
            "an authentication prompt may open in a separate window or browser tab…"
        )
        out_expander = st.expander("🖥️ Live PowerShell output (for administrators)", expanded=False)
        out_placeholder = out_expander.empty()
        output_lines: list[str] = []

        try:
            proc = subprocess.Popen(
                ["pwsh", "-NoProfile", "-Command", ps_cmd],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
            )

            for raw_line in proc.stdout:
                line = _strip_ansi(raw_line.rstrip())
                output_lines.append(line)
                out_placeholder.code(
                    "\n".join(output_lines[-60:]),   # rolling last 60 lines
                    language="text",
                )

            proc.wait()
            st.session_state.output_lines = output_lines
            st.session_state.returncode   = proc.returncode
            st.session_state.ran          = True

            if proc.returncode == 0:
                status_msg.success("✅ Scan complete.")
            else:
                status_msg.error(
                    f"❌ PowerShell exited with code {proc.returncode}. "
                    "See the Console Output tab for details."
                )

            csv_path = find_latest_csv(log_dir)
            st.session_state.csv_path = csv_path
            if csv_path:
                st.session_state.df = pd.read_csv(csv_path)
                st.caption(f"Data source: `{csv_path}`")
            else:
                st.session_state.df = None

        except FileNotFoundError:
            st.error(
                "**`pwsh` not found.** Install PowerShell 7.1+: "
                "https://aka.ms/powershell"
            )

# ── Results ─────────────────────────────────────────────────────────────────
if st.session_state.ran:

    # ── Compliance Summary — always visible above the tabs ───────────────────
    st.divider()
    st.subheader("Compliance Summary")

    df_summary = st.session_state.df
    if df_summary is not None and not df_summary.empty:
        private_s   = df_summary[bool_col(df_summary["IsPrivateChannel"])]
        ownerless_s = private_s[private_s["MC1134737_Status"] == "OwnerlessPending"]

        if not ownerless_s.empty:
            st.error(
                f"⚠️  **{len(ownerless_s)} critical gap(s) detected — immediate action required**  \n"
                "These channels were skipped during MC1134737 migration. "
                "Compliance copies remain in **individual member mailboxes** — "
                "not the group mailbox. These locations are **missing** from any "
                "Purview hold built from the custodian UPN alone."
            )
        else:
            st.success("✅  No ownerless channel gaps detected for the scanned custodians.")

        rows = []
        for upn in sorted(df_summary["UserPrincipalName"].unique()):
            udf  = df_summary[df_summary["UserPrincipalName"] == upn]
            priv = udf[bool_col(udf["IsPrivateChannel"])]
            n_ownerless = int((priv["MC1134737_Status"] == "OwnerlessPending").sum())
            n_pending   = int((priv["MC1134737_Status"] == "MigrationPending").sum())
            rows.append({
                "Custodian":        upn,
                "Private Channels": len(priv),
                "Migrated":         int((priv["MC1134737_Status"] == "Migrated").sum()),
                "⚠️ Ownerless":     n_ownerless,
                "Pending":          n_pending,
                "Unknown":          int((priv["MC1134737_Status"] == "Unknown").sum()),
                "Action Required": (
                    "🔴 Assign channel owner(s) — add all member mailboxes to hold"
                    if n_ownerless > 0
                    else (
                        "🟡 Verify migration status before finalising hold"
                        if n_pending > 0
                        else "🟢 Add group mailbox + SharePoint locations to hold"
                        if len(priv) > 0
                        else "ℹ️ No private channels — standard hold applies"
                    )
                ),
            })
        if rows:
            st.dataframe(pd.DataFrame(rows), width="stretch")
    else:
        st.warning(
            "No CSV data available. "
            "Enable **-ExportToCsv** in the sidebar and re-run."
        )

    st.divider()

    # ── Tabs ──────────────────────────────────────────────────────────────────
    tab_charts, tab_table, tab_hold, tab_console = st.tabs([
        "🔍 Gap Analysis",
        "📊 Records Table",
        "🏛️ Hold Summary",
        "🖥️ Raw Log",
    ])

    # ── Raw Log (admin use) ───────────────────────────────────────────────────
    with tab_console:
        with st.expander("🖥️ Raw PowerShell output (for administrators)", expanded=True):
            if st.session_state.output_lines:
                st.code("\n".join(st.session_state.output_lines), language="text")
            else:
                st.info("No console output captured.")

    # ── Records Table ─────────────────────────────────────────────────────────
    with tab_table:
        df = st.session_state.df
        if df is not None and not df.empty:
            c1, c2, c3 = st.columns(3)
            with c1:
                sel_upn = st.multiselect(
                    "Filter by UPN",
                    sorted(df["UserPrincipalName"].unique()),
                )
            with c2:
                sel_status = st.multiselect(
                    "Filter by MC1134737_Status",
                    sorted(df["MC1134737_Status"].unique()),
                )
            with c3:
                sel_team = st.multiselect(
                    "Filter by Team",
                    sorted(df["TeamName"].unique()),
                )

            fdf = df.copy()
            if sel_upn:    fdf = fdf[fdf["UserPrincipalName"].isin(sel_upn)]
            if sel_status: fdf = fdf[fdf["MC1134737_Status"].isin(sel_status)]
            if sel_team:   fdf = fdf[fdf["TeamName"].isin(sel_team)]

            display_cols = [
                c for c in [
                    "UserPrincipalName", "TeamName", "ChannelName",
                    "MC1134737_Status", "MembershipType", "UserRole",
                    "GroupMailbox", "SharePointSiteUrl", "ComplianceTarget",
                ] if c in fdf.columns
            ]
            st.dataframe(fdf[display_cols], width='stretch')
            st.caption(f"{len(fdf)} of {len(df)} records shown")

            st.download_button(
                "⬇️  Download filtered CSV",
                data=fdf.to_csv(index=False),
                file_name="ComplianceMap_filtered.csv",
                mime="text/csv",
            )
        else:
            st.info(
                "No CSV data available. "
                "Ensure **-ExportToCsv** is enabled in the sidebar and re-run."
            )

    # ── Charts ────────────────────────────────────────────────────────────────
    with tab_charts:
        df = st.session_state.df
        if df is not None and not df.empty:
            private = df[bool_col(df["IsPrivateChannel"])]

            if private.empty:
                st.info("No private channel records found in the results.")
            else:
                # KPI row
                k1, k2, k3, k4 = st.columns(4)
                ownerless_count = int(
                    (private["MC1134737_Status"] == "OwnerlessPending").sum()
                )
                k1.metric("Total records",    len(df))
                k2.metric("Private channels", len(private))
                k3.metric("Custodians",       df["UserPrincipalName"].nunique())
                k4.metric("⚠️ Ownerless gaps", ownerless_count)

                st.divider()
                col_l, col_r = st.columns(2)

                with col_l:
                    st.subheader("MC1134737 status breakdown")
                    counts = (
                        private["MC1134737_Status"]
                        .value_counts()
                        .rename_axis("Status")
                        .reset_index(name="Count")
                    )
                    fig_pie = px.pie(
                        counts,
                        names="Status",
                        values="Count",
                        color="Status",
                        color_discrete_map=STATUS_COLORS,
                        hole=0.4,
                    )
                    fig_pie.update_layout(margin=dict(t=20, b=20))
                    st.plotly_chart(fig_pie, width='stretch')

                with col_r:
                    st.subheader("Private channels per custodian")
                    per_upn = (
                        private
                        .groupby(["UserPrincipalName", "MC1134737_Status"])
                        .size()
                        .reset_index(name="Count")
                    )
                    fig_bar = px.bar(
                        per_upn,
                        x="UserPrincipalName",
                        y="Count",
                        color="MC1134737_Status",
                        color_discrete_map=STATUS_COLORS,
                        barmode="stack",
                    )
                    fig_bar.update_layout(
                        xaxis_tickangle=-30,
                        margin=dict(t=20, b=20),
                        legend_title_text="Status",
                        xaxis_title="Custodian",
                    )
                    st.plotly_chart(fig_bar, width='stretch')

                # Critical gap callout
                ownerless_df = private[private["MC1134737_Status"] == "OwnerlessPending"]
                if not ownerless_df.empty:
                    st.error(
                        f"⚠️  **{len(ownerless_df)} critical gap channel(s) — OwnerlessPending**  "
                        "These channels were skipped during migration. Compliance copies remain "
                        "in individual member mailboxes — not the group mailbox.  \n"
                        "Assign an owner via `Add-TeamChannelUser -User <upn> -Role Owner` "
                        "to unblock migration."
                    )
                    oc = [
                        c for c in [
                            "UserPrincipalName", "TeamName", "ChannelName",
                            "ChannelThreadId", "GroupId",
                        ] if c in ownerless_df.columns
                    ]
                    st.dataframe(ownerless_df[oc], width='stretch')
        else:
            st.info("No data available. Run a scan first.")

    # ── Hold Summary ──────────────────────────────────────────────────────────
    with tab_hold:
        hold_lines = extract_hold_summary(st.session_state.output_lines)

        if hold_lines:
            st.code("\n".join(hold_lines), language="text")
        elif opt_hold_summary:
            st.warning(
                "Hold Summary block not found in output. "
                "Check the **Console Output** tab for errors."
            )
        else:
            st.info(
                "Enable **-HoldSummary** in the sidebar and re-run "
                "to generate the Purview hold checklist."
            )

        # Structured per-custodian breakdown from the CSV
        df = st.session_state.df
        if df is not None and not df.empty:
            st.divider()
            st.subheader("Locations per custodian")

            for upn in sorted(df["UserPrincipalName"].unique()):
                udf     = df[df["UserPrincipalName"] == upn]
                private = udf[bool_col(udf["IsPrivateChannel"])]

                tenant       = upn.split("@")[1] if "@" in upn else ""
                tenant_short = tenant.split(".")[0]
                od_upn       = upn.replace("@", "_").replace(".", "_")
                onedrive_url = f"https://{tenant_short}-my.sharepoint.com/personal/{od_upn}"

                with st.expander(f"📋  {upn}", expanded=True):
                    st.markdown("**Always required — add as custodian data sources in Purview:**")
                    st.markdown(f"- Exchange mailbox: `{upn}`")
                    st.markdown(f"- OneDrive: `{onedrive_url}`")

                    if not private.empty:
                        ownerless = private[
                            private["MC1134737_Status"] == "OwnerlessPending"
                        ]
                        if not ownerless.empty:
                            st.markdown(
                                "**⚠️ Critical — Ownerless channels (old compliance model):**"
                            )
                            for _, r in ownerless.iterrows():
                                st.markdown(
                                    f"- `{r['TeamName']}` » `{r['ChannelName']}` — "
                                    "individual member mailboxes  "
                                    "*(assign owner via `Add-TeamChannelUser` to unblock)*"
                                )

                        other      = private[private["MC1134737_Status"] != "OwnerlessPending"]
                        seen_gm    = set()
                        ex_lines   = []
                        sp_lines   = []

                        for _, r in other.iterrows():
                            gm = str(r.get("GroupMailbox", "")).strip()
                            if gm and gm not in seen_gm:
                                seen_gm.add(gm)
                                ex_lines.append(
                                    f"- `{gm}` ({r['TeamName']}) "
                                    f"[{r['MC1134737_Status']}]"
                                )

                        for _, r in private.iterrows():
                            sp = str(r.get("SharePointSiteUrl", "")).strip()
                            if sp and sp.lower() != "nan":
                                sp_lines.append(
                                    f"- `{sp}` ({r['TeamName']} » {r['ChannelName']}) "
                                    f"[{r['MC1134737_Status']}]"
                                )

                        if ex_lines:
                            st.markdown(
                                "**Private channel Exchange locations — "
                                "add as non-custodial data sources:**"
                            )
                            for line in ex_lines:
                                st.markdown(line)

                        if sp_lines:
                            st.markdown(
                                "**Private channel SharePoint locations — "
                                "add as non-custodial data sources:**"
                            )
                            for line in sp_lines:
                                st.markdown(line)

                    std_teams = (
                        udf[~bool_col(udf["IsPrivateChannel"])]["TeamName"].unique()
                        if not udf.empty else []
                    )
                    if len(std_teams) > 0:
                        st.markdown(
                            "**Add manually — parent team SharePoint site "
                            "(standard channel file storage):**  \n"
                            "*Look up each team's SharePoint URL in the "
                            "Teams admin center or via `Get-Team`.*"
                        )
                        for t in sorted(std_teams):
                            st.markdown(f"- {t}")
