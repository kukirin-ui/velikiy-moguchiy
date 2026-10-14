use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::Semaphore;
pub use tokio_util::sync::CancellationToken;

use crate::config;
use crate::errors::{CoreError, Result};

const MANIFEST_FILE: &str = ".koe-manifest.json";
const CHECKSUM_CACHE_FILE: &str = ".koe-checksum.json";

/// Hard per-file download cap applied when the manifest declares no size
/// (`size == 0`, e.g. upstream size metadata was missing). The largest model
/// file the app ships today is ~135 MB, so 8 GiB leaves ample headroom for far
/// larger future models while still bounding a malicious or broken server to
/// a finite disk write instead of an unbounded stream. Manifests that declare
/// a size keep the stricter exact-size check.
const MAX_UNSIZED_DOWNLOAD_BYTES: u64 = 8 * 1024 * 1024 * 1024;

// ─── Data Structures ────────────────────────────────────────────────

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ModelManifest {
    pub provider: String,
    #[serde(default)]
    pub mode: Option<String>,
    pub description: String,
    pub repo: String,
    pub files: Vec<ModelFile>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ModelFile {
    pub name: String,
    pub size: u64,
    pub sha256: String,
    pub url: String,
}

/// A model discovered by scanning ~/.velikiy-moguchiy/models/.
#[derive(Debug, Clone)]
pub struct DiscoveredModel {
    /// Model directory path (unique identifier).
    pub path: PathBuf,
    pub manifest: ModelManifest,
}

/// Model installation status.
/// Values match the C FFI convention: 0=not installed, 1=incomplete, 2=installed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum ModelStatus {
    /// Only manifest, no data files downloaded.
    NotInstalled = 0,
    /// Manifest exists, but some files missing or wrong size.
    Incomplete = 1,
    /// Manifest exists, all files present with correct sizes.
    Installed = 2,
}

/// Controls how `model_status()` verifies file integrity.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VerifyMode {
    /// Use cached sha256 if valid (mtime matches), compute on cache miss, write back.
    Normal,
    /// Use cached sha256 if valid, return false on cache miss (never compute).
    CacheOnly,
    /// Ignore cache, always compute sha256, write back.
    ForceVerify,
}

/// Per-file checksum cache entry stored in `.koe-checksum.json`.
#[derive(Debug, Serialize, Deserialize, Clone)]
struct ChecksumEntry {
    /// File mtime (seconds since epoch) at the time sha256 was computed.
    mtime: i64,
    /// Hex-encoded sha256 hash.
    sha256: String,
}

/// Read the checksum cache, refusing to follow a non-regular path.
///
/// A symlink planted at `.koe-checksum.json` would otherwise be dereferenced,
/// and pointing it at a character device (`/dev/zero`) turns this into an
/// unbounded read. Absent/unreadable/corrupt caches degrade to "no cache",
/// exactly as before.
fn load_checksum_cache(path: &Path) -> Option<HashMap<String, ChecksumEntry>> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    if !meta.file_type().is_file() {
        log::warn!(
            "ignoring checksum cache {}: not a regular file",
            path.display()
        );
        return None;
    }
    let content = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&content).ok()
}

/// Write the checksum cache without ever following a symlink and without
/// truncating in place.
///
/// `std::fs::write` opens with `O_TRUNC` and follows symlinks, so a link
/// planted at `.koe-checksum.json` (the model dir is writable by anything that
/// can drop files there) would let verification destroy an arbitrary file.
/// Instead: refuse when the existing path is not a regular file, then write to
/// a fresh temp file in the same directory and rename over the destination —
/// `rename` replaces the entry itself rather than writing through it, and the
/// swap is atomic so a crash never leaves a half-written cache.
fn write_checksum_cache(path: &Path, cache: &HashMap<String, ChecksumEntry>) -> Result<()> {
    if let Ok(meta) = std::fs::symlink_metadata(path) {
        if !meta.file_type().is_file() {
            return Err(CoreError::Config(format!(
                "refusing to write checksum cache {}: not a regular file",
                path.display()
            )));
        }
    }

    let json = serde_json::to_string_pretty(cache)
        .map_err(|e| CoreError::Config(format!("serialize checksum cache: {e}")))?;

    let dir = path.parent().ok_or_else(|| {
        CoreError::Config(format!(
            "checksum cache path {} has no parent directory",
            path.display()
        ))
    })?;
    let unique = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let tmp = dir.join(format!(
        "{CHECKSUM_CACHE_FILE}.tmp.{}.{unique}",
        std::process::id()
    ));

    // `create_new` so a path planted at the temp name is never followed.
    let write_tmp = || -> std::io::Result<()> {
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)?;
        f.write_all(json.as_bytes())?;
        f.flush()
    };
    if let Err(e) = write_tmp() {
        let _ = std::fs::remove_file(&tmp);
        return Err(CoreError::Config(format!("write checksum cache: {e}")));
    }

    if let Err(e) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(CoreError::Config(format!("write checksum cache: {e}")));
    }
    Ok(())
}

fn mtime_secs(meta: &std::fs::Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

// ─── Models Directory ───────────────────────────────────────────────

/// Returns ~/.velikiy-moguchiy/models/
pub fn models_dir() -> PathBuf {
    config::config_dir().join("models")
}

// ─── Scan ───────────────────────────────────────────────────────────

/// Local ASR providers supported by this build (on-device, feature-gated).
pub fn supported_providers() -> &'static [&'static str] {
    &[
        #[cfg(feature = "apple-speech")]
        "apple-speech",
        #[cfg(feature = "mlx")]
        "mlx",
        #[cfg(feature = "sherpa-onnx")]
        "sherpa-onnx",
        #[cfg(feature = "wetype-offline")]
        "wetype",
    ]
}

/// Scan ~/.velikiy-moguchiy/models/**/.koe-manifest.json and return all discovered models.
pub fn scan_models() -> Vec<DiscoveredModel> {
    let dir = models_dir();
    if !dir.exists() {
        return Vec::new();
    }

    let mut models = Vec::new();
    scan_dir_recursive(&dir, &mut models);
    models
}

/// Scan models filtered to providers supported by this build.
pub fn scan_supported_models() -> Vec<DiscoveredModel> {
    let supported = supported_providers();
    let mut models = scan_models();
    models.retain(|m| supported.contains(&m.manifest.provider.as_str()));
    models
}

fn scan_dir_recursive(dir: &Path, models: &mut Vec<DiscoveredModel>) {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        // `Path::is_dir` follows symlinks: a link planted under the models
        // root would make discovery recurse outside it, or loop forever on a
        // cycle. Use the entry's own type so links are simply skipped.
        let is_real_dir = entry.file_type().map(|ft| ft.is_dir()).unwrap_or(false);
        if is_real_dir {
            if let Some(model) = load_manifest(&path) {
                models.push(model);
            }
            // Continue scanning subdirectories
            scan_dir_recursive(&path, models);
        }
    }
}

/// A manifest is small JSON; anything larger is malformed or hostile.
const MAX_MANIFEST_BYTES: u64 = 1024 * 1024;

fn load_manifest(model_dir: &Path) -> Option<DiscoveredModel> {
    let manifest_path = model_dir.join(MANIFEST_FILE);
    // Read only a regular file, and check the descriptor actually opened
    // rather than the path: a manifest symlinked to /dev/zero or replaced by
    // a FIFO would otherwise hang or exhaust memory during a routine scan,
    // and a link to a regular file would read outside the model directory.
    if !std::fs::symlink_metadata(&manifest_path)
        .map(|m| m.file_type().is_file())
        .unwrap_or(false)
    {
        return None;
    }
    let mut file = std::fs::File::open(&manifest_path).ok()?;
    let meta = file.metadata().ok()?;
    if !meta.is_file() || meta.len() > MAX_MANIFEST_BYTES {
        return None;
    }
    let mut content = String::new();
    use std::io::Read;
    file.take(MAX_MANIFEST_BYTES)
        .read_to_string(&mut content)
        .ok()?;
    let manifest: ModelManifest = serde_json::from_str(&content).ok()?;
    Some(DiscoveredModel {
        path: model_dir.to_path_buf(),
        manifest,
    })
}

