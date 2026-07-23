# R2Box

R2Box is an experimental desktop client for Cloudflare R2 and S3-compatible object storage, written in [V](https://vlang.io/) with [V UI](https://github.com/vlang/ui).

> [!WARNING]
> **R2Box is experimental software. Expect bugs.**
>
> It is a personal/open-source experiment built on a young GUI toolkit and is not intended to be treated as a production-grade replacement for mature S3 clients. Back up important data, use appropriately scoped credentials, and test destructive operations carefully.

R2Box focuses on a small desktop workflow:

```text
connect
browse
upload
download
inspect
delete
```

Starting with 0.4.0, R2Box also supports sequential transfer queues, cancellation, and retrying failed transfers.

## Platform

Current target:

```text
Ubuntu-based Linux
x86_64
X11
```

Primary test environment:

```text
FunOS
Ubuntu 26.04-based
JWM
x86_64
X11
```

R2Box may work elsewhere, but other distributions, architectures, Wayland sessions, and desktop environments are not currently claimed as supported targets.

## Toolchain

The development environment is intentionally pinned:

```text
V:    0.5.2
V UI: 2f6fd14e67cf3da8cae1dff162493b762ffc8289
```

Do not run `v up` if you want to reproduce the currently tested build.

V UI is still evolving, and several R2Box UI workarounds intentionally target the pinned revision above.

## Features

### Connection and object browser

- Cloudflare R2 / S3-compatible endpoint
- Access Key ID / Secret Access Key authentication
- Bucket browsing
- Prefix/folder-style navigation
- Up / Root navigation
- Clickable object selection
- Local filter
- S3 continuation-token pagination
- Object Key auto-fill
- Object metadata:
  - name
  - size
  - content type
  - last modified
  - ETag
  - full key

### Upload

- Internal local file picker
- Drag-and-drop local files from the desktop
- Multi-file staging
- Repeated **Browse** calls can add several files
- Multi-file drag-and-drop
- Sequential upload queue
- Background upload worker
- Multipart upload for larger files
- Upload progress
- Queue cancellation
- Retry failed uploads

### Download

- Automatic XDG-aware Downloads directory
- Multiple remote objects can be staged
- Sequential download queue
- Range/chunk downloads
- 5 MiB chunks
- Background download worker
- Download progress
- `.part` temporary files
- No silent overwrite of existing final files
- Queue cancellation
- Retry failed downloads

### Safety and behavior

- Delete requires typing `DELETE`
- Failed transfer jobs are retained in memory for Retry
- Upload multipart cancellation attempts to abort the in-flight multipart upload
- Cancelled downloads keep their `.part` file when data has already been written
- Only one transfer queue is active at a time

## Important file-picker note

R2Box intentionally uses a **single-selection ListBox** in its internal file picker.

A multi-selection implementation was tested during 0.4.0 development, but the pinned V UI build proved unstable when rebuilding or mutating a child-window ListBox during selection events.

The stable workflow is therefore:

```text
Browse
→ select one file
→ Open / Select

Browse again
→ select another file
→ Open / Select
```

Each selected file is added to the staged upload list.

For several files at once, use drag-and-drop from your file manager.

This is a deliberate stability trade-off, not an accidental omission.

## Transfer queue behavior

Queues are sequential:

```text
file 1
  ↓
file 2
  ↓
file 3
```

R2Box does not run several uploads/downloads in parallel.

This keeps memory, connection usage, progress reporting, cancellation, and error handling simpler.

When a normal transfer fails:

```text
item A  complete
item B  failed
item C  complete
```

the queue continues.

Failed jobs are retained in memory and can be retried with:

```text
Retry failed
```

Retry preserves:

- the original upload Object Key;
- the original download destination.

Download retry currently restarts from zero; it does not resume an existing `.part`.

Cancelled items are not automatically classified as failed items.

## Build dependencies

Ubuntu-based systems:

```bash
sudo apt update

sudo apt install -y \
  git build-essential make \
  libxi-dev libxcursor-dev mesa-common-dev \
  libgl-dev libxrandr-dev libasound2-dev \
  libegl-dev libfreetype6-dev \
  xclip
```

`xclip` is currently used by the explicit clipboard **Paste** buttons on X11.

## Install V 0.5.2

```bash
mkdir -p ~/.local/opt ~/.local/bin

git clone https://github.com/vlang/v ~/.local/opt/v

cd ~/.local/opt/v

git checkout 0.5.2
make

ln -sf ~/.local/opt/v/v ~/.local/bin/v
```

Make sure:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

is available in your shell environment.

Verify:

```bash
v version
```

## Install the pinned V UI revision

```bash
mkdir -p ~/.vmodules

git clone https://github.com/vlang/ui ~/.vmodules/ui

cd ~/.vmodules/ui

git checkout 2f6fd14e67cf3da8cae1dff162493b762ffc8289
```

## Clone R2Box

```bash
git clone https://github.com/jeannesbryan/r2box.git

cd r2box
```

Format:

```bash
v fmt -w main.v
```

Run:

```bash
v run main.v
```

## Production build

```bash
mkdir -p build

v -prod -o build/r2box main.v
```

Run:

```bash
./build/r2box
```

Inspect dynamic dependencies:

```bash
ldd build/r2box
```

There should be no:

```text
not found
```

entries.

## Cloudflare R2 configuration

A standard Cloudflare R2 S3-compatible endpoint has the form:

```text
https://<ACCOUNT_ID>.r2.cloudflarestorage.com
```

R2Box asks for:

```text
Endpoint
Access Key ID
Secret Access Key
Bucket
```

Then use:

```text
Connect / Refresh
```

Use credentials with only the permissions actually required by your workflow.

### Credential safety

Never commit real credentials in:

```text
main.v
README.md
screenshots
issues
logs
```

R2Box currently accepts credentials at runtime and does not intentionally persist them to a project configuration file.

## Upload workflow

Single file:

```text
Browse
→ select file
→ Open / Select
→ Upload
```

Several files:

```text
Browse → select A
Browse → select B
Browse → select C
→ Upload
```

or:

```text
select several files in your file manager
→ drag them onto R2Box
→ Upload
```

For a multi-file queue, each target Object Key defaults to:

```text
<current-prefix>/<local-filename>
```

The queue is processed sequentially.

## Download workflow

Select an object.

R2Box automatically proposes a destination using the current Linux user's XDG Downloads directory.

For example:

```text
/home/alice/Downloads/archive.zip
```

To create a queue:

```text
select object A
→ Add

select object B
→ Add

select object C
→ Add

→ Download
```

If nothing has been staged, clicking **Download** preserves the old one-object workflow and automatically stages the currently selected object.

## Large downloads

R2Box does not intentionally load a large object into RAM all at once.

It uses S3 range requests in 5 MiB chunks.

During transfer:

```text
archive.zip.part
```

is written.

After every chunk succeeds and the full object is complete:

```text
archive.zip.part
↓
archive.zip
```

R2Box refuses to silently overwrite an existing final destination.

## Cancel

Upload and download queues have a **Cancel** action.

Cancellation is cooperative.

A network request already in progress may need to return before the worker can observe the cancellation request.

### Upload cancellation

For an active multipart upload, R2Box attempts to abort the multipart state before stopping.

Remaining queue items stay staged.

### Download cancellation

The worker stops at a chunk/request boundary.

If data has already been written:

```text
filename.part
```

is kept.

Remaining queue items stay staged.

## Retry failed

After a queue finishes with failed jobs:

```text
Retry failed
```

starts a new queue containing only those failures.

Retry state is held in memory.

If R2Box is closed, the failed-job list is lost.

For downloads, retry starts the failed file from zero and replaces an old `.part`.

## Delete

Select an object and type:

```text
DELETE
```

in the confirmation field.

Then use:

```text
Delete object
```

Successful deletion also clears stale Object Details from the UI.

## Building an AppImage

The following manual workflow assumes `appimagetool` is available at:

```text
~/.local/bin/appimagetool
```

and the repository contains:

```text
r2box.png
```

### 1. Production binary

```bash
cd /path/to/r2box

mkdir -p build

v -prod -o build/r2box main.v

./build/r2box
```

### 2. Create AppDir

```bash
rm -rf AppDir

mkdir -p AppDir/usr/bin

cp build/r2box AppDir/usr/bin/r2box
cp r2box.png AppDir/r2box.png
```

### 3. Create `AppRun`

Use a launcher script rather than a symlink:

```bash
cat > AppDir/AppRun <<'EOF'
#!/bin/sh
APPDIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "$APPDIR/usr/bin/r2box" "$@"
EOF

chmod 755 AppDir/AppRun
```

### 4. Desktop entry

```bash
cat > AppDir/r2box.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=R2Box
Comment=Experimental Cloudflare R2 / S3 desktop client
Exec=r2box
Icon=r2box
Terminal=false
Categories=Network;Utility;
EOF
```

Structure:

```text
AppDir/
├── AppRun
├── r2box.desktop
├── r2box.png
└── usr/
    └── bin/
        └── r2box
```

### 5. Test AppDir first

```bash
./AppDir/AppRun
```

Do not build the AppImage until this works.

### 6. Build

```bash
mkdir -p dist

ARCH=x86_64 ~/.local/bin/appimagetool \
  AppDir \
  dist/R2Box-0.4.0-x86_64.AppImage
```

Make executable:

```bash
chmod +x dist/R2Box-0.4.0-x86_64.AppImage
```

Run:

```bash
./dist/R2Box-0.4.0-x86_64.AppImage
```

### AppImage runtime note

The current AppImage does not bundle `xclip`.

The host system therefore still needs:

```bash
sudo apt install xclip
```

for explicit clipboard Paste buttons.

## Recommended repository layout

```text
r2box/
├── main.v
├── README.md
├── LICENSE
├── .gitignore
├── r2box.svg
└── r2box.png
```

Generated artifacts should not be committed:

```text
build/
dist/
main
*.bak
main.v.before-*
main.v.*.backup
```

`AppDir/` can be generated during packaging, or its packaging metadata can be kept without committing the compiled `usr/bin/r2box` binary.

## Suggested `.gitignore`

```gitignore
/build/
/dist/
/main

*.bak
main.v.before-*
main.v.*.backup

/AppDir/usr/bin/r2box
```

## Known limitations

- R2Box is experimental and bugs should be expected.
- Current target is Ubuntu-based Linux x86_64 + X11.
- Clipboard Paste buttons depend on host `xclip`.
- V UI behavior is tied to a pinned pre-stable revision.
- The internal picker is intentionally single-select for stability.
- Multi-file Browse selection requires opening the picker repeatedly.
- Only one transfer queue can run at a time.
- Queues are sequential, not parallel.
- Download retry does not resume `.part`; it restarts from zero.
- Failed/retry state is not persisted across application restarts.
- Cancel cannot interrupt an HTTP request at an arbitrary instruction; it takes effect at cooperative checkpoints.
- Copy/move/rename operations are not implemented.
- Presigned URL generation is not currently exposed in the UI.
- AppImage portability has been tested conservatively and is not claimed across every Linux distribution.

## Project status

R2Box exists primarily as an experiment in building a small native-ish Linux object-storage client with V.

It is useful, but it should be treated as software under active experimentation rather than as production infrastructure.

That means:

```text
expect bugs
keep backups
use scoped credentials
verify important transfers
test before relying on destructive operations
```

## References

- [V](https://github.com/vlang/v)
- [V 0.5.2](https://github.com/vlang/v/tree/0.5.2)
- [V net.s3](https://github.com/vlang/v/tree/0.5.2/vlib/net/s3)
- [V UI](https://github.com/vlang/ui)
- [Pinned V UI revision](https://github.com/vlang/ui/tree/2f6fd14e67cf3da8cae1dff162493b762ffc8289)
- [Cloudflare R2 S3 API compatibility](https://developers.cloudflare.com/r2/api/s3/api/)
- [Cloudflare R2 API tokens](https://developers.cloudflare.com/r2/api/tokens/)
- [AppImage manual packaging](https://docs.appimage.org/packaging-guide/manual.html)
