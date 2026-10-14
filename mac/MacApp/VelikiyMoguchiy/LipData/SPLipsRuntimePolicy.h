#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Where the lips mode gets everything it needs on a Mac without a developer
/// checkout, as model manifests for the core's downloader (sha256-checked,
/// resumable): the MultiVSR base model from its authors, our fine-tuned weights
/// from a `lips-*` release of velikiy-moguchiy-models, and the tools that build
/// the service's Python environment. Pure: no network, no disk.
@interface SPLipsRuntimePolicy : NSObject

/// GitHub repository of the released lips models.
@property (class, nonatomic, readonly) NSString *modelsRepository;
/// Tag prefix of the lips model releases.
@property (class, nonatomic, readonly) NSString *releaseTagPrefix;

/// MultiVSR's model.pth and feature_extractor.pth from the authors (about 4.5 GB).
+ (NSDictionary *)baseModelManifest;

/// uv (builds the Python environment) and the MultiVSR code at the commit
/// lipread/multivsr_compat.py expects.
+ (NSDictionary *)toolsManifest;

/// File name of the uv archive and of the MultiVSR code archive in toolsManifest.
@property (class, nonatomic, readonly) NSString *uvArchiveName;
@property (class, nonatomic, readonly) NSString *multivsrArchiveName;
/// The folder the MultiVSR archive unpacks into.
@property (class, nonatomic, readonly) NSString *multivsrArchiveRoot;

/// `sha256  name` lines of a SHA256SUMS.txt -> name: lower-case hex. Nil when
/// a non-empty line is malformed.
+ (nullable NSDictionary<NSString *, NSString *> *)sha256SumsFromText:(nullable NSString *)text;

/// Manifest of a `lips-*` release: its LoRA (`*.pt`) saved as best.pt and its
/// visual front-end (`*-venc.pth`) as best_venc.pth, the names the service
/// reads. Every file needs a hash in SHA256SUMS.txt that agrees with the digest
/// GitHub reports, and a download URL inside the models repository. Nil, with
/// a reason, otherwise.
+ (nullable NSDictionary *)modelManifestForRelease:(NSDictionary *)release
                                        sha256Sums:(NSDictionary<NSString *, NSString *> *)sums
                                             error:(NSString *_Nullable *_Nullable)error;

/// Hugging Face mirror of the released lips models, tried before GitHub.
@property (class, nonatomic, readonly) NSString *huggingFaceRepository;

/// Manifest of the newest lips model in the Hugging Face mirror, from its
/// model info (`GET /api/models/{repo}?blobs=true`) and SHA256SUMS.txt: both
/// files of one version, each with a hash in SHA256SUMS.txt that agrees with
/// the LFS hash Hugging Face reports, downloaded at the info's revision.
/// `tag` gets the matching release tag ("lips-0.1"). Nil, with a reason,
/// otherwise.
+ (nullable NSDictionary *)huggingFaceManifestFromModelInfo:(NSDictionary *)info
                                                 sha256Sums:(NSDictionary<NSString *, NSString *> *)sums
                                                        tag:(NSString *_Nullable *_Nullable)tag
                                                      error:(NSString *_Nullable *_Nullable)error;

/// Whether two manifests list the same files (names, sizes, hashes), so one
/// can stand in for the other when its source is unreachable.
+ (BOOL)manifest:(nullable NSDictionary *)manifest hasSameFilesAs:(nullable NSDictionary *)other;

/// A folder name for a release tag, or nil when the tag has characters that
/// do not belong in one.
+ (nullable NSString *)directoryNameForTag:(nullable NSString *)tag;

/// `lips.service_dir` (a developer's lipread checkout) when set, else the
/// environment the app manages.
+ (NSString *)serviceDirectoryForOverride:(nullable NSString *)overridePath
                         managedDirectory:(NSString *)managedDirectory;

/// Free disk space the first setup needs: the downloads, the Python
/// environment and a margin.
+ (unsigned long long)requiredFreeBytes;

@end

NS_ASSUME_NONNULL_END