// ─── Status ─────────────────────────────────────────────────────────

/// Unified model status check with configurable verification depth.
pub fn model_status(model_dir: &Path, mode: VerifyMode) -> ModelStatus {
    // Verification reads paths built from untrusted manifest entries (and the
    // setup wizard runs it automatically), so resolve the model dir with the
    // same containment rule mutating operations use before touching anything
    // underneath it. A dir that does not exist or escapes the models root is
    // reported as "not installed" — the same answer a missing manifest gives.
    let model_dir = match canonical_dir_within_root(model_dir, &models_dir()) {
        Ok(dir) => dir,
        Err(e) => {
            log::warn!("model status: {e}");
            return ModelStatus::NotInstalled;
        }
    };
    let model_dir = model_dir.as_path();

    let model = match load_manifest(model_dir) {
        Some(m) => m,
        None => return ModelStatus::NotInstalled,
    };

    if model.manifest.files.is_empty() {
        return ModelStatus::Installed;
    }

    let cache_path = model_dir.join(CHECKSUM_CACHE_FILE);
    let cache: HashMap<String, ChecksumEntry> = match mode {
        VerifyMode::ForceVerify => HashMap::new(),
        _ => load_checksum_cache(&cache_path).unwrap_or_default(),
    };

    let mut found = 0usize;
    let total = model.manifest.files.len();
    let mut new_cache = cache.clone();
    let mut cache_dirty = false;

    for file in &model.manifest.files {
        if check_file(
            model_dir,
            file,
            mode,
            &cache,
            &mut new_cache,
            &mut cache_dirty,
        ) {
            found += 1;
        }
    }

    if cache_dirty && mode != VerifyMode::CacheOnly {
        let _ = write_checksum_cache(&cache_path, &new_cache);
    }

    if found == total {
        ModelStatus::Installed
    } else if found > 0 {
        ModelStatus::Incomplete
    } else {
        ModelStatus::NotInstalled
    }
}

/// Check a single file against its manifest entry.
///
/// `model_dir` must already be canonicalized (see `model_status`). A manifest
/// entry that does not resolve to a regular file strictly inside `model_dir`
/// counts as *not present* — verification never reads it.
fn check_file(
    model_dir: &Path,
    file: &ModelFile,
    mode: VerifyMode,
    cache: &HashMap<String, ChecksumEntry>,
    new_cache: &mut HashMap<String, ChecksumEntry>,
    cache_dirty: &mut bool,
) -> bool {
    // Same validation as the mutating paths: reject absolute/traversal names
    // lexically, then reject a symlink at any component and require the
    // deepest existing ancestor to canonicalize back inside the model dir.
    let file_path = match manifest_entry_path(model_dir, &file.name)
        .and_then(|p| ensure_target_contained(model_dir, &p).map(|()| p))
    {
        Ok(p) => p,
        Err(e) => {
            log::warn!("skipping manifest entry {:?}: {e}", file.name);
            return false;
        }
    };

    // `symlink_metadata` + `is_file` so a directory, fifo or device node in
    // the model dir is never sized, mtime-cached or hashed.
    let meta = match std::fs::symlink_metadata(&file_path) {
        Ok(m) => m,
        Err(_) => return false,
    };
    if !meta.file_type().is_file() {
        log::warn!(
            "skipping manifest entry {:?}: {} is not a regular file",
            file.name,
            file_path.display()
        );
        return false;
    }

    // manifest 有 size → 比较
    if file.size > 0 && meta.len() != file.size {
        return false;
    }

    // manifest 无 sha → size 通过即可
    if file.sha256.is_empty() {
        return true;
    }

    // manifest 有 sha → 需要验证
    let mtime = mtime_secs(&meta);

    // 检查缓存（ForceVerify 传入空 cache，不会命中）
    if let Some(entry) = cache.get(&file.name) {
        if entry.mtime == mtime {
            return entry.sha256 == file.sha256;
        }
    }

    // 缓存无效
    if mode == VerifyMode::CacheOnly {
        return false;
    }

    // 计算 sha256
    match sha256_file(&file_path) {
        Ok(hash) => {
            let ok = hash == file.sha256;
            new_cache.insert(
                file.name.clone(),
                ChecksumEntry {
                    mtime,
                    sha256: hash,
                },
            );
            *cache_dirty = true;
            ok
        }
        Err(_) => false,
    }
}

// ─── Path Containment ───────────────────────────────────────────────

/// Reject model directories whose path contains `..` or `.` components.
/// Relative model names are joined under `models_dir()` before reaching the
/// mutating operations, so a traversal component would escape the base.
fn validate_model_dir(model_dir: &Path) -> Result<()> {
    use std::path::Component;
    if model_dir
        .components()
        .any(|c| matches!(c, Component::ParentDir | Component::CurDir))
    {
        return Err(CoreError::Config(format!(
            "model dir {} contains path traversal components",
            model_dir.display()
        )));
    }
    Ok(())
}

/// Resolve a manifest-declared file name strictly beneath `model_dir`.
///
/// Manifest entries are untrusted input: reject absolute paths and any
/// non-normal component (`..`, `.`, prefixes) so mutating operations can
/// never create, overwrite, or delete files outside the model directory.
fn manifest_entry_path(model_dir: &Path, name: &str) -> Result<PathBuf> {
    use std::path::Component;
    let mut resolved = model_dir.to_path_buf();
    let mut has_component = false;
    for component in Path::new(name).components() {
        match component {
            Component::Normal(part) => {
                has_component = true;
                resolved.push(part);
            }
            _ => {
                return Err(CoreError::Config(format!(
                    "unsafe file name in manifest: {name:?}"
                )));
            }
        }
    }
    if !has_component {
        return Err(CoreError::Config(format!(
            "empty file name in manifest: {name:?}"
        )));
    }
    Ok(resolved)
}

/// Canonicalize `model_dir` for a MUTATING operation (download, remove,
/// part-file creation) and enforce containment.
///
/// The lexical checks above cannot see symlinks: a symlinked directory under
/// the models root would redirect deletion and part-file writes to arbitrary
/// external paths. Canonicalizing resolves symlinks up front; if the caller's
/// path claims to live under the models root, its canonical form must still
/// be inside the canonical models root. Absolute model dirs outside the root
/// are documented and stay supported (the caller owns those paths).
fn canonical_model_dir_for_mutation(model_dir: &Path) -> Result<PathBuf> {
    validate_model_dir(model_dir)?;
    canonical_dir_within_root(model_dir, &models_dir())
}

fn canonical_dir_within_root(model_dir: &Path, models_root: &Path) -> Result<PathBuf> {
    let canonical = std::fs::canonicalize(model_dir)
        .map_err(|e| CoreError::Config(format!("canonicalize {}: {e}", model_dir.display())))?;
    if model_dir.starts_with(models_root) {
        let canonical_root = std::fs::canonicalize(models_root).map_err(|e| {
            CoreError::Config(format!("canonicalize {}: {e}", models_root.display()))
        })?;
        if !canonical.starts_with(&canonical_root) {
            return Err(CoreError::Config(format!(
                "model dir {} resolves outside the models directory ({})",
                model_dir.display(),
                canonical.display()
            )));
        }
    }
    Ok(canonical)
}

