#!/usr/bin/env node
/**
 * Local dev server for testing the Upload UI in the browser.
 * Implements POST /upload and GET /list like the tvOS UploadServer.
 * Usage: UPLOAD_DEST=./upload-test node server-dev.mjs
 * Then run `npm run dev` and open http://localhost:5173; proxy forwards /upload and /list to this server.
 */

import fs from 'node:fs';
import path from 'node:path';
import { createServer } from 'node:http';

const PORT = Number(process.env.UPLOAD_PORT) || 8081;
const DEST = path.resolve(process.env.UPLOAD_DEST || 'upload-test');
const TARGETS = ['Songs', 'Themes', 'NoteSkins', 'Courses', 'Packages'];

function sanitizeSegment(name) {
	if (!name || name === '.' || name === '..') return '_';
	const safe = name.replace(/[^a-zA-Z0-9._-]/g, '_').trim();
	return safe || '_';
}

function sanitizeFilePath(fileName) {
	const parts = fileName.split(/[/\\]/).filter(Boolean).map(sanitizeSegment);
	return parts.join(path.sep);
}

function buildFileTree(dirPath) {
	if (!fs.existsSync(dirPath)) return [];
	const entries = fs.readdirSync(dirPath, { withFileTypes: true });
	const nodes = [];
	for (const e of entries) {
		if (e.name.startsWith('.')) continue;
		const full = path.join(dirPath, e.name);
		if (e.isDirectory()) {
			nodes.push({ name: e.name, children: buildFileTree(full) });
		} else {
			nodes.push({ name: e.name });
		}
	}
	nodes.sort((a, b) => {
		const aDir = 'children' in a ? 1 : 0;
		const bDir = 'children' in b ? 1 : 0;
		if (aDir !== bDir) return aDir - bDir;
		return a.name.localeCompare(b.name, undefined, { sensitivity: 'base' });
	});
	return nodes;
}

function parseMultipart(req) {
	return new Promise((resolve, reject) => {
		const chunks = [];
		req.on('data', (c) => chunks.push(c));
		req.on('end', () => {
			const body = Buffer.concat(chunks);
			const boundary = req.headers['content-type']?.match(/boundary=(?:"([^"]+)"|([^;\s]+))/);
			if (!boundary) {
				reject(new Error('No boundary'));
				return;
			}
			const b = (boundary[1] || boundary[2] || '').trim();
			if (!b) {
				reject(new Error('Empty boundary'));
				return;
			}
			const parts = body.split('--' + b).filter((p) => p.length && !p.startsWith('--\r\n'));
			const fields = {};
			const files = [];
			for (const part of parts) {
				const [head, ...rest] = part.split('\r\n\r\n');
				const bodyPart = rest.join('\r\n\r\n').replace(/\r\n$/, '');
				const nameMatch = head.match(/name="([^"]+)"/);
				const filenameMatch = head.match(/filename="([^"]*)"/);
				const name = nameMatch?.[1];
				if (!name) continue;
				if (filenameMatch) {
					const filename = filenameMatch[1].replace(/^.*[/\\]/, '') || 'upload';
					const safePath = sanitizeFilePath(filenameMatch[1]);
					files.push({ fieldname: name, originalPath: filenameMatch[1], safePath, buffer: Buffer.from(bodyPart, 'binary') });
				} else {
					fields[name] = bodyPart.trim();
				}
			}
			resolve({ fields, files });
		});
		req.on('error', reject);
	});
}

function safeBuildFileTree(dirPath) {
	try {
		if (!fs.existsSync(dirPath)) return [];
		return buildFileTree(dirPath);
	} catch (err) {
		console.error('[list]', dirPath, err);
		throw err;
	}
}

