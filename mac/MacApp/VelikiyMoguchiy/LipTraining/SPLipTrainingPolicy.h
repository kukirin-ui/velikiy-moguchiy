#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPLipTrainingMode) {
    /// train.py on frozen lip features: minutes.
    SPLipTrainingModeLight = 0,
    /// train_e2e.py, the visual front-end learns too: hours.
    SPLipTrainingModeFull = 1,
};

/// Pure decisions and Russian texts of «Обучить на мне» (lipread/train_on_me.py),
/// apart from the processes and the view so they can be unit tested. `scan` is
/// the JSON of `train_on_me.py scan`, `status` the job's lips_training/status.json.
@interface SPLipTrainingPolicy : NSObject

/// "light" / "full", as train_on_me.py --mode takes it.
+ (NSString *)modeArgument:(SPLipTrainingMode)mode;

/// Arguments of `python train_on_me.py <command>`; `--mode` only for "run".
+ (NSArray<NSString *> *)argumentsWithScript:(NSString *)scriptPath
                                     command:(NSString *)command
                                        mode:(SPLipTrainingMode)mode
                                     appData:(NSString *)appDataDirectory
                                    clipsDir:(NSString *)clipsDirectory;

/// A status that says "running" while its process is gone is a job that died
/// without writing its end: it reads as failed.
+ (nullable NSDictionary *)effectiveStatus:(nullable NSDictionary *)status processAlive:(BOOL)alive;

+ (BOOL)isRunningStatus:(nullable NSDictionary *)status;

/// The button is enabled: the scan says ready and no job is running.
+ (BOOL)canStartWithScan:(nullable NSDictionary *)scan status:(nullable NSDictionary *)status;

/// Why the button is disabled (nil when it is not, or while a job runs).
+ (nullable NSString *)blockerForScan:(nullable NSDictionary *)scan;

/// "Пригодно для обучения: 143 клипа, 9,5 минуты (из 160 записанных)".
+ (NSString *)clipsLineForScan:(nullable NSDictionary *)scan;

/// "Сейчас: Ваша модель от 14.10.2026 (лёгкий режим), ошибка 70,2% (была 74,1%)".
+ (NSString *)modelLineForScan:(nullable NSDictionary *)scan;

/// "Прежняя: Исходная модель", or nil when there is nothing to roll back to.
+ (nullable NSString *)rollbackHintForScan:(nullable NSDictionary *)scan;

/// The scan's time estimate of a mode ("≈ 1 ч 50 мин"), nil without one.
+ (nullable NSString *)estimateText:(SPLipTrainingMode)mode scan:(nullable NSDictionary *)scan;

/// "Лёгкий · ≈ 7 мин" for the mode switch.
+ (NSString *)modeTitle:(SPLipTrainingMode)mode scan:(nullable NSDictionary *)scan;
+ (NSString *)modeDescription:(SPLipTrainingMode)mode;

/// Overall progress 0…1 of a running job.
+ (double)progressForStatus:(nullable NSDictionary *)status;

/// "Обучение — 42%, осталось ≈ 6 мин"; a guard pause says so. Empty when not running.
/// The ETA in the status is as of its `updated_at`; `now` counts down from it.
+ (NSString *)progressLineForStatus:(nullable NSDictionary *)status now:(NSDate *)now;

/// The outcome of the last job (done, failed or cancelled), nil while running or none.
+ (nullable NSString *)resultLineForStatus:(nullable NSDictionary *)status;

/// The job's end installed a new model (the lips service should reload).
+ (BOOL)statusInstalledModel:(nullable NSDictionary *)status;

/// "меньше минуты", "≈ 12 мин", "≈ 1 ч 50 мин" (hours to the nearest 10 minutes).
+ (NSString *)durationText:(double)seconds;

/// 0.741 -> "74,1%".
+ (NSString *)percentText:(double)fraction;

@end

NS_ASSUME_NONNULL_END
