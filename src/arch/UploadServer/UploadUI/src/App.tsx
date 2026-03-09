import { useCallback, useEffect, useRef, useState } from "react";
import { useDropzone } from "react-dropzone";

const TARGETS = [
	"Songs",
	"Themes",
	"NoteSkins",
	"Courses",
	"Packages",
] as const;
type Target = (typeof TARGETS)[number];

type UploadState = "idle" | "uploading" | "done" | "error";

export type TreeNode = { name: string; children?: TreeNode[] };

function FileTree({
	target,
	refreshTrigger,
	onDeleted,
}: {
	target: Target;
	refreshTrigger: number;
	onDeleted?: () => void;
}) {
	const [tree, setTree] = useState<TreeNode[]>([]);
	const [loading, setLoading] = useState(true);
	const [error, setError] = useState<string | null>(null);
	const [deletingAll, setDeletingAll] = useState(false);

	const handleDeleteAll = useCallback(() => {
		const count = tree.length;
		if (
			!window.confirm(
				`Delete all ${count} item(s) in ${target}? This cannot be undone.`,
			)
		)
			return;
		setDeletingAll(true);
		const paths = tree.map((node) => node.name);
		(async () => {
			try {
				for (const path of paths) {
					const body = new URLSearchParams({ target, path });
					const r = await fetch("/delete", {
						method: "POST",
						headers: {
							"Content-Type": "application/x-www-form-urlencoded",
						},
						body: body.toString(),
					});
					if (!r.ok)
						throw new Error(
							r.status === 404 ? "Not found" : `HTTP ${r.status}`,
						);
				}
				onDeleted?.();
			} catch (err) {
				alert(err instanceof Error ? err.message : String(err));
			} finally {
				setDeletingAll(false);
			}
		})();
	}, [target, tree, onDeleted]);

	useEffect(() => {
		let cancelled = false;
		setLoading(true);
		setError(null);
		fetch(`/list?target=${encodeURIComponent(target)}`)
			.then(async (r) => {
				const text = await r.text();
				if (!r.ok) {
					let msg = `HTTP ${r.status}`;
					try {
						const j = JSON.parse(text);
						if (j?.error) msg = j.error;
					} catch {
						if (text.trim()) msg = text.trim().slice(0, 200);
					}
					throw new Error(msg);
				}
				return JSON.parse(text) as { tree: TreeNode[] };
			})
			.then((data) => {
				if (!cancelled) setTree(data.tree ?? []);
			})
			.catch((err) => {
				if (!cancelled)
					setError(err instanceof Error ? err.message : String(err));
			})
			.finally(() => {
				if (!cancelled) setLoading(false);
			});
		return () => {
			cancelled = true;
		};
	}, [target, refreshTrigger]);

	if (loading && tree.length === 0)
		return <div className="file-tree file-tree-loading">Loading…</div>;
	if (error)
		return (
			<div className="file-tree file-tree-error" role="alert">
				{error}
			</div>
		);
	if (tree.length === 0)
		return <div className="file-tree file-tree-empty">No files yet</div>;

	return (
		<div className="file-tree-wrap">
			<div className="file-tree-actions">
				<button
					type="button"
					className="file-tree-delete-all"
					onClick={handleDeleteAll}
					disabled={deletingAll}
					aria-label={`Delete all items in ${target}`}
				>
					{deletingAll ? "Deleting…" : "Delete all"}
				</button>
			</div>
			<div
				className="file-tree"
				role="tree"
				aria-label={`Files in ${target}`}
			>
				<TreeNodeList
					nodes={tree}
					depth={0}
					target={target}
					basePath=""
					onDeleted={onDeleted}
				/>
			</div>
		</div>
	);
}

function TreeNodeList({
	nodes,
	depth = 0,
	target,
	basePath,
	onDeleted,
}: {
	nodes: TreeNode[];
	depth?: number;
	target: Target;
	basePath: string;
	onDeleted?: () => void;
}) {
	return (
		<ul
			className={`file-tree-list ${depth > 0 ? "file-tree-list-nested" : ""}`}
			role="group"
			style={{ "--depth": depth } as React.CSSProperties}
		>
			{nodes.map((node) => (
				<TreeNodeItem
					key={basePath ? `${basePath}/${node.name}` : node.name}
					node={node}
					depth={depth}
					target={target}
					relativePath={basePath ? `${basePath}/${node.name}` : node.name}
					onDeleted={onDeleted}
				/>
			))}
		</ul>
	);
}

