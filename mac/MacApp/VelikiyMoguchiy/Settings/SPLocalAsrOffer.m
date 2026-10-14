#import "SPLocalAsrOffer.h"
#import <Cocoa/Cocoa.h>
#import "SPLocalAsrPolicy.h"
#import "SPProgressPanel.h"
#import "SPRustBridge.h"
#import "velikiy_moguchiy_core.h"

/// «Не сейчас» is final: a user without a key who wants it later picks a local model in the settings.
static NSString *const kDeclinedKey = @"SPLocalAsrOfferDeclined";

static NSDictionary *asrConfig(void) {
    char *raw = sp_config_get_json("asr");
    if (!raw) return @{};
    NSData *data = [NSData dataWithBytes:raw length:strlen(raw)];
    sp_core_free_string(raw);
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:[NSDictionary class]] ? json : @{};
}

static NSString *providerTitle(NSString *provider) {
    NSDictionary *titles = @{@"qwen" : @"Qwen (DashScope)", @"doubao" : @"Doubao", @"glm" : @"GLM", @"mimo" : @"MiMo"};
    return titles[provider] ?: provider;
}

@interface SPLocalAsrOffer ()
@property (nonatomic, weak) SPRustBridge *rustBridge;
@property (nonatomic) BOOL offeredThisLaunch;
@property (nonatomic) BOOL busy;
@property (nonatomic, strong, nullable) SPProgressPanel *panel;
@end

@implementation SPLocalAsrOffer

- (instancetype)initWithRustBridge:(SPRustBridge *)rustBridge {
    self = [super init];
    if (self) _rustBridge = rustBridge;
    return self;
}

- (void)offerIfNeeded {
    if (self.busy || self.offeredThisLaunch) return;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kDeclinedKey]) return;
    NSDictionary *asr = asrConfig();
    NSArray<NSString *> *supported = [self.rustBridge supportedLocalProviders];
    if (![SPLocalAsrPolicy shouldOfferLocalAsrWithAsrConfig:asr supportedLocalProviders:supported]) return;
    NSDictionary<NSString *, NSString *> *choice = [SPLocalAsrPolicy localChoiceForSupportedProviders:supported];
    self.offeredThisLaunch = YES;

    NSString *provider = [asr[@"provider"] isKindOfClass:[NSString class]] ? asr[@"provider"] : @"qwen";
    BOOL mlx = [choice[@"provider"] isEqualToString:@"mlx"];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Нет ключа распознавания";
    alert.informativeText = [NSString stringWithFormat:
        @"Выбрано облачное распознавание %@, но ключа для него нет, поэтому диктовка не сработает.\n\n"
        @"Можно распознавать речь прямо на этом Mac: модель %@ скачается один раз, звук никуда не уходит. "
        @"Облачное распознавание точнее; ключ можно указать в настройках в любой момент.",
        providerTitle(provider),
        mlx ? @"Qwen3-ASR (около 0,7 ГБ)" : @"Vosk для русского языка (около 30 МБ)"];
    [alert addButtonWithTitle:@"Скачать и включить"];
    [alert addButtonWithTitle:@"Указать ключ…"];
    [alert addButtonWithTitle:@"Не сейчас"];
    [NSApp activateIgnoringOtherApps:YES];
    NSModalResponse response = [alert runModal];
    if (response == NSAlertSecondButtonReturn) {
        if (self.openSettingsHandler) self.openSettingsHandler();
        return;
    }
    if (response != NSAlertFirstButtonReturn) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kDeclinedKey];
        return;
    }
    [self downloadAndSwitchTo:choice];
}

+ (NSDictionary *)currentAsrConfig {
    return asrConfig();
}

- (BOOL)canSwitchToLocalAsr {
    return [SPLocalAsrPolicy shouldOfferLocalAsrWithAsrConfig:asrConfig()
                                      supportedLocalProviders:[self.rustBridge supportedLocalProviders]];
}