const server = createServer(async (req, res) => {
	const url = new URL(req.url || '', `http://localhost:${PORT}`);

	if (req.method === 'GET' && url.pathname === '/list') {
		try {
			const target = TARGETS.includes(url.searchParams.get('target') || '') ? url.searchParams.get('target') : 'Songs';
			const targetDir = path.join(DEST, target);
			if (!fs.existsSync(targetDir)) {
				res.setHeader('Content-Type', 'application/json');
				res.end(JSON.stringify({ tree: [] }));
				return;
			}
			const tree = safeBuildFileTree(targetDir);
			res.setHeader('Content-Type', 'application/json');
			res.end(JSON.stringify({ tree }));
		} catch (err) {
			res.statusCode = 500;
			res.setHeader('Content-Type', 'application/json');
			res.end(JSON.stringify({ error: String(err.message) }));
			console.error('[list]', err);
		}
		return;
	}

	if (req.method === 'POST' && url.pathname === '/upload') {
		try {
			const { fields, files } = await parseMultipart(req);
			const target = TARGETS.includes(fields?.target || '') ? fields.target : 'Songs';
			const overwrite = (fields?.overwrite || '').toLowerCase().startsWith('1');
			const targetDir = path.join(DEST, target);
			fs.mkdirSync(targetDir, { recursive: true });
			let saved = 0;
			for (const file of files || []) {
				const rel = file.safePath || sanitizeFilePath(file.originalPath || '') || file.originalPath || 'upload';
				const destPath = path.join(targetDir, rel);
				const dir = path.dirname(destPath);
				fs.mkdirSync(dir, { recursive: true });
				if (!overwrite && fs.existsSync(destPath)) continue;
				if (overwrite && fs.existsSync(destPath)) fs.rmSync(destPath, { force: true });
				fs.writeFileSync(destPath, file.buffer);
				saved++;
			}
			res.setHeader('Content-Type', 'text/html; charset=utf-8');
			res.end(
				saved > 0
					? `<p>Saved ${saved} file(s) to ${target}.</p>`
					: '<p>No files saved.</p>'
			);
		} catch (err) {
			res.statusCode = 500;
			res.setHeader('Content-Type', 'text/plain');
			res.end(String(err.message));
			console.error('[upload]', err);
		}
		return;
	}

	if (req.method === 'POST' && url.pathname === '/delete') {
		const chunks = [];
		req.on('data', (c) => chunks.push(c));
		req.on('end', () => {
			const body = Buffer.concat(chunks).toString('utf-8');
			const params = Object.fromEntries(new URLSearchParams(body));
			const target = TARGETS.includes(params.target || '') ? params.target : 'Songs';
			const pathArg = params.path?.trim() || '';
			if (!pathArg) {
				res.statusCode = 400;
				res.setHeader('Content-Type', 'text/plain');
				res.end('Missing path');
				return;
			}
			const segments = pathArg.split(/[/\\]/).filter(Boolean).map((s) => sanitizeSegment(s.trim()));
			if (segments.some((s) => !s || s === '_')) {
				res.statusCode = 400;
				res.setHeader('Content-Type', 'text/plain');
				res.end('Invalid path');
				return;
			}
			const relativePath = segments.join(path.sep);
			const targetDir = path.join(DEST, target);
			const fullPath = path.resolve(targetDir, relativePath);
			if (!fullPath.startsWith(path.resolve(targetDir)) || fullPath === path.resolve(targetDir)) {
				res.statusCode = 400;
				res.setHeader('Content-Type', 'text/plain');
				res.end('Invalid path');
				return;
			}
			if (!fs.existsSync(fullPath)) {
				res.statusCode = 404;
				res.setHeader('Content-Type', 'text/plain');
				res.end('Not found');
				return;
			}
			try {
				fs.rmSync(fullPath, { recursive: true });
				res.setHeader('Content-Type', 'application/json');
				res.end(JSON.stringify({ ok: true }));
			} catch (err) {
				res.statusCode = 500;
				res.setHeader('Content-Type', 'text/plain');
				res.end(String(err.message));
			}
		});
		return;
	}

	res.statusCode = 404;
	res.end('Not found');
});

server.listen(PORT, () => {
	console.log(`Upload dev server: http://localhost:${PORT}`);
	console.log(`  Destination: ${DEST}`);
	console.log(`  Start the UI with: npm run dev`);
	console.log(`  Then open http://localhost:5173 and drag a folder (e.g. Dance Dance Revolution) onto Songs`);
});