/// Reject a target when any already-existing component below the (canonical)
/// model dir is a symlink, then require the deepest existing ancestor to
/// canonicalize back inside the model dir.
///
/// Used for both mutating and read-only (verification) access. Without this,
/// `File::create`/append on a planted symlink would truncate or grow a file
/// outside the model directory, removal/pruning through a symlinked
/// subdirectory would affect external files, and sha256 verification would
/// read whatever a planted link points at.
fn ensure_target_contained(canonical_dir: &Path, target: &Path) -> Result<()> {
    let rel = target.strip_prefix(canonical_dir).map_err(|_| {
        CoreError::Config(format!(
            "target {} is not inside model dir {}",
            target.display(),
            canonical_dir.display()
        ))
    })?;

    let mut current = canonical_dir.to_path_buf();
    let mut deepest_existing = canonical_dir.to_path_buf();
    for component in rel.components() {
        current.push(component);
        match std::fs::symlink_metadata(&current) {
            Ok(meta) if meta.file_type().is_symlink() => {
                return Err(CoreError::Config(format!(
                    "refusing to operate on {}: {} is a symlink",
                    target.display(),
                    current.display()
                )));
            }
            Ok(_) => deepest_existing = current.clone(),
            // Component not created yet — nothing below it can exist either.
            Err(_) => break,
        }
    }

    let canonical_ancestor = std::fs::canonicalize(&deepest_existing).map_err(|e| {
        CoreError::Config(format!("canonicalize {}: {e}", deepest_existing.display()))
    })?;
    if !canonical_ancestor.starts_with(canonical_dir) {
        return Err(CoreError::Config(format!(
            "target {} resolves outside model dir {}",
            target.display(),
            canonical_dir.display()
        )));
    }
    Ok(())
}

/// The `.part` sibling used while a file is being downloaded.
fn part_path_for(dest: &Path) -> PathBuf {
    dest.with_extension(format!(
        "{}.part",
        dest.extension().unwrap_or_default().to_string_lossy()
    ))
}

// ─── Remove ─────────────────────────────────────────────────────────

/// Remove downloaded model files, keeping the manifest.
///
/// Deletion is manifest-driven: only files listed in the manifest (plus the
/// velikiy-moguchiy-owned checksum cache and `.part` leftovers) are removed, and every
/// path is validated to stay inside `model_dir`. Requires a parseable
/// manifest so a bogus directory can never be swept wholesale.
pub fn remove_model_files(model_dir: &Path) -> Result<usize> {
    let model_dir = &canonical_model_dir_for_mutation(model_dir)?;
    let model = load_manifest(model_dir).ok_or_else(|| {
        CoreError::Config(format!("manifest not found in {}", model_dir.display()))
    })?;

    let mut removed = 0;
    for file in &model.manifest.files {
        let path = manifest_entry_path(model_dir, &file.name)?;
        ensure_target_contained(model_dir, &path)?;
        let part = part_path_for(&path);
        ensure_target_contained(model_dir, &part)?;
        for target in [&part, &path] {
            if target.is_file() {
                std::fs::remove_file(target)
                    .map_err(|e| CoreError::Config(format!("remove {}: {e}", target.display())))?;
                removed += 1;
            }
        }
        // Prune now-empty subdirectories between the file and model_dir.
        let mut parent = path.parent();
        while let Some(dir) = parent {
            if dir == model_dir || std::fs::remove_dir(dir).is_err() {
                break;
            }
            parent = dir.parent();
        }
    }

    let cache = model_dir.join(CHECKSUM_CACHE_FILE);
    if cache.is_file() {
        std::fs::remove_file(&cache)
            .map_err(|e| CoreError::Config(format!("remove {}: {e}", cache.display())))?;
        removed += 1;
    }
    Ok(removed)
}

// ─── Download ───────────────────────────────────────────────────────

/// Progress information for file downloads.
#[derive(Debug, Clone)]
pub struct DownloadProgress {
    pub file_index: usize,
    pub file_count: usize,
    pub filename: String,
    pub bytes_downloaded: u64,
    pub bytes_total: u64,
    /// true if file was already present and skipped
    pub already_exists: bool,
}

/// Download model files according to the manifest.
///
/// - Skips files already present with correct size
/// - Supports resume via `.part` files and Range headers
/// - Downloads in parallel (up to 4 concurrent)
/// - Verifies sha256 after download
/// - Respects cancellation token
pub async fn download_model<F>(
    model_dir: &Path,
    on_progress: F,
    cancel: CancellationToken,
) -> Result<()>
where
    F: Fn(DownloadProgress) + Send + Sync + 'static,
{
    let model_dir = canonical_model_dir_for_mutation(model_dir)?;
    let model = load_manifest(&model_dir).ok_or_else(|| {
        CoreError::Config(format!("manifest not found in {}", model_dir.display()))
    })?;

    let files = &model.manifest.files;
    if files.is_empty() {
        return Ok(());
    }

    let file_count = files.len();
    let on_progress = Arc::new(on_progress);
    let semaphore = Arc::new(Semaphore::new(4));
    let client = reqwest::Client::builder()
        .user_agent("velikiy-moguchiy/1.0")
        .connect_timeout(Duration::from_secs(30))
        .tcp_keepalive(Some(Duration::from_secs(30)))
        .build()
        .map_err(|e| CoreError::Config(format!("http client: {e}")))?;

    let mut handles = Vec::new();

    for (file_index, file) in files.iter().enumerate() {
        let model_dir = model_dir.to_path_buf();
        let file = file.clone();
        let on_progress = on_progress.clone();
        let semaphore = semaphore.clone();
        let client = client.clone();
        let cancel = cancel.clone();

        let handle = tokio::spawn(async move {
            let _permit = tokio::select! {
                permit = semaphore.acquire() => permit.unwrap(),
                _ = cancel.cancelled() => return Err(CoreError::Config("cancelled".into())),
            };
            download_file(
                &client,
                &model_dir,
                &file,
                file_index,
                file_count,
                &on_progress,
                &cancel,
            )
            .await
        });

        handles.push(handle);
    }

    let mut first_error: Option<CoreError> = None;
    for handle in handles {
        match handle.await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                if first_error.is_none() {
                    cancel.cancel();
                    first_error = Some(e);
                }
            }
            Err(e) => {
                if first_error.is_none() {
                    cancel.cancel();
                    first_error = Some(CoreError::Config(format!("join: {e}")));
                }
            }
        }
    }

    if let Some(e) = first_error {
        return Err(e);
    }

    Ok(())
}

