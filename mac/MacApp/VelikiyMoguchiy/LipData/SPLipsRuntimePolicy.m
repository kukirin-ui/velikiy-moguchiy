#import "SPLipsRuntimePolicy.h"
#import "SPUpdatePolicy.h"

static NSString *const kModelsRepository = @"zigansh1n/velikiy-moguchiy-models";
static NSString *const kHuggingFaceRepository = @"z1gansh1n/velikiy-moguchiy-lips";
static NSString *const kAssetPrefix = @"velikiy-moguchiy-lips-";
/// The public half of FL_MODEL_SIGNING_KEY, as in federated/client/community_defaults.py.
static NSString *const kSigningPublicKey = @"MqbG8ht29PUCKCdki4D6yfi6OJuovhXwC6EN44QWtag=";
static NSString *const kSignatureDomain = @"velikiy-moguchiy/lips-release/v1\n";
static NSString *const kMultivsrCommit = @"af28d8c4b687ee7e41942732eb240e0cdfff3ccd";
static NSString *const kUvVersion = @"0.12.19";
/// Python, torch and the other packages of lipread/uv.lock, with uv's cache.
static const unsigned long long kEnvironmentBytes = 3ull * 1000 * 1000 * 1000;
static const unsigned long long kMarginBytes = 1ull * 1000 * 1000 * 1000;

static NSDictionary *fileEntry(NSString *name, unsigned long long size, NSString *sha256, NSString *url) {
    return @{@"name" : name, @"size" : @(size), @"sha256" : sha256, @"url" : url};
}

@implementation SPLipsRuntimePolicy

+ (NSString *)modelsRepository {
    return kModelsRepository;
}

+ (NSString *)huggingFaceRepository {
    return kHuggingFaceRepository;
}

+ (NSString *)signingPublicKey {
    return kSigningPublicKey;
}

+ (NSString *)signatureFileName {
    return @"SHA256SUMS.txt.sig";
}

