# wsl-space

A small Windows tool that shows how much of C: your WSL distributions really use, finds what is big,
gives space back to C:, and warns before C: runs low.

![wsl-space window: C: free space, one row per distro with its drive, disk size, Linux used and reclaimable space, the action buttons and the activity log](docs/screenshot.png)

## Why

Each WSL distribution lives in a virtual disk file (`ext4.vhdx`) on C:. The file grows when Linux
needs space, but deleting files inside Linux does not shrink it, so C: fills up silently.
`df -h /` inside Linux shows the virtual disk's maximum (~1 TB), not the real limit, which is C:'s
free space.

## Requirements

Windows PowerShell 5.1 and WSL 2. Nothing to install: it uses WinForms, `fsutil`, `wsl.exe`,
`diskpart` and Task Scheduler, all built into Windows. **Move** needs WSL 2.5 or later
(`wsl --version`).

Tested on Windows 11 (build 26300) with WSL 3.0.5, Ubuntu 24.04 and Docker Desktop's data disk.
Other setups should work; please report what does not.

The script is not code-signed and Compact relaunches it with admin rights (UAC), so Windows
SmartScreen or antivirus may warn the first time. Read the script first if you like: it is one file.

## Run

- **Window:** double-click `wsl-space.cmd` (or `powershell -ExecutionPolicy Bypass -File wsl-space.ps1`).
- **Command line:**

| Switch | What it does |
|---|---|
| `-Report` | Per distro: drive the disk is on, VHDX size on disk, space Linux uses, reclaimable (= VHDX − used), sparse flag; plus C: free space. |
| `-BigFolders [-Distro x] [-Path p] [-Depth n] [-Top k]` | Biggest folders (`du -xk`), default `~`, depth 3, top 25. |
| `-Trim [-Distro x]` | `fstrim -v /` as root inside the distro; C: free before and after. |
| `-Compact <distro>` | Shrinks the VHDX with diskpart. Stops WSL, needs admin (asks for UAC). |
| `-Move <distro> -To <folder>` | Moves the distro's disk to another folder or drive with `wsl --manage --move`. Stops WSL. |
| `-Check [-ThresholdGB n]` | Shows a notification if C: is below the threshold. Does not start WSL. |
| `-SelfTest` | Runs the built-in tests; exit code 1 on any failure. |

Without `-Distro`, the distro with the biggest disk file is used.