function TreeNodeItem({
	node,
	depth,
	target,
	relativePath,
	onDeleted,
}: {
	node: TreeNode;
	depth: number;
	target: Target;
	relativePath: string;
	onDeleted?: () => void;
}) {
	const [open, setOpen] = useState(false);
	const [deleting, setDeleting] = useState(false);
	const isDir = Array.isArray(node.children);

	const children = node.children ?? [];

	const handleDelete = useCallback(
		(e: React.MouseEvent) => {
			e.stopPropagation();
			const label = relativePath;
			if (
				!window.confirm(
					`Delete "${label}"? This cannot be undone.${isDir ? " The folder and all its contents will be removed." : ""}`,
				)
			)
				return;
			setDeleting(true);
			const body = new URLSearchParams({ target, path: relativePath });
			fetch("/delete", {
				method: "POST",
				headers: { "Content-Type": "application/x-www-form-urlencoded" },
				body: body.toString(),
			})
				.then((r) => {
					if (!r.ok) throw new Error(r.status === 404 ? "Not found" : `HTTP ${r.status}`);
					return r.json();
				})
				.then(() => {
					onDeleted?.();
				})
				.catch((err) => {
					alert(err instanceof Error ? err.message : String(err));
				})
				.finally(() => setDeleting(false));
		},
		[target, relativePath, isDir, onDeleted],
	);

	return (
		<li
			className={`file-tree-item ${isDir ? "file-tree-dir" : "file-tree-file"}`}
			role="treeitem"
			aria-expanded={isDir ? open : undefined}
			tabIndex={0}
		>
			{isDir ? (
				<>
					<div className="file-tree-row">
						<button
							type="button"
							className="file-tree-toggle"
							onClick={() => setOpen((o) => !o)}
							aria-expanded={open}
							aria-label={open ? "Collapse" : "Expand"}
						>
							<span className="file-tree-chevron">
								{open ? "▼" : "▶"}
							</span>
							<span className="file-tree-name">{node.name}</span>
						</button>
						{onDeleted && (
							<button
								type="button"
								className="file-tree-delete"
								onClick={handleDelete}
								disabled={deleting}
								aria-label={`Delete ${node.name}`}
								title="Delete"
							>
								{deleting ? "…" : "✕"}
							</button>
						)}
					</div>
					{open && (
						<TreeNodeList
							nodes={children}
							depth={depth + 1}
							target={target}
							basePath={relativePath}
							onDeleted={onDeleted}
						/>
					)}
				</>
			) : (
				<div className="file-tree-row">
					<span className="file-tree-name">{node.name}</span>
					{onDeleted && (
						<button
							type="button"
							className="file-tree-delete"
							onClick={handleDelete}
							disabled={deleting}
							aria-label={`Delete ${node.name}`}
							title="Delete"
						>
							{deleting ? "…" : "✕"}
						</button>
					)}
				</div>
			)}
		</li>
	);
}

function uploadWithProgress(
	url: string,
	body: FormData,
	onProgress: (percent: number) => void,
): Promise<string> {
	return new Promise((resolve, reject) => {
		const xhr = new XMLHttpRequest();
		xhr.upload.addEventListener("progress", (e) => {
			if (e.lengthComputable) {
				onProgress(Math.round((e.loaded / e.total) * 100));
			} else {
				onProgress(0);
			}
		});
		xhr.addEventListener("load", () => {
			if (xhr.status >= 200 && xhr.status < 300) {
				resolve(xhr.responseText);
			} else {
				reject(new Error(xhr.responseText || `HTTP ${xhr.status}`));
			}
		});
		xhr.addEventListener("error", () => reject(new Error("Network error")));
		xhr.addEventListener("abort", () => reject(new Error("Aborted")));
		xhr.open("POST", url);
		xhr.send(body);
	});
}

function TabDropzone({
	target,
	overwrite,
	onUploadSuccess,
}: {
	target: Target;
	overwrite: string;
	onUploadSuccess?: () => void;
}) {
	const [status, setStatus] = useState<{
		message: string;
		state: UploadState;
	}>({
		message: "",
		state: "idle",
	});
	const [progress, setProgress] = useState<number>(0);

	const upload = useCallback(
		async (files: File[]) => {
			if (files.length === 0) return;
			setProgress(0);
			setStatus({
				message: `Uploading ${files.length} item(s)...`,
				state: "uploading",
			});
			const fd = new FormData();
			fd.append("target", target);
			fd.append("overwrite", overwrite);
			for (const file of files) fd.append("files", file);
			try {
				const text = await uploadWithProgress(
					"/upload",
					fd,
					setProgress,
				);
				if (text.includes("Saved")) {
					const m = text.match(/Saved (\d+)/);
					const n = m ? m[1] : "?";
					setStatus({
						message: `Saved ${n} file(s).`,
						state: "done",
					});
					onUploadSuccess?.();
				} else {
					const msg =
						text.includes("error") || text.includes("Error")
							? text
									.replace(/<[^>]*>/g, "")
									.trim()
									.slice(0, 150)
							: "Upload failed.";
					setStatus({ message: msg, state: "error" });
				}
			} catch (err) {
				setStatus({
					message: `Error: ${err instanceof Error ? err.message : String(err)}`,
					state: "error",
				});
			}
		},
		[target, overwrite, onUploadSuccess],
	);

	const { getRootProps, getInputProps, isDragActive } = useDropzone({
		onDrop: upload,
		noClick: false,
		noKeyboard: true,
	});

	return (
		<div
			{...getRootProps()}
			className={`dropzone ${isDragActive ? "drag-over" : ""} ${status.state}`}
			role="button"
			tabIndex={0}
			aria-label={`Drop folder or files to upload to ${target}`}
		>
			<input
				{...getInputProps()}
				{...({
					webkitDirectory: true,
				} as React.InputHTMLAttributes<HTMLInputElement>)}
			/>
			<span className="dropzone-text">
				{isDragActive
					? "Release to upload"
					: "Drop folder or files here"}
			</span>
			{status.state === "uploading" && (
				<div
					className="upload-progress-wrap"
					role="progressbar"
					aria-valuenow={progress}
					aria-valuemin={0}
					aria-valuemax={100}
					aria-label="Upload progress"
				>
					<div
						className="upload-progress-bar"
						style={{ width: `${progress}%` }}
					/>
				</div>
			)}
			{status.message && (
				<span className="dropzone-status" aria-live="polite">
					{status.message}
				</span>
			)}
		</div>
	);
}

