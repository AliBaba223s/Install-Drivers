# Install-Drivers.ps1

One PowerShell script that installs **every driver for a laptop in one go**: silently, in the right order, and with **only one administrator prompt at the very start**. After you click **Yes** once, you can walk away.

---

## ⚠️ Before you start: you need ONE big folder with ALL the drivers

**This is required.** The script does not go looking for drivers on its own. It installs whatever you give it, so you first need **one big folder (or one big `.zip` / `.cab` file) that holds all the drivers and downloads for that exact laptop model.**

The one exception is `downloads.txt` (see below), which lets the script fetch files from links you give it. Even then, everything ends up in one place before anything is installed.

### How to build the folder

1. **Find the exact model.** Look on the sticker under the laptop, or run this in PowerShell: `Get-CimInstance Win32_ComputerSystemProduct | Select-Object Vendor, Name, IdentifyingNumber`. The last value is the **serial number / service tag**, which you'll need next.
2. **Go to the manufacturer's support site** and enter that serial number or service tag:
   - Dell: dell.com/support (service tag)
   - HP: support.hp.com (serial number)
   - Lenovo: pcsupport.lenovo.com (serial number, "S/N")
   - ASUS, Acer, MSI and others: their support pages, searched by model
3. **Pick the right Windows version** (Windows 10 or 11, 64-bit).
4. **Download every driver** into the same folder: chipset, Intel Management Engine / Serial IO, storage (RST/VMD), graphics, audio, Wi-Fi, Bluetooth, Ethernet, touchpad, card reader, camera and so on.
   - **Shortcut:** most business laptops have a single **driver pack** with everything in one file. Examples are Dell *Family Driver Packs* (`.cab`), *HP Driver Packs* and *Lenovo SCCM driver packs*. Drop that one file in the folder and you're done.
   - Single drivers from the **Microsoft Update Catalog** (`.cab`) work too.
5. **Name the folder `Drivers`** and put it **next to the script**, for example on a USB stick:

```
USB stick
├── Install-Drivers.ps1
├── README.md
└── Drivers\                                   <- the ONE big folder
    ├── Intel-Chipset-Device-Software_XXXX.exe
    ├── Realtek-High-Definition-Audio_XXXX.exe
    ├── sp145678.exe                           (HP SoftPaq)
    ├── n2xuj33w.exe                           (Lenovo)
    ├── WiFi-and-Bluetooth.zip
    ├── Latitude-5420-DriverPack.cab           (a whole driver pack works too)
    ├── Graphics\
    │   └── 551.86-notebook-win10-win11-64bit.exe
    ├── _NotNow\                               (anything starting with _ is ignored)
    ├── switches.txt                           (optional, see below)
    └── downloads.txt                          (optional, see below)
```

You can also keep it as **one `.zip`** (`Drivers.zip` next to the script), or put it anywhere and point the script at it with `-DriverPath`.

### Rules for the folder

- **One laptop model per folder.** Drivers for a different model go in a different folder.
- **Only files from the manufacturer** (or Intel / NVIDIA / AMD / Microsoft). The script runs everything in the folder **as administrator**.
- Sub-folders are fine. Anything whose name starts with `_` or `.` is ignored, which is handy for parking files.
- BIOS and firmware updates are **skipped unless you ask for them** (see below).

### What file types it understands

| File | What the script does |
|---|---|
| `.exe` | Works out the silent switches (Dell, HP, NVIDIA, Intel, Realtek, Inno Setup, NSIS, InstallShield, WiX, Advanced Installer...) and runs it |
| `.msi` | `msiexec /i ... /qn /norestart` |
| `.msu` | `wusa ... /quiet /norestart` |
| `.zip`, `.cab` | Unpacks it, then installs what's inside |
| `.inf` (loose driver files) | Adds them with `pnputil /add-driver ... /install` |
| Unpacked installer folder (`setup.exe` plus its files) | Runs only that `setup.exe` |

`.7z` and `.rar` are not supported. Unpack them first.

---

## How to run it

**Easiest:** right-click `Install-Drivers.ps1` and choose **Run with PowerShell**. On Windows 11, click **Show more options** first.

**Or from a PowerShell window** in the script's folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Drivers.ps1
```

**Try a dry run first.** It shows what would be installed and which silent switches would be used, without installing anything or asking for admin:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Drivers.ps1 -DryRun
```

### What happens

1. **One prompt:** Windows asks for administrator rights **once**. If you're on a standard account, that's where you type the admin password. Nothing else will ask after this.
2. If there's a `downloads.txt`, those files are downloaded.
3. `.zip` / `.cab` files are unpacked.
4. You see the plan: everything that will be installed, in order, and anything skipped (with the reason).
5. Everything installs silently, one at a time. Restarts are held back.
6. You get a summary, then **one** question: *Restart now? (Y/N)*. Use `-AutoReboot` to skip the question.

The laptop is kept awake while it works. Leave it plugged in.

---

## Options

