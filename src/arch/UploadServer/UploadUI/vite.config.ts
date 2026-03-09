import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Proxy target: 8081 = local dev server (npm run dev:server), 8080 = tvOS app (mise run upload-ui:dev-with-api)
const apiPort = process.env.UPLOAD_API_PORT || "8081";
const apiTarget = `http://localhost:${apiPort}`;

export default defineConfig({
	plugins: [react()],
	base: "/",
	build: {
		outDir: "dist",
	},
	server: {
		proxy: {
			"/upload": apiTarget,
			"/list": apiTarget,
			"/delete": apiTarget,
		},
	},
});