"VHDX on disk" is the space the file actually takes on C: (for a sparse file this is less than its
nominal size shown in Explorer's *Size* column; compare with *Size on disk*).

### The window

The theme follows Windows' light/dark app setting. In dark mode nothing stays white: the title bar,
scrollbars, tabs, drop-downs, number spinners, check box, progress bar, grid headers and borders are
all painted from the palette, and disabled buttons stay readable. Selected grid rows get a subtle tint
with an accent bar on the left, so warning/error colors stay visible.

- **Header:** C: free space, a usage bar, and a status chip with symbol and text:
  `✓ Healthy`, `! Low (below 15 GB)` or `✗ Critical (below 5 GB)`.
- **Tabs**
  - **Distros:** one row per distro: Distribution, Drive (where the disk lives, e.g. `D:` after a Move), Disk size, Linux used, Reclaimable (bold when
    ≥ 5 GB), Sparse, Note (`✗` + the problem). The selected row is what Trim and Compact act on.
  - **Big folders:** pick a distro (defaults to the selected row), path (`~`), depth and top, then
    **Scan**. Results show size, a proportional size bar and path; **Open in Explorer** (or double-click) and
    **Copy path**.
- **Action bar:** **Refresh** (F5) · **Trim…** · **Compact…** (red: stops all WSL sessions) · **Move to drive…** (stops all WSL sessions), each with
  a tooltip, and the checkbox **Warn me daily when C: is below [15] GB**.
- **Activity log:** every command and its output, one line each as `HH:mm:ss  symbol  text`, colored
  by kind (`▶` section, `>` command, output, `✓` success, `!` warning, `✗` error). Each action ends with
  its result and duration, e.g. `✓ Refresh done (4 s)`. Filter **All / Commands & output / Errors
  only**, **Copy** (selection or everything), **Save…** to a text file, **Clear view** (display only).
  It stops auto-scrolling while you scroll up.
- **Status bar:** the running action with a marquee progress bar and elapsed seconds, and **Cancel** (Refresh, Big
  folders, Trim; Compact and Move cannot be cancelled). After Trim/Compact/Move it shows how C: free space changed;
  the log has the disk's own change.
- Keys: F5 refreshes, Ctrl+F jumps to the Big folders path; buttons have Alt mnemonics.
- Window size, position, splitter position and last tab are remembered in `settings.json`.
- Long operations run in the background, so the window stays responsive.

### Reclaiming space

1. **Trim** (safe, WSL keeps running). With a sparse VHDX, blocks freed by `fstrim` go back to C:;
   otherwise trim first, then Compact.
2. **Compact** (heavier). Runs `wsl --shutdown`, turns sparse off if needed (diskpart refuses sparse
   files), and runs `diskpart` (`attach vdisk readonly`, `compact vdisk`, `detach vdisk`). Sparse is
   left off afterwards: current WSL gates sparse VHDs behind `--allow-unsafe` because of possible data
   corruption. The disk is always detached, even on errors. The result is the disk file's own change
   ("Disk shrank by …" or "The disk did not shrink"), not the change in C: free space, which also moves
   because `wsl --shutdown` deletes WSL's swap file. A transcript of the elevated run is saved in
   `%LOCALAPPDATA%\wsl-space\compact-<time>.log` and shown in the log.
3. **Docker Desktop.** Its data disk (`%LOCALAPPDATA%\Docker\wsl\disk\docker_data.vhdx`, images,
   containers and volumes) is listed as **Docker Desktop data**. Linux used is not measured. With
   Docker Desktop running, check it with `docker system df` and free space with `docker system prune`
   (you choose what goes); Docker Desktop usually shrinks the file itself after a prune. Compact helps
   only if it did not: quit Docker Desktop and **Compact** that row. Compact refuses while Docker Desktop
   runs, because it restarts WSL. Trim, Big folders and Move do not apply to it (move it in Docker
   Desktop: Settings › Resources › Advanced › Disk image location).
4. **Move to another drive.** When C: itself is too small, **Move to drive…** (or `-Move <distro>
   -To <folder>`) runs `wsl --shutdown` and WSL's own `wsl --manage <distro> --move <folder>`. Before
   stopping anything it checks that the folder has no `ext4.vhdx` and that the drive has room for the
   disk plus 1 GB. If WSL's move fails, the distro stays where it was. Needs WSL 2.5 or later.

Weekly automatic trim inside WSL (run once in Linux; the tool only shows this hint):

```sh
sudo systemctl enable --now fstrim.timer
```

### Low-space warning

The threshold (default 15 GB) is stored in `%LOCALAPPDATA%\wsl-space\settings.json`.
Checking **Warn me daily when C: is below [15] GB** copies `wsl-space.ps1` to
`%LOCALAPPDATA%\wsl-space\` (so it does not depend on a `\\wsl.localhost` path or a running WSL) and
registers the task `wsl-space-check` (daily at 09:00 and at logon) running `-Check`. Unchecking it
removes the task. Changing the number saves the new threshold, which the task reads on its next run.

## Safety rules

- **The tool never deletes files.** It shows what is big; you decide. Some big folders are derived data
  you can regenerate (caches, `node_modules`, `.venv`, build output), others are irreplaceable
  (for example raw measurement captures). Only you know which is which.
- **Compaction only after an explicit confirmation** that names the distro and warns that all WSL
  sessions stop (including running Claude Code sessions and editors). It needs admin rights.
- **Move only after an explicit confirmation** naming the distro and target folder. It refuses a drive
  root, a folder on the same drive, a folder that already has an `ext4.vhdx`, or a drive without room,
  before stopping anything; the move itself is done by WSL.
- **Nothing irreversible:** no `wsl --unregister`, no removing distros. Extra distros are only reported.
- **Every command run is shown in the log.**
- Temporary diskpart scripts in `%TEMP%` and self-test folders `%TEMP%\wsl-space-test-*` are left in
  place (the tool deletes nothing); remove them yourself if you like.

## License

[MIT](LICENSE).
