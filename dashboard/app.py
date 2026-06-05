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
import json
import os
import re
import subprocess
import tempfile
import time
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
    "error_lines":  [],
    "df":           None,
    "csv_path":     None,
    "ran":          False,
    "returncode":   None,
    "submitted_upns": [],
}
for _k, _v in _defaults.items():
    if _k not in st.session_state:
        st.session_state[_k] = _v

# ── Persistent pwsh sentinels ───────────────────────────────────────────────
_SENTINEL     = "###GTPCCM_DONE###"
_SENTINEL_ERR = "###GTPCCM_ERR###"

# ── Settings persistence ─────────────────────────────────────────────────────
# Settings are saved to a JSON file next to app.py so they survive restarts.

_SETTINGS_FILE = Path(__file__).resolve().parent / "dashboard_settings.json"

_default_psd1_path = str(
    Path(__file__).resolve().parent.parent
    / "1.0"
    / "Get-TeamsPrivateChannelComplianceMap.psd1"
)
_default_log_dir = os.path.join(
    os.environ.get("TEMP", "C:\\Temp"),
    "Get-TeamsPrivateChannelComplianceMap",
)

_SETTINGS_DEFAULTS: dict = {
    "module_path":       _default_psd1_path,
    "log_dir":           _default_log_dir,
    "auth_method":       "Interactive (browser / MFA)",
    "tenant_id":         "",
    "cred_user":         "",
    "app_id":            "",
    "cert_thumb":        "",
    "opt_hold_summary":   True,
    "opt_resolve_sp":     False,
    "opt_medium_details": False,
    "opt_full_details":   False,
    "opt_stay_connected": False,
}


def _load_settings() -> dict:
    """Load persisted settings, falling back to defaults for missing keys."""
    settings = dict(_SETTINGS_DEFAULTS)
    if _SETTINGS_FILE.exists():
        try:
            saved = json.loads(_SETTINGS_FILE.read_text(encoding="utf-8"))
            for k, v in saved.items():
                if k in settings:
                    settings[k] = v
        except Exception:
            pass  # corrupt file — use defaults
    return settings


def _save_settings(s: dict) -> None:
    """Persist settings to JSON, excluding sensitive values."""
    safe = {k: v for k, v in s.items() if k not in ("cred_pass",)}
    try:
        _SETTINGS_FILE.write_text(json.dumps(safe, indent=2), encoding="utf-8")
    except Exception:
        pass


# Load once per session (not on every Streamlit re-run)
if "_settings" not in st.session_state:
    st.session_state["_settings"] = _load_settings()

_s = st.session_state["_settings"]

# ── Persistent process state defaults ───────────────────────────────────
for _k, _v in {"ps_proc": None, "ps_session_active": False}.items():
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
# ── Helper functions ──────────────────────────────────────────────────────────
def _ps_proc_alive() -> bool:
    """Return True if the persistent pwsh process is running."""
    proc = st.session_state.get("ps_proc")
    return proc is not None and proc.poll() is None


