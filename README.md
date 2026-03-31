# ssh-to-putty

Converts `~/.ssh/config` to a PuTTY `.reg` import file, creating one saved session per `Host` block.

## Dependencies

- **Git Bash** (or any Bash 4+ environment on Windows, e.g. Cygwin, MSYS2)
- **PuTTY** installed (sessions are written to `HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions`)
- **plink.exe** — only required if any hosts use `ProxyJump`

## Usage

```bash
./ssh-to-putty.sh [ssh_config] [output.reg]
```

| Argument | Default |
|---|---|
| `ssh_config` | `~/.ssh/config` |
| `output.reg` | `putty-sessions.reg` |

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `PLINK` | `C:\.ssh\plink.exe` | Path to `plink.exe`, used for `ProxyJump` proxy commands |

### Examples

```bash
# Use defaults
./ssh-to-putty.sh

# Specify a custom config and output file
./ssh-to-putty.sh ~/work/.ssh/config work-sessions.reg

# Custom plink location
PLINK='C:\.ssh\plink.exe' ./ssh-to-putty.sh
```

## Importing into PuTTY

After running the script, import the generated `.reg` file with:

```bash
regedit /s putty-sessions.reg
```

Or double-click the `.reg` file in Explorer and confirm the prompt.

## SSH config keyword mapping

| SSH keyword | PuTTY setting |
|---|---|
| `HostName` | `HostName` |
| `User` | `UserName` |
| `Port` | `PortNumber` |
| `IdentityFile` | `PublicKeyFile` |
| `ProxyJump` | `ProxyMethod` + `ProxyTelnetCommand` (via plink) |
| `ForwardAgent yes` | `AgentFwd` |
| `LocalForward` | `PortForwardings` (L entries) |
| `RemoteForward` | `PortForwardings` (R entries) |

### Unsupported keywords (silently ignored)

`StrictHostKeyChecking`, `UserKnownHostsFile`, `ControlMaster`, `ControlPersist`, `PubkeyAcceptedKeyTypes`, `LogLevel`, `IdentitiesOnly`, `ProxyCommand`

## Behaviour notes

- Wildcard `Host` blocks (`*`, `?`) are skipped entirely — no inheritance is applied.
- When the same host name appears in multiple blocks, first-occurrence wins for each setting, matching OpenSSH behaviour.
- `ProxyJump` chains (`jump1,jump2,...`) use only the first hop.
- Jump host aliases are resolved through the parsed config to their real hostname, user, and port.