async fn download_file<F>(
    client: &reqwest::Client,
    model_dir: &Path,
    file: &ModelFile,
    file_index: usize,
    file_count: usize,
    on_progress: &Arc<F>,
    cancel: &CancellationToken,
) -> Result<()>
where
    F: Fn(DownloadProgress),
{
    let dest = manifest_entry_path(model_dir, &file.name)?;
    ensure_target_contained(model_dir, &dest)?;

    // Already complete?
    if let Ok(meta) = std::fs::metadata(&dest) {
        let size_ok = file.size == 0 || meta.len() == file.size;
        if size_ok {
            // Verify sha256 if available — catches same-size corruption
            if !file.sha256.is_empty() {
                if let Ok(hash) = sha256_file(&dest) {
                    if hash != file.sha256 {
                        log::warn!(
                            "file {} has correct size but wrong sha256, re-downloading",
                            file.name
                        );
                        let _ = std::fs::remove_file(&dest);
                        // fall through to download
                    } else {
                        on_progress(DownloadProgress {
                            file_index,
                            file_count,
                            filename: file.name.clone(),
                            bytes_downloaded: meta.len(),
                            bytes_total: file.size,
                            already_exists: true,
                        });
                        return Ok(());
                    }
                }
                // sha256 read failed — fall through to re-download
            } else {
                on_progress(DownloadProgress {
                    file_index,
                    file_count,
                    filename: file.name.clone(),
                    bytes_downloaded: meta.len(),
                    bytes_total: file.size,
                    already_exists: true,
                });
                return Ok(());
            }
        }
    }

    // Resume from .part file
    let part_path = part_path_for(&dest);
    ensure_target_contained(model_dir, &part_path)?;

    // Effective per-file byte limit: exact manifest size when declared,
    // otherwise the hard cap so an unsized manifest can never stream forever.
    let size_limit = if file.size > 0 {
        file.size
    } else {
        MAX_UNSIZED_DOWNLOAD_BYTES
    };

    let mut existing_size = if part_path.exists() {
        std::fs::metadata(&part_path).map(|m| m.len()).unwrap_or(0)
    } else {
        0
    };

    // A partial file larger than the expected size can never verify; discard
    // it instead of resuming (and growing) it.
    if existing_size > size_limit {
        log::warn!(
            "partial file for {} is larger than expected ({} > {} bytes), restarting download",
            file.name,
            existing_size,
            size_limit
        );
        let _ = std::fs::remove_file(&part_path);
        existing_size = 0;
    }

    let mut request = client.get(&file.url);
    if existing_size > 0 {
        request = request.header("Range", format!("bytes={}-", existing_size));
    }

    let response = tokio::select! {
        result = request.send() => result
            .map_err(|e| CoreError::Config(format!("download {}: {e}", file.name)))?
            .error_for_status()
            .map_err(|e| CoreError::Config(format!("download {}: {e}", file.name)))?,
        _ = cancel.cancelled() => return Err(CoreError::Config("cancelled".into())),
    };

    let resuming = response.status() == reqwest::StatusCode::PARTIAL_CONTENT;

    let mut out = if resuming && existing_size > 0 {
        // Only ever append to a pre-existing regular file: a symlink (or
        // anything else) planted at the .part path must not be followed.
        let meta = std::fs::symlink_metadata(&part_path)
            .map_err(|e| CoreError::Config(format!("stat part file: {e}")))?;
        if !meta.file_type().is_file() {
            return Err(CoreError::Config(format!(
                "refusing to resume {}: not a regular file",
                part_path.display()
            )));
        }
        on_progress(DownloadProgress {
            file_index,
            file_count,
            filename: file.name.clone(),
            bytes_downloaded: existing_size,
            bytes_total: file.size,
            already_exists: false,
        });
        tokio::fs::OpenOptions::new()
            .append(true)
            .open(&part_path)
            .await
            .map_err(|e| CoreError::Config(format!("open part file: {e}")))?
    } else {
        if let Some(parent) = part_path.parent() {
            tokio::fs::create_dir_all(parent)
                .await
                .map_err(|e| CoreError::Config(format!("create dir: {e}")))?;
        }
        // Create-new semantics so a path planted between the containment check
        // and the open (symlink, directory, …) fails instead of being
        // followed/truncated. Remove any stale leftover first — it is either a
        // regular .part we are intentionally restarting, or a non-file that
        // must not survive; remove_file unlinks a symlink itself, never its
        // target.
        if std::fs::symlink_metadata(&part_path).is_ok() {
            std::fs::remove_file(&part_path)
                .map_err(|e| CoreError::Config(format!("remove stale part file: {e}")))?;
        }
        tokio::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&part_path)
            .await
            .map_err(|e| CoreError::Config(format!("create part file: {e}")))?
    };

    let mut downloaded = if resuming { existing_size } else { 0 };
    let mut stream = response.bytes_stream();

    use tokio::io::AsyncWriteExt;
    loop {
        let chunk = tokio::select! {
            item = stream.next() => match item {
                Some(chunk) => chunk.map_err(|e| CoreError::Config(format!("download {}: {e}", file.name)))?,
                None => break,
            },
            _ = cancel.cancelled() => return Err(CoreError::Config("cancelled".into())),
        };
        out.write_all(&chunk)
            .await
            .map_err(|e| CoreError::Config(format!("write {}: {e}", file.name)))?;
        downloaded += chunk.len() as u64;
        // Abort as soon as the stream exceeds the limit (manifest size, or
        // the hard cap when the manifest declares none) — don't wait for the
        // stream to end to notice an unbounded download.
        if downloaded > size_limit {
            drop(out);
            let _ = std::fs::remove_file(&part_path);
            return Err(CoreError::Config(format!(
                "download {}: received {} bytes, exceeds limit of {} bytes",
                file.name, downloaded, size_limit
            )));
        }
        on_progress(DownloadProgress {
            file_index,
            file_count,
            filename: file.name.clone(),
            bytes_downloaded: downloaded,
            bytes_total: file.size,
            already_exists: false,
        });
    }

    out.flush()
        .await
        .map_err(|e| CoreError::Config(format!("flush {}: {e}", file.name)))?;
    drop(out);

    // Verify integrity: use sha256 when available, otherwise check file size
    if !file.sha256.is_empty() {
        let part = part_path.clone();
        let actual_sha = tokio::select! {
            result = tokio::task::spawn_blocking(move || sha256_file(&part)) =>
                result.map_err(|e| CoreError::Config(format!("sha256 join: {e}")))??
            ,
            _ = cancel.cancelled() => return Err(CoreError::Config("cancelled".into())),
        };
        if actual_sha != file.sha256 {
            let _ = std::fs::remove_file(&part_path);
            return Err(CoreError::Config(format!(
                "sha256 mismatch for {}: expected {}, got {}",
                file.name, file.sha256, actual_sha
            )));
        }
    } else if file.size > 0 {
        let actual_size = std::fs::metadata(&part_path).map(|m| m.len()).unwrap_or(0);
        if actual_size != file.size {
            let _ = std::fs::remove_file(&part_path);
            return Err(CoreError::Config(format!(
                "size mismatch for {}: expected {}, got {}",
                file.name, file.size, actual_size
            )));
        }
    }

    // Rename .part → final
    std::fs::rename(&part_path, &dest)
        .map_err(|e| CoreError::Config(format!("rename {}: {e}", file.name)))?;

    Ok(())
}

