#import <Foundation/Foundation.h>

@class SPRustBridge;

NS_ASSUME_NONNULL_BEGIN

/// The environment the lips service runs from on a Mac without a developer
/// checkout, kept in the app's data folder:
///
///   lips/service/                 lipread code from the app bundle, multivsr/, .venv/ (uv),
///                                 weights -> models/lips/multivsr,
///                                 results/pod_runs/t1/checkpoints/me1 -> models/lips/releases/<tag>
///   lips/tools/, lips/python/     uv and the Python it installs
///   models/lips/multivsr/         MultiVSR model.pth + feature_extractor.pth (from the authors)
///   models/lips/releases/<tag>/   best.pt + best_venc.pth of a lips-* release
///   models/lips/tools/            the uv and MultiVSR code archives
///
/// The links give the service the same layout as a lipread checkout, so it
/// runs unchanged. `lips.service_dir` points the app at a developer checkout
/// instead, and then nothing here is used.
@interface SPLipsRuntime : NSObject

+ (instancetype)sharedRuntime;

/// Downloads go through the core's model downloader.
@property (nonatomic, weak, nullable) SPRustBridge *rustBridge;

/// The folder lips_service.py runs from.
- (NSString *)serviceDirectory;

/// Extra folder for the service's PATH (ffmpeg), nil for a developer checkout.
- (nullable NSString *)binDirectory;

/// YES when `lips.service_dir` is set.
- (BOOL)usesDeveloperCheckout;

/// The service can start: a developer checkout, or the managed environment
/// is complete for this build of the app.
- (BOOL)isReady;

/// Tag of the installed lips-* release, nil before the first setup.
- (nullable NSString *)installedReleaseTag;

@property (nonatomic, readonly) BOOL isInstalling;

/// Explains what will be downloaded, asks, then installs with a progress
/// window. When only the environment is out of date (a new app build) it
/// rebuilds without asking. The completion runs on the main queue.
- (void)offerSetupWithCompletion:(nullable void (^)(BOOL ready))completion;

/// At most once a day, and only once the lips mode is installed: looks for a
/// newer lips-* release and calls the handler on the main queue with its tag.
- (void)checkForModelUpdateWithHandler:(void (^)(NSString *tag))handler;

/// Asks to install the newer release found by the check, then downloads it
/// and switches the service over. The completion runs on the main queue.
- (void)offerModelUpdate:(NSString *)tag completion:(nullable void (^)(BOOL updated))completion;

@end

NS_ASSUME_NONNULL_END