| Option | What it does |
|---|---|
| `-DriverPath <folder or .zip>` | Where the drivers are. Default: `Drivers` / `Drivers.zip` next to the script. If neither exists, you're asked to pick a folder. |
| `-DryRun` | Show the plan only. Installs nothing. No admin prompt. |
| `-AutoReboot` | Restart automatically 30 seconds after finishing. |
| `-NoPause` | Don't wait for Enter at the end (for unattended use). |
| `-IncludeFirmware` | Also run BIOS / firmware updates (see below). |
| `-AllowUnsigned` | Also run installers that aren't validly digitally signed. |
| `-OrderByName` | Install in alphabetical order instead of by category. Prefix files `01_`, `02_`... to set the order. |
| `-TimeoutMinutes <n>` | Longest one installer may run before it's stopped. Default `20`. |
| `-Force` | Re-install things that already finished in an earlier run. |
| `-WorkFolder <folder>` | Where logs, unpacked files and downloads go. Default `C:\DriverInstall`. |

Example:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Drivers.ps1 -DriverPath "E:\ThinkPad T14 Drivers" -AutoReboot
```

---

## Install order

Drivers go in the order manufacturers recommend. The script works out the group from the file name, the folder name and the file's own description:

1. Chipset and platform (chipset, Management Engine, Serial IO, Dynamic Tuning...)
2. Storage (Intel RST / VMD, NVMe, SATA)
3. Graphics
4. Audio
5. Network and Bluetooth
6. Everything else (touchpad, card reader, camera, vendor apps...)
7. BIOS and firmware, last and only with `-IncludeFirmware`

---

## If an installer isn't silent: `switches.txt`

Most installers are detected automatically. If one pops up a window, you can just click through it (windows are left visible on purpose). If one times out, tell the script what to use next time by putting a `switches.txt` in the driver folder:

```
# file name (wildcards OK) = arguments
*Chipset*.exe       = -s -norestart
sp145678.exe        = /s /f C:\SWSetup\sp145678
camera-driver.exe   = NONE
dell-command*.exe   = SKIP
```

- `NONE` runs it with no switches, so you click through it yourself.
- `SKIP` leaves it out.
- For `.msi` files, the arguments go after `msiexec /i "file.msi"`.

The vendor's download page or release notes usually list the silent switches. Common ones are `/s`, `/S`, `-s`, `/quiet`, `/VERYSILENT` and `/qn`.

---

## Optional: let the script download files: `downloads.txt`

Put direct download links in a `downloads.txt` in the driver folder, one per line. Add `| name.exe` if the link doesn't end in a file name:

```
# links to the manufacturer's files
https://dl.dell.com/FOLDER0123456M/1/Intel-Chipset-Device-Software_XXXXX_WIN64_10.1.19444.8378_A00.EXE
https://ftp.hp.com/pub/softpaq/sp145501-146000/sp145678.exe
https://example.com/download?id=123 | Touchpad-Driver.exe
```

Downloads are saved to `C:\DriverInstall\Downloads` and installed with everything else. Files already downloaded aren't fetched again.

---

## BIOS and firmware

BIOS / UEFI / firmware updates are **skipped by default**. A failed BIOS update can brick a laptop, and on BitLocker-encrypted laptops it can trigger a recovery-key prompt. With `-IncludeFirmware` the script:

- runs them **last**,
- skips them if the laptop is on battery, and
- pauses BitLocker for one restart so you aren't asked for the recovery key.

The manufacturer's own update tool (Dell Command Update, HP Image Assistant, Lenovo System Update) is still the safest way to do BIOS updates.

Some BIOS files don't have "BIOS" in their name. If you're unsure, keep BIOS files out of the folder or rename them so the name includes `BIOS`.

---

## Logs, re-running and restarts

- Everything is logged in **`C:\DriverInstall\Logs`**: a full log, a `results_*.csv`, a `pnputil_*.log`, and a log for each `.msi`.
- The script **remembers what finished**. If something failed or the laptop restarted halfway, just **run it again** and it carries on with what's left. Use `-Force` to redo everything.
- Some drivers only finish after a restart. If something says "Needs another update first", restart and run the script once more.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| "Running scripts is disabled on this system" | Use the `powershell -ExecutionPolicy Bypass -File ...` command above, or right-click and choose **Run with PowerShell**. |
| An installer window popped up | Click through it, then add a line to `switches.txt` for next time. |
| "Timed out after 20 min" | The installer was probably waiting for a click. Add its switches to `switches.txt`, or use `NONE` and click through it. |
| "Not validly signed" | The file is unsigned or damaged. Download it again from the manufacturer. If you trust it, use `-AllowUnsigned`. |
| "Nothing to install" | Check that the folder actually has `.exe` / `.msi` / `.zip` / `.cab` / `.inf` files and isn't named with a leading `_`. |
| Drivers on a network drive | That works. The script switches mapped drive letters to `\\server\share` paths so the admin session can see them. |
| A device still shows a yellow "!" in Device Manager | Restart, then run the script again. If it's still there, that driver is missing from the folder. |

---

## Good to know

- Works on **Windows 10 and 11** with the built-in Windows PowerShell 5.1. PowerShell 7 works too.
- Driver packs are added to Windows' driver store with `pnputil`. Windows only uses the drivers that match hardware in the laptop.
- It never changes your power settings. It just keeps the PC awake while it runs.
