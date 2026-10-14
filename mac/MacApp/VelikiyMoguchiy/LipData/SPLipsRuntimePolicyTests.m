#import <XCTest/XCTest.h>
#import "SPLipsRuntimePolicy.h"

static NSString *const kLoraHash = @"720186ee8b0cd613a0ba0d76f02b73ba173571d3c5502839e4637aed9be628cf";
static NSString *const kVencHash = @"5d3d2808d7f2ca462c9ae8851d8b2114f3dc6937887f57c0ceeddf19d91f16cf";

@interface SPLipsRuntimePolicyTests : XCTestCase
@end

@implementation SPLipsRuntimePolicyTests

- (NSDictionary *)assetNamed:(NSString *)name size:(long long)size digest:(NSString *)digest {
    NSMutableDictionary *asset = [@{
        @"name" : name,
        @"size" : @(size),
        @"browser_download_url" :
            [@"https://github.com/zigansh1n/velikiy-moguchiy-models/releases/download/lips-0.1/" stringByAppendingString:name],
    } mutableCopy];
    if (digest) asset[@"digest"] = [@"sha256:" stringByAppendingString:digest];
    return asset;
}

- (NSDictionary *)releaseWithAssets:(NSArray *)assets {
    return @{@"tag_name" : @"lips-0.1", @"assets" : assets};
}

- (NSDictionary *)sums {
    return @{@"velikiy-moguchiy-lips-0.1.pt" : kLoraHash, @"velikiy-moguchiy-lips-0.1-venc.pth" : kVencHash};
}

- (void)testSha256SumsParsing {
    NSString *text = [NSString stringWithFormat:@"%@  velikiy-moguchiy-lips-0.1.pt\n%@ *velikiy-moguchiy-lips-0.1-venc.pth\n\n",
                                                kLoraHash.uppercaseString, kVencHash];
    XCTAssertEqualObjects([SPLipsRuntimePolicy sha256SumsFromText:text], [self sums]);
    XCTAssertNil([SPLipsRuntimePolicy sha256SumsFromText:@"abc  file.pt"]);
    XCTAssertNil([SPLipsRuntimePolicy sha256SumsFromText:kLoraHash]);
    XCTAssertEqualObjects([SPLipsRuntimePolicy sha256SumsFromText:@""], @{});
}