+ (NSData *)signedMessageForTag:(NSString *)tag sha256Sums:(NSData *)sums {
    NSMutableData *message = [[[NSString stringWithFormat:@"%@%@\n", kSignatureDomain, tag]
        dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [message appendData:sums ?: [NSData data]];
    return message;
}

+ (BOOL)signatureRequiredForTag:(NSString *)tag {
    NSString *version = [SPUpdatePolicy versionFromTag:tag prefix:self.releaseTagPrefix];
    return !version || [SPUpdatePolicy compareVersion:version toVersion:@"0.1"] == NSOrderedDescending;
}

+ (NSString *)releaseTagPrefix {
    return @"lips-";
}

+ (NSString *)uvArchiveName {
    return @"uv-aarch64-apple-darwin.tar.gz";
}

+ (NSString *)multivsrArchiveName {
    return @"multivsr.tar.gz";
}

+ (NSString *)multivsrArchiveRoot {
    return [@"multivsr-" stringByAppendingString:kMultivsrCommit];
}

+ (NSDictionary *)baseModelManifest {
    return @{
        @"provider" : @"lips",
        @"description" : @"MultiVSR (Oxford VGG), the base lip-reading model",
        @"repo" : @"https://github.com/Sindhu-Hegde/multivsr",
        @"files" : @[
            fileEntry(@"model.pth", 3374308500ull,
                      @"cd89f095cb3c653bacea5d18155b2235d78f9c36bd001db7aef60cca2a0cbf2c",
                      @"https://www.robots.ox.ac.uk/~vgg/research/multivsr/model.pth"),
            fileEntry(@"feature_extractor.pth", 1079529003ull,
                      @"3c822d0ec5a6d3f9abd9f2aac86eb73ec6af0eb8795bc7438ec205013a97125c",
                      @"https://www.robots.ox.ac.uk/~vgg/research/vtp-for-lip-reading/checkpoints/"
                      @"extended_train_data/feature_extractor.pth"),
        ],
    };
}

+ (NSDictionary *)toolsManifest {
    NSString *uvURL = [NSString stringWithFormat:@"https://github.com/astral-sh/uv/releases/download/%@/%@",
                                                 kUvVersion, self.uvArchiveName];
    NSString *codeURL = [NSString stringWithFormat:@"https://github.com/Sindhu-Hegde/multivsr/archive/%@.tar.gz",
                                                   kMultivsrCommit];
    return @{
        @"provider" : @"lips",
        @"description" : @"uv and the MultiVSR code for the lips service",
        @"repo" : @"https://github.com/astral-sh/uv",
        @"files" : @[
            fileEntry(self.uvArchiveName, 16988553ull,
                      @"a9a8df1eedeb192f2e47e40e2faabfb387db4b850209118786d42f89dde3e0ba", uvURL),
            // Size and hash unknown on purpose: the unpacked tree is checked instead (treeProblemWithExpected:).
            fileEntry(self.multivsrArchiveName, 0, @"", codeURL),
        ],
    };
}

+ (NSString *)treeProblemWithExpected:(NSDictionary<NSString *, NSString *> *)expected
                               actual:(NSDictionary<NSString *, NSString *> *)actual {
    if (expected.count == 0) return @"нет списка файлов MultiVSR";
    for (NSString *path in expected) {
        if (!actual[path]) return [@"в коде MultiVSR нет файла " stringByAppendingString:path];
        if (![actual[path] isEqualToString:expected[path]]) return [@"в коде MultiVSR изменён файл " stringByAppendingString:path];
    }
    for (NSString *path in actual) {
        if (!expected[path]) return [@"в коде MultiVSR лишний файл " stringByAppendingString:path];
    }
    return nil;
}

+ (BOOL)isSha256:(NSString *)value {
    if (value.length != 64) return NO;
    NSCharacterSet *notHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    return [value rangeOfCharacterFromSet:notHex].location == NSNotFound;
}

+ (NSDictionary<NSString *, NSString *> *)sha256SumsFromText:(NSString *)text {
    if (![text isKindOfClass:[NSString class]]) return nil;
    NSMutableDictionary<NSString *, NSString *> *sums = [NSMutableDictionary dictionary];
    for (NSString *rawLine in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;
        NSRange gap = [line rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet];
        if (gap.location == NSNotFound) return nil;
        NSString *hash = [line substringToIndex:gap.location].lowercaseString;
        NSString *name = [[line substringFromIndex:gap.location]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        // `sha256sum -b` marks binary mode with a leading asterisk.
        if ([name hasPrefix:@"*"]) name = [name substringFromIndex:1];
        if (![self isSha256:hash] || name.length == 0) return nil;
        sums[name] = hash;
    }
    return sums;
}

+ (NSDictionary *)modelManifestForRelease:(NSDictionary *)release
                               sha256Sums:(NSDictionary<NSString *, NSString *> *)sums
                                    error:(NSString **)error {
    NSString *tag = [release[@"tag_name"] isKindOfClass:[NSString class]] ? release[@"tag_name"] : nil;
    NSString *downloadPrefix =
        [NSString stringWithFormat:@"https://github.com/%@/releases/download/", kModelsRepository];
    NSDictionary *lora = nil, *venc = nil;
    NSArray *assets = [release[@"assets"] isKindOfClass:[NSArray class]] ? release[@"assets"] : @[];
    for (NSDictionary *asset in assets) {
        if (![asset isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = asset[@"name"];
        if (![name isKindOfClass:[NSString class]] || ![name hasPrefix:kAssetPrefix]) continue;
        if ([name hasSuffix:@"-venc.pth"]) {
            if (venc) return [self fail:@"два файла *-venc.pth в релизе" error:error];
            venc = asset;
        } else if ([name hasSuffix:@".pt"]) {
            if (lora) return [self fail:@"два файла *.pt в релизе" error:error];
            lora = asset;
        }
    }
    if (!tag || !lora || !venc) return [self fail:@"в релизе нет файлов модели губ" error:error];

    NSMutableArray *files = [NSMutableArray array];
    for (NSArray *pair in @[ @[ lora, @"best.pt" ], @[ venc, @"best_venc.pth" ] ]) {
        NSDictionary *asset = pair[0];
        NSString *name = asset[@"name"];
        NSString *url = asset[@"browser_download_url"];
        NSNumber *size = asset[@"size"];
        NSString *hash = sums[name];
        if (!hash) return [self fail:[NSString stringWithFormat:@"нет хэша %@ в SHA256SUMS.txt", name] error:error];
        NSString *digest = [asset[@"digest"] isKindOfClass:[NSString class]] ? asset[@"digest"] : nil;
        if ([digest hasPrefix:@"sha256:"] &&
            ![[digest substringFromIndex:7].lowercaseString isEqualToString:hash]) {
            return [self fail:[NSString stringWithFormat:@"хэш %@ не совпадает с GitHub", name] error:error];
        }
        if (![url isKindOfClass:[NSString class]] || ![url hasPrefix:downloadPrefix]) {
            return [self fail:[NSString stringWithFormat:@"чужой адрес у %@", name] error:error];
        }
        if (![size isKindOfClass:[NSNumber class]] || size.longLongValue <= 0) {
            return [self fail:[NSString stringWithFormat:@"нет размера у %@", name] error:error];
        }
        [files addObject:fileEntry(pair[1], size.unsignedLongLongValue, hash, url)];
    }
    return @{
        @"provider" : @"lips",
        @"description" : [NSString stringWithFormat:@"Velikiy Moguchiy lips model %@", tag],
        @"repo" : [@"https://github.com/" stringByAppendingString:kModelsRepository],
        @"files" : files,
    };
}

+ (NSDictionary *)huggingFaceManifestFromModelInfo:(NSDictionary *)info
                                        sha256Sums:(NSDictionary<NSString *, NSString *> *)sums
                                               tag:(NSString **)tag
                                             error:(NSString **)error {
    NSString *revision = [info isKindOfClass:[NSDictionary class]] ? info[@"sha"] : nil;
    if (![revision isKindOfClass:[NSString class]] || revision.length != 40 ||
        [revision rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"]
                                              invertedSet]].location != NSNotFound) {
        return [self fail:@"Hugging Face не сообщил ревизию" error:error];
    }
    NSMutableDictionary<NSString *, NSDictionary *> *files = [NSMutableDictionary dictionary];
    NSArray *siblings = [info[@"siblings"] isKindOfClass:[NSArray class]] ? info[@"siblings"] : @[];
    for (NSDictionary *sibling in siblings) {
        if (![sibling isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = sibling[@"rfilename"];
        if ([name isKindOfClass:[NSString class]] && [name hasPrefix:kAssetPrefix]) files[name] = sibling;
    }
    NSString *bestVersion = nil;
    for (NSString *name in files) {
        if (![name hasSuffix:@".pt"]) continue;
        NSString *version = [[name substringFromIndex:kAssetPrefix.length] stringByDeletingPathExtension];
        if (![self directoryNameForTag:version]) continue;
        NSString *venc = [[kAssetPrefix stringByAppendingString:version] stringByAppendingString:@"-venc.pth"];
        if (!files[venc] || !sums[name] || !sums[venc]) continue;
        if (!bestVersion || [SPUpdatePolicy compareVersion:version toVersion:bestVersion] == NSOrderedDescending) {
            bestVersion = version;
        }
    }
    if (!bestVersion) return [self fail:@"на Hugging Face нет полной модели губ" error:error];

    NSMutableArray *entries = [NSMutableArray array];
    NSString *stem = [kAssetPrefix stringByAppendingString:bestVersion];
    NSArray *pairs = @[
        @[ [stem stringByAppendingString:@".pt"], @"best.pt" ],
        @[ [stem stringByAppendingString:@"-venc.pth"], @"best_venc.pth" ],
    ];
    for (NSArray *pair in pairs) {
        NSDictionary *sibling = files[pair[0]];
        NSString *hash = sums[pair[0]];
        NSDictionary *lfs = [sibling[@"lfs"] isKindOfClass:[NSDictionary class]] ? sibling[@"lfs"] : nil;
        if ([lfs[@"sha256"] isKindOfClass:[NSString class]] && ![[lfs[@"sha256"] lowercaseString] isEqualToString:hash]) {
            return [self fail:[NSString stringWithFormat:@"хэш %@ не совпадает с Hugging Face", pair[0]] error:error];
        }
        NSNumber *size = [sibling[@"size"] isKindOfClass:[NSNumber class]] ? sibling[@"size"] : lfs[@"size"];
        if (![size isKindOfClass:[NSNumber class]] || size.longLongValue <= 0) {
            return [self fail:[NSString stringWithFormat:@"нет размера у %@", pair[0]] error:error];
        }
        NSString *url = [NSString stringWithFormat:@"https://huggingface.co/%@/resolve/%@/%@",
                                                   kHuggingFaceRepository, revision, pair[0]];
        [entries addObject:fileEntry(pair[1], size.unsignedLongLongValue, hash, url)];
    }
    if (tag) *tag = [self.releaseTagPrefix stringByAppendingString:bestVersion];
    return @{
        @"provider" : @"lips",
        @"description" : [NSString stringWithFormat:@"Velikiy Moguchiy lips model %@%@", self.releaseTagPrefix, bestVersion],
        @"repo" : [@"https://huggingface.co/" stringByAppendingString:kHuggingFaceRepository],
        @"files" : entries,
    };
}

+ (BOOL)manifest:(NSDictionary *)manifest hasSameFilesAs:(NSDictionary *)other {
    NSArray *a = manifest[@"files"], *b = other[@"files"];
    if (![a isKindOfClass:[NSArray class]] || ![b isKindOfClass:[NSArray class]] || a.count != b.count) return NO;
    for (NSUInteger i = 0; i < a.count; i++) {
        for (NSString *key in @[ @"name", @"size", @"sha256" ]) {
            if (![a[i][key] isEqual:b[i][key]]) return NO;
        }
    }
    return YES;
}

+ (id)fail:(NSString *)reason error:(NSString **)error {
    if (error) *error = reason;
    return nil;
}

+ (NSString *)directoryNameForTag:(NSString *)tag {
    if (![tag isKindOfClass:[NSString class]] || tag.length == 0 || tag.length > 64) return nil;
    if ([tag hasPrefix:@"."]) return nil;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    if ([tag rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    return tag;
}

+ (NSString *)serviceDirectoryForOverride:(NSString *)overridePath
                           sourceCheckout:(NSString *)sourceCheckout
                         managedDirectory:(NSString *)managedDirectory {
    NSString *trimmed = [overridePath stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length > 0) return trimmed.stringByExpandingTildeInPath.stringByStandardizingPath;
    if (sourceCheckout.length > 0) return sourceCheckout.stringByStandardizingPath;
    return managedDirectory;
}

+ (unsigned long long)requiredFreeBytes {
    unsigned long long total = kEnvironmentBytes + kMarginBytes;
    for (NSDictionary *manifest in @[ [self baseModelManifest], [self toolsManifest] ]) {
        for (NSDictionary *file in manifest[@"files"]) total += [file[@"size"] unsignedLongLongValue];
    }
    return total;
}

@end