/// Lowercase hex of a digest; the 0.11 digest output type no longer implements `LowerHex`.
fn hex_lower(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Hash a regular file.
///
/// Hashing reads to EOF, so a character device (`/dev/zero`) or fifo would
/// stream forever. The pre-open `symlink_metadata` check keeps us from ever
/// *opening* such a path (opening a fifo alone would block), and the post-open
/// `metadata` (an `fstat` on the descriptor we actually read) is authoritative
/// against a swap between the two.
fn sha256_file(path: &Path) -> Result<String> {
    use std::io::{BufReader, Read};
    let meta = std::fs::symlink_metadata(path)
        .map_err(|e| CoreError::Config(format!("stat for sha256: {e}")))?;
    if !meta.file_type().is_file() {
        return Err(CoreError::Config(format!(
            "refusing to hash {}: not a regular file",
            path.display()
        )));
    }
    let f = std::fs::File::open(path)
        .map_err(|e| CoreError::Config(format!("open for sha256: {e}")))?;
    let opened = f
        .metadata()
        .map_err(|e| CoreError::Config(format!("stat for sha256: {e}")))?;
    if !opened.file_type().is_file() {
        return Err(CoreError::Config(format!(
            "refusing to hash {}: not a regular file",
            path.display()
        )));
    }
    let mut reader = BufReader::with_capacity(128 * 1024, f);
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 128 * 1024]; // heap-allocated, safe for GCD worker threads
    loop {
        let n = reader
            .read(&mut buf)
            .map_err(|e| CoreError::Config(format!("read for sha256: {e}")))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hex_lower(&hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// Create a temp model dir with a manifest and a file that has the
    /// correct size but wrong content (wrong sha256).
    fn setup_corrupted_model() -> (PathBuf, String) {
        let tmp = std::env::temp_dir().join(format!(
            "velikiy-moguchiy-model-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&tmp).unwrap();

        let correct_content = b"correct model data here";
        let corrupt_content = b"corrupt model data xxxx"; // same length, different content
        assert_eq!(correct_content.len(), corrupt_content.len());

        let correct_sha = {
            let mut hasher = Sha256::new();
            hasher.update(correct_content);
            hex_lower(&hasher.finalize())
        };

        let manifest = ModelManifest {
            provider: "test".into(),
            mode: None,
            description: "test model".into(),
            repo: "test/model".into(),
            files: vec![ModelFile {
                name: "model.bin".into(),
                size: correct_content.len() as u64,
                sha256: correct_sha.clone(),
                url: String::new(),
            }],
        };

        fs::write(
            tmp.join(MANIFEST_FILE),
            serde_json::to_string(&manifest).unwrap(),
        )
        .unwrap();

        // Write the CORRUPTED file (same size, wrong hash)
        fs::write(tmp.join("model.bin"), corrupt_content).unwrap();

        (tmp, correct_sha)
    }

    #[test]
    fn cache_only_does_not_detect_corruption() {
        // CacheOnly without prior verification: sha is uncached, returns false
        let (tmp, _) = setup_corrupted_model();

        let status = model_status(&tmp, VerifyMode::CacheOnly);
        // CacheOnly can't verify — no cache yet, so files with sha fail
        assert_ne!(status, ModelStatus::Installed);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn normal_mode_detects_corruption() {
        let (tmp, _) = setup_corrupted_model();

        let status = model_status(&tmp, VerifyMode::Normal);
        assert_ne!(status, ModelStatus::Installed);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn force_verify_detects_corruption() {
        let (tmp, _) = setup_corrupted_model();

        let status = model_status(&tmp, VerifyMode::ForceVerify);
        assert_ne!(status, ModelStatus::Installed);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn normal_mode_valid_file() {
        let tmp = std::env::temp_dir().join(format!(
            "velikiy-moguchiy-model-test-valid-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&tmp).unwrap();

        let content = b"valid model content";
        let sha = {
            let mut hasher = Sha256::new();
            hasher.update(content);
            hex_lower(&hasher.finalize())
        };

        let manifest = ModelManifest {
            provider: "test".into(),
            mode: None,
            description: "test".into(),
            repo: "test/model".into(),
            files: vec![ModelFile {
                name: "model.bin".into(),
                size: content.len() as u64,
                sha256: sha,
                url: String::new(),
            }],
        };

        fs::write(
            tmp.join(MANIFEST_FILE),
            serde_json::to_string(&manifest).unwrap(),
        )
        .unwrap();
        fs::write(tmp.join("model.bin"), content).unwrap();

        assert_eq!(
            model_status(&tmp, VerifyMode::Normal),
            ModelStatus::Installed
        );
        assert_eq!(
            model_status(&tmp, VerifyMode::ForceVerify),
            ModelStatus::Installed
        );

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn no_sha256_all_modes_accept_by_size() {
        let tmp = std::env::temp_dir().join(format!(
            "velikiy-moguchiy-model-test-nosha-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&tmp).unwrap();

        let content = b"some model data";
        let manifest = ModelManifest {
            provider: "test".into(),
            mode: None,
            description: "test".into(),
            repo: "test/model".into(),
            files: vec![ModelFile {
                name: "model.bin".into(),
                size: content.len() as u64,
                sha256: String::new(), // no sha256
                url: String::new(),
            }],
        };

        fs::write(
            tmp.join(MANIFEST_FILE),
            serde_json::to_string(&manifest).unwrap(),
        )
        .unwrap();
        fs::write(tmp.join("model.bin"), content).unwrap();

        assert_eq!(
            model_status(&tmp, VerifyMode::CacheOnly),
            ModelStatus::Installed
        );
        assert_eq!(
            model_status(&tmp, VerifyMode::Normal),
            ModelStatus::Installed
        );

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn normal_writes_cache_then_cache_only_hits() {
        let (tmp, _) = setup_corrupted_model();

        // Normal computes sha and writes cache
        let status1 = model_status(&tmp, VerifyMode::Normal);
        assert_ne!(status1, ModelStatus::Installed); // corrupted

        // Cache file should exist now
        assert!(tmp.join(CHECKSUM_CACHE_FILE).exists());

        // CacheOnly should hit the cache and return same result
        let status2 = model_status(&tmp, VerifyMode::CacheOnly);
        assert_eq!(status1, status2);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn cache_hit_for_valid_model() {
        let tmp = std::env::temp_dir().join(format!(
            "velikiy-moguchiy-model-test-cache-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&tmp).unwrap();

        let content = b"valid cached model";
        let sha = {
            let mut hasher = Sha256::new();
            hasher.update(content);
            hex_lower(&hasher.finalize())
        };

        let manifest = ModelManifest {
            provider: "test".into(),
            mode: None,
            description: "test".into(),
            repo: "test/model".into(),
            files: vec![ModelFile {
                name: "model.bin".into(),
                size: content.len() as u64,
                sha256: sha,
                url: String::new(),
            }],
        };

        fs::write(
            tmp.join(MANIFEST_FILE),
            serde_json::to_string(&manifest).unwrap(),
        )
        .unwrap();
        fs::write(tmp.join("model.bin"), content).unwrap();

        // Normal: compute + cache
        assert_eq!(
            model_status(&tmp, VerifyMode::Normal),
            ModelStatus::Installed
        );
        assert!(tmp.join(CHECKSUM_CACHE_FILE).exists());

        // CacheOnly: cache hit
        assert_eq!(
            model_status(&tmp, VerifyMode::CacheOnly),
            ModelStatus::Installed
        );

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn cache_only_returns_not_installed_for_missing_files() {
        let tmp = std::env::temp_dir().join(format!(
            "velikiy-moguchiy-model-test-missing-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&tmp).unwrap();

        let manifest = ModelManifest {
            provider: "test".into(),
            mode: None,
            description: "test".into(),
            repo: "test/model".into(),
            files: vec![ModelFile {
                name: "model.bin".into(),
                size: 100,
                sha256: "abc".into(),
                url: String::new(),
            }],
        };
        fs::write(
            tmp.join(MANIFEST_FILE),
            serde_json::to_string(&manifest).unwrap(),
        )
        .unwrap();
        // No model.bin file

        assert_eq!(
            model_status(&tmp, VerifyMode::CacheOnly),
            ModelStatus::NotInstalled
        );

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn force_verify_ignores_existing_cache() {
        let (tmp, _) = setup_corrupted_model();

        // Build a fake cache that claims Installed
        let mut fake_cache = HashMap::new();
        let meta = fs::metadata(tmp.join("model.bin")).unwrap();
        fake_cache.insert(
            "model.bin".to_string(),
            ChecksumEntry {
                mtime: mtime_secs(&meta),
                sha256: "fake_matching_sha_that_would_fool_cache".into(),
            },
        );
        write_checksum_cache(&tmp.join(CHECKSUM_CACHE_FILE), &fake_cache).unwrap();

        // Normal would trust the cache (mtime matches) — but the cached sha
        // doesn't match the manifest sha, so it still fails
        // ForceVerify ignores cache entirely, recomputes sha
        let status = model_status(&tmp, VerifyMode::ForceVerify);
        assert_ne!(status, ModelStatus::Installed);

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn remove_model_files_deletes_cache() {
        let tmp = std::env::temp_dir().join(format!(
            "velikiy-moguchiy-model-test-remove-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&tmp).unwrap();

        let content = b"model data for remove test";
        let sha = {
            let mut hasher = Sha256::new();
            hasher.update(content);
            hex_lower(&hasher.finalize())
        };
        let manifest = ModelManifest {
            provider: "test".into(),
            mode: None,
            description: "test".into(),
            repo: "test/model".into(),
            files: vec![ModelFile {
                name: "model.bin".into(),
                size: content.len() as u64,
                sha256: sha,
                url: String::new(),
            }],
        };
        fs::write(
            tmp.join(MANIFEST_FILE),
            serde_json::to_string(&manifest).unwrap(),
        )
        .unwrap();
        fs::write(tmp.join("model.bin"), content).unwrap();

        // Build cache
        assert_eq!(
            model_status(&tmp, VerifyMode::Normal),
            ModelStatus::Installed
        );
        assert!(tmp.join(CHECKSUM_CACHE_FILE).exists());

        // Remove model files (keeps manifest)
        let removed = remove_model_files(&tmp).unwrap();
        assert!(removed >= 1);
        assert!(!tmp.join(CHECKSUM_CACHE_FILE).exists());
        assert!(tmp.join(MANIFEST_FILE).exists());

        assert_eq!(
            model_status(&tmp, VerifyMode::CacheOnly),
            ModelStatus::NotInstalled
        );

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn remove_model_files_handles_subdirectories() {
        let tmp = std::env::temp_dir().join(format!(
            "velikiy-moguchiy-model-test-nested-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&tmp).unwrap();

        let manifest = ModelManifest {
            provider: "test".into(),
            mode: None,
            description: "test".into(),
            repo: "test/model".into(),
            files: vec![
                ModelFile {
                    name: "weights.bin".into(),
                    size: 10,
                    sha256: String::new(),
                    url: String::new(),
                },
                ModelFile {
                    name: "subdir/config.json".into(),
                    size: 5,
                    sha256: String::new(),
                    url: String::new(),
                },
            ],
        };
        fs::write(
            tmp.join(MANIFEST_FILE),
            serde_json::to_string(&manifest).unwrap(),
        )
        .unwrap();

        // Create files including nested ones
        fs::write(tmp.join("weights.bin"), b"0123456789").unwrap();
        fs::create_dir_all(tmp.join("subdir")).unwrap();
        fs::write(tmp.join("subdir/config.json"), b"12345").unwrap();

        let removed = remove_model_files(&tmp).unwrap();
        assert_eq!(removed, 2);
        assert!(tmp.join(MANIFEST_FILE).exists());
        assert!(!tmp.join("weights.bin").exists());
        assert!(!tmp.join("subdir").exists());

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn mtime_change_invalidates_cache() {
        let tmp = std::env::temp_dir().join(format!(
            "velikiy-moguchiy-model-test-mtime-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&tmp).unwrap();

        let content = b"original content";
        let sha = {
            let mut hasher = Sha256::new();
            hasher.update(content);
            hex_lower(&hasher.finalize())
        };
        let manifest = ModelManifest {
            provider: "test".into(),
            mode: None,
            description: "test".into(),
            repo: "test/model".into(),
            files: vec![ModelFile {
                name: "model.bin".into(),
                size: content.len() as u64,
                sha256: sha,
                url: String::new(),
            }],
        };
        fs::write(
            tmp.join(MANIFEST_FILE),
            serde_json::to_string(&manifest).unwrap(),
        )
        .unwrap();
        fs::write(tmp.join("model.bin"), content).unwrap();

        // Build cache
        assert_eq!(
            model_status(&tmp, VerifyMode::Normal),
            ModelStatus::Installed
        );

        // Overwrite file with different content (same size, different sha, new mtime)
        // Use sleep to ensure mtime changes (filesystem granularity)
        std::thread::sleep(std::time::Duration::from_secs(1));
        fs::write(tmp.join("model.bin"), b"modified content").unwrap();

        // CacheOnly: mtime changed → cache invalid → returns false
        assert_ne!(
            model_status(&tmp, VerifyMode::CacheOnly),
            ModelStatus::Installed
        );

        // Normal: recomputes sha, finds mismatch
        assert_ne!(
            model_status(&tmp, VerifyMode::Normal),
            ModelStatus::Installed
        );

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn manifest_entry_path_accepts_normal_relative_names() {
        let base = Path::new("/base/models/m");
        assert_eq!(
            manifest_entry_path(base, "model.bin").unwrap(),
            base.join("model.bin")
        );
        assert_eq!(
            manifest_entry_path(base, "subdir/config.json").unwrap(),
            base.join("subdir/config.json")
        );
    }

    #[test]
    fn manifest_entry_path_rejects_traversal_and_absolute_names() {
        let base = Path::new("/base/models/m");
        assert!(manifest_entry_path(base, "../evil.bin").is_err());
        assert!(manifest_entry_path(base, "sub/../../evil.bin").is_err());
        assert!(manifest_entry_path(base, "/etc/passwd").is_err());
        assert!(manifest_entry_path(base, "./model.bin").is_err());
        assert!(manifest_entry_path(base, "").is_err());
    }

    #[test]
    fn validate_model_dir_rejects_parent_components() {
        assert!(validate_model_dir(Path::new("/home/u/.velikiy-moguchiy/models/../x")).is_err());
        assert!(validate_model_dir(Path::new("./models/x")).is_err());
        assert!(validate_model_dir(Path::new("/home/u/.velikiy-moguchiy/models/x")).is_ok());
    }

    #[test]
    fn remove_model_files_requires_parseable_manifest() {
        let tmp = std::env::temp_dir().join(format!(
            "velikiy-moguchiy-model-test-nomanifest-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&tmp).unwrap();
        fs::write(tmp.join("stray.bin"), b"data").unwrap();

        assert!(remove_model_files(&tmp).is_err());
        assert!(tmp.join("stray.bin").exists());

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn remove_model_files_refuses_traversal_entries_and_unlisted_files() {
        let tmp = std::env::temp_dir().join(format!(
            "velikiy-moguchiy-model-test-traversal-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let model_dir = tmp.join("model");
        fs::create_dir_all(&model_dir).unwrap();
        let victim = tmp.join("victim.txt");
        fs::write(&victim, b"do not delete").unwrap();

        let manifest = ModelManifest {
            provider: "test".into(),
            mode: None,
            description: "test".into(),
            repo: "test/model".into(),
            files: vec![ModelFile {
                name: "../victim.txt".into(),
                size: 13,
                sha256: String::new(),
                url: String::new(),
            }],
        };
        fs::write(
            model_dir.join(MANIFEST_FILE),
            serde_json::to_string(&manifest).unwrap(),
        )
        .unwrap();
        fs::write(model_dir.join("unlisted.bin"), b"stray").unwrap();

        assert!(remove_model_files(&model_dir).is_err());
        assert!(victim.exists());
        // Unlisted files are never swept by manifest-driven deletion.
        assert!(model_dir.join("unlisted.bin").exists());

        let _ = fs::remove_dir_all(&tmp);
    }

    #[cfg(unix)]
    #[test]
    fn remove_model_files_refuses_symlinked_entry_file() {
        let tmp = std::env::temp_dir().join(format!(
            "velikiy-moguchiy-model-test-symfile-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let model_dir = tmp.join("model");
        fs::create_dir_all(&model_dir).unwrap();
        let victim = tmp.join("victim.bin");
        fs::write(&victim, b"victim data").unwrap();
        std::os::unix::fs::symlink(&victim, model_dir.join("model.bin")).unwrap();

        let manifest = ModelManifest {
            provider: "test".into(),
            mode: None,
            description: "test".into(),
            repo: "test/model".into(),
            files: vec![ModelFile {
                name: "model.bin".into(),
                size: 11,
                sha256: String::new(),
                url: String::new(),
            }],
        };
        fs::write(
            model_dir.join(MANIFEST_FILE),
            serde_json::to_string(&manifest).unwrap(),
        )
        .unwrap();

        assert!(remove_model_files(&model_dir).is_err());
        // The external victim file must be untouched.
        assert_eq!(fs::read(&victim).unwrap(), b"victim data");

        let _ = fs::remove_dir_all(&tmp);
    }

    #[cfg(unix)]
    #[test]
    fn remove_model_files_refuses_symlinked_intermediate_dir() {
        let tmp = std::env::temp_dir().join(format!(
            "velikiy-moguchiy-model-test-symdir-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let model_dir = tmp.join("model");
        fs::create_dir_all(&model_dir).unwrap();
        let external = tmp.join("external");
        fs::create_dir_all(&external).unwrap();
        fs::write(external.join("config.json"), b"external").unwrap();
        std::os::unix::fs::symlink(&external, model_dir.join("subdir")).unwrap();

        let manifest = ModelManifest {
            provider: "test".into(),
            mode: None,
            description: "test".into(),
            repo: "test/model".into(),
            files: vec![ModelFile {
                name: "subdir/config.json".into(),
                size: 8,
                sha256: String::new(),
                url: String::new(),
            }],
        };
        fs::write(
            model_dir.join(MANIFEST_FILE),
            serde_json::to_string(&manifest).unwrap(),
        )
        .unwrap();

        assert!(remove_model_files(&model_dir).is_err());
        // The file behind the symlinked directory must be untouched.
        assert_eq!(fs::read(external.join("config.json")).unwrap(), b"external");
        assert!(external.exists());

        let _ = fs::remove_dir_all(&tmp);
    }

    #[cfg(unix)]
    #[test]
    fn symlinked_model_dir_under_root_is_rejected_for_mutation() {
        let tmp = std::env::temp_dir().join(format!(
            "velikiy-moguchiy-model-test-symroot-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let root = tmp.join("models");
        fs::create_dir_all(&root).unwrap();
        let outside = tmp.join("outside");
        fs::create_dir_all(&outside).unwrap();
        std::os::unix::fs::symlink(&outside, root.join("evil")).unwrap();

        // A model dir that lexically claims to be under the root but resolves
        // elsewhere is refused.
        assert!(canonical_dir_within_root(&root.join("evil"), &root).is_err());

        // A real directory under the root is accepted.
        let good = root.join("good");
        fs::create_dir_all(&good).unwrap();
        let canonical = canonical_dir_within_root(&good, &root).unwrap();
        assert!(canonical.starts_with(fs::canonicalize(&root).unwrap()));

        // Absolute model dirs outside the root stay supported (documented).
        assert!(canonical_dir_within_root(&outside, &root).is_ok());

        let _ = fs::remove_dir_all(&tmp);
    }

    #[cfg(unix)]
    #[test]
    fn mutation_target_containment_rejects_symlinked_part_and_entry_paths() {
        let tmp = std::env::temp_dir().join(format!(
            "velikiy-moguchiy-model-test-target-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let model_dir = tmp.join("model");
        fs::create_dir_all(&model_dir).unwrap();
        let victim = tmp.join("victim.part");
        fs::write(&victim, b"external part").unwrap();
        let canonical = fs::canonicalize(&model_dir).unwrap();

        // Symlinked final component (e.g. a planted .part file) is refused.
        std::os::unix::fs::symlink(&victim, canonical.join("model.bin.part")).unwrap();
        assert!(ensure_target_contained(&canonical, &canonical.join("model.bin.part")).is_err());

        // Regular file and not-yet-created targets are fine.
        fs::write(canonical.join("model.bin"), b"data").unwrap();
        assert!(ensure_target_contained(&canonical, &canonical.join("model.bin")).is_ok());
        assert!(ensure_target_contained(&canonical, &canonical.join("new.bin")).is_ok());
        assert!(ensure_target_contained(&canonical, &canonical.join("sub/new.bin")).is_ok());

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn cache_only_no_cache_file_does_not_panic() {
        // Simulates what scan_models_json does: CacheOnly on a model
        // directory that has never been verified (no .koe-checksum.json).
        let tmp = std::env::temp_dir().join(format!(
            "velikiy-moguchiy-model-test-nocache-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&tmp).unwrap();

        let content = b"installed model data";
        let sha = {
            let mut hasher = Sha256::new();
            hasher.update(content);
            hex_lower(&hasher.finalize())
        };
        let manifest = ModelManifest {
            provider: "test".into(),
            mode: None,
            description: "test".into(),
            repo: "test/model".into(),
            files: vec![ModelFile {
                name: "model.bin".into(),
                size: content.len() as u64,
                sha256: sha,
                url: String::new(),
            }],
        };
        fs::write(
            tmp.join(MANIFEST_FILE),
            serde_json::to_string(&manifest).unwrap(),
        )
        .unwrap();
        fs::write(tmp.join("model.bin"), content).unwrap();

        // No .koe-checksum.json exists
        assert!(!tmp.join(CHECKSUM_CACHE_FILE).exists());

        // CacheOnly should NOT panic — returns NotInstalled because
        // cache miss for files with sha256 in manifest
        let status = model_status(&tmp, VerifyMode::CacheOnly);
        assert_eq!(status, ModelStatus::NotInstalled);

        // No cache file should have been written
        assert!(!tmp.join(CHECKSUM_CACHE_FILE).exists());

        let _ = fs::remove_dir_all(&tmp);
    }

    // ─── Verification-path containment ──────────────────────────────

    fn unique_tmp(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "velikiy-moguchiy-model-test-{tag}-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    fn sha_of(bytes: &[u8]) -> String {
        let mut hasher = Sha256::new();
        hasher.update(bytes);
        hex_lower(&hasher.finalize())
    }

    fn write_manifest(model_dir: &Path, files: Vec<ModelFile>) {
        let manifest = ModelManifest {
            provider: "test".into(),
            mode: None,
            description: "test".into(),
            repo: "test/model".into(),
            files,
        };
        fs::write(
            model_dir.join(MANIFEST_FILE),
            serde_json::to_string(&manifest).unwrap(),
        )
        .unwrap();
    }

    /// Verification must not read a file the manifest points at outside the
    /// model dir. The manifest here declares the victim's real size and sha,
    /// so a verification that *did* follow the entry would report Installed.
    #[test]
    fn verification_refuses_traversal_and_absolute_manifest_entries() {
        let tmp = unique_tmp("verify-traversal");
        let model_dir = tmp.join("model");
        fs::create_dir_all(&model_dir).unwrap();

        let victim_content = b"secret file contents";
        let victim = tmp.join("victim.bin");
        fs::write(&victim, victim_content).unwrap();

        for name in ["../victim.bin", "./victim.bin", "sub/../../victim.bin"] {
            write_manifest(
                &model_dir,
                vec![ModelFile {
                    name: name.into(),
                    size: victim_content.len() as u64,
                    sha256: sha_of(victim_content),
                    url: String::new(),
                }],
            );
            for mode in [
                VerifyMode::Normal,
                VerifyMode::CacheOnly,
                VerifyMode::ForceVerify,
            ] {
                assert_eq!(
                    model_status(&model_dir, mode),
                    ModelStatus::NotInstalled,
                    "entry {name:?} in {mode:?} must not be read"
                );
            }
        }

        // Absolute manifest entries are refused the same way.
        write_manifest(
            &model_dir,
            vec![ModelFile {
                name: victim.to_string_lossy().into_owned(),
                size: victim_content.len() as u64,
                sha256: sha_of(victim_content),
                url: String::new(),
            }],
        );
        assert_eq!(
            model_status(&model_dir, VerifyMode::Normal),
            ModelStatus::NotInstalled
        );

        // Nothing was cached about the out-of-tree file.
        assert!(!model_dir.join(CHECKSUM_CACHE_FILE).exists());

        let _ = fs::remove_dir_all(&tmp);
    }

    /// A symlinked manifest entry is not dereferenced by verification, even
    /// though the link target matches the declared size and sha.
    #[cfg(unix)]
    #[test]
    fn verification_refuses_symlinked_manifest_entry() {
        let tmp = unique_tmp("verify-symlink-entry");
        let model_dir = tmp.join("model");
        fs::create_dir_all(&model_dir).unwrap();

        let victim_content = b"outside the model dir";
        let victim = tmp.join("victim.bin");
        fs::write(&victim, victim_content).unwrap();
        std::os::unix::fs::symlink(&victim, model_dir.join("model.bin")).unwrap();

        write_manifest(
            &model_dir,
            vec![ModelFile {
                name: "model.bin".into(),
                size: victim_content.len() as u64,
                sha256: sha_of(victim_content),
                url: String::new(),
            }],
        );

        assert_eq!(
            model_status(&model_dir, VerifyMode::Normal),
            ModelStatus::NotInstalled
        );
        assert_eq!(
            model_status(&model_dir, VerifyMode::ForceVerify),
            ModelStatus::NotInstalled
        );

        let _ = fs::remove_dir_all(&tmp);
    }

    /// Hashing refuses anything that is not a regular file, so a character
    /// device such as `/dev/zero` can never be read unbounded.
    #[cfg(unix)]
    #[test]
    fn sha256_file_refuses_non_regular_files() {
        let err = sha256_file(Path::new("/dev/zero")).unwrap_err();
        assert!(format!("{err}").contains("not a regular file"), "{err}");

        let tmp = unique_tmp("sha-nonregular");
        fs::create_dir_all(&tmp).unwrap();
        assert!(sha256_file(&tmp).is_err());

        // Regular files still hash.
        fs::write(tmp.join("f.bin"), b"abc").unwrap();
        assert_eq!(sha256_file(&tmp.join("f.bin")).unwrap(), sha_of(b"abc"));

        let _ = fs::remove_dir_all(&tmp);
    }

    /// A symlink planted at `.koe-checksum.json` must not be followed: the
    /// victim it points at stays byte-for-byte intact, and verification of the
    /// (well-formed) model still succeeds.
    #[cfg(unix)]
    #[test]
    fn verification_does_not_follow_symlinked_checksum_cache() {
        let tmp = unique_tmp("verify-cache-symlink");
        let model_dir = tmp.join("model");
        fs::create_dir_all(&model_dir).unwrap();

        let victim_content = b"important data that must survive verification";
        let victim = tmp.join("victim.txt");
        fs::write(&victim, victim_content).unwrap();
        std::os::unix::fs::symlink(&victim, model_dir.join(CHECKSUM_CACHE_FILE)).unwrap();

        let content = b"valid model content";
        fs::write(model_dir.join("model.bin"), content).unwrap();
        write_manifest(
            &model_dir,
            vec![ModelFile {
                name: "model.bin".into(),
                size: content.len() as u64,
                sha256: sha_of(content),
                url: String::new(),
            }],
        );

        // Verification still works…
        assert_eq!(
            model_status(&model_dir, VerifyMode::Normal),
            ModelStatus::Installed
        );
        // …and the victim was neither truncated nor overwritten.
        assert_eq!(fs::read(&victim).unwrap(), victim_content);
        // The planted link is still a link — nothing was written through it.
        assert!(fs::symlink_metadata(model_dir.join(CHECKSUM_CACHE_FILE))
            .unwrap()
            .file_type()
            .is_symlink());

        // The direct writer refuses too, rather than silently succeeding.
        assert!(
            write_checksum_cache(&model_dir.join(CHECKSUM_CACHE_FILE), &HashMap::new()).is_err()
        );
        assert_eq!(fs::read(&victim).unwrap(), victim_content);

        let _ = fs::remove_dir_all(&tmp);
    }

    /// Well-formed models still verify, and the cache is still both consulted
    /// and written: a planted entry with the file's real mtime but a wrong sha
    /// changes the Normal-mode answer, which is only possible if it was read.
    #[test]
    fn well_formed_model_verifies_and_still_uses_the_cache() {
        let tmp = unique_tmp("verify-cache-reuse");
        fs::create_dir_all(&tmp).unwrap();

        let content = b"valid model content";
        fs::write(tmp.join("model.bin"), content).unwrap();
        write_manifest(
            &tmp,
            vec![ModelFile {
                name: "model.bin".into(),
                size: content.len() as u64,
                sha256: sha_of(content),
                url: String::new(),
            }],
        );

        // Normal computes and writes the cache back.
        assert_eq!(
            model_status(&tmp, VerifyMode::Normal),
            ModelStatus::Installed
        );
        let cache_path = tmp.join(CHECKSUM_CACHE_FILE);
        assert!(fs::symlink_metadata(&cache_path)
            .unwrap()
            .file_type()
            .is_file());
        let cached = load_checksum_cache(&cache_path).unwrap();
        assert_eq!(cached.get("model.bin").unwrap().sha256, sha_of(content));
        // No temp file left behind by the atomic write.
        let leftovers: Vec<_> = fs::read_dir(&tmp)
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().contains(".tmp."))
            .collect();
        assert!(leftovers.is_empty());

        // CacheOnly can now answer without hashing.
        assert_eq!(
            model_status(&tmp, VerifyMode::CacheOnly),
            ModelStatus::Installed
        );

        // Poison the cache with the real mtime but a wrong hash: Normal must
        // trust it (proving it is read), ForceVerify must ignore it.
        let meta = fs::metadata(tmp.join("model.bin")).unwrap();
        let mut poisoned = HashMap::new();
        poisoned.insert(
            "model.bin".to_string(),
            ChecksumEntry {
                mtime: mtime_secs(&meta),
                sha256: "0".repeat(64),
            },
        );
        write_checksum_cache(&cache_path, &poisoned).unwrap();
        assert_eq!(
            model_status(&tmp, VerifyMode::Normal),
            ModelStatus::NotInstalled
        );
        assert_eq!(
            model_status(&tmp, VerifyMode::ForceVerify),
            ModelStatus::Installed
        );
        // ForceVerify wrote the correct hash back.
        assert_eq!(
            load_checksum_cache(&cache_path)
                .unwrap()
                .get("model.bin")
                .unwrap()
                .sha256,
            sha_of(content)
        );

        let _ = fs::remove_dir_all(&tmp);
    }

    /// Serves `files` (URL path -> body) over HTTP on 127.0.0.1 until the test ends.
    fn serve(files: Vec<(&'static str, Vec<u8>)>) -> String {
        use std::io::{BufRead, BufReader, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut request_line = String::new();
                if reader.read_line(&mut request_line).is_err() {
                    continue;
                }
                loop {
                    let mut header = String::new();
                    if reader.read_line(&mut header).unwrap_or(0) == 0 || header == "\r\n" {
                        break;
                    }
                }
                let path = request_line.split_whitespace().nth(1).unwrap_or("").to_string();
                let mut stream = stream;
                match files.iter().find(|(p, _)| *p == path) {
                    Some((_, body)) => {
                        let head = format!(
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            body.len()
                        );
                        let _ = stream.write_all(head.as_bytes());
                        let _ = stream.write_all(body);
                    }
                    None => {
                        let _ = stream.write_all(
                            b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                        );
                    }
                }
            }
        });
        base
    }

    fn sha_hex(data: &[u8]) -> String {
        hex_lower(&Sha256::digest(data))
    }

    fn download_dir(name: &str, files: Vec<ModelFile>) -> PathBuf {
        let tmp = std::env::temp_dir().join(format!(
            "velikiy-moguchiy-download-{name}-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&tmp).unwrap();
        let manifest = ModelManifest {
            provider: "lips".into(),
            mode: None,
            description: "download test".into(),
            repo: "test/model".into(),
            files,
        };
        fs::write(tmp.join(MANIFEST_FILE), serde_json::to_string(&manifest).unwrap()).unwrap();
        tmp
    }

    fn run_download(dir: &Path) -> Result<()> {
        tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(download_model(dir, |_| {}, CancellationToken::new()))
    }

    #[test]
    fn download_saves_verified_files_under_manifest_names() {
        let lora = b"lora weights".to_vec();
        let venc = b"visual front-end".to_vec();
        let base = serve(vec![
            ("/releases/velikiy-moguchiy-lips-0.1.pt", lora.clone()),
            ("/releases/velikiy-moguchiy-lips-0.1-venc.pth", venc.clone()),
        ]);
        let dir = download_dir(
            "ok",
            vec![
                ModelFile {
                    name: "best.pt".into(),
                    size: lora.len() as u64,
                    sha256: sha_hex(&lora),
                    url: format!("{base}/releases/velikiy-moguchiy-lips-0.1.pt"),
                },
                ModelFile {
                    name: "sub/best_venc.pth".into(),
                    size: venc.len() as u64,
                    sha256: sha_hex(&venc),
                    url: format!("{base}/releases/velikiy-moguchiy-lips-0.1-venc.pth"),
                },
            ],
        );

        run_download(&dir).unwrap();

        assert_eq!(fs::read(dir.join("best.pt")).unwrap(), lora);
        assert_eq!(fs::read(dir.join("sub/best_venc.pth")).unwrap(), venc);
        assert!(!dir.join("best.pt.part").exists());
        assert_eq!(model_status(&dir, VerifyMode::ForceVerify), ModelStatus::Installed);
        // A second run finds everything in place and downloads nothing.
        run_download(&dir).unwrap();
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn download_with_wrong_hash_keeps_nothing() {
        let served = b"tampered model".to_vec();
        let base = serve(vec![("/model.pth", served.clone())]);
        let dir = download_dir(
            "bad-hash",
            vec![ModelFile {
                name: "model.pth".into(),
                size: served.len() as u64,
                sha256: sha_hex(b"the model the manifest promised"),
                url: format!("{base}/model.pth"),
            }],
        );

        let err = run_download(&dir).unwrap_err().to_string();

        assert!(err.contains("sha256 mismatch"), "{err}");
        assert!(!dir.join("model.pth").exists());
        assert!(!dir.join("model.pth.part").exists());
        assert_eq!(model_status(&dir, VerifyMode::Normal), ModelStatus::NotInstalled);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn download_reports_a_missing_file() {
        let base = serve(vec![]);
        let dir = download_dir(
            "missing",
            vec![ModelFile {
                name: "model.pth".into(),
                size: 4,
                sha256: sha_hex(b"data"),
                url: format!("{base}/gone.pth"),
            }],
        );

        assert!(run_download(&dir).is_err());
        assert!(!dir.join("model.pth").exists());
        let _ = fs::remove_dir_all(&dir);
    }
}