def _get_persistent_proc():
    """Return the existing persistent pwsh process, or spawn a new one."""
    if _ps_proc_alive():
        return st.session_state["ps_proc"]
    proc = subprocess.Popen(
        ["pwsh", "-NoProfile", "-NoExit"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
    )
    st.session_state["ps_proc"] = proc
    st.session_state["ps_session_active"] = False
    return proc


def _kill_persistent_proc() -> None:
    """Terminate the persistent pwsh process if running."""
    proc = st.session_state.get("ps_proc")
    if proc is not None:
        try:
            proc.terminate()
        except Exception:
            pass
    st.session_state["ps_proc"] = None
    st.session_state["ps_session_active"] = False

def _ps_quote(value: str) -> str:
    """Single-quote and escape a string for safe PowerShell interpolation."""
    return "'" + value.replace("'", "''") + "'"


# Matches all ANSI/VT100 escape sequences (colours, bold, cursor movement, etc.)
_ANSI_RE = re.compile(r'\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')


def _strip_ansi(text: str) -> str:
    """Remove ANSI escape sequences from a string."""
    return _ANSI_RE.sub('', text)


def build_ps_command(
    upns:               list[str],
    module_path:        str,
    log_dir:            str,
    auth_method:        str,
    tenant_id:          str,
    cred_user:          str,
    cred_pass:          str,
    app_id:             str,
    cert_thumb:         str,
    hold_summary:       bool,
    medium_details:     bool,
    full_details:       bool,
    stay_connected:     bool,
    resolve_sharepoint: bool,
    force_stay_connected: bool = False,
) -> str:
    """Build the PowerShell command block that runs the scan."""
    upn_array = ", ".join(_ps_quote(u) for u in upns)

    params = [
        f"    UserPrincipalName = @({upn_array})",
        f"    LoggingDirectory  = {_ps_quote(log_dir)}",
    ]
    if hold_summary:                        params.append("    HoldSummary            = $true")
    if resolve_sharepoint:                  params.append("    ResolveSharePointUrls  = $true")
    if medium_details:                      params.append("    MediumDetails          = $true")
    if full_details:                        params.append("    FullDetails            = $true")
    if stay_connected or force_stay_connected: params.append("    StayConnected          = $true")

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
    preamble = (
        "$PSStyle.OutputRendering = 'PlainText'\n"
        "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8\n"
        "$OutputEncoding = [System.Text.Encoding]::UTF8\n"
        "try { "
        "  $sz = $Host.UI.RawUI.BufferSize; $sz.Width = 220; "
        "  $Host.UI.RawUI.BufferSize = $sz "
        "} catch {}\n"
    )
    # Wrap in try/catch so a persistent process stays alive on error.
    # The catch block avoids string interpolation of the error message to
    # prevent quote-escaping issues; instead it writes the sentinel then
    # the message on a second line which the dashboard reads as error context.
    return (
        f"{preamble}"
        f"try {{\n"
        f"  Import-Module {_ps_quote(module_path)} -Force -ErrorAction Stop\n"
        f"  $params = @{{\n{param_block}\n  }}\n"
        f"  Get-TeamsPrivateChannelComplianceMap @params\n"
        f"}} catch {{\n"
        f"  $errMsg = $_.Exception.Message -replace \"`n\",\" \"\n"
        f"  Write-Host \"{_SENTINEL_ERR} $errMsg\"\n"
        f"}}"
    )


def find_latest_csv(log_dir: str) -> str | None:
    """Return the most recently written ComplianceMap CSV in log_dir."""
    files = glob.glob(os.path.join(log_dir, "ComplianceMap_*.csv"))
    return max(files, key=os.path.getmtime) if files else None


def find_latest_log(log_dir: str) -> str | None:
    """Return the most recently written Logging_*.txt in log_dir."""
    files = glob.glob(os.path.join(log_dir, "Logging_*.txt"))
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


with st.sidebar:
    st.title("⚙️ Configuration")

    module_path = st.text_input(
        "Module manifest (.psd1)",
        value=_s["module_path"],
    )
    module_ok = os.path.isfile(module_path)
    if module_ok:
        st.success("Module found ✓")
    else:
        st.error("Module manifest not found — update the path above")

    log_dir = st.text_input(
        "Log / CSV output directory",
        value=_s["log_dir"],
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
    _auth_idx = AUTH_METHODS.index(_s["auth_method"]) if _s["auth_method"] in AUTH_METHODS else 0
    auth_method = st.selectbox("Method", AUTH_METHODS, index=_auth_idx)

    tenant_id = cred_user = cred_pass = app_id = cert_thumb = ""

    if auth_method in ("Interactive (browser / MFA)", "Device Code"):
        tenant_id = st.text_input(
            "Tenant ID or domain (optional)",
            value=_s["tenant_id"],
            help="e.g. contoso.onmicrosoft.com",
        )

    if auth_method == "PSCredential":
        st.warning(
            "Password is passed to PowerShell in memory only. "
            "Do not use on shared or unattended machines."
        )
        cred_user = st.text_input("Username (UPN)", value=_s["cred_user"])
        cred_pass = st.text_input("Password", type="password")

    if auth_method == "Service Principal":
        app_id     = st.text_input("Application (client) ID", value=_s["app_id"])
        tenant_id  = st.text_input("Tenant ID or domain", value=_s["tenant_id"])
        cert_thumb = st.text_input("Certificate thumbprint", value=_s["cert_thumb"])

    st.divider()
    st.subheader("Switches")

    opt_hold_summary   = st.checkbox(
        "-HoldSummary", value=_s["opt_hold_summary"],
        help="Generate a per-custodian Purview eDiscovery hold checklist",
    )
    opt_resolve_sp     = st.checkbox(
        "-ResolveSharePointUrls", value=_s["opt_resolve_sp"],
        help="Query Microsoft Graph (Sites.Read.All) for authoritative parent team SharePoint URLs. "
             "Requires Microsoft.Graph.Authentication module and Sites.Read.All permission. "
             "Falls back to constructed URL if the Graph call fails. "
             "Not supported with PSCredential auth.",
    )
    opt_medium_details = st.checkbox(
        "-MediumDetails", value=_s["opt_medium_details"],
        help="Print a consolidated 6-column table after the gap summaries",
    )
    opt_full_details   = st.checkbox(
        "-FullDetails", value=_s["opt_full_details"],
        help="Print all record properties as Format-List after the summaries",
    )
    opt_stay_connected = st.checkbox(
        "-StayConnected", value=_s["opt_stay_connected"],
        help="Keep the Teams session open after the run",
    )
    # Persist any changes back to disk immediately
    _current = {
        "module_path":       module_path,
        "log_dir":           log_dir,
        "auth_method":       auth_method,
        "tenant_id":         tenant_id,
        "cred_user":         cred_user,
        "app_id":            app_id,
        "cert_thumb":        cert_thumb,
        "opt_hold_summary":   opt_hold_summary,
        "opt_resolve_sp":     opt_resolve_sp,
        "opt_medium_details": opt_medium_details,
        "opt_full_details":   opt_full_details,
        "opt_stay_connected": opt_stay_connected,
    }
    if _current != _s:
        st.session_state["_settings"] = _current
        _save_settings(_current)

    # ── Session status ────────────────────────────────────────────────────
    st.divider()
    st.subheader("Session")

    if _ps_proc_alive():
        if st.session_state.get("ps_session_active"):
            st.success("🟢 Teams session active — sign-in skipped on next scan")
        else:
            st.info("🔵 PowerShell process running")

        col_dc, col_kill = st.columns(2)

        if col_dc.button("Disconnect Teams", width="stretch"):
            proc = st.session_state.get("ps_proc")
            if proc and proc.poll() is None:
                try:
                    proc.stdin.write(
                        f'Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue; '
                        f'Write-Host "{_SENTINEL}"\n'
                    )
                    proc.stdin.flush()
                    # drain until sentinel or 5 s timeout
                    deadline = time.time() + 5
                    while time.time() < deadline:
                        ln = proc.stdout.readline()
                        if not ln or _SENTINEL in ln:
                            break
                except Exception:
                    pass
            st.session_state["ps_session_active"] = False
            st.rerun()

        if col_kill.button("Kill session", width="stretch"):
            _kill_persistent_proc()
            st.rerun()
    else:
        st.caption("⚫ No active PowerShell session — will start on next scan")

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
            opt_stay_connected, opt_resolve_sp,
            force_stay_connected=True,  # always keep session alive in persistent proc
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
        try:
            proc = _get_persistent_proc()

            # Write the full multi-line command to a temp .ps1 file.
            # Sending multi-line scripts directly to a persistent -NoExit process
            # causes PowerShell's interactive parser to emit '>>' continuation
            # prompts into stdout, which corrupts sentinel detection.
            # Dot-sourcing a file sends a single line and avoids the issue entirely.
            tmp_ps1 = tempfile.NamedTemporaryFile(
                mode="w", suffix=".ps1", delete=False, encoding="utf-8"
            )
            tmp_ps1.write(ps_cmd)
            tmp_ps1.close()
            tmp_path = tmp_ps1.name.replace("\\", "/")  # forward slashes work in PS

            single_line = (
                f'. "{tmp_path}"; '
                f'Write-Host "{_SENTINEL}"\n'
            )

            try:
                proc.stdin.write(single_line)
                proc.stdin.flush()
            except (BrokenPipeError, OSError):
                # Process died unexpectedly — spawn fresh and retry
                _kill_persistent_proc()
                proc = _get_persistent_proc()
                proc.stdin.write(single_line)
                proc.stdin.flush()

            error_detected = False
            output_lines: list[str] = []
            error_lines:  list[str] = []

            for raw_line in proc.stdout:
                line = _strip_ansi(raw_line.rstrip())
                if _SENTINEL in line:
                    break
                if _SENTINEL_ERR in line:
                    error_detected = True
                    err_msg = line.replace(_SENTINEL_ERR, "").strip()
                    error_lines.append(f"[FATAL] {err_msg}")
                    break
                # Route WARNING / ERROR lines to error_lines as well as output
                lup = line.upper()
                if any(lup.startswith(p) for p in ("ERROR", "WARN:", "[ERROR", "[WARN")):
                    error_lines.append(line)
                output_lines.append(line)
                # output is shown in the Raw Log tab after scan completes

            st.session_state.output_lines  = output_lines
            st.session_state.error_lines   = error_lines
            st.session_state.returncode    = 1 if error_detected else 0
            st.session_state.ran           = True
            st.session_state.submitted_upns = upns

            # Clean up temp script file
            try:
                os.unlink(tmp_ps1.name)
            except Exception:
                pass

            if not error_detected:
                if error_lines:
                    status_msg.warning("⚠️ Scan complete with warnings. Check the Error Log tab.")
                else:
                    status_msg.success("✅ Scan complete. Teams session remains active for the next scan.")
                st.session_state["ps_session_active"] = True
            else:
                status_msg.error(
                    "❌ A fatal error occurred during the scan. "
                    "See the Error Log tab for details."
                )
                st.session_state["ps_session_active"] = False

            csv_path = find_latest_csv(log_dir)
            st.session_state.csv_path = csv_path
            if csv_path:
                st.session_state.df = pd.read_csv(csv_path)
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
    submitted  = st.session_state.get("submitted_upns", [])

    # Build the full set of UPNs to show: submitted + any extra in the CSV
    csv_upns = (
        list(df_summary["UserPrincipalName"].unique())
        if df_summary is not None and not df_summary.empty
        else []
    )
    all_upns = sorted(
        set(u.lower() for u in submitted) | set(u.lower() for u in csv_upns),
        key=lambda u: u
    )
    # Normalise: prefer the casing from the CSV, fall back to submitted casing
    csv_upn_map   = {u.lower(): u for u in csv_upns}
    sub_upn_map   = {u.lower(): u for u in submitted}
    display_upns  = [csv_upn_map.get(u) or sub_upn_map.get(u) or u for u in all_upns]

    # Check for UPNs that returned no data at all
    missing_upns = [u for u in display_upns if u.lower() not in csv_upn_map]
    if missing_upns:
        st.warning(
            f"⚠️  **{len(missing_upns)} UPN(s) returned no results** — "
            "they may not belong to any Teams or `Get-Team` returned nothing for them.  \n"
            + ", ".join(f"`{u}`" for u in missing_upns)
        )

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
        for upn in display_upns:
            if upn.lower() not in csv_upn_map:
                # UPN was submitted but has no CSV records
                rows.append({
                    "Custodian":        upn,
                    "Private Channels": 0,
                    "Migrated":         0,
                    "⚠️ Ownerless":     0,
                    "Pending":          0,
                    "Unknown":          0,
                    "Action Required":  "⚫ No Teams data returned — check log for details",
                })
                continue
            udf  = df_summary[df_summary["UserPrincipalName"].str.lower() == upn.lower()]
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
        if not missing_upns:
            st.warning("No CSV data found for any submitted UPN.")

    st.divider()

    # ── Tabs ──────────────────────────────────────────────────────────────────
    tab_charts, tab_table, tab_hold, tab_console, tab_errors = st.tabs([
        "🔍 Gap Analysis",
        "📊 Records Table",
        "🏛️ Hold Summary",
        "🖥️ Raw Log",
        "🚨 Error Log",
    ])

    # ── Raw Log (admin use) ───────────────────────────────────────────────────
    with tab_console:
        log_path = find_latest_log(log_dir)
        if log_path:
            try:
                log_text = open(log_path, encoding="utf-8", errors="replace").read()
            except Exception as exc:
                log_text = None
                st.warning(f"Could not read log file: {exc}")

            if log_text is not None:
                st.download_button(
                    "⬇️  Download log file",
                    data=log_text,
                    file_name=os.path.basename(log_path),
                    mime="text/plain",
                )
                with st.expander(f"📄 Log file: `{os.path.basename(log_path)}`", expanded=True):
                    st.code(log_text, language="text")
        else:
            st.info("No log file found yet — run a scan first.")

    # ── Error Log ───────────────────────────────────────────────────────────
    with tab_errors:
        error_lines = st.session_state.get("error_lines", [])
        if error_lines:
            st.error(f"⚠️  {len(error_lines)} error/warning line(s) captured")
            st.code("\n".join(error_lines), language="text")
            st.download_button(
                "⬇️  Download error log",
                data="\n".join(error_lines),
                file_name="error_log.txt",
                mime="text/plain",
            )
        else:
            st.success("✅  No errors or warnings captured in the last scan.")
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
                "No CSV data available. Run a scan first."
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

                    std_records = udf[~bool_col(udf["IsPrivateChannel"])]
                    if not std_records.empty:
                        # Standard/Shared channel group mailboxes — deduplicated per team
                        seen_std_gm  = set()
                        std_gm_lines = []
                        for _, r in std_records.iterrows():
                            gm = str(r.get("GroupMailbox", "")).strip()
                            if gm and gm not in seen_std_gm:
                                seen_std_gm.add(gm)
                                std_gm_lines.append(f"- `{gm}` ({r['TeamName']})")

                        if std_gm_lines:
                            st.markdown(
                                "**Standard/Shared channel Exchange locations — "
                                "add as non-custodial data sources:**  \n"
                                "*Captures all standard and shared channel messages "
                                "via the TeamsMessagesData substrate folder.*"
                            )
                            for line in std_gm_lines:
                                st.markdown(line)

                        std_teams = sorted(std_records["TeamName"].unique())
                        if std_teams:
                            # Use ParentTeamSharePointUrl from the CSV if available
                            # (populated by the ps1 — Graph-resolved or Constructed).
                            # Fall back to constructing from GroupMailbox MailNickName.
                            has_sp_col = "ParentTeamSharePointUrl" in std_records.columns
                            all_graph = (
                                has_sp_col and
                                std_records["ParentTeamSharePointUrl"].notna().all() and
                                not (std_records["ParentTeamSharePointUrl"].astype(str).str.contains("sharepoint.com/sites/", na=False) == False).any()
                            )
                            label_suffix = "`[Graph-resolved]`" if (has_sp_col and all_graph) else "`[Constructed]`"
                            st.markdown(
                                "**Parent team SharePoint — file storage "
                                "(add as non-custodial data sources):**  \n"
                                f"*{label_suffix.strip('`')} — verify `[Constructed]` URLs if the site was manually renamed.*"
                            )
                            seen_sp = set()
                            for _, r in std_records.iterrows():
                                tname = r["TeamName"]
                                if tname in seen_sp:
                                    continue
                                seen_sp.add(tname)

                                sp_url = None
                                lbl    = "[Constructed]"

                                if has_sp_col:
                                    v = str(r.get("ParentTeamSharePointUrl", "")).strip()
                                    if v and v.lower() not in ("", "nan", "none"):
                                        sp_url = v
                                        # Label is Graph-resolved if it differs from the constructed form
                                        gm = str(r.get("GroupMailbox", "")).strip()
                                        if "@" in gm:
                                            mail_nick  = gm.split("@")[0]
                                            tenant_dom = gm.split("@")[1]
                                            sp_tenant  = tenant_dom.split(".")[0]
                                            constructed = f"https://{sp_tenant}.sharepoint.com/sites/{mail_nick}"
                                            lbl = "[Graph-resolved]" if sp_url.rstrip("/") != constructed.rstrip("/") else "[Constructed]"

                                if not sp_url:
                                    gm = str(r.get("GroupMailbox", "")).strip()
                                    if "@" in gm:
                                        mail_nick  = gm.split("@")[0]
                                        tenant_dom = gm.split("@")[1]
                                        sp_tenant  = tenant_dom.split(".")[0]
                                        sp_url = f"https://{sp_tenant}.sharepoint.com/sites/{mail_nick}"
                                        lbl    = "[Constructed]"

                                if sp_url:
                                    st.markdown(f"- `{sp_url}` ({tname}) `{lbl}`")
                                else:
                                    st.markdown(f"- {tname} *(URL not available — look up in Teams admin center)*")
