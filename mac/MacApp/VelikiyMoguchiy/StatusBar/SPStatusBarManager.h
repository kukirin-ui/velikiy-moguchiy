#import <Cocoa/Cocoa.h>

@class SPPermissionManager;
@class SPAudioDeviceManager;

@protocol SPStatusBarDelegate <NSObject>
@optional
- (void)statusBarDidSelectReloadConfig;
- (void)statusBarDidSelectQuit;
- (void)statusBarDidSelectSetupWizard;
/// "Начало работы…".
- (void)statusBarDidSelectOnboarding;
- (void)statusBarDidSelectRecentDictations;
- (void)statusBarMenuDidOpen;
- (void)statusBarMenuDidClose;
- (void)statusBarDidSelectAudioDeviceWithUID:(nullable NSString *)uid;
/// Start a hands-free session when idle, end the running one while recording.
- (void)statusBarDidSelectToggleVoiceInput;
/// "Ещё ▸ Отменить последнюю вставку".
- (void)statusBarDidSelectUndoLastInsertion;
/// "Ещё ▸ Вставить последнюю диктовку".
- (void)statusBarDidSelectRepasteLastDictation;
/// A mode picked in "Ещё ▸ Режим текста": raw, light, structured or formal.
- (void)statusBarDidSelectOutputMode:(nullable NSString *)mode;
/// "Сообщить о проблеме…".
- (void)statusBarDidSelectReportProblem;
/// "Доступна новая версия …".
- (void)statusBarDidSelectAppUpdate;
/// "Обновить модель губ до …".
- (void)statusBarDidSelectLipsModelUpdate;
@end

NS_ASSUME_NONNULL_BEGIN

@interface SPStatusBarManager : NSObject <NSMenuDelegate>

- (instancetype)initWithDelegate:(nullable id<SPStatusBarDelegate>)delegate
               permissionManager:(SPPermissionManager *)permissionManager
              audioDeviceManager:(SPAudioDeviceManager *)audioDeviceManager;

/// Builds the menu without a status item (design preview).
- (instancetype)initMenuOnlyWithPermissionManager:(SPPermissionManager *)permissionManager
                               audioDeviceManager:(SPAudioDeviceManager *)audioDeviceManager;

@property (nonatomic, readonly) NSMenu *menu;

/// The menu's items drawn as a static view on menu material, for screenshots:
/// the custom views are the real ones, standard rows are approximated.
- (NSView *)designPreviewView;

/// Update the status bar icon and status text.
/// state: "idle", "recording_hold", "recording_toggle", "connecting_asr",
///        "finalizing_asr", "correcting", "preparing_paste", "pasting", "error", "completed"
- (void)updateState:(NSString *)state;

/// Shows "Доступна новая версия …" at the top of the menu; nil hides it.
- (void)showAppUpdateVersion:(nullable NSString *)version;

/// Shows "Обновить модель губ до …"; nil hides it.
- (void)showLipsModelUpdate:(nullable NSString *)tag;

@end

NS_ASSUME_NONNULL_END
