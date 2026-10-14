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
///   lips/federated/               the «Помочь обучить» client from the app bundle (its packages are in uv.lock)
///   models/lips/multivsr/         MultiVSR model.pth + feature_extractor.pth (from the authors)
///   models/lips/releases/<tag>/   best.pt + best_venc.pth of a lips-* release
///   models/lips/tools/            the uv and MultiVSR code archives
///
/// The links give the service the same layout as a lipread checkout, so it
/// runs unchanged. A developer's lipread folder (serviceDirectory) replaces
/// all of this.
@interface SPLipsRuntime : NSObject

+ (instancetype)sharedRuntime;

/// Downloads go through the core's model downloader.
@property (nonatomic, weak, nullable) SPRustBridge *rustBridge;

/// Extra folder for the service's PATH (ffmpeg), nil for a developer checkout.
- (nullable NSString *)binDirectory;

/// The lipread folder every lips feature runs from (the service, «Обучить на
/// мне», community training): `lips.service_dir`, else the lipread folder of
/// the source tree a local build came from when it has its .venv, else the
/// managed environment.
- (NSString *)serviceDirectory;

/// The federated client folder for «Помочь обучить»: federated/ next to a developer's
/// lipread folder, else the managed copy (lips/federated) the setup makes from the app.
- (NSString *)federatedDirectory;

/// YES when serviceDirectory is a developer's lipread folder, not the managed one.
- (BOOL)usesDeveloperCheckout;

/// The service can start: a developer checkout, or the managed environment
/// is complete for this build of the app.
- (BOOL)isReady;

/// Tag of the installed lips-* release, nil before the first setup.
- (nullable NSString *)installedReleaseTag;

@property (nonatomic, readonly) BOOL isInstalling;

/// The user answered «Не сейчас» to the setup offer; the key press then only
/// points at the settings, where offerSetupWithCompletion: is still available.
@property (nonatomic, readonly) BOOL setupDeclined;

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
