#!/usr/bin/env python3
"""Push song folders from a Mac directory (an iCloud Drive folder, say) to an Apple TV.

tvOS apps cannot read iCloud Drive -- Apple grants Apple TV only CloudKit and
key-value storage, never ubiquity document containers (see
Docs/tvOS-device-build.md). A Mac can, so the sync happens here: point this at a
folder that iCloud already keeps in step across your devices, and it posts what
is missing to the TV's upload server.

Re-running is the update path. The server merges by default and skips files that
already exist, so a second run costs one request per song and uploads nothing.

    ./Utils/push-songs.py ~/Library/Mobile\\ Documents/com~apple~CloudDocs/RRRevoloution/Songs 10.0.1.23
"""

import argparse
import mimetypes
import os
import sys
import urllib.error
import urllib.request
import uuid

DEFAULT_PORT = 8080
# One request per song folder: keeps memory flat on a 400MB pack and means a
# failure loses one song, not the whole library.
SKIP = {".DS_Store"}


def multipart(target, files):
    """files: list of (relative_path, absolute_path)."""
    boundary = uuid.uuid4().hex
    body = bytearray()

    def field(name, value):
        body.extend(f"--{boundary}\r\n".encode())
        body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        body.extend(f"{value}\r\n".encode())

    field("target", target)
    field("overwrite", "")

    for rel, path in files:
        ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
        body.extend(f"--{boundary}\r\n".encode())
        body.extend(
            f'Content-Disposition: form-data; name="files"; filename="{rel}"\r\n'.encode()
        )
        body.extend(f"Content-Type: {ctype}\r\n\r\n".encode())
        with open(path, "rb") as f:
            body.extend(f.read())
        body.extend(b"\r\n")

    body.extend(f"--{boundary}--\r\n".encode())
    return boundary, bytes(body)


def song_folders(root):
    """Yield (group/song, [(relpath, abspath)]) for each Songs/<group>/<song>/."""
    for group in sorted(os.listdir(root)):
        gpath = os.path.join(root, group)
        if group.startswith(".") or not os.path.isdir(gpath):
            continue
        for song in sorted(os.listdir(gpath)):
            spath = os.path.join(gpath, song)
            if song.startswith(".") or not os.path.isdir(spath):
                continue
            files = []
            for dirpath, _, names in os.walk(spath):
                for n in sorted(names):
                    if n in SKIP or n.startswith("."):
                        continue
                    abspath = os.path.join(dirpath, n)
                    rel = os.path.relpath(abspath, root)
                    files.append((rel, abspath))
            if files:
                yield f"{group}/{song}", files


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("source", help="a Songs/ directory containing <group>/<song>/ folders")
    ap.add_argument("host", help="Apple TV hostname or IP (see the URL shown on the TV)")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--target", default="Songs", help="Songs, Themes, NoteSkins, Courses...")
    args = ap.parse_args()

    if not os.path.isdir(args.source):
        sys.exit(f"not a directory: {args.source}")

    url = f"http://{args.host}:{args.port}/upload"
    sent = skipped = failed = 0
    for name, files in song_folders(args.source):
        boundary, body = multipart(args.target, files)
        req = urllib.request.Request(url, data=body, method="POST")
        req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
        try:
            with urllib.request.urlopen(req, timeout=600) as r:
                # The server merges: it answers "No files saved" when every file
                # was already there, which is the steady state on a re-run.
                saved = "Saved" in r.read().decode(errors="replace")
            print(f"{'sent   ' if saved else 'present'}  {name}  ({len(files)} files)")
            sent += 1 if saved else 0
            skipped += 0 if saved else 1
        except (urllib.error.URLError, TimeoutError) as e:
            print(f"FAILED {name}: {e}", file=sys.stderr)
            failed += 1

    print(f"\n{sent} sent, {skipped} already present, {failed} failed.")
    if sent:
        print("Reload songs on the TV (Options -> Reload Songs) to pick them up.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