- (void)switchToLocalAsrOnUserRequest {
    if (self.busy || ![self canSwitchToLocalAsr]) return;
    [self downloadAndSwitchTo:[SPLocalAsrPolicy
                                  localChoiceForSupportedProviders:[self.rustBridge supportedLocalProviders]]];
}

- (void)downloadAndSwitchTo:(NSDictionary<NSString *, NSString *> *)choice {
    NSString *model = choice[@"model"];
    SPRustBridge *bridge = self.rustBridge;
    self.busy = YES;
    SPProgressPanel *panel = [[SPProgressPanel alloc] initWithTitle:@"Локальное распознавание"];
    panel.cancelHandler = ^{
        [bridge cancelDownload:model];
    };
    self.panel = panel;
    [panel setStep:@"Загрузка модели распознавания" detail:nil];
    [panel present];

    NSMutableDictionary<NSString *, NSNumber *> *perFile = [NSMutableDictionary dictionary];
    uint64_t total = 0;
    for (NSDictionary *entry in [bridge scanModels]) {
        if ([entry[@"path"] isEqual:model]) total = [entry[@"total_size"] unsignedLongLongValue];
    }
    void (^finish)(BOOL, NSString *) = ^(BOOL ok, NSString *message) {
        self.busy = NO;
        if (!ok) {
            NSLog(@"[VelikiyMoguchiy] local ASR model download failed: %@", message);
            BOOL cancelled = [message containsString:@"cancelled"];
            [panel finishWithMessage:cancelled ? @"Загрузка остановлена. Распознавание не менялось."
                                               : @"Не получилось скачать модель. Проверьте интернет и попробуйте снова."
                             success:NO];
            return;
        }
        // A key added while the model was downloading is the user's choice; keep it.
        if (![SPLocalAsrPolicy shouldOfferLocalAsrWithAsrConfig:asrConfig()
                                        supportedLocalProviders:[bridge supportedLocalProviders]]) {
            [panel finishWithMessage:@"Модель скачана. Распознавание не менялось: ключ уже задан." success:YES];
            return;
        }
        NSString *provider = choice[@"provider"];
        NSString *modelKey = [NSString stringWithFormat:@"asr.%@.model", provider];
        BOOL saved = sp_config_set(modelKey.UTF8String, model.UTF8String) == 0 &&
                     sp_config_set("asr.provider", provider.UTF8String) == 0;
        if (!saved) {
            [panel finishWithMessage:@"Модель скачана, но настройки не сохранились." success:NO];
            return;
        }
        NSLog(@"[VelikiyMoguchiy] switched ASR to the local %@ model %@ (no cloud key)", provider, model);
        if (self.configChangedHandler) self.configChangedHandler();
        [panel finishWithMessage:@"Готово: речь распознаётся на этом Mac." success:YES];
    };
    if ([bridge modelStatus:model mode:SPModelVerifyNormal] == 2) {
        finish(YES, @"");
        return;
    }
    [bridge downloadModel:model
        progress:^(NSUInteger fileIndex, NSUInteger fileCount, uint64_t downloaded, uint64_t fileTotal, NSString *filename) {
            perFile[filename] = @(downloaded);
            uint64_t sum = 0;
            for (NSNumber *bytes in perFile.allValues) sum += bytes.unsignedLongLongValue;
            NSString *detail = [NSString stringWithFormat:@"%@ из %@ (файл %lu из %lu)",
                [NSByteCountFormatter stringFromByteCount:(long long)sum countStyle:NSByteCountFormatterCountStyleFile],
                [NSByteCountFormatter stringFromByteCount:(long long)total countStyle:NSByteCountFormatterCountStyleFile],
                (unsigned long)fileIndex + 1, (unsigned long)fileCount];
            [panel setStep:@"Загрузка модели распознавания" detail:detail];
            [panel setProgress:total > 0 ? (double)sum / (double)total : -1];
        }
        completion:finish];
}

@end
