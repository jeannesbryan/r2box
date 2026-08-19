# R2Box

R2Box is an experimental desktop client for Cloudflare R2 and S3-compatible object storage, written in [V](https://vlang.io/) with [V UI](https://github.com/vlang/ui).

> [!WARNING]
> **R2Box is experimental software. Expect bugs.**
> It is a personal/open-source experiment built on a young GUI toolkit and is not intended to be treated as a production-grade replacement for mature S3 clients. Back up important data, use appropriately scoped credentials, and test destructive operations carefully.

R2Box focuses on a small desktop workflow: connect, browse, upload, download, inspect, copy, move/rename, and delete. R2Box also supports sequential transfer queues, cancellation, and retrying failed transfers

## Features

*   **Connection & Browser:** Cloudflare R2 / S3-compatible endpoint support, prefix/folder-style navigation, local filtering, S3 continuation-token pagination, and detailed object metadata inspection.
*   **Upload:** Internal local file picker, drag-and-drop support, multi-file staging, sequential background upload worker, multipart uploads for larger files, queue cancellation, and failed upload retries.
*   **Download:** XDG-aware Downloads directory integration, range/chunk downloads (5 MiB chunks), background worker, `.part` temporary files preventing silent overwrites, queue cancellation, and retries.
*   **Safety:** Deletion requires typing `DELETE`. Cancelled downloads retain their `.part` files if data was written. Only one transfer queue is active at a time to keep memory and connection usage predictable.

## Platform & Toolchain

**Current target:** Ubuntu-based Linux, x86_64, X11.
R2Box may work elsewhere, but other distributions, architectures, Wayland sessions, and desktop environments are not currently claimed as supported targets.

**Development environment is intentionally pinned:**
*   **V:** 0.5.2 (Do not run `v up` if you want to reproduce the tested build).
*   **V UI:** Revision `2f6fd14e67cf3da8cae1dff162493b762ffc8289`.

## File Picker & Queue Behavior

*   **Single-Selection:** R2Box intentionally uses a single-selection ListBox in its internal file picker for stability against the pinned V UI revision. To stage multiple files, either open the picker repeatedly or drag-and-drop from your OS file manager.
*   **Sequential Queues:** R2Box does not run multiple uploads/downloads in parallel. Failed jobs are retained in memory and can be retried. Download retries currently restart from zero and do not resume an existing `.part`.

## Building & Installation

### 1. Build Dependencies (Ubuntu-based)
```bash
sudo apt update
sudo apt install -y git build-essential make libxi-dev libxcursor-dev mesa-common-dev libgl-dev libxrandr-dev libasound2-dev libegl-dev libfreetype6-dev xclip
```
*(Note: `xclip` is currently required for explicit clipboard Paste buttons on X11).*

### 2. Install Pinned V & V UI
```bash
# Install V 0.5.2
mkdir -p ~/.local/opt ~/.local/bin
git clone https://github.com/vlang/v ~/.local/opt/v
cd ~/.local/opt/v
git checkout 0.5.2
make
ln -sf ~/.local/opt/v/v ~/.local/bin/v
export PATH="$HOME/.local/bin:$PATH"

# Install V UI pinned revision
mkdir -p ~/.vmodules
git clone https://github.com/vlang/ui ~/.vmodules/ui
cd ~/.vmodules/ui
git checkout 2f6fd14e67cf3da8cae1dff162493b762ffc8289
```

### 3. Build R2Box
```bash
git clone https://github.com/jeannesbryan/r2box.git
cd r2box
mkdir -p build
v -prod -o build/r2box main.v
./build/r2box
```

## AppImage Packaging

To distribute as an AppImage, assuming `appimagetool` is available on your host system:
1. Create an `AppDir/usr/bin` structure and copy the `r2box` binary and `r2box.png` icon.
2. Create an `AppRun` launcher script and a `r2box.desktop` entry within the AppDir.
3. Build the binary and generate the image: `ARCH=x86_64 appimagetool AppDir dist/R2Box-0.4.0-x86_64.AppImage`.
*(Note: The runtime AppImage does not bundle `xclip`, which must remain installed natively).*

## Known Limitations

*   Clipboard Paste buttons depend on host `xclip`.
*   Failed/retry state is not persisted across application restarts.
*   Cancel cannot interrupt an HTTP request at an arbitrary instruction; it takes effect at cooperative checkpoints.
*   Copy/move/rename operations are not implemented.
*   Presigned URL generation is not currently exposed in the UI.

## Project Status

R2Box is an experiment in building a small native-ish Linux object-storage client with V. It is useful but should be treated as software under active experimentation rather than production infrastructure.