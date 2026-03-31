#!/usr/bin/env bash
# ssh-to-putty.sh — Convert ~/.ssh/config to a PuTTY .reg import file
#
# Usage:
#   ./ssh-to-putty.sh [ssh_config] [output.reg]
#
# Defaults:
#   ssh_config  = ~/.ssh/config
#   output.reg  = putty-sessions.reg
#
# Environment:
#   PLINK = path to plink binary (default: C:\.ssh\plink.exe)
#           Used for ProxyJump proxy commands.
#
# Import the result with:
#   regedit /s putty-sessions.reg
#
# Mapped SSH keywords:
#   HostName, User, Port, IdentityFile, ProxyJump
#   ForwardAgent  → AgentFwd
#   LocalForward  → PortForwardings (L entries)
#   RemoteForward → PortForwardings (R entries)
#
# Not mappable to PuTTY per-session settings (silently ignored):
#   StrictHostKeyChecking, UserKnownHostsFile, ControlMaster, ControlPersist,
#   PubkeyAcceptedKeyTypes, LogLevel, IdentitiesOnly, ProxyCommand
#
# Notes:
#   - Wildcard Host blocks (*, ?) are skipped entirely — no inheritance applied.
#   - When the same Host name appears in multiple blocks, first-occurrence wins
#     for each setting, matching OpenSSH behaviour.
#   - ProxyJump chains (a,b,c) use only the first hop.

set -euo pipefail

SSH_CONFIG="${1:-$HOME/.ssh/config}"
OUTPUT="${2:-putty-sessions.reg}"
PLINK="${PLINK:-C:\\.ssh\\plink.exe}"

die() { echo "Error: $*" >&2; exit 1; }
[[ -f "$SSH_CONFIG" ]] || die "SSH config not found: $SSH_CONFIG"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Convert a Unix/Git-Bash path to a Windows path for .reg values.
to_winpath() {
    local p="$1"
    p="${p/#\~/$HOME}"
    if command -v cygpath &>/dev/null; then
        cygpath -w "$p"
    elif [[ "$p" =~ ^/([a-zA-Z])/(.*) ]]; then
        echo "${BASH_REMATCH[1]^^}:\\${BASH_REMATCH[2]//\//\\}"
    else
        echo "$p"
    fi
}

# Escape for use inside a .reg double-quoted string value.
reg_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    echo "$s"
}

# PuTTY URL-encodes session names in registry keys.
reg_session_name() {
    local s="$1" out="" c hex
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9._-]) out+="$c" ;;
            ' ')             out+="%20" ;;
            *)               printf -v hex '%02X' "'$c"; out+="%$hex" ;;
        esac
    done
    echo "$out"
}

# ---------------------------------------------------------------------------
# Parse ~/.ssh/config
# ---------------------------------------------------------------------------

declare -a host_order=()       # ordered list of session names (deduplicated)
declare -A h_seen=()           # tracks which names are already in host_order
declare -A h_hostname=()
declare -A h_user=()
declare -A h_port=()
declare -A h_identityfile=()
declare -A h_proxyjump=()
declare -A h_forwardagent=()
declare -A h_portfwds=()       # combined LocalForward+RemoteForward for each host

# Current block buffer
cur_names=()
cur_hostname="" cur_user="" cur_port="" cur_identityfile=""
cur_proxyjump="" cur_forwardagent="" cur_portfwds=""

flush_block() {
    local name
    for name in "${cur_names[@]+"${cur_names[@]}"}"; do
        # Add to ordered list only once
        if [[ -z "${h_seen[$name]:-}" ]]; then
            host_order+=("$name")
            h_seen["$name"]=1
        fi
        # First occurrence wins for each scalar setting (matches OpenSSH behaviour)
        [[ -n "$cur_hostname"     && -z "${h_hostname[$name]:-}"     ]] && h_hostname["$name"]="$cur_hostname"
        [[ -n "$cur_user"         && -z "${h_user[$name]:-}"         ]] && h_user["$name"]="$cur_user"
        [[ -n "$cur_port"         && -z "${h_port[$name]:-}"         ]] && h_port["$name"]="$cur_port"
        [[ -n "$cur_identityfile" && -z "${h_identityfile[$name]:-}" ]] && h_identityfile["$name"]="$cur_identityfile"
        [[ -n "$cur_proxyjump"    && -z "${h_proxyjump[$name]:-}"    ]] && h_proxyjump["$name"]="$cur_proxyjump"
        [[ -n "$cur_forwardagent" && -z "${h_forwardagent[$name]:-}" ]] && h_forwardagent["$name"]="$cur_forwardagent"
        # Port forwards accumulate across duplicate blocks
        if [[ -n "$cur_portfwds" ]]; then
            if [[ -z "${h_portfwds[$name]:-}" ]]; then
                h_portfwds["$name"]="$cur_portfwds"
            else
                h_portfwds["$name"]+=",$cur_portfwds"
            fi
        fi
    done
    # Always reset — prevents wildcard-block settings leaking into subsequent blocks
    cur_names=()
    cur_hostname="" cur_user="" cur_port="" cur_identityfile=""
    cur_proxyjump="" cur_forwardagent="" cur_portfwds=""
}

# Convert SSH LocalForward/RemoteForward to a PuTTY PortForwardings entry.
# SSH:    LocalForward  [bind:]srcport desthost:destport
# PuTTY:  L[bind:]srcport=desthost:destport
make_fwd() {
    local type="$1" spec="$2"   # type = L or R
    local src dest
    read -r src dest <<< "$spec"
    printf '%s%s=%s' "$type" "$src" "$dest"
}

