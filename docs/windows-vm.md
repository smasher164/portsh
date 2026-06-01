# Real Windows testing via a UTM Win11-ARM VM

Wine can't run on Apple Silicon, and it's only an approximation anyway. For a
*legitimate* `cmd.exe`, run a Windows 11 ARM VM (Apple hypervisor, so ARM-on-ARM
is fast and `cmd.exe` is native). The harness (`tests/run.sh`) then runs the cmd
leg over SSH when `PORTSH_WIN_SSH=user@host` is set.

Two ways to host the VM:

- **UTM** (GUI, easiest) — a friendly front-end over QEMU that bundles the
  UEFI firmware, TPM, and virtio drivers Windows 11 needs. Ships `utmctl`
  (`/Applications/UTM.app/Contents/MacOS/utmctl`) for automation:
  `utmctl start <vm>`, `utmctl ip-address <vm>`, `utmctl exec ...`. Not
  nix-packageable (it's a Mac cask), so it's an out-of-band install.
- **Raw `qemu`** (in the flake, fully reproducible) — `nix develop` puts
  `qemu` on PATH. You drive the install yourself and supply ARM UEFI firmware
  (`edk2-aarch64`) plus a software TPM (`swtpm`, Linux) for the Win11 TPM 2.0
  check. More setup, but no GUI dependency — this is the path for CI/headless.

The steps below use UTM; the SSH wiring (§3–5) is identical either way.

## 1. Install UTM + CrystalFetch

CrystalFetch (by the UTM team) downloads official Windows 11 ARM64 ISOs.

```sh
brew install --cask utm crystalfetch
```

(May prompt for your password to move the apps into /Applications. If it hangs
in a non-interactive shell, run it yourself with `! brew install --cask utm crystalfetch`.)

## 2. Get the ISO and create the VM

1. Open **CrystalFetch** → pick Windows 11 / ARM64 / your language → Download.
2. In **UTM**: Create a New VM → **Virtualize** → Windows → attach the ISO,
   give it ~4 cores / 8 GB RAM / 64 GB disk → install Windows normally.
   (Runs unactivated fine for testing — just a watermark.)

## 3. Enable OpenSSH Server in the guest

Win11 ships OpenSSH as an optional feature. In an **Administrator PowerShell**
inside the VM:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic
Start-Service sshd
# Make the default SSH shell cmd.exe (so `cmd /c ...` from the harness is clean):
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell `
  -Value "C:\Windows\System32\cmd.exe" -PropertyType String -Force
# Firewall (usually auto-added, but to be sure):
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True `
  -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```

Find the VM's IP (`ipconfig` in the guest). With UTM "Shared Network" the host
can reach it directly.

## 4. (Recommended) key-based auth from the Mac

```sh
ssh-copy-id <winuser>@<vm-ip>        # or paste your ~/.ssh/id_*.pub into the guest
ssh <winuser>@<vm-ip> "cmd /c ver"  # smoke test -> should print the Windows version
```

## 5. Run the harness against the VM

```sh
export PORTSH_WIN_SSH=<winuser>@<vm-ip>
sh tests/run.sh
```

The cmd leg now `scp`s each fixture into the guest and runs it under real
`cmd.exe`, normalises CRLF, and diffs against `NAME.cmd.expected`. The header
prints `cmd mode : ssh (<winuser>@<vm-ip>)` so you know it's live.

> Snapshot the VM once it's set up — reverting is faster than reinstalling, and
> keeps the batch environment pristine between test runs.

## Relationship to CI

This local VM is the high-fidelity *dev loop*. CI (`.github/workflows/test.yml`)
still runs the cmd leg on a GitHub `windows-latest` runner as the shared trust
anchor — keep both; they catch different drift.