- (void)testReleaseManifestMapsAssetsToServiceNames {
    NSDictionary *release = [self releaseWithAssets:@[
        [self assetNamed:@"velikiy-moguchiy-lips-0.1-venc.pth" size:51884747 digest:kVencHash],
        [self assetNamed:@"velikiy-moguchiy-lips-0.1.pt" size:58986354 digest:kLoraHash],
        [self assetNamed:@"SHA256SUMS.txt" size:196 digest:nil],
    ]];
    NSString *error = nil;
    NSDictionary *manifest = [SPLipsRuntimePolicy modelManifestForRelease:release sha256Sums:[self sums] error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(manifest[@"provider"], @"lips");
    NSArray *files = manifest[@"files"];
    XCTAssertEqual(files.count, 2u);
    XCTAssertEqualObjects(files[0][@"name"], @"best.pt");
    XCTAssertEqualObjects(files[0][@"sha256"], kLoraHash);
    XCTAssertEqualObjects(files[0][@"size"], @58986354);
    XCTAssertEqualObjects(files[1][@"name"], @"best_venc.pth");
    XCTAssertEqualObjects(files[1][@"sha256"], kVencHash);
}

- (void)testReleaseWithoutVerifiableFilesIsRejected {
    NSString *error = nil;
    NSDictionary *pt = [self assetNamed:@"velikiy-moguchiy-lips-0.1.pt" size:10 digest:nil];
    NSDictionary *venc = [self assetNamed:@"velikiy-moguchiy-lips-0.1-venc.pth" size:10 digest:nil];
    // No hash in SHA256SUMS.txt.
    NSArray *both = @[ pt, venc ];
    XCTAssertNil([self manifestFor:both sums:@{} error:&error]);
    XCTAssertNotNil(error);
    // GitHub's digest disagrees with SHA256SUMS.txt.
    NSDictionary *wrongDigest = [self assetNamed:@"velikiy-moguchiy-lips-0.1.pt" size:10 digest:kVencHash];
    NSArray *wrong = @[ wrongDigest, venc ];
    XCTAssertNil([self manifestFor:wrong sums:[self sums] error:nil]);
    // A download URL outside the models repository.
    NSMutableDictionary *foreign = [pt mutableCopy];
    foreign[@"browser_download_url"] = @"https://example.com/velikiy-moguchiy-lips-0.1.pt";
    NSArray *foreignPair = @[ foreign, venc ];
    XCTAssertNil([self manifestFor:foreignPair sums:[self sums] error:nil]);
    // The visual front-end is missing.
    NSArray *loraOnly = @[ pt ];
    XCTAssertNil([self manifestFor:loraOnly sums:[self sums] error:nil]);
    XCTAssertNotNil([self manifestFor:both sums:[self sums] error:nil]);
}

- (NSDictionary *)manifestFor:(NSArray *)assets sums:(NSDictionary *)sums error:(NSString **)error {
    return [SPLipsRuntimePolicy modelManifestForRelease:[self releaseWithAssets:assets] sha256Sums:sums error:error];
}

- (NSDictionary *)huggingFaceInfoWithVencHash:(NSString *)vencHash {
    return @{
        @"sha" : @"ba8c34b409ffdb7ebee519eb57d355578099898a",
        @"siblings" : @[
            @{@"rfilename" : @"README.md", @"size" : @2008},
            @{@"rfilename" : @"SHA256SUMS.txt", @"size" : @196},
            @{@"rfilename" : @"velikiy-moguchiy-lips-0.1-venc.pth", @"size" : @51884747,
              @"lfs" : @{@"sha256" : vencHash, @"size" : @51884747}},
            @{@"rfilename" : @"velikiy-moguchiy-lips-0.1.pt", @"size" : @58986354,
              @"lfs" : @{@"sha256" : kLoraHash, @"size" : @58986354}},
        ],
    };
}

- (void)testHuggingFaceManifestIsPinnedToTheRevision {
    NSString *tag = nil, *error = nil;
    NSDictionary *manifest = [SPLipsRuntimePolicy huggingFaceManifestFromModelInfo:[self huggingFaceInfoWithVencHash:kVencHash]
                                                                        sha256Sums:[self sums]
                                                                               tag:&tag
                                                                             error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(tag, @"lips-0.1");
    NSArray *files = manifest[@"files"];
    XCTAssertEqualObjects(files[0][@"name"], @"best.pt");
    XCTAssertEqualObjects(files[0][@"url"],
                          @"https://huggingface.co/z1gansh1n/velikiy-moguchiy-lips/resolve/"
                          @"ba8c34b409ffdb7ebee519eb57d355578099898a/velikiy-moguchiy-lips-0.1.pt");
    XCTAssertEqualObjects(files[1][@"sha256"], kVencHash);

    // The same files as the GitHub release, so either can stand in for the other.
    NSArray *assets = @[
        [self assetNamed:@"velikiy-moguchiy-lips-0.1.pt" size:58986354 digest:kLoraHash],
        [self assetNamed:@"velikiy-moguchiy-lips-0.1-venc.pth" size:51884747 digest:kVencHash],
    ];
    NSDictionary *github = [self manifestFor:assets sums:[self sums] error:nil];
    XCTAssertTrue([SPLipsRuntimePolicy manifest:manifest hasSameFilesAs:github]);
    XCTAssertFalse([SPLipsRuntimePolicy manifest:manifest hasSameFilesAs:@{}]);
}

- (void)testHuggingFaceManifestNeedsAgreeingHashes {
    NSString *error = nil;
    XCTAssertNil([SPLipsRuntimePolicy huggingFaceManifestFromModelInfo:[self huggingFaceInfoWithVencHash:kLoraHash]
                                                            sha256Sums:[self sums] tag:nil error:&error]);
    XCTAssertNotNil(error);
    XCTAssertNil([SPLipsRuntimePolicy huggingFaceManifestFromModelInfo:[self huggingFaceInfoWithVencHash:kVencHash]
                                                            sha256Sums:@{} tag:nil error:nil]);
    NSMutableDictionary *noRevision = [[self huggingFaceInfoWithVencHash:kVencHash] mutableCopy];
    noRevision[@"sha"] = @"main";
    XCTAssertNil([SPLipsRuntimePolicy huggingFaceManifestFromModelInfo:noRevision sha256Sums:[self sums] tag:nil error:nil]);
}

- (void)testStaticManifestsAreVerifiable {
    for (NSDictionary *manifest in @[ [SPLipsRuntimePolicy baseModelManifest], [SPLipsRuntimePolicy toolsManifest] ]) {
        for (NSDictionary *file in manifest[@"files"]) {
            XCTAssertEqual([file[@"sha256"] length], 64u, @"%@", file[@"name"]);
            XCTAssertGreaterThan([file[@"size"] longLongValue], 0);
            XCTAssertTrue([file[@"url"] hasPrefix:@"https://"]);
        }
    }
    XCTAssertGreaterThan([SPLipsRuntimePolicy requiredFreeBytes], 4500000000ull);
}

- (void)testTagFolderNames {
    XCTAssertEqualObjects([SPLipsRuntimePolicy directoryNameForTag:@"lips-0.1"], @"lips-0.1");
    XCTAssertNil([SPLipsRuntimePolicy directoryNameForTag:@"../lips"]);
    XCTAssertNil([SPLipsRuntimePolicy directoryNameForTag:@"lips/0.1"]);
    XCTAssertNil([SPLipsRuntimePolicy directoryNameForTag:@".."]);
    XCTAssertNil([SPLipsRuntimePolicy directoryNameForTag:@""]);
    XCTAssertNil([SPLipsRuntimePolicy directoryNameForTag:nil]);
}

- (void)testDeveloperCheckoutOverridesTheManagedEnvironment {
    XCTAssertEqualObjects([SPLipsRuntimePolicy serviceDirectoryForOverride:@"" managedDirectory:@"/data/lips/service"],
                          @"/data/lips/service");
    XCTAssertEqualObjects([SPLipsRuntimePolicy serviceDirectoryForOverride:nil managedDirectory:@"/data/lips/service"],
                          @"/data/lips/service");
    XCTAssertEqualObjects([SPLipsRuntimePolicy serviceDirectoryForOverride:@" /src/lipread/ " managedDirectory:@"/m"],
                          @"/src/lipread");
    XCTAssertEqualObjects([SPLipsRuntimePolicy serviceDirectoryForOverride:@"~/lipread" managedDirectory:@"/m"],
                          [NSHomeDirectory() stringByAppendingPathComponent:@"lipread"]);
}

@end