while IFS= read -r raw || [[ -n "$raw" ]]; do
    # Strip leading whitespace
    line="${raw#"${raw%%[![:space:]]*}"}"
    # Skip blank lines and full-line comments
    [[ -z "$line" || "$line" == '#'* ]] && continue

    # Extract keyword (terminates at first space or =)
    keyword="${line%%[[:space:]=]*}"
    keyword_lc="${keyword,,}"

    # Extract value: drop keyword and any leading spaces/= separators
    rest="${line:${#keyword}}"
    rest="${rest#"${rest%%[![:space:]=]*}"}"   # strip [[:space:]=] prefix
    rest="${rest#"${rest%%[![:space:]]*}"}"    # strip any remaining leading space
    value="$rest"
    # Strip trailing inline comment and whitespace
    value="${value%% #*}"
    value="${value%"${value##*[![:space:]]}"}"

    case "$keyword_lc" in
        host)
            flush_block
            local_name=""
            for local_name in $value; do
                [[ "$local_name" == *'*'* || "$local_name" == *'?'* || "$local_name" == '!'* ]] && continue
                cur_names+=("$local_name")
            done
            ;;
        hostname)      cur_hostname="$value" ;;
        user)          cur_user="$value" ;;
        port)          cur_port="$value" ;;
        identityfile)  [[ -z "$cur_identityfile" ]] && cur_identityfile="$value" ;;
        proxyjump)     [[ -z "$cur_proxyjump"    ]] && cur_proxyjump="$value" ;;
        forwardagent)  [[ -z "$cur_forwardagent" ]] && cur_forwardagent="${value,,}" ;;
        localforward)
            fwd="$(make_fwd L "$value")"
            cur_portfwds="${cur_portfwds:+$cur_portfwds,}$fwd"
            ;;
        remoteforward)
            fwd="$(make_fwd R "$value")"
            cur_portfwds="${cur_portfwds:+$cur_portfwds,}$fwd"
            ;;
    esac
done < "$SSH_CONFIG"
flush_block   # flush the final block

# ---------------------------------------------------------------------------
# Emit .reg file  (regedit requires Windows CRLF line endings)
# ---------------------------------------------------------------------------

{
printf 'Windows Registry Editor Version 5.00\r\n'

for host in "${host_order[@]}"; do
    hostname="${h_hostname[$host]:-$host}"
    user="${h_user[$host]:-}"
    port="${h_port[$host]:-22}"
    keyfile="${h_identityfile[$host]:-}"
    proxyjump="${h_proxyjump[$host]:-}"
    forwardagent="${h_forwardagent[$host]:-}"
    portfwds="${h_portfwds[$host]:-}"

    session_key="$(reg_session_name "$host")"
    port_hex="$(printf '%08x' "$port")"

    printf '\r\n'
    printf '[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\%s]\r\n' "$session_key"
    printf '"HostName"="%s"\r\n'       "$(reg_escape "$hostname")"
    printf '"PortNumber"=dword:%s\r\n' "$port_hex"
    printf '"Protocol"="ssh"\r\n'

    [[ -n "$user" ]] &&
        printf '"UserName"="%s"\r\n' "$(reg_escape "$user")"

    # IdentityFile none means "no key file" in SSH config — don't set PublicKeyFile
    if [[ -n "$keyfile" && "$keyfile" != "none" ]]; then
        winpath="$(to_winpath "$keyfile")"
        printf '"PublicKeyFile"="%s"\r\n' "$(reg_escape "$winpath")"
    fi

    # ForwardAgent yes/true → AgentFwd
    if [[ "$forwardagent" == "yes" || "$forwardagent" == "true" ]]; then
        printf '"AgentFwd"=dword:00000001\r\n'
    fi

    # LocalForward / RemoteForward → PortForwardings
    [[ -n "$portfwds" ]] &&
        printf '"PortForwardings"="%s"\r\n' "$(reg_escape "$portfwds")"

    # ProxyJump → plink local proxy command
    if [[ -n "$proxyjump" ]]; then
        # Take only the first hop (chains: jump1,jump2,...)
        jump="${proxyjump%%,*}"
        pj_user="" pj_host="$jump" pj_port=""

        [[ "$jump" == *'@'* ]] && { pj_user="${jump%%@*}"; pj_host="${jump#*@}"; }
        [[ "$pj_host" == *':'* ]] && { pj_port="${pj_host##*:}"; pj_host="${pj_host%:*}"; }

        # Resolve jump host alias → real hostname/user/port via parsed config
        actual_host="${h_hostname[$pj_host]:-$pj_host}"
        [[ -z "$pj_user" ]] && pj_user="${h_user[$pj_host]:-}"
        [[ -z "$pj_port" ]] && pj_port="${h_port[$pj_host]:-22}"

        cmd="$(reg_escape "$PLINK") -batch"
        [[ -n "$pj_user" ]]      && cmd+=" -l $(reg_escape "$pj_user")"
        [[ "$pj_port" != "22" ]] && cmd+=" -P $pj_port"
        cmd+=" $(reg_escape "$actual_host") -nc %host:%port"

        printf '"ProxyMethod"=dword:00000005\r\n'     # 5 = Local (run a command)
        printf '"ProxyTelnetCommand"="%s"\r\n' "$cmd"
    fi
done

} > "$OUTPUT"

count=$(grep -c '^\[HKEY_' "$OUTPUT" || true)
echo "Wrote $count session(s) to $OUTPUT"
echo "Import: regedit /s \"$OUTPUT\""
