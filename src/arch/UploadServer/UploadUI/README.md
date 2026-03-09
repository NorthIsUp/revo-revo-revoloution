# ITGmania Upload UI

Mini React app for the tvOS upload server. Built with Vite, React, and [react-dropzone](https://react-dropzone.js.org/).

## Build

```bash
npm install
npm run build
```

Output is written to `dist/`. The tvOS app bundle includes this folder when present; the server serves it at `GET /` and falls back to the embedded HTML UI if `dist` is missing.

## Development

### Option A – Local test server (no tvOS app)

For testing upload and sync in the browser with a local folder (e.g. a simfiles directory):

1. **Terminal 1 – backend** (implements `POST /upload` and `GET /list`, writes to `./upload-test` by default):

   ```bash
   npm run dev:server
   ```

   Uses port **8081** by default (8080 is often used by the tvOS app). Set `UPLOAD_DEST` to write elsewhere, e.g.:

   ```bash
   UPLOAD_DEST=/path/to/destination npm run dev:server
   ```

2. **Terminal 2 – UI** (Vite proxies `/upload` and `/list` to the backend):

   ```bash
   npm run dev
   ```

3. Open **http://localhost:5173** (or the port Vite prints), then drag a folder (e.g. **Dance Dance Revolution** from `~/Library/CloudStorage/Dropbox/Benami/simfiles/`) onto the **Songs** dropzone. The tree view under each tab shows existing files and updates after a successful upload.

   If you see **500 errors** or "No files yet" never loading: ensure the backend is running first (`npm run dev:server` in another terminal). The UI proxies `/list` and `/upload` to port 8081.

   When using **dev-with-api** (tvOS app on 8080), the app’s server must register the static/fallback GET handler *before* the API handlers so that `/list`, `/upload`, and `/delete` are tried first (GCDWebServer tries handlers in reverse registration order).

### Option B – tvOS app (real upload server on device/simulator)

To test the UI against the **tvOS app’s** upload server (port 8080), e.g. in the simulator:

```bash
mise run upload-ui:dev-with-api
```

This launches the tvOS app (and simulator if needed), waits for the upload server to bind, then starts Vite with the proxy set to 8080. One command, no separate backend.

---

### Mise tasks (recommended)

| Task | Use when |
|------|----------|
| `mise run upload-ui:dev` | Local UI work: runs **local** backend (8081) + Vite. No app/simulator. |
| `mise run upload-ui:dev-with-api` | Testing against the **tvOS app**: launches app (8080), then Vite proxying to 8080. |

Both are needed: **dev** for quick iteration without the app; **dev-with-api** when you want to hit the real server (e.g. to verify tvOS upload/list/delete).