export default function App() {
	const [overwrite, setOverwrite] = useState("");
	const [selectedTarget, setSelectedTarget] = useState<Target>("Songs");
	const [pickerProgress, setPickerProgress] = useState<number | null>(null);
	const [treeRefresh, setTreeRefresh] = useState<
		Partial<Record<Target, number>>
	>({});
	const fileInputRef = useRef<HTMLInputElement>(null);
	const pickerTargetRef = useRef<Target>("Songs");

	const refreshTreeFor = useCallback((target: Target) => {
		setTreeRefresh((r) => ({ ...r, [target]: (r[target] ?? 0) + 1 }));
	}, []);

	const openFolderPicker = useCallback((target: Target) => {
		pickerTargetRef.current = target;
		setSelectedTarget(target);
		fileInputRef.current?.click();
	}, []);

	const handleFileChange = useCallback(
		(e: React.ChangeEvent<HTMLInputElement>) => {
			const files = e.target.files;
			if (!files?.length) return;
			const target = pickerTargetRef.current;
			const fd = new FormData();
			fd.append("target", target);
			fd.append("overwrite", overwrite);
			for (let i = 0; i < files.length; i++) fd.append("files", files[i]);
			setPickerProgress(0);
			uploadWithProgress("/upload", fd, setPickerProgress)
				.then((t) => {
					if (t.includes("Saved")) {
						const m = t.match(/Saved (\d+)/);
						alert(`Saved ${m ? m[1] : "?"} file(s).`);
						refreshTreeFor(target);
					} else {
						const msg =
							t
								.replace(/<[^>]*>/g, "")
								.trim()
								.slice(0, 200) || "Upload failed.";
						alert(msg);
					}
				})
				.catch((err) =>
					alert(err instanceof Error ? err.message : String(err)),
				)
				.finally(() => {
					setPickerProgress(null);
					e.target.value = "";
				});
		},
		[overwrite, refreshTreeFor],
	);

	return (
		<>
			<h1>ITGmania Upload</h1>
			{pickerProgress !== null && (
				<div
					className="global-progress-wrap"
					role="progressbar"
					aria-valuenow={pickerProgress}
					aria-valuemin={0}
					aria-valuemax={100}
					aria-label="Upload progress"
				>
					<div
						className="upload-progress-bar"
						style={{ width: `${pickerProgress}%` }}
					/>
				</div>
			)}
			<input
				ref={fileInputRef}
				type="file"
				id="files"
				multiple
				style={{ display: "none" }}
				onChange={handleFileChange}
				{...({
					webkitDirectory: true,
					directory: true,
				} as React.InputHTMLAttributes<HTMLInputElement>)}
			/>
			<div className="tabs">
				{TARGETS.map((t) => (
					<div
						key={t}
						className={`tab ${selectedTarget === t ? "active" : ""}`}
						data-target={t}
					>
						<h2>{t}</h2>
						<TabDropzone
							target={t}
							overwrite={overwrite}
							onUploadSuccess={() => refreshTreeFor(t)}
						/>
						<p>
							<button
								type="button"
								onClick={() => openFolderPicker(t)}
							>
								Add folder…
							</button>
						</p>
						<FileTree
							target={t}
							refreshTrigger={treeRefresh[t] ?? 0}
							onDeleted={() => refreshTreeFor(t)}
						/>
					</div>
				))}
			</div>
			<p className="overwrite-wrap">
				When an uploaded folder has the same name:
				<br />
				<label className="radio">
					<input
						type="radio"
						name="overwrite"
						value="1"
						checked={overwrite === "1"}
						onChange={() => setOverwrite("1")}
					/>{" "}
					Replace the current contents with the new folder
				</label>
				<label className="radio">
					<input
						type="radio"
						name="overwrite"
						value=""
						checked={overwrite === ""}
						onChange={() => setOverwrite("")}
					/>{" "}
					Merge two folders contents
				</label>
			</p>
		</>
	);
}
