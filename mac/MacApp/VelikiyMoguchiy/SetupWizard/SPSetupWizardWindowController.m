#import "SPSetupWizardWindowController.h"
#import "SPCommunityTrainingCard.h"
#import "SPLipCaptureManager.h"
#import "SPLipDataPolicy.h"
#import "SPLipsRuntime.h"
#import "SPLipTrainingCard.h"
#import "SPLocalization.h"
#import "SPOverlayPanel.h"
#import "SPQwenModelChoice.h"
#import "SPRustBridge.h"
#import "SPSettingsSidebar.h"
#import "SPSettingsViews.h"
#import "SPErrorExplainer.h"
#import "SPTheme.h"
#import "SPTriggerKeyPolicy.h"
#import <Carbon/Carbon.h>
#import <Cocoa/Cocoa.h>
#import <Speech/Speech.h>

// Apple Speech asset management FFI (AppleSpeechBridge Swift package)
extern int32_t sp_apple_speech_is_available(void);
extern int32_t sp_apple_speech_asset_status(const char *locale);
extern void sp_apple_speech_install_asset(const char *locale,
                                           void (*callback)(void *ctx,
                                                            int32_t event_type,
                                                            const char *text),
                                           void *ctx);
extern int32_t sp_apple_speech_release_asset(const char *locale);
extern uint8_t *sp_apple_speech_supported_locales(uint32_t *outLen);

static NSString *const kDictionaryFile = @"dictionary.txt";
static NSString *const kSystemPromptFile = @"system_prompt.txt";
static NSString *const kTemplateEditablePromptKey = @"__editable_prompt";
static NSString *const kTemplateOriginalPromptKey = @"__original_prompt";
static NSString *const kDefaultLlmChatCompletionsPath = @"/chat/completions";
static NSString *const kDefaultLlmResponsesPath = @"/responses";
static NSString *const kDefaultLlmAnthropicMessagesPath = @"/messages";
static NSString *const kLlmProtocolOpenAIChat = @"openai_chat";
static NSString *const kLlmProtocolOpenAIResponses = @"openai_responses";
static NSString *const kLlmProtocolAnthropicMessages = @"anthropic_messages";
static NSString *const kOverlayFontFamilyDefault = @"system";
static NSString *const kOverlayFontFamilySystemLabel = @"Системный по умолчанию";
static const NSInteger kOverlayFontSizeDefault = 13;
static const NSInteger kRecordingsRetentionMin = 1;
static const NSInteger kRecordingsRetentionMax = 365;
static const NSInteger kRecordingsRetentionDefault = 30;
static const NSInteger kOverlayFontSizeMin = 12;
static const NSInteger kOverlayFontSizeMax = 28;
static const NSInteger kOverlayBottomMarginDefault = 10;
static const NSInteger kOverlayBottomMarginMax = 180;
static const BOOL kOverlayLimitVisibleLinesDefault = YES;
static const NSInteger kOverlayMaxVisibleLinesDefault = 3;
static const NSInteger kOverlayMaxVisibleLinesMin = 3;
static const NSInteger kOverlayMaxVisibleLinesMax = 5;
static NSString *const kOverlayPreviewSampleText =
    @"Только что попробовал этот голосовой ввод, очень удобно: после "
    @"слов текст сам приводится в порядок, знаки препинания тоже "
    @"расставлены, и это куда быстрее, чем печатать.";

// Toolbar item identifiers
// Draws a view (and its subviews) into a PNG at the window's backing scale.
// The app renders its own views, so this needs no screen-capture permission.
void SPWriteViewSnapshot(NSView *view, NSString *path) {
  [view layoutSubtreeIfNeeded];
  [view displayIfNeeded];
  NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
  [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
  [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path
                                                                         atomically:YES];
}

static NSToolbarItemIdentifier const kToolbarASR = @"asr";
static NSToolbarItemIdentifier const kToolbarLLM = @"llm";
static NSToolbarItemIdentifier const kToolbarOverlay = @"overlay";
static NSToolbarItemIdentifier const kToolbarHotkey = @"hotkey";
static NSToolbarItemIdentifier const kToolbarDictionary = @"dictionary";
static NSToolbarItemIdentifier const kToolbarSnippets = @"snippets";
static NSToolbarItemIdentifier const kToolbarSystemPrompt = @"system_prompt";
static NSToolbarItemIdentifier const kToolbarTemplates = @"templates";
static NSToolbarItemIdentifier const kToolbarAbout = @"about";

// ─── Config helpers (backed by sp_config_get / sp_config_set) ───────
#import "velikiy_moguchiy_core.h"
#import "SPAppPaths.h"

static NSString *configDirPath(void) {
  return SPAppDataDirectory();
}

static NSString *configFilePath(void) {
  return [configDirPath() stringByAppendingPathComponent:@"config.yaml"];
}

static BOOL restoreConfigSnapshot(NSString *snapshot, BOOL existed,
                                  NSError **error) {
  NSString *path = configFilePath();
  NSFileManager *fileManager = [NSFileManager defaultManager];
  if (!existed) {
    if (![fileManager fileExistsAtPath:path])
      return YES;
    return [fileManager removeItemAtPath:path error:error];
  }

  return [(snapshot ?: @"") writeToFile:path
                             atomically:YES
                               encoding:NSUTF8StringEncoding
                                  error:error];
}

static NSString *configGet(NSString *keyPath) {
  char *raw = sp_config_get(keyPath.UTF8String);
  if (!raw)
    return @"";
  NSString *result = [NSString stringWithUTF8String:raw] ?: @"";
  sp_core_free_string(raw);
  return result;
}

static BOOL configSet(NSString *keyPath, NSString *value) {
  return sp_config_set(keyPath.UTF8String, (value ?: @"").UTF8String) == 0;
}

// Fetch a config sub-tree as a parsed JSON object (NSDictionary / NSArray).
// Returns nil if the key is missing, empty, or not parseable.
static id configGetJSON(NSString *keyPath) {
  char *raw = sp_config_get_json(keyPath.UTF8String);
  if (!raw)
    return nil;
  NSString *jsonStr = [NSString stringWithUTF8String:raw] ?: @"";
  sp_core_free_string(raw);
  if (jsonStr.length == 0)
    return nil;
  NSData *data = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
  if (!data)
    return nil;
  id parsed = [NSJSONSerialization JSONObjectWithData:data
                                              options:0
                                                error:NULL];
  return parsed;
}

static BOOL configSetJSON(NSString *keyPath, id object) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                 options:0
                                                   error:NULL];
  if (!data)
    return NO;
  NSString *json = [[NSString alloc] initWithData:data
                                         encoding:NSUTF8StringEncoding];
  return sp_config_set_json(keyPath.UTF8String, json.UTF8String) == 0;
}

// Returns user-configured custom headers for the given ASR provider, or nil.
// Mirrors Rust behavior: when `asr.<provider>.headers` is a non-empty map,
// those headers fully replace the provider's default auth headers.
static NSDictionary<NSString *, NSString *> *
asrCustomHeaders(NSString *providerKey) {
  NSString *keyPath =
      [NSString stringWithFormat:@"asr.%@.headers", providerKey];
  id parsed = configGetJSON(keyPath);
  if (![parsed isKindOfClass:[NSDictionary class]])
    return nil;
  NSMutableDictionary<NSString *, NSString *> *out =
      [NSMutableDictionary dictionary];
  for (id key in parsed) {
    if (![key isKindOfClass:[NSString class]])
      continue;
    id value = parsed[key];
    if (![value isKindOfClass:[NSString class]])
      continue;
    out[key] = value;
  }
  return out.count > 0 ? out : nil;
}

static NSInteger clampedOverlayFontSizeValue(NSInteger value) {
  return MAX(kOverlayFontSizeMin, MIN(kOverlayFontSizeMax, value));
}

static NSInteger clampedOverlayBottomMarginValue(NSInteger value) {
  return MAX(0, MIN(kOverlayBottomMarginMax, value));
}

static NSInteger clampedOverlayMaxVisibleLinesValue(NSInteger value) {
  return MAX(kOverlayMaxVisibleLinesMin,
             MIN(kOverlayMaxVisibleLinesMax, value));
}

static BOOL configBooleanValue(NSString *value, BOOL fallback) {
  NSString *normalized = [[[value ?: @""
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]]
      lowercaseString] copy];
  if (normalized.length == 0) {
    return fallback;
  }

  if ([normalized isEqualToString:@"1"] ||
      [normalized isEqualToString:@"true"] ||
      [normalized isEqualToString:@"yes"] ||
      [normalized isEqualToString:@"on"]) {
    return YES;
  }

  if ([normalized isEqualToString:@"0"] ||
      [normalized isEqualToString:@"false"] ||
      [normalized isEqualToString:@"no"] ||
      [normalized isEqualToString:@"off"]) {
    return NO;
  }

  return fallback;
}

static NSString *normalizedOverlayFontFamilyValue(NSString *value) {
  NSString *normalized = [[value ?: @""
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]]
      copy];
  if (normalized.length == 0) {
    return kOverlayFontFamilyDefault;
  }
  return normalized;
}

static BOOL overlayUsesSystemFontFamily(NSString *value) {
  return [normalizedOverlayFontFamilyValue(value)
             caseInsensitiveCompare:kOverlayFontFamilyDefault] == NSOrderedSame;
}

static NSFont *overlayFontForFamily(NSString *fontFamily, CGFloat fontSize) {
  CGFloat clampedFontSize = clampedOverlayFontSizeValue(lround(fontSize));
  NSString *normalized = normalizedOverlayFontFamilyValue(fontFamily);

  if (overlayUsesSystemFontFamily(normalized)) {
    return [NSFont systemFontOfSize:clampedFontSize weight:NSFontWeightMedium];
  }

  NSFont *font = [NSFont fontWithName:normalized size:clampedFontSize];
  if (font) {
    return font;
  }

  NSFontManager *fontManager = [NSFontManager sharedFontManager];
  font = [fontManager fontWithFamily:normalized
                              traits:0
                              weight:5
                                size:clampedFontSize];
  if (font) {
    return font;
  }

  for (NSArray *member in
       [fontManager availableMembersOfFontFamily:normalized]) {
    if (member.count == 0)
      continue;
    NSString *memberName = member[0];
    font = [NSFont fontWithName:memberName size:clampedFontSize];
    if (font) {
      return font;
    }
  }

  return [NSFont systemFontOfSize:clampedFontSize weight:NSFontWeightMedium];
}

static BOOL isNumericKeycode(NSString *value) {
  if (value.length == 0)
    return NO;
  NSScanner *scanner = [NSScanner scannerWithString:value];
  int intValue;
  return [scanner scanInt:&intValue] && [scanner isAtEnd];
}

static NSString *displayCharacterForKeycode(NSInteger keycode) {
  TISInputSourceRef inputSource = TISCopyCurrentKeyboardLayoutInputSource();
  if (!inputSource)
    return nil;

  CFDataRef layoutData =
      TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData);
  if (!layoutData) {
    CFRelease(inputSource);
    return nil;
  }

  const UCKeyboardLayout *keyboardLayout =
      (const UCKeyboardLayout *)CFDataGetBytePtr(layoutData);
  if (!keyboardLayout) {
    CFRelease(inputSource);
    return nil;
  }

  UInt32 deadKeyState = 0;
  UniChar chars[4];
  UniCharCount length = 0;
  OSStatus status = UCKeyTranslate(
      keyboardLayout, (UInt16)keycode, kUCKeyActionDisplay, 0, LMGetKbdType(),
      kUCKeyTranslateNoDeadKeysBit, &deadKeyState,
      sizeof(chars) / sizeof(chars[0]), &length, chars);
  CFRelease(inputSource);

  if (status != noErr || length == 0)
    return nil;

  NSString *result = [[NSString stringWithCharacters:chars
                                              length:(NSUInteger)length]
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  if (result.length == 0)
    return nil;
  return result.uppercaseString;
}

static NSString *displayNameForKeycodeValue(NSString *value) {
  NSInteger keycode = value.integerValue;
  switch (keycode) {
  case 122:
    return @"F1";
  case 120:
    return @"F2";
  case 99:
    return @"F3";
  case 118:
    return @"F4";
  case 96:
    return @"F5";
  case 97:
    return @"F6";
  case 98:
    return @"F7";
  case 100:
    return @"F8";
  case 101:
    return @"F9";
  case 109:
    return @"F10";
  case 103:
    return @"F11";
  case 111:
    return @"F12";
  case 49:
    return @"Пробел";
  case 53:
    return @"Escape";
  case 48:
    return @"Tab";
  case 57:
    return @"Caps Lock";
  case 36:
    return @"Return";
  case 51:
    return @"Delete";
  case 117:
    return @"Forward Delete";
  case 115:
    return @"Home";
  case 119:
    return @"End";
  case 116:
    return @"Page Up";
  case 121:
    return @"Page Down";
  case 123:
    return @"Стрелка влево";
  case 124:
    return @"Стрелка вправо";
  case 125:
    return @"Стрелка вниз";
  case 126:
    return @"Стрелка вверх";
  default: {
    NSString *displayCharacter = displayCharacterForKeycode(keycode);
    return displayCharacter.length > 0
               ? displayCharacter
               : [NSString stringWithFormat:@"Клавиша %ld", (long)keycode];
  }
  }
}

static NSSet<NSString *> *presetHotkeyValues(void) {
  static NSSet<NSString *> *validValues;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    validValues = [NSSet setWithArray:@[
      @"fn",
      @"left_option",
      @"right_option",
      @"left_command",
      @"right_command",
      @"left_control",
      @"right_control",
    ]];
  });
  return validValues;
}

static NSArray<NSString *> *comboModifierOrder(void) {
  return @[ @"command", @"option", @"control", @"shift", @"fn" ];
}

static NSDictionary<NSString *, NSString *> *comboModifierDisplayNames(void) {
  static NSDictionary<NSString *, NSString *> *displayNames;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    displayNames = @{
      @"command" : @"Command",
      @"option" : @"Option",
      @"control" : @"Control",
      @"shift" : @"Shift",
      @"fn" : @"Fn",
    };
  });
  return displayNames;
}

static NSString *normalizedHotkeyComboValue(NSString *value) {
  if (![value containsString:@"+"])
    return nil;

  NSMutableOrderedSet<NSString *> *modifiers = [NSMutableOrderedSet orderedSet];
  NSString *keyToken = nil;

  for (NSString *rawPart in [value componentsSeparatedByString:@"+"]) {
    NSString *part = [[rawPart
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]]
        lowercaseString];
    if (part.length == 0)
      return nil;

    NSString *normalizedModifier = nil;
    if ([part isEqualToString:@"cmd"] || [part isEqualToString:@"command"]) {
      normalizedModifier = @"command";
    } else if ([part isEqualToString:@"alt"] ||
               [part isEqualToString:@"option"]) {
      normalizedModifier = @"option";
    } else if ([part isEqualToString:@"ctrl"] ||
               [part isEqualToString:@"control"]) {
      normalizedModifier = @"control";
    } else if ([part isEqualToString:@"shift"]) {
      normalizedModifier = @"shift";
    } else if ([part isEqualToString:@"fn"] ||
               [part isEqualToString:@"function"] ||
               [part isEqualToString:@"globe"]) {
      normalizedModifier = @"fn";
    }

    if (normalizedModifier) {
      [modifiers addObject:normalizedModifier];
      continue;
    }

    if (keyToken != nil || !isNumericKeycode(part)) {
      return nil;
    }
    keyToken = [NSString stringWithFormat:@"%ld", (long)part.integerValue];
  }

  if (modifiers.count == 0 || keyToken.length == 0)
    return nil;

  NSMutableArray<NSString *> *parts = [NSMutableArray array];
  for (NSString *modifier in comboModifierOrder()) {
    if ([modifiers containsObject:modifier]) {
      [parts addObject:modifier];
    }
  }
  [parts addObject:keyToken];
  return [parts componentsJoinedByString:@"+"];
}

static NSString *normalizedHotkeyValue(NSString *value) {
  NSString *trimmedValue = [value
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  if ([presetHotkeyValues() containsObject:trimmedValue])
    return trimmedValue;
  if (isNumericKeycode(trimmedValue)) {
    return [NSString stringWithFormat:@"%ld", (long)trimmedValue.integerValue];
  }
  NSString *normalizedCombo = normalizedHotkeyComboValue(trimmedValue);
  if (normalizedCombo.length > 0)
    return normalizedCombo;
  return @"fn";
}

static NSString *displayNameForHotkeyValue(NSString *value) {
  NSString *normalizedValue = normalizedHotkeyValue(value);
  if ([normalizedValue isEqualToString:@"left_option"])
    return @"Левый Option (⌥)";
  if ([normalizedValue isEqualToString:@"right_option"])
    return @"Правый Option (⌥)";
  if ([normalizedValue isEqualToString:@"left_command"])
    return @"Левый Command (⌘)";
  if ([normalizedValue isEqualToString:@"right_command"])
    return @"Правый Command (⌘)";
  if ([normalizedValue isEqualToString:@"left_control"])
    return @"Левый Control (⌃)";
  if ([normalizedValue isEqualToString:@"right_control"])
    return @"Правый Control (⌃)";
  if ([normalizedValue isEqualToString:@"fn"])
    return @"Fn (Globe)";
  NSString *normalizedCombo = normalizedHotkeyComboValue(normalizedValue);
  if (normalizedCombo.length > 0) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSArray<NSString *> *tokens =
        [normalizedCombo componentsSeparatedByString:@"+"];
    NSDictionary<NSString *, NSString *> *displayNames =
        comboModifierDisplayNames();
    for (NSInteger idx = 0; idx < (NSInteger)tokens.count; idx++) {
      NSString *token = tokens[idx];
      if (idx == (NSInteger)tokens.count - 1) {
        [parts addObject:displayNameForKeycodeValue(token)];
      } else {
        [parts addObject:displayNames[token] ?: token.capitalizedString];
      }
    }
    return [parts componentsJoinedByString:@" + "];
  }
  if (isNumericKeycode(normalizedValue))
    return displayNameForKeycodeValue(normalizedValue);
  return normalizedValue;
}

static BOOL hotkeyValueUsesCustomPopupItem(NSString *value) {
  NSString *normalizedValue = normalizedHotkeyValue(value);
  return isNumericKeycode(normalizedValue) ||
         normalizedHotkeyComboValue(normalizedValue).length > 0;
}

/// If the value is a custom hotkey (recorded combo or raw keycode), add a
/// custom popup item and select it.
static void ensureCustomHotkeyInPopup(NSPopUpButton *popup, NSString *value) {
  NSString *normalizedValue = normalizedHotkeyValue(value);
  if (!hotkeyValueUsesCustomPopupItem(normalizedValue))
    return;

  NSMutableArray<NSMenuItem *> *itemsToRemove = [NSMutableArray array];
  for (NSMenuItem *item in popup.itemArray) {
    NSString *representedObject =
        [item.representedObject isKindOfClass:[NSString class]]
            ? item.representedObject
            : nil;
    if (representedObject.length > 0 &&
        ![presetHotkeyValues() containsObject:representedObject] &&
        ![representedObject isEqualToString:normalizedValue]) {
      [itemsToRemove addObject:item];
    }
    if ([representedObject isEqualToString:normalizedValue]) {
      [popup selectItem:item];
      return;
    }
  }

  for (NSMenuItem *item in itemsToRemove) {
    [popup.menu removeItem:item];
  }

  [popup addItemWithTitle:displayNameForHotkeyValue(normalizedValue)];
  [popup lastItem].representedObject = normalizedValue;
  [popup selectItem:[popup lastItem]];
}

// The pane backdrop and the card surface now live in SPSettingsViews: every
// pane floats on the window's gradient rather than painting its own opaque
// background, and SPCardView is the shared translucent card.

// Flipped document view for a pane's scrolling content area, so a pane's
// origin is its top-left and adding content grows downward.
@interface SPFlippedDocumentView : NSView
@end

@implementation SPFlippedDocumentView
- (BOOL)isFlipped {
  return YES;
}
@end

// Status label whose text is set from many call sites at runtime (test
// results, model download states). Keeps long text readable without any
// caller cooperation: in growing mode it re-measures its wrapped height on
// every text change (top edge fixed, grows downward); otherwise it stays a
// single truncating line and mirrors the full text into its tooltip.
@interface SPStatusLabel : NSTextField
@property(nonatomic, assign) BOOL growsDownward;
/// Upper bound for growing mode. A provider can return an arbitrarily long
/// error (a full JSON body), and an unbounded label grows straight out of
/// its card and off the pane. Anything past the bound is truncated on
/// screen and kept in the tooltip. 0 means unbounded.
@property(nonatomic, assign) CGFloat maxGrowHeight;
/// A view the label must stay inside of (its card). The bound is recomputed
/// on every text change rather than fixed at build time: panes are re-laid
/// out after they are hosted in the scroll view, so a build-time measurement
/// is stale by the time a message actually arrives.
@property(nonatomic, weak) NSView *growthBoundsView;
@property(nonatomic, assign) CGFloat growthBottomInset;
@end

@implementation SPStatusLabel

- (void)setStringValue:(NSString *)stringValue {
  [super setStringValue:stringValue];
  if (self.growsDownward) {
    [self sp_remeasureHeight];
    // Whatever did not fit is still reachable, and the label is selectable
    // so the full text can be copied out of the tooltip's source.
    self.toolTip = stringValue.length > 0 ? stringValue : nil;
  } else {
    self.toolTip = stringValue.length > 0 ? stringValue : nil;
  }
}

- (void)sp_remeasureHeight {
  CGFloat width = self.frame.size.width;
  if (width <= 0.0)
    return;
  NSTextFieldCell *cell = (NSTextFieldCell *)self.cell;
  NSSize size = [cell cellSizeForBounds:NSMakeRect(0, 0, width, CGFLOAT_MAX)];
  CGFloat height = ceil(MAX(18.0, size.height));
  if (self.maxGrowHeight > 0.0) {
    height = MIN(height, self.maxGrowHeight);
  }
  NSView *bounds = self.growthBoundsView;
  if (bounds) {
    CGFloat room =
        NSMaxY(self.frame) - (NSMinY(bounds.frame) + self.growthBottomInset);
    height = MIN(height, MAX(18.0, room));
  }
  NSRect frame = self.frame;
  frame.origin.y = NSMaxY(frame) - height;
  frame.size.height = height;
  self.frame = frame;
}

@end

/// Condense a provider error for display. Remote APIs answer failures with a
/// JSON body, and dumping it raw into a settings label is both unreadable and
/// unbounded. Pulls out the human-readable message (and error code when
/// present) and keeps the leading "HTTP 429 Too Many Requests" context.
/// Anything that is not recognizably JSON is returned unchanged.
static NSString *SPCondensedProviderError(NSString *raw) {
  if (raw.length == 0)
    return raw;
  NSRange brace = [raw rangeOfString:@"{"];
  if (brace.location == NSNotFound)
    return raw;

  NSString *prefix =
      [[raw substringToIndex:brace.location]
          stringByTrimmingCharactersInSet:
              [NSCharacterSet characterSetWithCharactersInString:@" :\n\t"]];
  NSString *jsonPart = [raw substringFromIndex:brace.location];
  NSDictionary *json = [NSJSONSerialization
      JSONObjectWithData:[jsonPart dataUsingEncoding:NSUTF8StringEncoding]
                 options:0
                   error:nil];
  if (![json isKindOfClass:[NSDictionary class]])
    return raw;

  id errorValue = json[@"error"];
  NSString *detail = nil;
  NSString *code = nil;
  if ([errorValue isKindOfClass:[NSDictionary class]]) {
    id message = errorValue[@"message"];
    if ([message isKindOfClass:[NSString class]])
      detail = message;
    for (NSString *key in @[ @"code", @"type" ]) {
      id value = errorValue[key];
      if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
        code = value;
        break;
      }
    }
  } else if ([errorValue isKindOfClass:[NSString class]]) {
    detail = errorValue;
  } else if ([json[@"message"] isKindOfClass:[NSString class]]) {
    detail = json[@"message"];
  }

  if (detail.length == 0)
    return raw;

  // Providers like to append documentation links and hints after the actual
  // reason. The first sentence is the part a user acts on; the rest stays in
  // the tooltip.
  NSRange sentenceEnd = [detail rangeOfString:@". "];
  if (sentenceEnd.location != NSNotFound && sentenceEnd.location > 24)
    detail = [detail substringToIndex:sentenceEnd.location + 1];
  if (detail.length > 150)
    detail = [[detail substringToIndex:149] stringByAppendingString:@"…"];

  NSMutableString *condensed = [NSMutableString string];
  if (prefix.length > 0)
    [condensed appendFormat:@"%@ — ", prefix];
  [condensed appendString:detail];
  if (code.length > 0)
    [condensed appendFormat:@" (%@)", code];
  return condensed;
}

@interface SPTemplateRowView : NSTableRowView
@end

@implementation SPTemplateRowView

- (void)drawSelectionInRect:(NSRect)dirtyRect {
  if (!self.isSelected)
    return;

  NSRect selectionRect = NSInsetRect(self.bounds, 2.0, 2.0);
  NSBezierPath *selectionPath =
      [NSBezierPath bezierPathWithRoundedRect:selectionRect
                                      xRadius:8.0
                                      yRadius:8.0];
  [SPTheme.selectionBackground setFill];
  [selectionPath fill];
}

- (void)drawSeparatorInRect:(NSRect)dirtyRect {
}

@end

// Row view for the LLM profile list. Draws a prominent accent-colored
// selection background that stays visible even when the table view is not
// the first responder (the detail form on the right steals focus every time
// the user edits a field).
@interface SPLlmProfileRowView : NSTableRowView
@end

@implementation SPLlmProfileRowView

// Keep the cell subviews drawing their "normal" (dark-on-light) appearance
// even when this row is selected — the custom accent background is light
// enough that white text would be unreadable.
- (NSBackgroundStyle)interiorBackgroundStyle {
  return NSBackgroundStyleNormal;
}

- (void)drawSelectionInRect:(NSRect)dirtyRect {
  if (!self.isSelected)
    return;

  NSRect selectionRect = NSInsetRect(self.bounds, 3.0, 3.0);
  NSBezierPath *selectionPath =
      [NSBezierPath bezierPathWithRoundedRect:selectionRect
                                      xRadius:6.0
                                      yRadius:6.0];
  [SPTheme.selectionBackground setFill];
  [selectionPath fill];

  [[SPTheme.accent colorWithAlphaComponent:0.85] setStroke];
  selectionPath.lineWidth = 1.5;
  [selectionPath stroke];
}

- (void)drawSeparatorInRect:(NSRect)dirtyRect {
}

@end

// ─── Window Controller ──────────────────────────────────────────────

// Text view for the DashScope key list: reports focus changes so the keys can
// be shown masked at rest and in full while they are edited.
@interface SPKeysTextView : NSTextView
@property(nonatomic, copy) void (^onFocusChange)(BOOL focused);
@end

@implementation SPKeysTextView
- (BOOL)becomeFirstResponder {
  BOOL accepted = [super becomeFirstResponder];
  if (accepted && self.onFocusChange)
    self.onFocusChange(YES);
  return accepted;
}
- (BOOL)resignFirstResponder {
  BOOL resigned = [super resignFirstResponder];
  if (resigned && self.onFocusChange)
    self.onFocusChange(NO);
  return resigned;
}
@end

@interface SPSetupWizardWindowController () <
    NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate,
    NSTextViewDelegate, NSWindowDelegate>

// Window chrome
@property(nonatomic, strong) SPSettingsSidebarViewController *sidebar;
// «Лицензии» window opened from the About pane (kept so it is reused, not rebuilt)
@property(nonatomic, strong) NSWindow *licensesWindow;
@property(nonatomic, strong) NSScrollView *paneScrollView;
@property(nonatomic, strong) NSView *paneDocumentView;
@property(nonatomic, strong) NSTextField *pageTitleLabel;
@property(nonatomic, strong) NSView *paneFooterView;

// Current pane
@property(nonatomic, copy) NSString *currentPaneIdentifier;
@property(nonatomic, strong) NSView *currentPaneView;

// ASR fields
@property(nonatomic, strong) NSPopUpButton *asrProviderPopup;
@property(nonatomic, strong) NSTextField *asrAppKeyField;
@property(nonatomic, strong) NSTextField *asrAccessKeyField;
@property(nonatomic, strong) NSSecureTextField *asrAccessKeySecureField;
@property(nonatomic, strong) NSButton *asrAccessKeyToggle;
@property(nonatomic, strong) SPKeysTextView *asrQwenKeysTextView;
@property(nonatomic, copy) NSArray<NSString *> *asrQwenKeys;
@property(nonatomic, assign) BOOL asrQwenKeysEditing;
@property(nonatomic, strong) NSButton *asrQwenFieldContextCheckbox;
@property(nonatomic, strong) SPFlippedDocumentView *asrQwenAppModesRows;
@property(nonatomic, strong) NSScrollView *asrQwenAppModesScroll;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *asrQwenAppModeEntries;
@property(nonatomic, strong) NSMutableArray<NSTextField *> *asrQwenAppModeFields;
@property(nonatomic, strong) NSMutableArray<NSPopUpButton *> *asrQwenAppModePopups;
@property(nonatomic, strong) NSButton *asrQwenAddRunningAppButton;
@property(nonatomic, assign) CGFloat asrQwenRequiredPaneHeight;
@property(nonatomic, strong) NSPopUpButton *asrQwenOutputModePopup;
@property(nonatomic, strong) NSTextField *asrQwenTranslateToField;
@property(nonatomic, strong) NSPopUpButton *asrQwenModelPopup;
@property(nonatomic, strong) NSTextField *asrQwenModelCustomField;
@property(nonatomic, assign) CGFloat asrQwenModelRowWidth;
// The model as loaded, so Save writes asr.qwen.model only when the user picked
// another one.
@property(nonatomic, copy) NSString *asrQwenLoadedModel;
@property(nonatomic, strong) NSSecureTextField *asrGlmApiKeySecureField;
@property(nonatomic, strong) NSTextField *asrGlmApiKeyField;
@property(nonatomic, strong) NSButton *asrGlmApiKeyToggle;
@property(nonatomic, strong) NSSecureTextField *asrMimoApiKeySecureField;
@property(nonatomic, strong) NSTextField *asrMimoApiKeyField;
@property(nonatomic, strong) NSButton *asrMimoApiKeyToggle;
@property(nonatomic, strong) NSButton *asrTestButton;
@property(nonatomic, strong) NSTextField *asrTestResultLabel;
// Doubao auth mode + new console API key
@property(nonatomic, strong) NSSegmentedControl *asrAuthModeControl;
@property(nonatomic, strong) NSSecureTextField *asrApiKeySecureField;
@property(nonatomic, strong) NSTextField *asrApiKeyField;
@property(nonatomic, strong) NSButton *asrApiKeyToggle;
// Doubao language selection
@property(nonatomic, strong) NSPopUpButton *asrLanguagePopup;
// Doubao advanced settings
@property(nonatomic, strong) NSButton *asrAdvancedDisclosure;
@property(nonatomic, strong) NSView *asrAdvancedContainer;
@property(nonatomic, strong) NSTextField *asrEndWindowField;
@property(nonatomic, strong) NSPopUpButton *asrOutputVariantPopup;
@property(nonatomic, strong) NSButton *asrAccelerateCheckbox;

// The card behind the ASR form. Held so it can stretch with the pane.
@property(nonatomic, strong) NSView *asrFormCard;

// Local ASR model selection
@property(nonatomic, strong) NSPopUpButton *localModelPopup;
@property(nonatomic, strong) NSTextField *localModelLabel;
@property(nonatomic, strong) NSTextField *modelStatusLabel;
@property(nonatomic, strong) NSButton *modelDownloadButton;
@property(nonatomic, strong) NSButton *modelDeleteButton;
@property(nonatomic, strong) NSProgressIndicator *modelProgressBar;
@property(nonatomic, strong) NSTextField *modelProgressSizeLabel;
@property(nonatomic, strong) NSMutableSet<NSString *> *downloadingModels;
@property(nonatomic, copy) NSString *pendingVerificationPath;
// Pane height needed for the MiMo provider (derived from the measured
// privacy-notice height at build time).
@property(nonatomic, assign) CGFloat asrMimoRequiredPaneHeight;
@property(nonatomic, assign) CGFloat asrWetypeRequiredPaneHeight;

// Apple Speech locale selection
@property(nonatomic, strong) NSPopUpButton *appleSpeechLocalePopup;

// LLM fields
@property(nonatomic, strong) NSSwitch *llmEnabledCheckbox;
@property(nonatomic, strong) NSSwitch *llmAutoPasteProcessedTextSwitch;
@property(nonatomic, strong) NSTableView *llmProfileTableView;
@property(nonatomic, strong) NSScrollView *llmProfileTableScroll;
@property(nonatomic, strong) NSButton *llmAddProfileButton;
@property(nonatomic, strong) NSButton *llmDeleteProfileButton;
@property(nonatomic, strong) NSMutableArray<NSString *> *llmProfileOrder;
@property(nonatomic, assign) BOOL suppressLlmProfileSelection;
@property(nonatomic, strong) NSTextField *llmProfileNameField;
@property(nonatomic, strong) NSTextField *llmProfileTypeLabel;
@property(nonatomic, strong) NSTextField *llmBaseUrlField;
@property(nonatomic, strong) NSTextField *llmApiKeyField;
@property(nonatomic, strong) NSSecureTextField *llmApiKeySecureField;
@property(nonatomic, strong) NSButton *llmApiKeyToggle;
@property(nonatomic, strong) NSTextField *llmModelField;
@property(nonatomic, strong) NSButton *llmToggleModelPickerButton;
@property(nonatomic, strong) NSPopUpButton *llmRemoteModelPopup;
@property(nonatomic, strong) NSButton *llmRefreshModelsButton;
@property(nonatomic, strong) NSTextField *llmChatCompletionsPathField;
@property(nonatomic, strong) NSButton *llmTestButton;
@property(nonatomic, strong) SPStatusLabel *llmTestResultLabel;
@property(nonatomic, assign) BOOL llmRemoteModelPickerExpanded;
@property(nonatomic, assign) BOOL llmRemoteModelPickerRowVisible;

// LLM max token parameter
@property(nonatomic, strong) NSPopUpButton *maxTokenParamPopup;

// LLM local model selection (MLX)
@property(nonatomic, strong) NSPopUpButton *llmLocalModelPopup;
@property(nonatomic, strong) NSTextField *llmModelStatusLabel;
@property(nonatomic, strong) NSButton *llmModelDownloadButton;
@property(nonatomic, strong) NSButton *llmModelDeleteButton;
@property(nonatomic, strong) NSProgressIndicator *llmModelProgressBar;
@property(nonatomic, strong) NSTextField *llmModelProgressSizeLabel;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSMutableDictionary *> *llmProfiles;
@property(nonatomic, copy) NSString *activeLlmProfileId;

// Hotkey
@property(nonatomic, strong) NSPopUpButton *hotkeyPopup;
@property(nonatomic, strong) NSButton *recordTriggerHotkeyButton;
@property(nonatomic, strong) NSButton *resetTriggerHotkeyButton;
@property(nonatomic, strong) id hotkeyRecordingMonitor;
@property(nonatomic, copy) NSString *recordingHotkeyTarget;
// Trigger mode
@property(nonatomic, strong) NSPopUpButton *triggerModePopup;
@property(nonatomic, strong) NSPopUpButton *translateKeyPopup;
@property(nonatomic, strong) NSPopUpButton *askKeyPopup;
@property(nonatomic, strong) NSPopUpButton *abortKeyPopup;
@property(nonatomic, strong) NSPopUpButton *modeKeyPopup;
@property(nonatomic, strong) NSPopUpButton *editKeyPopup;
@property(nonatomic, strong) NSPopUpButton *undoKeyPopup;
@property(nonatomic, strong) NSPopUpButton *repasteKeyPopup;
@property(nonatomic, strong) NSPopUpButton *mouseButtonPopup;
@property(nonatomic, strong) NSPopUpButton *autoStopSilencePopup;
@property(nonatomic, strong) NSPopUpButton *recordingCapPopup;
@property(nonatomic, strong) NSSwitch *voiceCommandsSwitch;
@property(nonatomic, strong) NSSwitch *mediaPlayPauseSwitch;
@property(nonatomic, strong) NSSwitch *keepLastDictationSwitch;
@property(nonatomic, strong) NSSwitch *pasteAsrFirstSwitch;
@property(nonatomic, strong) NSSwitch *streamingInsertSwitch;
@property(nonatomic, strong) NSSwitch *liveInsertSwitch;
@property(nonatomic, strong) NSSwitch *keepMicWarmSwitch;
@property(nonatomic, strong) NSSwitch *lipflowSwitch;
@property(nonatomic, strong) NSSwitch *saveRecordingsSwitch;
@property(nonatomic, strong) NSSwitch *lipdataCaptureSwitch;
// training.contribute: the separate opt-in consent to community training
@property(nonatomic, strong) NSSwitch *trainingContributeSwitch;
@property(nonatomic, strong) NSTextField *lipdataCountLabel;
@property(nonatomic, strong) NSTextField *lipsModeLabel;
@property(nonatomic, strong) NSButton *lipsModeButton;
@property(nonatomic, strong) NSSwitch *autoRetryOnErrorSwitch;
@property(nonatomic, strong) NSTextField *recordingsRetentionField;
@property(nonatomic, strong) NSStepper *recordingsRetentionStepper;
@property(nonatomic, assign) NSInteger loadedRecordingsRetentionDays;
@property(nonatomic, strong) NSSwitch *startSoundCheckbox;
@property(nonatomic, strong) NSSwitch *stopSoundCheckbox;
@property(nonatomic, strong) NSSwitch *errorSoundCheckbox;
@property(nonatomic, strong) NSSwitch *muteSystemOutputCheckbox;
// Paste behavior
@property(nonatomic, strong) NSSwitch *autoReturnSwitch;

// Overlay
@property(nonatomic, strong) NSPopUpButton *overlayFontFamilyPopup;
@property(nonatomic, copy) NSArray<NSString *> *overlayAvailableFontFamilies;
@property(nonatomic, strong) NSSlider *overlayFontSizeSlider;
@property(nonatomic, strong) NSTextField *overlayFontSizeValueLabel;
@property(nonatomic, strong) NSSlider *overlayBottomMarginSlider;
@property(nonatomic, strong) NSTextField *overlayBottomMarginValueLabel;
@property(nonatomic, strong) NSSwitch *overlayLimitVisibleLinesSwitch;
@property(nonatomic, strong) NSPopUpButton *overlayMaxVisibleLinesPopup;

// Dictionary
@property(nonatomic, strong) NSTextView *dictionaryTextView;

// Snippets
@property(nonatomic, strong) SPFlippedDocumentView *snippetRows;
@property(nonatomic, strong) NSScrollView *snippetScroll;
@property(nonatomic, strong) NSMutableArray<NSTextField *> *snippetTriggerFields;
@property(nonatomic, strong) NSMutableArray<NSTextField *> *snippetTextFields;
@property(nonatomic, copy) NSString *loadedSnippetsSignature;

// System Prompt
@property(nonatomic, strong) NSTextView *systemPromptTextView;

// Templates
@property(nonatomic, strong)
    NSMutableArray<NSMutableDictionary *> *templatesData;
@property(nonatomic, strong) NSTableView *templatesTableView;
@property(nonatomic, strong) NSSwitch *templatesEnabledSwitch;
@property(nonatomic, strong) NSSegmentedControl *templatePrimaryActionsControl;
@property(nonatomic, strong) NSSegmentedControl *templateReorderActionsControl;
@property(nonatomic, strong) NSTextField *templateNameField;
@property(nonatomic, strong) NSSwitch *templateItemEnabledSwitch;
@property(nonatomic, strong) NSTextView *templatePromptTextView;
@property(nonatomic, assign) NSInteger selectedTemplateIndex;
@property(nonatomic, assign) BOOL suppressTemplateSync;
@property(nonatomic, assign) BOOL templateEditorDirty;

// Values captured when a pane is loaded. Saving only writes controls whose
// semantic value changed, so visiting Settings cannot normalize or overwrite
// config that the user did not edit.
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSNumber *> *loadedBooleanValues;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSString *> *loadedStringValues;
@property(nonatomic, copy) NSString *loadedDictionaryContent;
@property(nonatomic, copy) NSString *loadedSystemPromptContent;
@property(nonatomic, copy)
    NSArray<NSDictionary *> *loadedTemplatesSnapshot;

@end

@implementation SPSetupWizardWindowController {
  dispatch_queue_t _verifyQueue;
}

- (instancetype)init {
  // One fixed size, and every pane is laid out to fill exactly this. The window
  // used to animate its height to each pane, so the content jumped on every
  // switch and each pane had to declare its own height; the panes now scroll
  // inside one shape instead.
  NSSize contentSize = SPTheme.windowContentSize;
  NSWindow *window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, contentSize.width, contentSize.height)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskMiniaturizable |
                          NSWindowStyleMaskFullSizeContentView
                  backing:NSBackingStoreBuffered
                    defer:YES];
  window.title = @"«Великий & Могучий» — настройки";
  window.titlebarAppearsTransparent = YES;
  window.titleVisibility = NSWindowTitleHidden;
  window.movableByWindowBackground = YES;
  // Pinned from both sides: without the resizable mask the user cannot drag an
  // edge, and matching min to max stops a zoom or a Stage Manager tile from
  // resizing it either.
  window.contentMinSize = contentSize;
  window.contentMaxSize = contentSize;
  [window standardWindowButton:NSWindowZoomButton].enabled = NO;

  self = [super initWithWindow:window];
  if (self) {
    _verifyQueue =
        dispatch_queue_create("velikiy-moguchiy.model.verify", DISPATCH_QUEUE_SERIAL);
    _loadedBooleanValues = [NSMutableDictionary dictionary];
    _loadedStringValues = [NSMutableDictionary dictionary];
    window.delegate = self;
    [self buildWindowChrome];
  }
  return self;
}

- (void)showForDesignPreviewOnScreen:(NSScreen *)screen pane:(NSString *)pane {
  [self switchToPane:pane.length > 0 ? pane : kToolbarASR];
  [self loadCurrentValues];
  NSRect visible = screen.visibleFrame;
  [self.window setFrameTopLeftPoint:NSMakePoint(NSMinX(visible) + 40, NSMaxY(visible) - 40)];
  [self.window orderFrontRegardless];
}

- (void)writeDesignSnapshotsToDirectory:(NSString *)directory suffix:(NSString *)suffix {
  for (NSString *pane in @[ kToolbarASR, kToolbarLLM, kToolbarHotkey, kToolbarOverlay,
                            kToolbarDictionary, kToolbarSnippets, kToolbarSystemPrompt,
                            kToolbarTemplates, kToolbarAbout ]) {
    [self switchToPane:pane];
    [self loadCurrentValues];
    NSString *path = [directory
        stringByAppendingPathComponent:[NSString stringWithFormat:@"settings-%@%@.png", pane, suffix]];
    SPWriteViewSnapshot(self.window.contentView.superview, path);
  }
}

- (void)showPane:(NSString *)pane {
  [self switchToPane:pane];
  [self showWindow:nil];
}

- (void)showWindow:(id)sender {
  if (!self.currentPaneIdentifier) {
    [self switchToPane:kToolbarASR];
  }
  [self loadCurrentValues];
  [self.window center];
  [self.window makeKeyAndOrderFront:sender];
  [NSApp activateIgnoringOtherApps:YES];
}

// ─── Window Chrome ──────────────────────────────────────────────────

// One diagonal gradient behind the whole window, a clear-backed sidebar on the
// left, and on the right a scrolling content area under a fixed page title,
// with the Save/Cancel footer pinned below it.
- (void)buildWindowChrome {
  SPGradientBackdropView *root = [[SPGradientBackdropView alloc]
      initWithFrame:self.window.contentView.bounds];
  root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  self.window.contentView = root;

  self.sidebar = [SPSettingsSidebarViewController new];
  NSView *sidebarView = self.sidebar.view;
  sidebarView.translatesAutoresizingMaskIntoConstraints = NO;
  [root addSubview:sidebarView];
  __weak typeof(self) weakSelf = self;
  self.sidebar.onSelect = ^(NSString *identifier) {
    [weakSelf switchToPane:identifier];
  };

  // No divider: the content simply abuts the sidebar, both over one gradient.
  NSView *content = [NSView new];
  content.translatesAutoresizingMaskIntoConstraints = NO;
  [root addSubview:content];

  // The page title is chrome, not content — it stays put while the pane below
  // it scrolls, so it never moves between panes.
  self.pageTitleLabel = [NSTextField labelWithString:@""];
  self.pageTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
  self.pageTitleLabel.font = SPTheme.pageTitleFont;
  self.pageTitleLabel.textColor = SPTheme.headingText;
  [content addSubview:self.pageTitleLabel];

  self.paneFooterView = [self buildPaneFooter];
  [content addSubview:self.paneFooterView];

  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  scroll.hasVerticalScroller = YES;
  scroll.drawsBackground = NO;
  // The window uses a full-size content view, so AppKit would otherwise inset
  // the document by the titlebar height and push the pane down under the title.
  scroll.automaticallyAdjustsContentInsets = NO;
  scroll.contentInsets = NSEdgeInsetsZero;
  self.paneScrollView = scroll;
  [content addSubview:scroll];

  self.paneDocumentView = [[SPFlippedDocumentView alloc] initWithFrame:NSZeroRect];
  scroll.documentView = self.paneDocumentView;

  CGFloat margin = SPTheme.pageMargin;
  [NSLayoutConstraint activateConstraints:@[
    [sidebarView.topAnchor constraintEqualToAnchor:root.topAnchor],
    [sidebarView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    [sidebarView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
    [sidebarView.widthAnchor constraintEqualToConstant:SPTheme.sidebarWidth],

    [content.topAnchor constraintEqualToAnchor:root.topAnchor],
    [content.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    [content.leadingAnchor constraintEqualToAnchor:sidebarView.trailingAnchor],
    [content.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],

    // The title stands inside the arch of the page frame (PageFrame.pdf).
    [self.pageTitleLabel.lastBaselineAnchor constraintEqualToAnchor:content.topAnchor
                                                           constant:SPTheme.pageTitleBaseline],
    [self.pageTitleLabel.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],

    [self.paneFooterView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
    [self.paneFooterView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    [self.paneFooterView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],

    [scroll.topAnchor constraintEqualToAnchor:content.topAnchor
                                     constant:SPTheme.pageContentTop],
    [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    [scroll.bottomAnchor constraintEqualToAnchor:self.paneFooterView.topAnchor],
  ]];
}

// Save/Cancel used to be laid out inside each pane at its bottom edge, which
// with a scrolling pane would scroll them out of reach. They are chrome now.
- (NSView *)buildPaneFooter {
  NSView *footer = [NSView new];
  footer.translatesAutoresizingMaskIntoConstraints = NO;

  NSButton *saveButton = [NSButton buttonWithTitle:@"Сохранить"
                                            target:self
                                            action:@selector(saveConfig:)];
  saveButton.translatesAutoresizingMaskIntoConstraints = NO;
  saveButton.bezelStyle = NSBezelStyleRounded;
  saveButton.keyEquivalent = @"\r";
  [footer addSubview:saveButton];

  NSButton *cancelButton = [NSButton buttonWithTitle:@"Отмена"
                                              target:self
                                              action:@selector(cancelSetup:)];
  cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
  cancelButton.bezelStyle = NSBezelStyleRounded;
  cancelButton.keyEquivalent = @"\033";
  [footer addSubview:cancelButton];

  SPApplyHouseStyle(footer);
  CGFloat margin = SPTheme.pageMargin;
  [NSLayoutConstraint activateConstraints:@[
    // Clear of the frame band along the bottom of the page.
    [footer.heightAnchor constraintEqualToConstant:78],

    [saveButton.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor
                                              constant:-margin],
    [saveButton.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
    [saveButton.widthAnchor constraintGreaterThanOrEqualToConstant:80],

    [cancelButton.trailingAnchor constraintEqualToAnchor:saveButton.leadingAnchor
                                                constant:-10],
    [cancelButton.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor],
    [cancelButton.widthAnchor constraintGreaterThanOrEqualToConstant:80],
  ]];
  return footer;
}

// Width available to a pane: the content area minus the scroller's gutter.
- (CGFloat)paneContentWidth {
  return SPTheme.windowContentSize.width - SPTheme.sidebarWidth;
}

// The scroll view's *visible* height. A pane whose editor should fill the
// window sizes itself to this instead of picking a fixed height, which would
// otherwise leave dead space under it in a window that no longer resizes.
- (CGFloat)paneViewportHeight {
  [self.window.contentView layoutSubtreeIfNeeded];
  CGFloat height = NSHeight(self.paneScrollView.contentView.bounds);
  // Before the first layout pass the scroll view has no size yet; fall back to
  // the height the fixed window geometry produces.
  return height > 100.0 ? height : 560.0;
}

// Text editors sit directly on their card. An NSTextView draws its own opaque
// textBackgroundColor by default, which would punch a hard white rectangle
// through the translucent card behind it.
- (void)styleEditorTextView:(NSTextView *)textView
                 scrollView:(NSScrollView *)scrollView {
  textView.drawsBackground = NO;
  textView.textColor = SPTheme.label;
  scrollView.drawsBackground = NO;
  scrollView.borderType = NSNoBorder;
  scrollView.scrollerStyle = NSScrollerStyleOverlay;
}

// Bezel-bordered editors (key lists, per-app modes, profile lists) would draw
// stark white boxes on the parchment; give them the theme's vellum instead.
- (void)applyVellumToEditors:(NSView *)root {
  for (NSView *view in root.subviews) {
    if ([view isKindOfClass:NSScrollView.class]) {
      NSScrollView *scroll = (NSScrollView *)view;
      if (scroll.borderType == NSBezelBorder || scroll.drawsBackground) {
        scroll.backgroundColor = SPTheme.fieldBackground;
        NSView *document = scroll.documentView;
        if ([document isKindOfClass:NSTextView.class] && ((NSTextView *)document).drawsBackground) {
          ((NSTextView *)document).backgroundColor = SPTheme.fieldBackground;
        } else if ([document isKindOfClass:NSTableView.class]) {
          ((NSTableView *)document).backgroundColor = NSColor.clearColor;
        }
      }
      continue;
    }
    [self applyVellumToEditors:view];
  }
}

- (NSString *)pageTitleForPane:(NSString *)identifier {
  if ([identifier isEqualToString:kToolbarASR])
    return @"Распознавание";
  if ([identifier isEqualToString:kToolbarLLM])
    return @"Языковая модель";
  if ([identifier isEqualToString:kToolbarOverlay])
    return @"Оверлей";
  if ([identifier isEqualToString:kToolbarHotkey])
    return @"Управление";
  if ([identifier isEqualToString:kToolbarDictionary])
    return @"Словарь";
  if ([identifier isEqualToString:kToolbarSnippets])
    return @"Сниппеты";
  if ([identifier isEqualToString:kToolbarSystemPrompt])
    return @"Промпт";
  if ([identifier isEqualToString:kToolbarTemplates])
    return @"Шаблоны";
  if ([identifier isEqualToString:kToolbarAbout])
    return @"О программе";
  return @"";
}

- (void)windowWillClose:(NSNotification *)notification {
  [self endHotkeyRecording];
  [self hideRuntimeOverlayPreview];
}


// ─── Pane Switching ─────────────────────────────────────────────────

- (void)switchToPane:(NSString *)identifier {
  if ([self.currentPaneIdentifier isEqualToString:identifier])
    return;

  // Save template edits before switching away
  if ([self.currentPaneIdentifier isEqualToString:kToolbarTemplates]) {
    [self saveCurrentTemplateEdits];
  } else if ([self.currentPaneIdentifier isEqualToString:kToolbarOverlay]) {
    [self hideRuntimeOverlayPreview];
  }
  [self endHotkeyRecording];

  self.currentPaneIdentifier = identifier;

  // Remove old pane
  // The pane and any tailpiece after it.
  [self.paneDocumentView.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];

  // Build new pane
  NSView *paneView;
  if ([identifier isEqualToString:kToolbarASR]) {
    paneView = [self buildAsrPane];
  } else if ([identifier isEqualToString:kToolbarLLM]) {
    paneView = [self buildLlmPane];
  } else if ([identifier isEqualToString:kToolbarOverlay]) {
    paneView = [self buildOverlayPane];
  } else if ([identifier isEqualToString:kToolbarHotkey]) {
    paneView = [self buildHotkeyPane];
  } else if ([identifier isEqualToString:kToolbarDictionary]) {
    paneView = [self buildDictionaryPane];
  } else if ([identifier isEqualToString:kToolbarSnippets]) {
    paneView = [self buildSnippetsPane];
  } else if ([identifier isEqualToString:kToolbarSystemPrompt]) {
    paneView = [self buildSystemPromptPane];
  } else if ([identifier isEqualToString:kToolbarTemplates]) {
    paneView = [self buildTemplatesPane];
  } else if ([identifier isEqualToString:kToolbarAbout]) {
    paneView = [self buildAboutPane];
  }

  if (!paneView)
    return;

  self.currentPaneView = paneView;
  [self applyVellumToEditors:paneView];
  SPApplyHouseStyle(paneView);
  self.pageTitleLabel.attributedStringValue =
      [SPTheme titleString:[self pageTitleForPane:identifier] size:SPTheme.pageTitleFont.pointSize];
  [self.sidebar selectPaneIdentifier:identifier];
  // About is the one pane with nothing to save.
  self.paneFooterView.hidden = [identifier isEqualToString:kToolbarAbout];

  [self hostPaneView:paneView];

  // Reload values for this pane
  [self loadValuesForPane:identifier];
}

// Place a pane inside the scrolling document. Panes lay themselves out with
// absolute frames in a bottom-left origin, so the pane keeps its own unflipped
// coordinate system and only the document view is flipped — its height is the
// pane's, which is what makes a tall pane scroll instead of resizing anything.
- (void)hostPaneView:(NSView *)paneView {
  CGFloat width = [self paneContentWidth];
  CGFloat height = MAX(paneView.frame.size.height,
                       NSHeight(self.paneScrollView.contentView.bounds));
  self.paneDocumentView.frame = NSMakeRect(0, 0, width, height);
  paneView.frame = NSMakeRect(0, 0, width, paneView.frame.size.height);
  paneView.autoresizingMask = NSViewWidthSizable;
  [self.paneDocumentView addSubview:paneView];
  // A short pane ends with a tailpiece, as a chapter does in a book.
  CGFloat viewport = NSHeight(self.paneScrollView.contentView.bounds);
  if (paneView.frame.size.height + 96.0 <= viewport) {
    SPTailpieceView *tail = [[SPTailpieceView alloc]
        initWithFrame:NSMakeRect(0, paneView.frame.size.height + 18.0, width, 60.0)];
    tail.autoresizingMask = NSViewWidthSizable;
    [self.paneDocumentView addSubview:tail];
  }
  // Always start a pane at its top: an inherited scroll offset from the pane
  // before it would otherwise open the new one part-way down.
  [self.paneDocumentView scrollPoint:NSZeroPoint];
}

// Re-host the current pane after its intrinsic height changed (the ASR pane
// grows and shrinks with the selected provider). Only the document height
// needs to follow — no window resize.
- (void)refreshHostedPaneHeight {
  if (!self.currentPaneView)
    return;
  [self hostPaneView:self.currentPaneView];
}

// ─── Build Panes ────────────────────────────────────────────────────

- (NSView *)buildAsrPane {
  CGFloat paneWidth = [self paneContentWidth];
  CGFloat contentX = SPTheme.pageMargin;
  CGFloat contentW = paneWidth - 2.0 * contentX;
  // Label column measured from the actual strings so no label ever clips.
  CGFloat labelW = [self formLabelColumnWidthForTitles:@[
    @"Провайдер", @"Режим авторизации", @"API-ключ", @"App Key", @"Access Key",
    @"Язык", @"Модель", @"Пауза конца фразы", @"Вариант вывода",
    @"Режим текста", @"Язык перевода", @"Ключи DashScope",
    @"(по одному в строке)", @"Режим по приложению"
  ]];
  // The form sits inside a card, so its columns are inset by the card padding.
  CGFloat formX = contentX + SPTheme.cardPadding;
  CGFloat fieldX = formX + labelW + 12;
  // Capped: at the window's full width a text field would run ~500pt, which
  // reads as a stretched form rather than a column of inputs.
  CGFloat fieldW =
      MIN(paneWidth - fieldX - contentX - SPTheme.cardPadding, 440.0);
  CGFloat rowH = 32;

  // Calculate content height (auth mode, test result, language, advanced
  // section)
  CGFloat contentHeight = 450;
  NSView *pane =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];

  CGFloat y = contentHeight - 30.0;

  // Description
  NSTextField *desc =
      [self addSettingsDescriptionText:
                @"Выберите провайдера распознавания речи."
                                toPane:pane
                                  topY:y
                                     x:contentX
                                 width:contentW];

  NSTextField *sectionTitle = [self
      sectionTitleLabel:@"Подключение"
                  frame:NSMakeRect(contentX, floor(NSMinY(desc.frame) - 36.0),
                                   contentW, 20)];
  [pane addSubview:sectionTitle];

  // The card that every form row floats on. It is added before the rows so it
  // stays behind them, and it is the one subview pinned to BOTH pane edges —
  // the rows are top-anchored, so the card stretches as the pane grows and
  // shrinks with the selected provider.
  CGFloat formCardTop = NSMinY(sectionTitle.frame) - SPTheme.sectionHeadingGap;
  self.asrFormCard = [self
      surfaceCardViewWithFrame:NSMakeRect(contentX, contentX, contentW,
                                          formCardTop - contentX)];
  [pane addSubview:self.asrFormCard];

  y = formCardTop - SPTheme.cardPadding - 22.0;
  CGFloat formStartY = y;

  // Provider
  [pane addSubview:[self formLabel:@"Провайдер"
                             frame:NSMakeRect(formX, y, labelW, 22)]];
  self.asrProviderPopup =
      [[NSPopUpButton alloc] initWithFrame:NSMakeRect(fieldX, y - 2, 200, 26)
                                 pullsDown:NO];
  [self.asrProviderPopup addItemWithTitle:@"Qwen (Alibaba Cloud)"];
  [self.asrProviderPopup lastItem].representedObject = @"qwen";
  [self.asrProviderPopup addItemWithTitle:@"Doubao (ByteDance)"];
  [self.asrProviderPopup lastItem].representedObject = @"doubao";
  [self.asrProviderPopup addItemWithTitle:@"GLM (Zhipu)"];
  [self.asrProviderPopup lastItem].representedObject = @"glm";
  [self.asrProviderPopup addItemWithTitle:@"MiMo (Xiaomi)"];
  [self.asrProviderPopup lastItem].representedObject = @"mimo";
  NSArray<NSString *> *supportedLocalProviders =
      [self.rustBridge supportedLocalProviders];
  // Add Apple Speech (macOS 26+, no model download required; also requires the
  // apple-speech feature to be compiled into the Rust core — excluded on
  // x86_64)
  if (@available(macOS 26.0, *)) {
    if ([supportedLocalProviders containsObject:@"apple-speech"]) {
      [self.asrProviderPopup addItemWithTitle:@"Apple Speech (на устройстве)"];
      [self.asrProviderPopup lastItem].representedObject = @"apple-speech";
    }
  }
  // Add local providers supported by this build (model-based)
  NSDictionary *localProviderLabels = @{
    @"mlx" : @"MLX (Apple Silicon)",
    @"sherpa-onnx" : @"Sherpa-ONNX",
    @"wetype" : @"WeType (на устройстве)",
  };
  for (NSString *provider in supportedLocalProviders) {
    NSString *label = localProviderLabels[provider];
    if (!label)
      continue; // apple-speech handled above
    [self.asrProviderPopup addItemWithTitle:label];
    [self.asrProviderPopup lastItem].representedObject = provider;
  }
  [self.asrProviderPopup setTarget:self];
  [self.asrProviderPopup setAction:@selector(asrProviderChanged:)];
  [pane addSubview:self.asrProviderPopup];

  // Test button next to Provider
  self.asrTestButton = [NSButton buttonWithTitle:@"Проверить"
                                          target:self
                                          action:@selector(testAsrConnection:)];
  self.asrTestButton.bezelStyle = NSBezelStyleRounded;
  self.asrTestButton.frame = NSMakeRect(fieldX + 208, y - 2, 70, 28);
  [pane addSubview:self.asrTestButton];
  y -= rowH;

  // Auth Mode segmented control (Doubao only)
  NSTextField *authModeLabel = [self formLabel:@"Режим авторизации"
                                         frame:NSMakeRect(formX, y, labelW, 22)];
  authModeLabel.tag = 1006;
  authModeLabel.hidden = YES;
  [pane addSubview:authModeLabel];
  self.asrAuthModeControl = [[NSSegmentedControl alloc]
      initWithFrame:NSMakeRect(fieldX, y - 1, 240, 24)];
  [self.asrAuthModeControl setSegmentCount:2];
  [self.asrAuthModeControl setLabel:@"Новая консоль" forSegment:0];
  [self.asrAuthModeControl setLabel:@"Старая консоль" forSegment:1];
  [self.asrAuthModeControl setSelectedSegment:0];
  [self.asrAuthModeControl setTarget:self];
  [self.asrAuthModeControl setAction:@selector(asrAuthModeChanged:)];
  self.asrAuthModeControl.hidden = YES;
  [pane addSubview:self.asrAuthModeControl];
  y -= rowH;

  // API Key (Doubao new console mode)
  CGFloat eyeW = 28;
  CGFloat secFieldW = fieldW - eyeW - 4;
  self.asrApiKeySecureField = [[NSSecureTextField alloc]
      initWithFrame:NSMakeRect(fieldX, y, secFieldW, 22)];
  self.asrApiKeySecureField.placeholderString =
      @"API-ключ из консоли Volcengine";
  self.asrApiKeySecureField.font = [NSFont systemFontOfSize:13];
  self.asrApiKeySecureField.hidden = YES;
  [pane addSubview:self.asrApiKeySecureField];
  self.asrApiKeyField = [self formTextField:NSMakeRect(fieldX, y, secFieldW, 22)
                                placeholder:@"API-ключ из консоли Volcengine"];
  self.asrApiKeyField.hidden = YES;
  [pane addSubview:self.asrApiKeyField];
  self.asrApiKeyToggle = [self
      eyeButtonWithFrame:NSMakeRect(fieldX + secFieldW + 4, y - 1, eyeW, 24)
                  action:@selector(toggleAsrApiKeyVisibility:)];
  self.asrApiKeyToggle.hidden = YES;
  [pane addSubview:self.asrApiKeyToggle];
  NSTextField *apiKeyLabel = [self formLabel:@"API-ключ"
                                       frame:NSMakeRect(formX, y, labelW, 22)];
  apiKeyLabel.tag = 1007;
  apiKeyLabel.hidden = YES;
  [pane addSubview:apiKeyLabel];

  // App Key (Doubao legacy mode)
  self.asrAppKeyField = [self formTextField:NSMakeRect(fieldX, y, fieldW, 22)
                                placeholder:@"App ID Volcengine"];
  [pane addSubview:self.asrAppKeyField];
  NSTextField *appKeyLabel = [self formLabel:@"App Key"
                                       frame:NSMakeRect(formX, y, labelW, 22)];
  appKeyLabel.tag = 1001;
  [pane addSubview:appKeyLabel];

  // Apple Speech locale popup (same row as App Key / Model, tag 1005)
  NSTextField *localeLabel = [self formLabel:@"Язык"
                                       frame:NSMakeRect(formX, y, labelW, 22)];
  localeLabel.tag = 1005;
  localeLabel.hidden = YES;
  [pane addSubview:localeLabel];
  self.appleSpeechLocalePopup = [[NSPopUpButton alloc]
      initWithFrame:NSMakeRect(fieldX, y - 2, fieldW - 26, 26)
          pullsDown:NO];
  self.appleSpeechLocalePopup.hidden = YES;
  [self.appleSpeechLocalePopup setTarget:self];
  [self.appleSpeechLocalePopup setAction:@selector(appleSpeechLocaleChanged:)];
  // Populate from system-reported supported locales
  [self populateAppleSpeechLocalePopup];
  [pane addSubview:self.appleSpeechLocalePopup];

  // Row 1: Model popup + Download button (Local providers, same row as App Key)
  self.localModelLabel = [self formLabel:@"Модель"
                                   frame:NSMakeRect(formX, y, labelW, 22)];
  self.localModelLabel.tag = 1004;
  self.localModelLabel.hidden = YES;
  [pane addSubview:self.localModelLabel];
  self.localModelPopup = [[NSPopUpButton alloc]
      initWithFrame:NSMakeRect(fieldX, y - 2, fieldW - 26, 26)
          pullsDown:NO];
  self.localModelPopup.hidden = YES;
  [self.localModelPopup setTarget:self];
  [self.localModelPopup setAction:@selector(localModelChanged:)];
  [pane addSubview:self.localModelPopup];

  // Download button (right of model popup, same style as eye button)
  self.modelDownloadButton = [[NSButton alloc]
      initWithFrame:NSMakeRect(fieldX + fieldW - 20, y + 1, 20, 20)];
  self.modelDownloadButton.image =
      [NSImage imageWithSystemSymbolName:@"arrow.down.circle"
                accessibilityDescription:@"Скачать"];
  self.modelDownloadButton.bezelStyle = NSBezelStyleInline;
  self.modelDownloadButton.bordered = NO;
  self.modelDownloadButton.imageScaling = NSImageScaleProportionallyUpOrDown;
  self.modelDownloadButton.target = self;
  self.modelDownloadButton.action = @selector(downloadSelectedModel:);
  self.modelDownloadButton.hidden = YES;
  [pane addSubview:self.modelDownloadButton];

  y -= rowH;

  // Row 2: Status + Delete button
  self.modelStatusLabel = [[SPStatusLabel alloc]
      initWithFrame:NSMakeRect(fieldX, y + 2, fieldW - 32, 18)];
  self.modelStatusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
  self.modelStatusLabel.usesSingleLineMode = YES;
  self.modelStatusLabel.bezeled = NO;
  self.modelStatusLabel.drawsBackground = NO;
  self.modelStatusLabel.editable = NO;
  self.modelStatusLabel.selectable = NO;
  self.modelStatusLabel.font = [NSFont systemFontOfSize:12];
  self.modelStatusLabel.hidden = YES;
  [pane addSubview:self.modelStatusLabel];

  // Delete button (right end of status row, same style as eye button)
  self.modelDeleteButton = [[NSButton alloc]
      initWithFrame:NSMakeRect(fieldX + fieldW - 20, y + 1, 20, 20)];
  self.modelDeleteButton.image = [NSImage imageWithSystemSymbolName:@"trash"
                                           accessibilityDescription:@"Удалить"];
  self.modelDeleteButton.bezelStyle = NSBezelStyleInline;
  self.modelDeleteButton.bordered = NO;
  self.modelDeleteButton.imageScaling = NSImageScaleProportionallyUpOrDown;
  self.modelDeleteButton.target = self;
  self.modelDeleteButton.action = @selector(deleteSelectedModel:);
  self.modelDeleteButton.hidden = YES;
  [pane addSubview:self.modelDeleteButton];

  y -= rowH;

  // Row 3: Progress bar + size label
  self.modelProgressBar = [[NSProgressIndicator alloc]
      initWithFrame:NSMakeRect(fieldX, y + 10, fieldW - 120, 10)];
  self.modelProgressBar.controlSize = NSControlSizeMini;
  self.modelProgressBar.style = NSProgressIndicatorStyleBar;
  self.modelProgressBar.minValue = 0;
  self.modelProgressBar.maxValue = 100;
  self.modelProgressBar.indeterminate = NO;
  self.modelProgressBar.hidden = YES;
  [pane addSubview:self.modelProgressBar];

  self.modelProgressSizeLabel = [[NSTextField alloc]
      initWithFrame:NSMakeRect(fieldX + fieldW - 114, y + 2, 114, 18)];
  self.modelProgressSizeLabel.bezeled = NO;
  self.modelProgressSizeLabel.drawsBackground = NO;
  self.modelProgressSizeLabel.editable = NO;
  self.modelProgressSizeLabel.selectable = NO;
  self.modelProgressSizeLabel.alignment = NSTextAlignmentRight;
  self.modelProgressSizeLabel.font =
      [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
  self.modelProgressSizeLabel.textColor = [NSColor secondaryLabelColor];
  self.modelProgressSizeLabel.hidden = YES;
  [pane addSubview:self.modelProgressSizeLabel];

  y -= rowH;

  // Access Key (Doubao) — fixed at row 2 (same as Qwen API Key)
  CGFloat accessKeyY = formStartY - rowH - rowH - rowH;

  self.asrAccessKeySecureField = [[NSSecureTextField alloc]
      initWithFrame:NSMakeRect(fieldX, accessKeyY, secFieldW, 22)];
  self.asrAccessKeySecureField.placeholderString = @"Access Token Volcengine";
  self.asrAccessKeySecureField.font = [NSFont systemFontOfSize:13];
  [pane addSubview:self.asrAccessKeySecureField];
  self.asrAccessKeyField =
      [self formTextField:NSMakeRect(fieldX, accessKeyY, secFieldW, 22)
              placeholder:@"Access Token Volcengine"];
  self.asrAccessKeyField.hidden = YES;
  [pane addSubview:self.asrAccessKeyField];
  self.asrAccessKeyToggle =
      [self eyeButtonWithFrame:NSMakeRect(fieldX + secFieldW + 4,
                                          accessKeyY - 1, eyeW, 24)
                        action:@selector(toggleAsrAccessKeyVisibility:)];
  [pane addSubview:self.asrAccessKeyToggle];
  NSTextField *accessKeyLabel =
      [self formLabel:@"Access Key"
                frame:NSMakeRect(formX, accessKeyY, labelW, 22)];
  accessKeyLabel.tag = 1002;
  [pane addSubview:accessKeyLabel];

  // Qwen model: the row Doubao's auth mode uses, with the trade-off hint under
  // it; the rest of the Qwen form moves down by the hint. Tag 1017.
  CGFloat qwenModelY = formStartY - rowH;
  NSTextField *qwenModelLabel =
      [self formLabel:@"Модель" frame:NSMakeRect(formX, qwenModelY, labelW, 22)];
  qwenModelLabel.tag = 1017;
  qwenModelLabel.hidden = YES;
  [pane addSubview:qwenModelLabel];
  self.asrQwenModelRowWidth = fieldW;
  self.asrQwenModelPopup = [[NSPopUpButton alloc]
      initWithFrame:NSMakeRect(fieldX, qwenModelY - 2, fieldW, 26)
          pullsDown:NO];
  for (NSString *model in SPQwenModelChoice.presetModels) {
    [self.asrQwenModelPopup
        addItemWithTitle:[SPQwenModelChoice titleForPresetModel:model]];
    [self.asrQwenModelPopup lastItem].representedObject = model;
  }
  [self.asrQwenModelPopup addItemWithTitle:@"Другая…"];
  self.asrQwenModelPopup.target = self;
  self.asrQwenModelPopup.action = @selector(qwenModelChanged:);
  self.asrQwenModelPopup.tag = 1017;
  self.asrQwenModelPopup.hidden = YES;
  [pane addSubview:self.asrQwenModelPopup];
  self.asrQwenModelCustomField =
      [self formTextField:NSMakeRect(fieldX, qwenModelY, fieldW, 22)
              placeholder:@"Идентификатор модели DashScope"];
  self.asrQwenModelCustomField.hidden = YES;
  [pane addSubview:self.asrQwenModelCustomField];
  NSTextField *qwenModelHint = [NSTextField wrappingLabelWithString:
      @"Умная модель расставляет знаки и убирает оговорки, но может "
      @"переформулировать. Дословная только записывает сказанное. Перевод, "
      @"вопрос и правка голосом работают только с умной."];
  qwenModelHint.font = [NSFont systemFontOfSize:11];
  qwenModelHint.textColor = [NSColor secondaryLabelColor];
  CGFloat qwenModelHintH = [self fittingHeightForWrappingLabel:qwenModelHint
                                                         width:fieldW];
  qwenModelHint.frame = NSMakeRect(fieldX, qwenModelY - 6 - qwenModelHintH,
                                   fieldW, qwenModelHintH);
  qwenModelHint.tag = 1017;
  qwenModelHint.hidden = YES;
  [pane addSubview:qwenModelHint];

  // Qwen: DashScope keys, output mode, translation target, field context
  // switch and the per-app mode editor. Every view is tagged for the provider
  // switch (1003, 1014, 1015, 1016).
  CGFloat qwenY = formStartY - rowH - rowH - (qwenModelHintH + 6);
  const CGFloat qwenKeysH = 66.0;
  NSTextField *qwenKeyLabel =
      [self formLabel:@"Ключи DashScope\n(по одному в строке)"
                frame:NSMakeRect(formX, qwenY + 22 - 36, labelW, 36)];
  qwenKeyLabel.maximumNumberOfLines = 2;
  qwenKeyLabel.tag = 1003;
  qwenKeyLabel.hidden = YES;
  [pane addSubview:qwenKeyLabel];

  NSScrollView *qwenKeysScroll = [[NSScrollView alloc]
      initWithFrame:NSMakeRect(fieldX, qwenY + 22 - qwenKeysH, fieldW,
                               qwenKeysH)];
  qwenKeysScroll.hasVerticalScroller = YES;
  qwenKeysScroll.borderType = NSBezelBorder;
  NSSize qwenKeysContent = qwenKeysScroll.contentSize;
  self.asrQwenKeysTextView = [[SPKeysTextView alloc]
      initWithFrame:NSMakeRect(0, 0, qwenKeysContent.width,
                               qwenKeysContent.height)];
  self.asrQwenKeysTextView.minSize = NSMakeSize(0, qwenKeysContent.height);
  self.asrQwenKeysTextView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
  self.asrQwenKeysTextView.verticallyResizable = YES;
  self.asrQwenKeysTextView.horizontallyResizable = NO;
  self.asrQwenKeysTextView.autoresizingMask = NSViewWidthSizable;
  self.asrQwenKeysTextView.textContainer.widthTracksTextView = YES;
  self.asrQwenKeysTextView.textContainer.containerSize =
      NSMakeSize(qwenKeysContent.width, CGFLOAT_MAX);
  self.asrQwenKeysTextView.font =
      [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
  self.asrQwenKeysTextView.richText = NO;
  self.asrQwenKeysTextView.automaticQuoteSubstitutionEnabled = NO;
  self.asrQwenKeysTextView.automaticDashSubstitutionEnabled = NO;
  self.asrQwenKeysTextView.automaticTextReplacementEnabled = NO;
  self.asrQwenKeysTextView.automaticSpellingCorrectionEnabled = NO;
  self.asrQwenKeysTextView.continuousSpellCheckingEnabled = NO;
  __weak typeof(self) weakSelf = self;
  self.asrQwenKeysTextView.onFocusChange = ^(BOOL focused) {
    [weakSelf qwenKeysFocusChanged:focused];
  };
  qwenKeysScroll.documentView = self.asrQwenKeysTextView;
  qwenKeysScroll.hidden = YES;
  [pane addSubview:qwenKeysScroll];
  NSButton *keyHelpLink = [self linkButtonWithTitle:@"Как получить ключ"
                                             action:@selector(openDashScopeKeyHelp:)];
  keyHelpLink.frame = NSMakeRect(formX, qwenY + 22 - qwenKeysH + 2, labelW, 18);
  keyHelpLink.tag = 1003;
  keyHelpLink.hidden = YES;
  [pane addSubview:keyHelpLink];

  CGFloat qwenModeY = qwenY + 22 - qwenKeysH - 12 - 22;
  NSTextField *qwenModeLabel =
      [self formLabel:@"Режим текста"
                frame:NSMakeRect(formX, qwenModeY, labelW, 22)];
  qwenModeLabel.tag = 1014;
  qwenModeLabel.hidden = YES;
  [pane addSubview:qwenModeLabel];
  self.asrQwenOutputModePopup = [[NSPopUpButton alloc]
      initWithFrame:NSMakeRect(fieldX, qwenModeY - 2, 240, 26)
          pullsDown:NO];
  NSArray<NSArray<NSString *> *> *qwenModes = @[
    @[ @"Как сказал (пунктуация)", @"raw" ],
    @[ @"Лёгкая правка", @"light" ],
    @[ @"Структура (списки, шаги)", @"structured" ],
    @[ @"Деловой стиль", @"formal" ],
  ];
  for (NSArray<NSString *> *mode in qwenModes) {
    [self.asrQwenOutputModePopup addItemWithTitle:mode[0]];
    [self.asrQwenOutputModePopup lastItem].representedObject = mode[1];
  }
  self.asrQwenOutputModePopup.hidden = YES;
  [pane addSubview:self.asrQwenOutputModePopup];

  CGFloat qwenTranslateY = qwenModeY - rowH;
  NSTextField *qwenTranslateLabel =
      [self formLabel:@"Язык перевода"
                frame:NSMakeRect(formX, qwenTranslateY, labelW, 22)];
  qwenTranslateLabel.tag = 1015;
  qwenTranslateLabel.hidden = YES;
  [pane addSubview:qwenTranslateLabel];
  self.asrQwenTranslateToField =
      [self formTextField:NSMakeRect(fieldX, qwenTranslateY, 240, 22)
              placeholder:@"английский"];
  self.asrQwenTranslateToField.hidden = YES;
  [pane addSubview:self.asrQwenTranslateToField];

  CGFloat qwenContextY = qwenTranslateY - rowH;
  self.asrQwenFieldContextCheckbox =
      [NSButton checkboxWithTitle:@"Учитывать текст вокруг курсора"
                           target:nil
                           action:nil];
  self.asrQwenFieldContextCheckbox.frame =
      NSMakeRect(fieldX, qwenContextY, fieldW, 22);
  self.asrQwenFieldContextCheckbox.font = [NSFont systemFontOfSize:12];
  // Disclosure (PRIVACY.md): on by default, sent only with the audio.
  self.asrQwenFieldContextCheckbox.toolTip =
      @"Вместе со звуком провайдеру Qwen Omni уходят заголовок окна и до 400 "
      @"знаков перед курсором, чтобы точнее расставить слова и знаки. Нигде не "
      @"сохраняется. Поля паролей и защищённый ввод не читаются.";
  self.asrQwenFieldContextCheckbox.tag = 1016;
  self.asrQwenFieldContextCheckbox.hidden = YES;
  [pane addSubview:self.asrQwenFieldContextCheckbox];

  CGFloat qwenAppModesY = qwenContextY - rowH;
  const CGFloat qwenAppModesH = 112.0;
  NSTextField *qwenAppModesLabel =
      [self formLabel:@"Режим по приложению"
                frame:NSMakeRect(formX, qwenAppModesY, labelW, 22)];
  qwenAppModesLabel.tag = 1016;
  qwenAppModesLabel.hidden = YES;
  [pane addSubview:qwenAppModesLabel];
  self.asrQwenAppModesScroll = [[NSScrollView alloc]
      initWithFrame:NSMakeRect(fieldX, qwenAppModesY + 22 - qwenAppModesH,
                               fieldW, qwenAppModesH)];
  self.asrQwenAppModesScroll.hasVerticalScroller = YES;
  self.asrQwenAppModesScroll.borderType = NSBezelBorder;
  self.asrQwenAppModesRows = [[SPFlippedDocumentView alloc]
      initWithFrame:NSMakeRect(0, 0, self.asrQwenAppModesScroll.contentSize.width,
                               qwenAppModesH)];
  self.asrQwenAppModesScroll.documentView = self.asrQwenAppModesRows;
  self.asrQwenAppModesScroll.hidden = YES;
  [pane addSubview:self.asrQwenAppModesScroll];
  self.asrQwenAppModeEntries = [NSMutableArray array];
  self.asrQwenAppModeFields = [NSMutableArray array];
  self.asrQwenAppModePopups = [NSMutableArray array];

  CGFloat qwenAppButtonsY = qwenAppModesY + 22 - qwenAppModesH - 30;
  NSButton *qwenAddAppButton =
      [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"plus"
                                          accessibilityDescription:@"Добавить"]
                         target:self
                         action:@selector(addQwenAppModeRow:)];
  qwenAddAppButton.frame = NSMakeRect(fieldX, qwenAppButtonsY, 32, 26);
  qwenAddAppButton.bezelStyle = NSBezelStyleRounded;
  qwenAddAppButton.tag = 1016;
  qwenAddAppButton.hidden = YES;
  [pane addSubview:qwenAddAppButton];
  self.asrQwenAddRunningAppButton =
      [NSButton buttonWithTitle:@"Добавить запущенное…"
                         target:self
                         action:@selector(showRunningAppsMenu:)];
  self.asrQwenAddRunningAppButton.frame =
      NSMakeRect(fieldX + 40, qwenAppButtonsY, 190, 26);
  self.asrQwenAddRunningAppButton.bezelStyle = NSBezelStyleRounded;
  self.asrQwenAddRunningAppButton.tag = 1016;
  self.asrQwenAddRunningAppButton.hidden = YES;
  [pane addSubview:self.asrQwenAddRunningAppButton];

  NSTextField *qwenAppModesHint = [NSTextField wrappingLabelWithString:
      @"Идентификатор приложения (com.apple.mail) или его имя; подойдёт и "
      @"начало идентификатора. Если приложения нет в списке: мессенджеры, "
      @"терминалы, редакторы кода и ИИ-чаты — как сказал, остальные — режим "
      @"выше. Перевод, вопрос и правка голосом всегда отправляют звук в "
      @"DashScope (Qwen Omni), даже если диктовка локальная."];
  qwenAppModesHint.font = [NSFont systemFontOfSize:11];
  qwenAppModesHint.textColor = [NSColor secondaryLabelColor];
  CGFloat qwenHintW = fieldW;
  CGFloat qwenHintH = [self fittingHeightForWrappingLabel:qwenAppModesHint
                                                    width:qwenHintW];
  qwenAppModesHint.frame = NSMakeRect(fieldX, qwenAppButtonsY - 8 - qwenHintH,
                                      qwenHintW, qwenHintH);
  qwenAppModesHint.tag = 1016;
  qwenAppModesHint.hidden = YES;
  [pane addSubview:qwenAppModesHint];
  self.asrQwenRequiredPaneHeight =
      ceil(contentHeight - NSMinY(qwenAppModesHint.frame)) + 56.0;

  // GLM API Key — fixed at row 1 (same position as Qwen, toggled by provider)
  CGFloat glmY = formStartY - rowH - rowH;
  self.asrGlmApiKeySecureField = [[NSSecureTextField alloc]
      initWithFrame:NSMakeRect(fieldX, glmY, secFieldW, 22)];
  self.asrGlmApiKeySecureField.placeholderString =
      @"API-ключ с bigmodel.cn";
  self.asrGlmApiKeySecureField.font = [NSFont systemFontOfSize:13];
  self.asrGlmApiKeySecureField.hidden = YES;
  [pane addSubview:self.asrGlmApiKeySecureField];
  self.asrGlmApiKeyField =
      [self formTextField:NSMakeRect(fieldX, glmY, secFieldW, 22)
              placeholder:@"API-ключ с bigmodel.cn"];
  self.asrGlmApiKeyField.hidden = YES;
  [pane addSubview:self.asrGlmApiKeyField];
  self.asrGlmApiKeyToggle = [self
      eyeButtonWithFrame:NSMakeRect(fieldX + secFieldW + 4, glmY - 1, eyeW, 24)
                  action:@selector(toggleGlmApiKeyVisibility:)];
  self.asrGlmApiKeyToggle.hidden = YES;
  [pane addSubview:self.asrGlmApiKeyToggle];
  NSTextField *glmKeyLabel =
      [self formLabel:@"API-ключ" frame:NSMakeRect(formX, glmY, labelW, 22)];
  glmKeyLabel.tag = 1010;
  glmKeyLabel.hidden = YES;
  [pane addSubview:glmKeyLabel];

  // MiMo API Key — fixed at row 1 (same position as Qwen/GLM, toggled by provider)
  CGFloat mimoY = formStartY - rowH - rowH;
  self.asrMimoApiKeySecureField = [[NSSecureTextField alloc]
      initWithFrame:NSMakeRect(fieldX, mimoY, secFieldW, 22)];
  self.asrMimoApiKeySecureField.placeholderString =
      @"API-ключ с xiaomimimo.com";
  self.asrMimoApiKeySecureField.font = [NSFont systemFontOfSize:13];
  self.asrMimoApiKeySecureField.hidden = YES;
  [pane addSubview:self.asrMimoApiKeySecureField];
  self.asrMimoApiKeyField =
      [self formTextField:NSMakeRect(fieldX, mimoY, secFieldW, 22)
              placeholder:@"API-ключ с xiaomimimo.com"];
  self.asrMimoApiKeyField.hidden = YES;
  [pane addSubview:self.asrMimoApiKeyField];
  self.asrMimoApiKeyToggle = [self
      eyeButtonWithFrame:NSMakeRect(fieldX + secFieldW + 4, mimoY - 1, eyeW, 24)
                  action:@selector(toggleMimoApiKeyVisibility:)];
  self.asrMimoApiKeyToggle.hidden = YES;
  [pane addSubview:self.asrMimoApiKeyToggle];
  NSTextField *mimoKeyLabel =
      [self formLabel:@"API-ключ" frame:NSMakeRect(formX, mimoY, labelW, 22)];
  mimoKeyLabel.tag = 1011;
  mimoKeyLabel.hidden = YES;
  [pane addSubview:mimoKeyLabel];
  // Privacy notice — audio is sent to Xiaomi's servers, not ours.
  NSTextField *mimoPrivacyNotice = [NSTextField wrappingLabelWithString:
      @"Выбирая модель Xiaomi (MiMo), вы добровольно соглашаетесь на "
      @"сбор Xiaomi ваших персональных данных и голоса. «Великий & Могучий» ничего не "
      @"собирает и не держит серверов. По любым вопросам обращайтесь в "
      @"Xiaomi."];
  mimoPrivacyNotice.font = [NSFont systemFontOfSize:11];
  // Measured height so the full notice is always visible; sits below the
  // test result row, growing downward. All provider notes share the same
  // horizontal span: from the label column's left edge to one card padding
  // short of the card's right edge, so both sides read balanced.
  CGFloat noteX = formX;
  CGFloat noteW = contentX + contentW - SPTheme.cardPadding - noteX;
  CGFloat mimoNoticeH = [self fittingHeightForWrappingLabel:mimoPrivacyNotice
                                                      width:noteW];
  CGFloat mimoNoticeTop = mimoY - rowH * 2 - 6;
  mimoPrivacyNotice.frame = NSMakeRect(noteX, mimoNoticeTop - mimoNoticeH,
                                       noteW, mimoNoticeH);
  mimoPrivacyNotice.textColor = SPTheme.warning;
  mimoPrivacyNotice.tag = 1011;
  mimoPrivacyNotice.hidden = YES;
  [pane addSubview:mimoPrivacyNotice];
  // Pane height needed to show the whole notice (56pt bottom button area).
  self.asrMimoRequiredPaneHeight =
      ceil(contentHeight - NSMinY(mimoPrivacyNotice.frame)) + 56.0;

  // WeType language note — in testing the on-device model only reliably
  // recognizes Chinese; say so under its model rows.
  NSTextField *wetypeNote = [NSTextField wrappingLabelWithString:
      @"Примечание: по нашим тестам эта модель на устройстве понимает "
      @"только китайский. Другие языки не распознаются."];
  wetypeNote.font = [NSFont systemFontOfSize:11];
  wetypeNote.textColor = SPTheme.warning;
  CGFloat wetypeNoteH = [self fittingHeightForWrappingLabel:wetypeNote
                                                      width:noteW];
  // Below the model progress row, clear of every model-management control.
  CGFloat wetypeNoteTop = NSMinY(self.modelProgressBar.frame) - 18.0;
  wetypeNote.frame =
      NSMakeRect(noteX, wetypeNoteTop - wetypeNoteH, noteW, wetypeNoteH);
  wetypeNote.tag = 1013;
  wetypeNote.hidden = YES;
  [pane addSubview:wetypeNote];
  self.asrWetypeRequiredPaneHeight =
      ceil(contentHeight - NSMinY(wetypeNote.frame)) + 56.0;

  // Test result label — pinned to the bottom of the form card rather than to a
  // fixed row, because the pane's height changes with the provider: anchored to
  // the top like the rows, it ended up below the card entirely (and off-window)
  // for the compact providers, so a failed test reported nowhere.
  SPStatusLabel *asrTestResult = [SPStatusLabel labelWithString:@""];
  asrTestResult.lineBreakMode = NSLineBreakByTruncatingTail;
  asrTestResult.usesSingleLineMode = YES;
  self.asrTestResultLabel = asrTestResult;
  CGFloat testResultY = accessKeyY - rowH;
  self.asrTestResultLabel.frame =
      NSMakeRect(formX, contentX + SPTheme.cardPadding,
                 contentW - 2.0 * SPTheme.cardPadding, 20);
  self.asrTestResultLabel.font = [NSFont systemFontOfSize:12];
  self.asrTestResultLabel.selectable = YES;
  [pane addSubview:self.asrTestResultLabel];

  // Language popup (Doubao)
  CGFloat langY = testResultY - rowH;
  NSTextField *langLabel = [self formLabel:@"Язык"
                                     frame:NSMakeRect(formX, langY, labelW, 22)];
  langLabel.tag = 1008;
  langLabel.hidden = YES;
  [pane addSubview:langLabel];
  self.asrLanguagePopup = [[NSPopUpButton alloc]
      initWithFrame:NSMakeRect(fieldX, langY - 2, 200, 26)
          pullsDown:NO];
  [self.asrLanguagePopup addItemWithTitle:@"Авто (китайский, английский, диалекты)"];
  [self.asrLanguagePopup lastItem].representedObject = @"";
  [self.asrLanguagePopup addItemWithTitle:@"Китайский (путунхуа)"];
  [self.asrLanguagePopup lastItem].representedObject = @"zh-CN";
  [self.asrLanguagePopup addItemWithTitle:@"Английский"];
  [self.asrLanguagePopup lastItem].representedObject = @"en-US";
  [self.asrLanguagePopup addItemWithTitle:@"Японский"];
  [self.asrLanguagePopup lastItem].representedObject = @"ja-JP";
  [self.asrLanguagePopup addItemWithTitle:@"Корейский"];
  [self.asrLanguagePopup lastItem].representedObject = @"ko-KR";
  [self.asrLanguagePopup addItemWithTitle:@"Немецкий"];
  [self.asrLanguagePopup lastItem].representedObject = @"de-DE";
  [self.asrLanguagePopup addItemWithTitle:@"Французский"];
  [self.asrLanguagePopup lastItem].representedObject = @"fr-FR";
  [self.asrLanguagePopup addItemWithTitle:@"Испанский"];
  [self.asrLanguagePopup lastItem].representedObject = @"es-MX";
  [self.asrLanguagePopup addItemWithTitle:@"Португальский"];
  [self.asrLanguagePopup lastItem].representedObject = @"pt-BR";
  [self.asrLanguagePopup addItemWithTitle:@"Кантонский"];
  [self.asrLanguagePopup lastItem].representedObject = @"yue-CN";
  self.asrLanguagePopup.hidden = YES;
  [pane addSubview:self.asrLanguagePopup];

  // Advanced Settings toggle button (Doubao only)
  CGFloat advY = langY - rowH;
  self.asrAdvancedDisclosure =
      [NSButton checkboxWithTitle:@"Дополнительно"
                           target:self
                           action:@selector(asrAdvancedToggled:)];
  self.asrAdvancedDisclosure.frame = NSMakeRect(fieldX, advY, 200, 22);
  self.asrAdvancedDisclosure.font = [NSFont systemFontOfSize:12];
  self.asrAdvancedDisclosure.state = NSControlStateValueOff;
  self.asrAdvancedDisclosure.tag = 1009;
  self.asrAdvancedDisclosure.hidden = YES;
  [pane addSubview:self.asrAdvancedDisclosure];

  // Advanced settings container (initially hidden)
  CGFloat advContainerY = advY - (rowH * 3) - 4;
  self.asrAdvancedContainer = [[NSView alloc]
      initWithFrame:NSMakeRect(0, advContainerY, paneWidth, rowH * 3)];
  self.asrAdvancedContainer.hidden = YES;
  [pane addSubview:self.asrAdvancedContainer];

  // Advanced row 1: Endpoint Silence
  CGFloat advRowY = rowH * 2;
  NSTextField *endLabel = [self formLabel:@"Пауза конца фразы"
                                    frame:NSMakeRect(formX, advRowY, labelW, 22)];
  [self.asrAdvancedContainer addSubview:endLabel];
  self.asrEndWindowField =
      [self formTextField:NSMakeRect(fieldX, advRowY, 80, 22)
              placeholder:@"800"];
  [self.asrAdvancedContainer addSubview:self.asrEndWindowField];
  NSTextField *endUnit =
      [self formLabel:@"мс (мин. 200)"
                frame:NSMakeRect(fieldX + 86, advRowY, 100, 22)];
  endUnit.alignment = NSTextAlignmentLeft;
  endUnit.font = [NSFont systemFontOfSize:11];
  endUnit.textColor = [NSColor secondaryLabelColor];
  [self.asrAdvancedContainer addSubview:endUnit];

  // Advanced row 2: Output Variant
  advRowY -= rowH;
  NSTextField *variantLabel =
      [self formLabel:@"Вариант вывода"
                frame:NSMakeRect(formX, advRowY, labelW, 22)];
  [self.asrAdvancedContainer addSubview:variantLabel];
  self.asrOutputVariantPopup = [[NSPopUpButton alloc]
      initWithFrame:NSMakeRect(fieldX, advRowY - 2, 160, 26)
          pullsDown:NO];
  [self.asrOutputVariantPopup addItemWithTitle:@"Упрощённый"];
  [self.asrOutputVariantPopup lastItem].representedObject = @"";
  [self.asrOutputVariantPopup addItemWithTitle:@"Традиционный"];
  [self.asrOutputVariantPopup lastItem].representedObject = @"traditional";
  [self.asrOutputVariantPopup addItemWithTitle:@"Тайвань"];
  [self.asrOutputVariantPopup lastItem].representedObject = @"tw";
  [self.asrOutputVariantPopup addItemWithTitle:@"Гонконг"];
  [self.asrOutputVariantPopup lastItem].representedObject = @"hk";
  [self.asrAdvancedContainer addSubview:self.asrOutputVariantPopup];

  // Advanced row 3: Accelerate First Character
  advRowY -= rowH;
  self.asrAccelerateCheckbox = [NSButton
      checkboxWithTitle:@"Ускорить первый символ (может снизить точность)"
                 target:nil
                 action:nil];
  self.asrAccelerateCheckbox.frame = NSMakeRect(fieldX, advRowY, fieldW, 22);
  self.asrAccelerateCheckbox.font = [NSFont systemFontOfSize:12];
  [self.asrAdvancedContainer addSubview:self.asrAccelerateCheckbox];

  // Every control is anchored to the top of the pane, so
  // `resizeAsrPaneToCurrentProvider` can shrink or grow the pane per provider
  // without orphaning any of them. (Save/Cancel used to be pinned to the
  // pane's bottom edge and needed the opposite mask; they are window chrome
  // now, outside the pane entirely.)
  for (NSView *sub in pane.subviews) {
    sub.autoresizingMask = NSViewMinYMargin;
  }
  // Both margins fixed, height free: the card's top stays under the caption and
  // its bottom stays on the page margin however tall the pane becomes.
  self.asrFormCard.autoresizingMask = NSViewHeightSizable;
  // Bottom-pinned, so it tracks the card's lower edge as the pane resizes.
  self.asrTestResultLabel.autoresizingMask = NSViewMaxYMargin;
  pane.autoresizesSubviews = YES;

  // Size the pane to the *saved* provider's footprint so it opens at the right
  // height rather than reflowing on first load.
  NSString *savedProvider = configGet(@"asr.provider");
  if (savedProvider.length == 0) savedProvider = @"qwen";
  CGFloat initialHeight =
      [self targetAsrPaneHeightForProvider:savedProvider advancedExpanded:NO];
  NSRect paneFrame = pane.frame;
  paneFrame.size.height = initialHeight;
  pane.frame = paneFrame;

  return pane;
}

- (NSView *)buildLlmPane {
  CGFloat paneWidth = [self paneContentWidth];
  CGFloat contentX = SPTheme.pageMargin;
  CGFloat contentW = paneWidth - 2.0 * contentX;
  CGFloat contentHeight = [self paneViewportHeight];

  // The correction note under the behaviour card consumes vertical space the
  // viewport-sized layout did not budget for. Grow the pane by exactly that
  // much (the pane scrolls) so the profiles area keeps its full height and
  // the Test Connection button stays inside the detail card.
  NSTextField *correctionNote = [self
      descriptionLabel:@"Коррекция через LLM по умолчанию выключена. Пока она выключена, "
                       @"итоговым текстом считается результат распознавания как есть."];
  CGFloat correctionNoteH =
      [self fittingHeightForWrappingLabel:correctionNote width:contentW];
  contentHeight += correctionNoteH + 10.0;
  // Room the result line under the Test Connection button may occupy: two
  // lines. The form already reaches the card's bottom edge, so without this
  // the result renders below the card entirely (issue #118). The pane grows
  // by it and scrolls; -showLlmTestResult: scrolls the line into view.
  const CGFloat kLlmTestResultReserve = 60.0;
  contentHeight += kLlmTestResultReserve;

  // The profiles area is two cards side by side: the list on the left, the
  // selected profile's form on the right.
  CGFloat cardPad = SPTheme.cardPadding;
  CGFloat cardGap = 16.0;
  CGFloat sidebarX = contentX;
  CGFloat sidebarW = 220.0;
  CGFloat sidebarButtonsH = 28.0;
  CGFloat detailCardX = contentX + sidebarW + cardGap;
  CGFloat detailCardW = contentW - sidebarW - cardGap;

  // Detail form geometry (right of sidebar). The label column is measured
  // from the actual strings so no label ever clips.
  CGFloat labelW = [self formLabelColumnWidthForTitles:@[
    @"Название", @"Тип", @"Base URL", @"API-ключ", @"Модель", @"Список моделей",
    @"Путь API", @"Параметр токенов"
  ]];
  CGFloat detailLabelX = detailCardX + cardPad;
  CGFloat fieldX = detailLabelX + labelW + 8;
  CGFloat fieldW =
      MIN(detailCardX + detailCardW - cardPad - fieldX, 440.0);
  CGFloat rowH = 30;

  NSView *pane =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];

  CGFloat y = contentHeight - 30.0;

  // Description
  NSTextField *desc = [self
      addSettingsDescriptionText:@"Настройте LLM, чтобы он приводил в порядок текст после "
                                 @"распознавания речи."
                          toPane:pane
                            topY:y
                               x:contentX
                           width:contentW];
  y = NSMinY(desc.frame) - 16.0;

  // Both switches share one card — two rows in a single surface, like the
  // Controls pane, rather than two 48pt cards separated by a gap.
  self.llmEnabledCheckbox =
      [self settingsSwitchWithAction:@selector(llmEnabledToggled:)];
  self.llmAutoPasteProcessedTextSwitch = [self settingsSwitchWithAction:NULL];
  NSView *behaviourCard = [self
      cardWithTitle:@""
               rows:@[
                 [self cardRowWithLabel:@"Коррекция через LLM"
                                control:self.llmEnabledCheckbox],
                 [self cardRowWithLabel:@"Автоматически вставлять обработанный текст"
                                control:self.llmAutoPasteProcessedTextSwitch],
               ]
              width:contentW];
  CGFloat behaviourH = behaviourCard.frame.size.height;
  behaviourCard.frame = NSMakeRect(contentX, y - behaviourH, contentW, behaviourH);
  [pane addSubview:behaviourCard];
  [self layoutCardRowControls:behaviourCard.subviews.firstObject width:contentW];
  y = NSMinY(behaviourCard.frame) - 10.0;

  // Under the toggle: make the default and the disabled behavior explicit
  // (pre-measured above so the pane height already budgets for it).
  correctionNote.frame =
      NSMakeRect(contentX, floor(y - correctionNoteH), contentW, correctionNoteH);
  [pane addSubview:correctionNote];
  y = NSMinY(correctionNote.frame) - SPTheme.sectionGap;

  NSTextField *sectionTitle = [self
      sectionTitleLabel:@"Профили"
                  frame:NSMakeRect(contentX, floor(y - 20.0), contentW, 20.0)];
  [pane addSubview:sectionTitle];
  y = NSMinY(sectionTitle.frame) - 16.0;

  CGFloat profilesBottomY = SPTheme.pageMargin;
  CGFloat sidebarH = y - profilesBottomY;
  CGFloat sidebarY = profilesBottomY;

  // The two cards the profiles area is built on. Added before their contents so
  // they stay behind them; both are resized to hug the form once it has been
  // laid out (see the end of this method).
  NSView *listCard = [self surfaceCardViewWithFrame:NSMakeRect(sidebarX, sidebarY,
                                                               sidebarW, sidebarH)];
  NSView *detailCard = [self surfaceCardViewWithFrame:NSMakeRect(detailCardX, sidebarY,
                                                                 detailCardW, sidebarH)];
  [pane addSubview:listCard];
  [pane addSubview:detailCard];

  // ─── Sidebar: profile list ─────────────────────────────────────────
  // Inset inside its card, with the +/− buttons on the card's bottom edge.
  NSScrollView *scroll = [[NSScrollView alloc]
      initWithFrame:NSMakeRect(sidebarX + 10, sidebarY + sidebarButtonsH + 10,
                               sidebarW - 20,
                               sidebarH - sidebarButtonsH - 10 - cardPad)];
  scroll.hasVerticalScroller = YES;
  scroll.hasHorizontalScroller = NO;
  scroll.borderType = NSNoBorder;
  scroll.drawsBackground = NO;
  scroll.autohidesScrollers = YES;
  self.llmProfileTableScroll = scroll;

  NSTableView *table = [[NSTableView alloc] initWithFrame:scroll.bounds];
  table.headerView = nil;
  table.backgroundColor = NSColor.clearColor;
  table.rowHeight = 44;
  table.allowsEmptySelection = NO;
  table.allowsMultipleSelection = NO;
  table.intercellSpacing = NSMakeSize(0, 0);
  table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
  table.dataSource = self;
  table.delegate = self;

  NSTableColumn *col =
      [[NSTableColumn alloc] initWithIdentifier:@"LlmProfileColumn"];
  // The column has to fit the scroll view's content width, not the card's —
  // anything wider scrolls horizontally and clips the profile subtitle.
  col.width = NSWidth(scroll.frame) - 4;
  col.resizingMask = NSTableColumnAutoresizingMask;
  [table addTableColumn:col];

  scroll.documentView = table;
  [pane addSubview:scroll];
  self.llmProfileTableView = table;

  // Sidebar +/- buttons (Finder-style), on the card's bottom edge
  self.llmAddProfileButton = [[NSButton alloc]
      initWithFrame:NSMakeRect(sidebarX + 10, sidebarY + cardPad - 12, 28, 24)];
  self.llmAddProfileButton.bezelStyle = NSBezelStyleSmallSquare;
  self.llmAddProfileButton.image = [NSImage imageWithSystemSymbolName:@"plus"
                                             accessibilityDescription:@"Добавить"];
  self.llmAddProfileButton.target = self;
  self.llmAddProfileButton.action = @selector(showAddLlmProfileMenu:);
  [pane addSubview:self.llmAddProfileButton];

  self.llmDeleteProfileButton = [[NSButton alloc]
      initWithFrame:NSMakeRect(sidebarX + 40, sidebarY + cardPad - 12, 28, 24)];
  self.llmDeleteProfileButton.bezelStyle = NSBezelStyleSmallSquare;
  self.llmDeleteProfileButton.image =
      [NSImage imageWithSystemSymbolName:@"minus"
                accessibilityDescription:@"Удалить"];
  self.llmDeleteProfileButton.target = self;
  self.llmDeleteProfileButton.action = @selector(deleteLlmProfile:);
  [pane addSubview:self.llmDeleteProfileButton];

  // ─── Detail form (right side) ─────────────────────────────────────
  // Inset from the card's top edge by its padding, so the first row does not
  // sit flush against it.
  CGFloat detailY = y - cardPad - 22.0;

  // Name field (editable custom display name for this profile)
  NSTextField *nameLabel =
      [self formLabel:@"Название"
                frame:NSMakeRect(detailLabelX, detailY, labelW, 22)];
  [pane addSubview:nameLabel];
  self.llmProfileNameField =
      [self formTextField:NSMakeRect(fieldX, detailY, fieldW, 22)
              placeholder:@"Мой профиль"];
  self.llmProfileNameField.target = self;
  self.llmProfileNameField.action = @selector(llmProfileNameChanged:);
  self.llmProfileNameField.delegate = self;
  [pane addSubview:self.llmProfileNameField];
  detailY -= rowH;

  // Type (read-only label — locked at creation)
  NSTextField *typeLabelLeft =
      [self formLabel:@"Тип"
                frame:NSMakeRect(detailLabelX, detailY, labelW, 22)];
  [pane addSubview:typeLabelLeft];
  self.llmProfileTypeLabel = [NSTextField labelWithString:@""];
  self.llmProfileTypeLabel.frame = NSMakeRect(fieldX, detailY, fieldW, 22);
  self.llmProfileTypeLabel.font = [NSFont systemFontOfSize:13];
  self.llmProfileTypeLabel.textColor = [NSColor secondaryLabelColor];
  [pane addSubview:self.llmProfileTypeLabel];
  detailY -= rowH + 4;

  CGFloat providerDetailStartY = detailY;

  // --- OpenAI fields (tag 2001-2008 for show/hide) ---

  // Base URL
  NSTextField *baseUrlLabel =
      [self formLabel:@"Base URL"
                frame:NSMakeRect(detailLabelX, detailY, labelW, 22)];
  baseUrlLabel.tag = 2001;
  [pane addSubview:baseUrlLabel];
  self.llmBaseUrlField =
      [self formTextField:NSMakeRect(fieldX, detailY, fieldW, 22)
              placeholder:@"https://api.openai.com/v1"];
  self.llmBaseUrlField.tag = 2001;
  [pane addSubview:self.llmBaseUrlField];
  detailY -= rowH;

  // API Key (secure by default)
  CGFloat eyeW = 28;
  CGFloat secFieldW = fieldW - eyeW - 4;
  NSTextField *apiKeyLabel =
      [self formLabel:@"API-ключ"
                frame:NSMakeRect(detailLabelX, detailY, labelW, 22)];
  apiKeyLabel.tag = 2002;
  [pane addSubview:apiKeyLabel];
  self.llmApiKeySecureField = [[NSSecureTextField alloc]
      initWithFrame:NSMakeRect(fieldX, detailY, secFieldW, 22)];
  self.llmApiKeySecureField.placeholderString =
      @"sk-... (можно оставить пустым)";
  self.llmApiKeySecureField.font = [NSFont systemFontOfSize:13];
  self.llmApiKeySecureField.tag = 2002;
  [pane addSubview:self.llmApiKeySecureField];
  self.llmApiKeyField =
      [self formTextField:NSMakeRect(fieldX, detailY, secFieldW, 22)
              placeholder:@"sk-... (можно оставить пустым)"];
  self.llmApiKeyField.hidden = YES;
  self.llmApiKeyField.tag = 2002;
  [pane addSubview:self.llmApiKeyField];
  self.llmApiKeyToggle =
      [self eyeButtonWithFrame:NSMakeRect(fieldX + secFieldW + 4, detailY - 1,
                                          eyeW, 24)
                        action:@selector(toggleLlmApiKeyVisibility:)];
  [pane addSubview:self.llmApiKeyToggle];
  detailY -= rowH;

  // Model (text field for OpenAI) + Choose button (toggles remote model picker)
  CGFloat modelPickerButtonW = 74;
  CGFloat modelFieldW = fieldW - modelPickerButtonW - 6;
  NSTextField *modelLabel =
      [self formLabel:@"Модель"
                frame:NSMakeRect(detailLabelX, detailY, labelW, 22)];
  modelLabel.tag = 2003;
  [pane addSubview:modelLabel];
  self.llmModelField =
      [self formTextField:NSMakeRect(fieldX, detailY, modelFieldW, 22)
              placeholder:@"gpt-5.4-nano"];
  self.llmModelField.tag = 2003;
  [pane addSubview:self.llmModelField];
  self.llmToggleModelPickerButton =
      [NSButton buttonWithTitle:@"Выбрать"
                         target:self
                         action:@selector(toggleLlmRemoteModelPicker:)];
  self.llmToggleModelPickerButton.frame =
      NSMakeRect(fieldX + modelFieldW + 6, detailY - 2, modelPickerButtonW, 26);
  self.llmToggleModelPickerButton.bezelStyle = NSBezelStyleRounded;
  self.llmToggleModelPickerButton.tag = 2003;
  [pane addSubview:self.llmToggleModelPickerButton];
  detailY -= rowH;

  // Model List (OpenAI /models) — initially hidden, toggled by Choose button
  NSTextField *modelListLabel =
      [self formLabel:@"Список моделей"
                frame:NSMakeRect(detailLabelX, detailY, labelW, 22)];
  modelListLabel.tag = 2004;
  [pane addSubview:modelListLabel];
  self.llmRemoteModelPopup = [[NSPopUpButton alloc]
      initWithFrame:NSMakeRect(fieldX, detailY - 2, fieldW - 74, 26)
          pullsDown:NO];
  self.llmRemoteModelPopup.tag = 2004;
  [self.llmRemoteModelPopup addItemWithTitle:@"Модели не загружены"];
  self.llmRemoteModelPopup.enabled = NO;
  [self.llmRemoteModelPopup setTarget:self];
  [self.llmRemoteModelPopup setAction:@selector(llmRemoteModelChanged:)];
  [pane addSubview:self.llmRemoteModelPopup];
  self.llmRefreshModelsButton =
      [NSButton buttonWithTitle:@"Обновить"
                         target:self
                         action:@selector(refreshLlmRemoteModels:)];
  self.llmRefreshModelsButton.frame =
      NSMakeRect(fieldX + fieldW - 66, detailY - 2, 66, 26);
  self.llmRefreshModelsButton.bezelStyle = NSBezelStyleRounded;
  self.llmRefreshModelsButton.tag = 2004;
  [pane addSubview:self.llmRefreshModelsButton];
  self.llmRemoteModelPickerExpanded = NO;
  self.llmRemoteModelPickerRowVisible = YES;
  [self setHidden:YES forViewsWithTagInRange:NSMakeRange(2004, 1) inView:pane];
  detailY -= rowH + 4;

  // Protocol endpoint path
  NSTextField *chatPathLabel =
      [self formLabel:@"Путь API"
                frame:NSMakeRect(detailLabelX, detailY, labelW, 22)];
  chatPathLabel.tag = 2005;
  [pane addSubview:chatPathLabel];
  self.llmChatCompletionsPathField =
      [self formTextField:NSMakeRect(fieldX, detailY, fieldW, 22)
              placeholder:kDefaultLlmChatCompletionsPath];
  self.llmChatCompletionsPathField.tag = 2005;
  [pane addSubview:self.llmChatCompletionsPathField];
  detailY -= rowH;

  // Max Token Parameter
  NSTextField *tokenParamLabel =
      [self formLabel:@"Параметр токенов"
                frame:NSMakeRect(detailLabelX, detailY, labelW, 22)];
  tokenParamLabel.tag = 2006;
  [pane addSubview:tokenParamLabel];
  self.maxTokenParamPopup = [[NSPopUpButton alloc]
      initWithFrame:NSMakeRect(fieldX, detailY - 2, MIN(240.0, fieldW), 26)
          pullsDown:NO];
  self.maxTokenParamPopup.tag = 2006;
  [self.maxTokenParamPopup addItemsWithTitles:@[
    @"max_completion_tokens",
    @"max_tokens",
  ]];
  [self.maxTokenParamPopup itemAtIndex:0].representedObject =
      @"max_completion_tokens";
  [self.maxTokenParamPopup itemAtIndex:1].representedObject = @"max_tokens";
  [pane addSubview:self.maxTokenParamPopup];

  // Hint text — measured so the full text is always visible
  NSTextField *tokenHint = [self
      descriptionLabel:@"GPT-4o и более старые модели используют max_tokens. GPT-5 и "
                       @"модели с рассуждением (o1/o3) используют max_completion_tokens."];
  // The hint spans the card's full inner width, not just the field column —
  // at the field width it wraps to three lines and pushes the button out.
  CGFloat tokenHintW = detailCardX + detailCardW - cardPad - detailLabelX;
  CGFloat tokenHintH = [self fittingHeightForWrappingLabel:tokenHint
                                                     width:tokenHintW];
  tokenHint.frame = NSMakeRect(detailLabelX, detailY - 10.0 - tokenHintH,
                               tokenHintW, tokenHintH);
  tokenHint.tag = 2007;
  [pane addSubview:tokenHint];
  // The button's frame origin is its BOTTOM edge, so the gap below the hint is
  // this offset minus the button's own 28pt height.
  detailY = NSMinY(tokenHint.frame) - 16.0 - 28.0;

  // Test button
  self.llmTestButton = [NSButton buttonWithTitle:@"Проверить подключение"
                                          target:self
                                          action:@selector(testLlmConnection:)];
  self.llmTestButton.bezelStyle = NSBezelStyleRounded;
  self.llmTestButton.frame = NSMakeRect(fieldX, detailY, 130, 28);
  self.llmTestButton.tag = 2008;
  [pane addSubview:self.llmTestButton];

  // Test result — re-measures and grows downward whenever its text changes
  SPStatusLabel *llmTestResult = [SPStatusLabel wrappingLabelWithString:@""];
  llmTestResult.growsDownward = YES;
  self.llmTestResultLabel = llmTestResult;
  // Two lines are reserved so a typical result stays inside the card; the label
  // keeps its top edge and re-measures downward for anything longer.
  self.llmTestResultLabel.frame =
      NSMakeRect(fieldX, detailY - 8.0 - 32.0, fieldW, 32.0);
  self.llmTestResultLabel.font = [NSFont systemFontOfSize:12];
  self.llmTestResultLabel.selectable = YES;
  self.llmTestResultLabel.tag = 2008;
  [pane addSubview:self.llmTestResultLabel];

  // --- MLX fields (tag 2010-2012 for show/hide, initially hidden) ---
  CGFloat mlxY = providerDetailStartY; // same Y as Base URL row

  // MLX Model popup + Download button
  NSTextField *llmModelLabel =
      [self formLabel:@"Модель"
                frame:NSMakeRect(detailLabelX, mlxY, labelW, 22)];
  llmModelLabel.tag = 2010;
  llmModelLabel.hidden = YES;
  [pane addSubview:llmModelLabel];
  self.llmLocalModelPopup = [[NSPopUpButton alloc]
      initWithFrame:NSMakeRect(fieldX, mlxY - 2, fieldW - 26, 26)
          pullsDown:NO];
  self.llmLocalModelPopup.tag = 2010;
  self.llmLocalModelPopup.hidden = YES;
  [self.llmLocalModelPopup setTarget:self];
  [self.llmLocalModelPopup setAction:@selector(llmLocalModelChanged:)];
  [pane addSubview:self.llmLocalModelPopup];

  self.llmModelDownloadButton = [[NSButton alloc]
      initWithFrame:NSMakeRect(fieldX + fieldW - 20, mlxY + 1, 20, 20)];
  self.llmModelDownloadButton.image =
      [NSImage imageWithSystemSymbolName:@"arrow.down.circle"
                accessibilityDescription:@"Скачать"];
  self.llmModelDownloadButton.bezelStyle = NSBezelStyleInline;
  self.llmModelDownloadButton.bordered = NO;
  self.llmModelDownloadButton.imageScaling = NSImageScaleProportionallyUpOrDown;
  self.llmModelDownloadButton.target = self;
  self.llmModelDownloadButton.action = @selector(llmDownloadSelectedModel:);
  self.llmModelDownloadButton.tag = 2010;
  self.llmModelDownloadButton.hidden = YES;
  [pane addSubview:self.llmModelDownloadButton];

  mlxY -= rowH;

  // MLX Status + Delete button
  self.llmModelStatusLabel = [[SPStatusLabel alloc]
      initWithFrame:NSMakeRect(fieldX, mlxY + 2, fieldW - 32, 18)];
  self.llmModelStatusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
  self.llmModelStatusLabel.usesSingleLineMode = YES;
  self.llmModelStatusLabel.bezeled = NO;
  self.llmModelStatusLabel.drawsBackground = NO;
  self.llmModelStatusLabel.editable = NO;
  self.llmModelStatusLabel.selectable = NO;
  self.llmModelStatusLabel.font = [NSFont systemFontOfSize:12];
  self.llmModelStatusLabel.tag = 2011;
  self.llmModelStatusLabel.hidden = YES;
  [pane addSubview:self.llmModelStatusLabel];

  self.llmModelDeleteButton = [[NSButton alloc]
      initWithFrame:NSMakeRect(fieldX + fieldW - 20, mlxY + 1, 20, 20)];
  self.llmModelDeleteButton.image =
      [NSImage imageWithSystemSymbolName:@"trash"
                accessibilityDescription:@"Удалить"];
  self.llmModelDeleteButton.bezelStyle = NSBezelStyleInline;
  self.llmModelDeleteButton.bordered = NO;
  self.llmModelDeleteButton.imageScaling = NSImageScaleProportionallyUpOrDown;
  self.llmModelDeleteButton.target = self;
  self.llmModelDeleteButton.action = @selector(llmDeleteSelectedModel:);
  self.llmModelDeleteButton.tag = 2011;
  self.llmModelDeleteButton.hidden = YES;
  [pane addSubview:self.llmModelDeleteButton];

  mlxY -= rowH;

  // MLX Progress bar + size label
  self.llmModelProgressBar = [[NSProgressIndicator alloc]
      initWithFrame:NSMakeRect(fieldX, mlxY + 10, fieldW - 120, 10)];
  self.llmModelProgressBar.controlSize = NSControlSizeMini;
  self.llmModelProgressBar.style = NSProgressIndicatorStyleBar;
  self.llmModelProgressBar.minValue = 0;
  self.llmModelProgressBar.maxValue = 100;
  self.llmModelProgressBar.indeterminate = NO;
  self.llmModelProgressBar.hidden = YES;
  [pane addSubview:self.llmModelProgressBar];

  self.llmModelProgressSizeLabel = [[NSTextField alloc]
      initWithFrame:NSMakeRect(fieldX + fieldW - 114, mlxY + 2, 114, 18)];
  self.llmModelProgressSizeLabel.bezeled = NO;
  self.llmModelProgressSizeLabel.drawsBackground = NO;
  self.llmModelProgressSizeLabel.editable = NO;
  self.llmModelProgressSizeLabel.selectable = NO;
  self.llmModelProgressSizeLabel.alignment = NSTextAlignmentRight;
  self.llmModelProgressSizeLabel.font =
      [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
  self.llmModelProgressSizeLabel.textColor = [NSColor secondaryLabelColor];
  self.llmModelProgressSizeLabel.hidden = YES;
  [pane addSubview:self.llmModelProgressSizeLabel];

  // Shrink both cards to hug the form. Sized to the whole available height they
  // put ~120pt of empty card under the last row while the first row sat one
  // padding below the top edge — all the slack collected at the bottom. The
  // measurement includes rows that are hidden for the current profile type, so
  // the card does not jump when a different one is selected.
  CGFloat lowestFormEdge = CGFLOAT_MAX;
  for (NSView *sub in pane.subviews) {
    if (sub == listCard || sub == detailCard)
      continue;
    if (sub == self.llmTestResultLabel)
      continue; // reserved for explicitly below, not by its current height
    if (NSMinX(sub.frame) < detailCardX - 1.0)
      continue; // list side, or the page-wide header rows
    lowestFormEdge = MIN(lowestFormEdge, NSMinY(sub.frame));
  }
  // The result label is measured by its RESERVE, not by whatever it happens
  // to hold right now: hugging to an empty (or one-line) label would shrink
  // the card to exactly the space a later failure message needs.
  lowestFormEdge = MIN(lowestFormEdge,
                       NSMaxY(self.llmTestResultLabel.frame) -
                           kLlmTestResultReserve);
  if (lowestFormEdge < CGFLOAT_MAX) {
    // Only ever shrinks: clamped at the page margin so a form that already
    // fills the card cannot push the cards below the pane.
    CGFloat cardBottom =
        MAX(profilesBottomY, floor(lowestFormEdge - cardPad));
    CGFloat cardHeight = NSMaxY(detailCard.frame) - cardBottom;
    detailCard.frame =
        NSMakeRect(detailCardX, cardBottom, detailCardW, cardHeight);
    // The list card matches so the pair reads as one row of cards.
    listCard.frame = NSMakeRect(sidebarX, cardBottom, sidebarW, cardHeight);
    NSRect scrollFrame = scroll.frame;
    scrollFrame.origin.y = cardBottom + sidebarButtonsH + 10.0;
    scrollFrame.size.height =
        NSMaxY(listCard.frame) - cardPad - NSMinY(scrollFrame);
    scroll.frame = scrollFrame;
    NSRect addFrame = self.llmAddProfileButton.frame;
    addFrame.origin.y = cardBottom + cardPad - 12.0;
    self.llmAddProfileButton.frame = addFrame;
    NSRect deleteFrame = self.llmDeleteProfileButton.frame;
    deleteFrame.origin.y = addFrame.origin.y;
    self.llmDeleteProfileButton.frame = deleteFrame;
  }

  // The test result is the one label whose content is arbitrary provider
  // text (issue #118: a JSON error body grew it straight through the card
  // edge and off the pane). Pin it inside the card for good: it spans the
  // card's full inner width, keeps its top edge under the Test button, and
  // may never grow past the card's bottom padding. Whatever still does not
  // fit stays in the tooltip.
  CGFloat resultTop = NSMaxY(self.llmTestResultLabel.frame);
  CGFloat resultLeft = detailLabelX;
  CGFloat resultWidth = detailCardX + detailCardW - cardPad - resultLeft;
  self.llmTestResultLabel.frame =
      NSMakeRect(resultLeft, resultTop - 18.0, resultWidth, 18.0);
  // Two lines at most, and never past the card's bottom padding — the room
  // is re-evaluated on every message because the pane is re-laid out after
  // it is hosted (a build-time bound would be stale).
  self.llmTestResultLabel.maxGrowHeight = kLlmTestResultReserve;
  self.llmTestResultLabel.growthBoundsView = detailCard;
  self.llmTestResultLabel.growthBottomInset = cardPad;

  return pane;
}

- (NSView *)buildOverlayPane {
  CGFloat paneWidth = [self paneContentWidth];
  CGFloat contentX = SPTheme.pageMargin;
  CGFloat contentW = paneWidth - 2.0 * contentX;
  NSString *descriptionText =
      @"Настройте нижнюю панель с живой расшифровкой: системный шрифт, "
      @"размер текста, отступ от низа экрана и то, ограничивать ли "
      @"длинный текст несколькими строками или показывать целиком. "
      @"Каждое изменение сразу видно на реальном месте панели.";

  self.overlayFontFamilyPopup = [self overlayFontFamilyPopupControl];

  self.overlayFontSizeSlider =
      [self overlaySliderWithMin:kOverlayFontSizeMin
                             max:kOverlayFontSizeMax
                          action:@selector(overlayControlChanged:)];
  self.overlayFontSizeValueLabel = [self overlayValueLabel];
  NSView *fontSliderControl =
      [self sliderControlWithSlider:self.overlayFontSizeSlider
                         valueLabel:self.overlayFontSizeValueLabel
                              width:290.0];

  self.overlayBottomMarginSlider =
      [self overlaySliderWithMin:0
                             max:kOverlayBottomMarginMax
                          action:@selector(overlayControlChanged:)];
  self.overlayBottomMarginValueLabel = [self overlayValueLabel];
  NSView *bottomSliderControl =
      [self sliderControlWithSlider:self.overlayBottomMarginSlider
                         valueLabel:self.overlayBottomMarginValueLabel
                              width:290.0];

  self.overlayLimitVisibleLinesSwitch =
      [self settingsSwitchWithAction:@selector(overlayControlChanged:)];
  self.overlayMaxVisibleLinesPopup = [self overlayMaxVisibleLinesPopupControl];

  NSButton *resetButton =
      [NSButton buttonWithTitle:@"Сбросить"
                         target:self
                         action:@selector(resetOverlaySettings:)];
  resetButton.bezelStyle = NSBezelStyleRounded;
  resetButton.frame = NSMakeRect(0, 0, 126.0, 28.0);

  NSView *controlsCard = [self
      cardWithTitle:@"Оформление"
               rows:@[
                 [self cardRowWithLabel:@"Шрифт"
                                control:self.overlayFontFamilyPopup],
                 [self cardRowWithLabel:@"Размер текста" control:fontSliderControl],
                 [self cardRowWithLabel:@"Отступ от низа"
                                control:bottomSliderControl],
                 [self cardRowWithLabel:@"Ограничить число строк"
                                control:self.overlayLimitVisibleLinesSwitch],
                 [self cardRowWithLabel:@"Максимум строк"
                                control:self.overlayMaxVisibleLinesPopup],
                 [self cardRowWithLabel:@"По умолчанию" control:resetButton],
               ]
              width:contentW];
  CGFloat descriptionHeight = [self
      fittingHeightForWrappingLabel:[self descriptionLabel:descriptionText]
                              width:contentW];
  // The card carries its own section caption, so no separate heading here.
  CGFloat paneHeight = 30.0 + descriptionHeight + 18.0 +
                       controlsCard.frame.size.height + 30.0;

  NSView *pane =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, paneHeight)];

  CGFloat y = paneHeight - 30.0;
  NSTextField *desc = [self addSettingsDescriptionText:descriptionText
                                                toPane:pane
                                                  topY:y
                                                     x:contentX
                                                 width:contentW];
  y = NSMinY(desc.frame) - 18.0;

  controlsCard.frame =
      NSMakeRect(contentX, y - controlsCard.frame.size.height, contentW,
                 controlsCard.frame.size.height);
  [pane addSubview:controlsCard];
  NSView *controlsCardBody = controlsCard.subviews.count > 1
                                 ? controlsCard.subviews[1]
                                 : controlsCard.subviews[0];
  [self layoutCardRowControls:controlsCardBody width:contentW];
  [self updateOverlayLineLimitControlsEnabled];


  return pane;
}

- (void)updateOverlayControlValueLabels {
  self.overlayFontSizeValueLabel.stringValue = [NSString
      stringWithFormat:@"%ld пт", (long)clampedOverlayFontSizeValue(lround(
                                      self.overlayFontSizeSlider.doubleValue))];
  self.overlayBottomMarginValueLabel.stringValue = [NSString
      stringWithFormat:@"%ld пт",
                       (long)clampedOverlayBottomMarginValue(
                           lround(self.overlayBottomMarginSlider.doubleValue))];
}

- (SPOverlayPanel *)runtimeOverlayPanel {
  id appDelegate = NSApp.delegate;
  if (!appDelegate) {
    return nil;
  }

  id overlayPanel = nil;
  @try {
    overlayPanel = [appDelegate valueForKey:@"overlayPanel"];
  } @catch (__unused NSException *exception) {
    return nil;
  }

  if (![overlayPanel isKindOfClass:[SPOverlayPanel class]]) {
    return nil;
  }
  return (SPOverlayPanel *)overlayPanel;
}

- (void)showRuntimeOverlayPreview {
  SPOverlayPanel *overlayPanel = [self runtimeOverlayPanel];
  if (!overlayPanel)
    return;

  NSInteger fontSize = clampedOverlayFontSizeValue(
      lround(self.overlayFontSizeSlider.doubleValue));
  NSInteger bottomMargin = clampedOverlayBottomMarginValue(
      lround(self.overlayBottomMarginSlider.doubleValue));
  NSString *fontFamily = [self selectedOverlayFontFamilyValue];
  BOOL limitVisibleLines =
      self.overlayLimitVisibleLinesSwitch.state == NSControlStateValueOn;
  NSInteger maxVisibleLines = [self selectedOverlayMaxVisibleLinesValue];
  [overlayPanel showPreviewWithText:kOverlayPreviewSampleText
                           fontSize:(CGFloat)fontSize
                         fontFamily:fontFamily
                       bottomMargin:(CGFloat)bottomMargin
                  limitVisibleLines:limitVisibleLines
                    maxVisibleLines:maxVisibleLines];
}

- (void)hideRuntimeOverlayPreview {
  [[self runtimeOverlayPanel] hidePreview];
}

- (void)syncOverlayPreviewFromControls {
  [self updateOverlayLineLimitControlsEnabled];
  [self updateOverlayControlValueLabels];
  [self showRuntimeOverlayPreview];
}

- (void)overlayControlChanged:(id)sender {
  [self syncOverlayPreviewFromControls];
}

- (void)resetOverlaySettings:(id)sender {
  [self selectOverlayFontFamilyValue:kOverlayFontFamilyDefault];
  self.overlayFontSizeSlider.integerValue = kOverlayFontSizeDefault;
  self.overlayBottomMarginSlider.integerValue = kOverlayBottomMarginDefault;
  self.overlayLimitVisibleLinesSwitch.state = kOverlayLimitVisibleLinesDefault
                                                  ? NSControlStateValueOn
                                                  : NSControlStateValueOff;
  [self selectOverlayMaxVisibleLinesValue:kOverlayMaxVisibleLinesDefault];
  [self syncOverlayPreviewFromControls];
}

- (NSView *)buildHotkeyPane {
  CGFloat paneWidth = [self paneContentWidth];
  CGFloat cardWidth = paneWidth - 2.0 * SPTheme.pageMargin;
  CGFloat cardSpacing = 16.0;
  CGFloat topPad = 24.0;

  // ── Trigger Key ──
  self.hotkeyPopup = [self hotkeyPresetPopup];
  self.hotkeyPopup.target = self;
  self.hotkeyPopup.action = @selector(triggerHotkeyChanged:);
  self.recordTriggerHotkeyButton =
      [NSButton buttonWithTitle:@"Записать"
                         target:self
                         action:@selector(recordTriggerHotkey:)];
  self.recordTriggerHotkeyButton.bezelStyle = NSBezelStyleRounded;
  // Wide enough for both runtime titles ("Record" / "Press...")
  self.recordTriggerHotkeyButton.title = @"Нажмите…";
  [self.recordTriggerHotkeyButton sizeToFit];
  CGFloat recordButtonW = self.recordTriggerHotkeyButton.frame.size.width;
  self.recordTriggerHotkeyButton.title = @"Записать";
  [self.recordTriggerHotkeyButton sizeToFit];
  recordButtonW =
      MAX(recordButtonW, self.recordTriggerHotkeyButton.frame.size.width);
  self.recordTriggerHotkeyButton.frame = NSMakeRect(0, 0, recordButtonW, 28);
  self.resetTriggerHotkeyButton =
      [NSButton buttonWithTitle:@"Сбросить"
                         target:self
                         action:@selector(resetTriggerHotkey:)];
  self.resetTriggerHotkeyButton.bezelStyle = NSBezelStyleRounded;
  self.resetTriggerHotkeyButton.frame = NSMakeRect(0, 0, 58, 28);
  NSView *triggerShortcutControl =
      [self hotkeyPickerControlWithPopup:self.hotkeyPopup
                            recordButton:self.recordTriggerHotkeyButton
                             resetButton:self.resetTriggerHotkeyButton];

  // ── Trigger Mode ──
  self.triggerModePopup =
      [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 220, 26)
                                 pullsDown:NO];
  [self.triggerModePopup addItemsWithTitles:@[
    @"Удержание (нажать и держать)",
    @"Переключатель (нажатие — старт/стоп)",
    @"Двойное нажатие",
    @"Авто (нажатие — переключить, удержание — говорить)",
  ]];
  [self.triggerModePopup itemAtIndex:0].representedObject = @"hold";
  [self.triggerModePopup itemAtIndex:1].representedObject = @"toggle";
  [self.triggerModePopup itemAtIndex:2].representedObject = @"double_tap";
  [self.triggerModePopup itemAtIndex:3].representedObject = @"auto";

  self.translateKeyPopup = [self extraHotkeyPopup];
  self.askKeyPopup = [self extraHotkeyPopup];
  self.abortKeyPopup = [self abortKeyPopupButton];
  self.modeKeyPopup = [self extraHotkeyPopup];
  self.editKeyPopup = [self extraHotkeyPopup];
  self.undoKeyPopup = [self extraHotkeyPopup];
  self.repasteKeyPopup = [self extraHotkeyPopup];
  self.mouseButtonPopup = [self mouseButtonPopupButton];
  self.mediaPlayPauseSwitch = [self settingsSwitchWithAction:NULL];

  // ── Trigger card ──
  NSView *triggerCard =
      [self cardWithTitle:@"Запуск"
                     rows:@[
                       [self cardRowWithLabel:@"Клавиша запуска"
                                      control:triggerShortcutControl],
                       [self cardRowWithLabel:@"Режим запуска"
                                      control:self.triggerModePopup],
                       [self cardRowWithLabel:@"Клавиша перевода"
                                      control:self.translateKeyPopup],
                       [self cardRowWithLabel:@"Клавиша вопроса по выделенному"
                                      control:self.askKeyPopup],
                       [self cardRowWithLabel:@"Клавиша правки выделенного"
                                      control:self.editKeyPopup],
                       [self cardRowWithLabel:@"Клавиша «отменить вставку»"
                                      control:self.undoKeyPopup],
                       [self cardRowWithLabel:@"Клавиша «вставить последнюю диктовку»"
                                      control:self.repasteKeyPopup],
                       [self cardRowWithLabel:@"Клавиша режима текста"
                                      control:self.modeKeyPopup],
                       [self cardRowWithLabel:@"Клавиша отмены записи"
                                      control:self.abortKeyPopup],
                       [self cardRowWithLabel:@"Кнопка мыши для записи"
                                      control:self.mouseButtonPopup],
                       [self cardRowWithLabel:@"Кнопка Play/Pause запускает диктовку"
                                      control:self.mediaPlayPauseSwitch],
                     ]
                    width:cardWidth];

  // ── Paste Behavior ──
  self.autoReturnSwitch = [self settingsSwitchWithAction:NULL];
  self.keepLastDictationSwitch = [self settingsSwitchWithAction:NULL];
  self.pasteAsrFirstSwitch = [self settingsSwitchWithAction:NULL];
  self.streamingInsertSwitch = [self settingsSwitchWithAction:NULL];
  self.liveInsertSwitch = [self settingsSwitchWithAction:NULL];
  self.voiceCommandsSwitch = [self settingsSwitchWithAction:NULL];

  NSView *pasteCard =
      [self cardWithTitle:@"Вставка"
                     rows:@[
                       [self cardRowWithLabel:@"Нажимать Return после вставки"
                                      control:self.autoReturnSwitch],
                       [self cardRowWithLabel:@"Голосовые команды"
                                      control:self.voiceCommandsSwitch],
                       [self cardRowWithLabel:@"Оставлять диктовку в буфере обмена (скопированное раньше не вернётся)"
                                      control:self.keepLastDictationSwitch],
                       [self cardRowWithLabel:@"Вставлять сырой текст сразу, потом исправлять"
                                      control:self.pasteAsrFirstSwitch],
                       [self cardRowWithLabel:@"Печатать текст по ходу генерации"
                                      control:self.streamingInsertSwitch],
                       [self cardRowWithLabel:@"Писать прямо в поле во время речи"
                                      control:self.liveInsertSwitch],
                     ]
                    width:cardWidth];

  // ── Feedback Sounds ──
  self.startSoundCheckbox = [self settingsSwitchWithAction:NULL];
  self.stopSoundCheckbox = [self settingsSwitchWithAction:NULL];
  self.errorSoundCheckbox = [self settingsSwitchWithAction:NULL];

  NSView *feedbackCard =
      [self cardWithTitle:@"Звуки"
                     rows:@[
                       [self cardRowWithLabel:@"Начало записи"
                                      control:self.startSoundCheckbox],
                       [self cardRowWithLabel:@"Конец записи"
                                      control:self.stopSoundCheckbox],
                       [self cardRowWithLabel:@"Ошибка"
                                      control:self.errorSoundCheckbox],
                     ]
                    width:cardWidth];

  // ── Recording ──
  self.muteSystemOutputCheckbox = [self settingsSwitchWithAction:NULL];
  self.keepMicWarmSwitch = [self settingsSwitchWithAction:NULL];
  self.lipflowSwitch = [self settingsSwitchWithAction:NULL];
  self.autoStopSilencePopup = [self autoStopSilencePopupButton];
  self.recordingCapPopup = [self recordingCapPopupButton];
  NSView *recordingCard =
      [self cardWithTitle:@"Запись"
                     rows:@[
                       [self cardRowWithLabel:@"Приглушать звук системы во время записи"
                                      control:self.muteSystemOutputCheckbox],
                       [self cardRowWithLabel:@"Держать микрофон включённым (без задержки старта)"
                                      control:self.keepMicWarmSwitch],
                       [self cardRowWithLabel:@"Запускать Lipflow (чтение по губам)"
                                      control:self.lipflowSwitch],
                       [self cardRowWithLabel:@"Автостоп по тишине (без удержания)"
                                      control:self.autoStopSilencePopup],
                       [self cardRowWithLabel:@"Предел длины записи"
                                      control:self.recordingCapPopup],
                     ]
                    width:cardWidth];

  // ── History ──
  self.saveRecordingsSwitch = [self settingsSwitchWithAction:NULL];
  self.autoRetryOnErrorSwitch = [self settingsSwitchWithAction:NULL];
  NSView *historyCard =
      [self cardWithTitle:@"История"
                     rows:@[
                       [self cardRowWithLabel:@"Сохранять аудиозаписи диктовок"
                                      control:self.saveRecordingsSwitch],
                       [self cardRowWithLabel:@"Повторно распознавать при ошибке"
                                      control:self.autoRetryOnErrorSwitch],
                       [self cardRowWithLabel:@"Хранить, дней"
                                      control:[self recordingsRetentionControl]],
                     ]
                    width:cardWidth];

  // ── Lip-reading data ──
  NSView *lipdataCard = [self lipdataCardWithWidth:cardWidth];
  // ── «Обучить на мне» (LipTraining/SPLipTrainingCard: builds and runs itself) ──
  NSView *lipTrainingCard = [[SPLipTrainingCard alloc] initWithWidth:cardWidth];
  // ── «Помочь обучить» (CommunityTraining/SPCommunityTrainingCard: builds and runs itself) ──
  NSView *communityCard = [[SPCommunityTrainingCard alloc] initWithWidth:cardWidth];

  // ── Layout ──
  CGFloat triggerH = triggerCard.frame.size.height;
  CGFloat pasteH = pasteCard.frame.size.height;
  CGFloat feedbackH = feedbackCard.frame.size.height;
  CGFloat recordingH = recordingCard.frame.size.height;
  CGFloat historyH = historyCard.frame.size.height;
  CGFloat lipdataH = lipdataCard.frame.size.height;
  CGFloat lipTrainingH = lipTrainingCard.frame.size.height;
  CGFloat communityH = communityCard.frame.size.height;
  CGFloat contentHeight = topPad + triggerH + cardSpacing + pasteH +
                          cardSpacing + feedbackH + cardSpacing + recordingH +
                          cardSpacing + historyH + cardSpacing + lipdataH +
                          cardSpacing + lipTrainingH + cardSpacing + communityH + 56;

  NSView *pane =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];

  CGFloat y = contentHeight - topPad;

  y -= triggerH;
  triggerCard.frame = NSMakeRect(24, y, cardWidth, triggerH);
  [pane addSubview:triggerCard];
  // Fix control positions — the card's child (index 1) is the white card view
  NSView *triggerCardBody = triggerCard.subviews.count > 1
                                ? triggerCard.subviews[1]
                                : triggerCard.subviews[0];
  [self layoutCardRowControls:triggerCardBody width:cardWidth];

  y -= cardSpacing + pasteH;
  pasteCard.frame = NSMakeRect(24, y, cardWidth, pasteH);
  [pane addSubview:pasteCard];
  NSView *pasteCardBody = pasteCard.subviews.count > 1
                              ? pasteCard.subviews[1]
                              : pasteCard.subviews[0];
  [self layoutCardRowControls:pasteCardBody width:cardWidth];

  y -= cardSpacing + feedbackH;
  feedbackCard.frame = NSMakeRect(24, y, cardWidth, feedbackH);
  [pane addSubview:feedbackCard];
  NSView *feedbackCardBody = feedbackCard.subviews.count > 1
                                 ? feedbackCard.subviews[1]
                                 : feedbackCard.subviews[0];
  [self layoutCardRowControls:feedbackCardBody width:cardWidth];

  y -= cardSpacing + recordingH;
  recordingCard.frame = NSMakeRect(24, y, cardWidth, recordingH);
  [pane addSubview:recordingCard];
  NSView *recordingCardBody = recordingCard.subviews.count > 1
                                  ? recordingCard.subviews[1]
                                  : recordingCard.subviews[0];
  [self layoutCardRowControls:recordingCardBody width:cardWidth];

  y -= cardSpacing + historyH;
  historyCard.frame = NSMakeRect(24, y, cardWidth, historyH);
  [pane addSubview:historyCard];
  NSView *historyCardBody = historyCard.subviews.count > 1
                                ? historyCard.subviews[1]
                                : historyCard.subviews[0];
  [self layoutCardRowControls:historyCardBody width:cardWidth];

  y -= cardSpacing + lipdataH;
  lipdataCard.frame = NSMakeRect(24, y, cardWidth, lipdataH);
  [pane addSubview:lipdataCard];
  NSView *lipdataCardBody = lipdataCard.subviews.count > 1
                                ? lipdataCard.subviews[1]
                                : lipdataCard.subviews[0];
  [self layoutCardRowControls:lipdataCardBody width:cardWidth];

  y -= cardSpacing + lipTrainingH;
  lipTrainingCard.frame = NSMakeRect(24, y, cardWidth, lipTrainingH);
  [pane addSubview:lipTrainingCard];

  y -= cardSpacing + communityH;
  communityCard.frame = NSMakeRect(24, y, cardWidth, communityH);
  [pane addSubview:communityCard];

  return pane;
}

/// "Данные для чтения по губам": opt-in camera recording during dictation.
- (NSView *)lipdataCardWithWidth:(CGFloat)cardWidth {
  self.lipdataCaptureSwitch =
      [self settingsSwitchWithAction:@selector(lipdataSwitchToggled:)];

  NSButton *finderButton = [NSButton buttonWithTitle:@"Показать в Finder"
                                              target:self
                                              action:@selector(lipdataShowInFinder:)];
  finderButton.bezelStyle = NSBezelStyleRounded;
  finderButton.controlSize = NSControlSizeSmall;
  [finderButton sizeToFit];

  NSView *switchRow =
      [self cardRowWithLabel:@"Снимать камеру во время диктовки (для обучения)"
                     control:self.lipdataCaptureSwitch];
  NSView *pathRow = [self cardRowWithLabel:[SPLipCaptureManager dataDirectory]
                                   control:finderButton];
  NSView *countRow =
      [self cardRowWithLabel:@"Собрано: …"
                     control:[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1)]];

  // The path is read-only text that elides in the middle; the counter is a caption.
  for (NSView *sub in pathRow.subviews) {
    if (![sub isKindOfClass:[NSTextField class]])
      continue;
    NSTextField *pathLabel = (NSTextField *)sub;
    pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    pathLabel.textColor = SPTheme.secondaryLabel;
    pathLabel.selectable = YES;
    pathLabel.toolTip = pathLabel.stringValue;
  }
  for (NSView *sub in countRow.subviews) {
    if ([sub isKindOfClass:[NSTextField class]]) {
      self.lipdataCountLabel = (NSTextField *)sub;
      self.lipdataCountLabel.textColor = SPTheme.secondaryLabel;
    }
  }

  // A separate consent, off by default: recording clips above never implies it.
  self.trainingContributeSwitch =
      [self settingsSwitchWithAction:@selector(trainingContributeToggled:)];
  NSView *contributeRow =
      [self cardRowWithLabel:@"Участвовать в общем обучении (только изменения весов)"
                     control:self.trainingContributeSwitch];

  // The lips mode's download is offered here too, so declining it at the key press is not final.
  self.lipsModeButton = [NSButton buttonWithTitle:@"Установить…"
                                           target:self
                                           action:@selector(lipsModeSetupPressed:)];
  self.lipsModeButton.bezelStyle = NSBezelStyleRounded;
  self.lipsModeButton.controlSize = NSControlSizeSmall;
  [self.lipsModeButton sizeToFit];
  NSView *lipsModeRow = [self cardRowWithLabel:@"Режим «губы»: …" control:self.lipsModeButton];
  for (NSView *sub in lipsModeRow.subviews) {
    if ([sub isKindOfClass:[NSTextField class]]) self.lipsModeLabel = (NSTextField *)sub;
  }

  return [self cardWithTitle:@"Данные для чтения по губам"
                        rows:@[ switchRow, pathRow, countRow, contributeRow, lipsModeRow ]
                       width:cardWidth];
}

- (void)refreshLipsModeRow {
  SPLipsRuntime *runtime = [SPLipsRuntime sharedRuntime];
  NSString *status;
  if ([runtime usesDeveloperCheckout]) {
    status = @"Режим «губы»: папка разработчика";
  } else if ([runtime isReady]) {
    status = [NSString stringWithFormat:@"Режим «губы»: установлен, модель %@", [runtime installedReleaseTag] ?: @"—"];
  } else {
    status = @"Режим «губы»: не установлен (около 9 ГБ)";
  }
  self.lipsModeLabel.stringValue = status;
  self.lipsModeButton.hidden = [runtime isReady];
}

- (void)lipsModeSetupPressed:(id)sender {
  __weak typeof(self) weakSelf = self;
  [[SPLipsRuntime sharedRuntime] offerSetupWithCompletion:^(BOOL ready) {
    [weakSelf refreshLipsModeRow];
  }];
}

/// Counts the clips on disk off the main thread and shows the total.
- (void)refreshLipdataCounter {
  NSString *dir = [SPLipCaptureManager dataDirectory];
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    SPLipDataStats stats = [SPLipDataPolicy statsForDirectory:dir];
    NSString *summary = [SPLipDataPolicy counterSummaryForStats:stats];
    dispatch_async(dispatch_get_main_queue(), ^{
      weakSelf.lipdataCountLabel.stringValue = summary;
    });
  });
}

- (void)lipdataShowInFinder:(id)sender {
  NSString *dir = [SPLipCaptureManager dataDirectory];
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:dir]) {
    [fm createDirectoryAtPath:dir
        withIntermediateDirectories:YES
                         attributes:@{NSFilePosixPermissions : @(0700)}
                              error:nil];
  }
  [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dir isDirectory:YES]];
}

/// Contributing to training is an explicit, informed opt-in: turning the switch
/// on asks once what it means; cancelling leaves it off.
- (void)trainingContributeToggled:(id)sender {
  if (self.trainingContributeSwitch.state != NSControlStateValueOn)
    return;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Участвовать в общем обучении?";
  alert.informativeText =
      @"Модель чтения по губам будет дообучаться на этом Mac на ваших клипах, "
      @"а на сервер проекта уйдут только изменения весов адаптера — никогда "
      @"видео, звук или текст. Это отдельное согласие, его можно отозвать в "
      @"любой момент этим же переключателем. Условия — в PRIVACY.md и "
      @"federated/docs/AGREEMENT.md. Пока общее обучение в приложение не "
      @"встроено, переключатель только запоминает ваше решение.";
  [alert addButtonWithTitle:@"Участвовать"];
  [alert addButtonWithTitle:@"Отмена"];
  if ([alert runModal] != NSAlertFirstButtonReturn) {
    self.trainingContributeSwitch.state = NSControlStateValueOff;
  }
}

/// Turning the switch on is the one moment the camera permission is asked for
/// (never in the middle of a dictation).
- (void)lipdataSwitchToggled:(id)sender {
  if (self.lipdataCaptureSwitch.state != NSControlStateValueOn)
    return;
  [SPLipCaptureManager requestAccessIfNeeded:^(AVAuthorizationStatus status) {
    if (status == AVAuthorizationStatusDenied ||
        status == AVAuthorizationStatusRestricted) {
      NSLog(@"[VelikiyMoguchiy] lipdata: camera access is denied; the menu will show the "
            @"missing permission");
    }
  }];
}

- (NSView *)recordingsRetentionControl {
  NSView *control = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 84, 26)];

  NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
  formatter.numberStyle = NSNumberFormatterNoStyle;
  formatter.minimum = @(kRecordingsRetentionMin);
  formatter.maximum = @(kRecordingsRetentionMax);
  formatter.allowsFloats = NO;

  self.recordingsRetentionField =
      [[NSTextField alloc] initWithFrame:NSMakeRect(0, 1, 56, 24)];
  self.recordingsRetentionField.formatter = formatter;
  self.recordingsRetentionField.alignment = NSTextAlignmentRight;
  self.recordingsRetentionField.integerValue = kRecordingsRetentionDefault;
  self.recordingsRetentionField.target = self;
  self.recordingsRetentionField.action = @selector(recordingsRetentionFieldChanged:);

  self.recordingsRetentionStepper =
      [[NSStepper alloc] initWithFrame:NSMakeRect(62, 1, 19, 24)];
  self.recordingsRetentionStepper.minValue = kRecordingsRetentionMin;
  self.recordingsRetentionStepper.maxValue = kRecordingsRetentionMax;
  self.recordingsRetentionStepper.increment = 1;
  self.recordingsRetentionStepper.valueWraps = NO;
  self.recordingsRetentionStepper.integerValue = kRecordingsRetentionDefault;
  self.recordingsRetentionStepper.target = self;
  self.recordingsRetentionStepper.action = @selector(recordingsRetentionStepperChanged:);

  [control addSubview:self.recordingsRetentionField];
  [control addSubview:self.recordingsRetentionStepper];
  return control;
}

- (NSInteger)recordingsRetentionValue {
  NSInteger days = self.recordingsRetentionField.integerValue;
  return MAX(kRecordingsRetentionMin, MIN(kRecordingsRetentionMax, days));
}

- (void)setRecordingsRetentionValue:(NSInteger)days {
  days = MAX(kRecordingsRetentionMin, MIN(kRecordingsRetentionMax, days));
  self.recordingsRetentionField.integerValue = days;
  self.recordingsRetentionStepper.integerValue = days;
}

- (void)recordingsRetentionFieldChanged:(id)sender {
  [self setRecordingsRetentionValue:self.recordingsRetentionField.integerValue];
}

- (void)recordingsRetentionStepperChanged:(id)sender {
  [self setRecordingsRetentionValue:self.recordingsRetentionStepper.integerValue];
}

- (NSPopUpButton *)hotkeyPresetPopup {
  NSPopUpButton *popup =
      [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 168, 26)
                                 pullsDown:NO];
  NSArray<NSString *> *titles = @[
    @"Fn (Globe)",
    @"Left Option (\u2325)",
    @"Right Option (\u2325)",
    @"Left Command (\u2318)",
    @"Right Command (\u2318)",
    @"Left Control (\u2303)",
    @"Right Control (\u2303)",
  ];
  NSArray<NSString *> *values = @[
    @"fn",
    @"left_option",
    @"right_option",
    @"left_command",
    @"right_command",
    @"left_control",
    @"right_control",
  ];
  [popup addItemsWithTitles:titles];
  for (NSInteger idx = 0; idx < (NSInteger)values.count; idx++) {
    [popup itemAtIndex:idx].representedObject = values[idx];
  }
  return popup;
}

// Optional extra trigger (translate / ask): "off" is an empty config value.
- (NSPopUpButton *)extraHotkeyPopup {
  NSPopUpButton *popup =
      [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 168, 26)
                                 pullsDown:NO];
  NSArray<NSArray<NSString *> *> *options = @[
    @[ @"Выключено", @"" ],
    @[ @"Правый ⌥", @"right_option" ],
    @[ @"Левый ⌥", @"left_option" ],
    @[ @"Правый ⌘", @"right_command" ],
    @[ @"Левый ⌘", @"left_command" ],
    @[ @"Правый Control", @"right_control" ],
    @[ @"Левый Control", @"left_control" ],
    @[ @"Fn", @"fn" ],
  ];
  for (NSArray<NSString *> *option in options) {
    [popup addItemWithTitle:option[0]];
    [popup lastItem].representedObject = option[1];
  }
  return popup;
}

// Mouse button as a second trigger. Values are the 1-based button numbers
// written to hotkey.mouse_button; "0" is off.
- (NSPopUpButton *)mouseButtonPopupButton {
  NSPopUpButton *popup =
      [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 168, 26)
                                 pullsDown:NO];
  NSArray<NSArray<NSString *> *> *options = @[
    @[ @"Выключено", @"0" ],
    @[ @"Средняя", @"3" ],
    @[ @"Боковая 4 (назад)", @"4" ],
    @[ @"Боковая 5 (вперёд)", @"5" ],
  ];
  for (NSArray<NSString *> *option in options) {
    [popup addItemWithTitle:option[0]];
    [popup lastItem].representedObject = option[1];
  }
  return popup;
}

// Seconds of silence after speech that end a hands-free recording; "0" is off.
- (NSPopUpButton *)autoStopSilencePopupButton {
  NSPopUpButton *popup =
      [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 168, 26)
                                 pullsDown:NO];
  NSArray<NSArray<NSString *> *> *options = @[
    @[ @"Выключено", @"0" ],
    @[ @"2 с", @"2" ],
    @[ @"3 с", @"3" ],
    @[ @"5 с", @"5" ],
    @[ @"8 с", @"8" ],
    @[ @"15 с", @"15" ],
    @[ @"30 с", @"30" ],
    @[ @"60 с", @"60" ],
  ];
  for (NSArray<NSString *> *option in options) {
    [popup addItemWithTitle:option[0]];
    [popup lastItem].representedObject = option[1];
  }
  return popup;
}

// Seconds after which any recording ends; "0" is no limit.
- (NSPopUpButton *)recordingCapPopupButton {
  NSPopUpButton *popup =
      [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 168, 26)
                                 pullsDown:NO];
  NSArray<NSArray<NSString *> *> *options = @[
    @[ @"Без предела", @"0" ],
    @[ @"5 мин", @"300" ],
    @[ @"10 мин", @"600" ],
    @[ @"30 мин", @"1800" ],
  ];
  for (NSArray<NSString *> *option in options) {
    [popup addItemWithTitle:option[0]];
    [popup lastItem].representedObject = option[1];
  }
  return popup;
}

// Selects the item holding `value`; a value outside the list (set by hand in
// config.yaml) gets an item of its own so saving does not rewrite it.
- (void)selectValue:(NSString *)value
            inPopup:(NSPopUpButton *)popup
        customTitle:(NSString * (^)(NSString *))customTitle {
  NSString *trimmed = [value stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (trimmed.length == 0)
    trimmed = @"0";
  for (NSMenuItem *item in popup.itemArray) {
    if ([[item.representedObject description] isEqualToString:trimmed]) {
      [popup selectItem:item];
      return;
    }
  }
  [popup addItemWithTitle:customTitle(trimmed)];
  [popup lastItem].representedObject = trimmed;
  [popup selectItem:[popup lastItem]];
}

// Cancels an active dictation: a plain key, since it is captured only while a
// session runs. "off" is an empty config value.
- (NSPopUpButton *)abortKeyPopupButton {
  NSPopUpButton *popup =
      [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 168, 26)
                                 pullsDown:NO];
  NSArray<NSArray<NSString *> *> *options = @[
    @[ @"Escape", @"escape" ],
    @[ @"Выключено", @"" ],
    @[ @"F1", @"122" ],
    @[ @"F2", @"120" ],
    @[ @"F3", @"99" ],
    @[ @"F4", @"118" ],
    @[ @"F5", @"96" ],
    @[ @"F6", @"97" ],
  ];
  for (NSArray<NSString *> *option in options) {
    [popup addItemWithTitle:option[0]];
    [popup lastItem].representedObject = option[1];
  }
  return popup;
}

// `isSet` is NO when hotkey.abort_key is absent from config.yaml, which means
// the default (Escape), unlike an explicit empty value, which means off.
- (void)selectAbortKeyValue:(NSString *)value
                      isSet:(BOOL)isSet
                    inPopup:(NSPopUpButton *)popup {
  NSString *trimmed = [[value stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]]
      lowercaseString];
  if (!isSet || [trimmed isEqualToString:@"esc"]) {
    trimmed = @"escape";
  }
  if (isNumericKeycode(trimmed)) {
    trimmed = [NSString stringWithFormat:@"%ld", (long)trimmed.integerValue];
  }
  for (NSMenuItem *item in popup.itemArray) {
    if ([[item.representedObject description] isEqualToString:trimmed]) {
      [popup selectItem:item];
      return;
    }
  }
  if (isNumericKeycode(trimmed)) {
    [popup addItemWithTitle:[NSString stringWithFormat:@"Клавиша %@", trimmed]];
    [popup lastItem].representedObject = trimmed;
    [popup selectItem:[popup lastItem]];
    return;
  }
  [popup selectItemAtIndex:0];
}

- (void)selectExtraHotkeyValue:(NSString *)value inPopup:(NSPopUpButton *)popup {
  NSString *trimmed = [value stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (trimmed.length == 0) {
    [popup selectItemAtIndex:0];
    return;
  }
  NSString *normalized = normalizedHotkeyValue(trimmed);
  for (NSMenuItem *item in popup.itemArray) {
    if ([[item.representedObject description] isEqualToString:normalized]) {
      [popup selectItem:item];
      return;
    }
  }
  ensureCustomHotkeyInPopup(popup, normalized);
}

- (NSView *)hotkeyPickerControlWithPopup:(NSPopUpButton *)popup
                            recordButton:(NSButton *)button
                             resetButton:(NSButton *)resetButton {
  CGFloat spacing = 6.0;
  CGFloat width = popup.frame.size.width + spacing + button.frame.size.width +
                  spacing + resetButton.frame.size.width;
  CGFloat height = MAX(popup.frame.size.height, button.frame.size.height);
  NSView *container =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];

  popup.frame = NSMakeRect(0, floor((height - popup.frame.size.height) / 2.0),
                           popup.frame.size.width, popup.frame.size.height);
  button.frame = NSMakeRect(CGRectGetMaxX(popup.frame) + spacing,
                            floor((height - button.frame.size.height) / 2.0),
                            button.frame.size.width, button.frame.size.height);
  resetButton.frame =
      NSMakeRect(CGRectGetMaxX(button.frame) + spacing,
                 floor((height - resetButton.frame.size.height) / 2.0),
                 resetButton.frame.size.width, resetButton.frame.size.height);
  [container addSubview:popup];
  [container addSubview:button];
  [container addSubview:resetButton];
  return container;
}

- (void)setRuntimeHotkeyMonitoringSuspended:(BOOL)suspended {
  id appDelegate = NSApp.delegate;
  if (!appDelegate)
    return;

  id monitor = nil;
  @try {
    monitor = [appDelegate valueForKey:@"hotkeyMonitor"];
  } @catch (__unused NSException *exception) {
    return;
  }

  if ([monitor respondsToSelector:@selector(setSuspended:)]) {
    [monitor setSuspended:suspended];
  }
}

- (void)selectHotkeyValue:(NSString *)value inPopup:(NSPopUpButton *)popup {
  NSString *normalizedValue = normalizedHotkeyValue(value);
  if (hotkeyValueUsesCustomPopupItem(normalizedValue)) {
    ensureCustomHotkeyInPopup(popup, normalizedValue);
    return;
  }

  NSMutableArray<NSMenuItem *> *itemsToRemove = [NSMutableArray array];
  for (NSMenuItem *item in popup.itemArray) {
    NSString *representedObject =
        [item.representedObject isKindOfClass:[NSString class]]
            ? item.representedObject
            : nil;
    if (representedObject.length > 0 &&
        ![presetHotkeyValues() containsObject:representedObject]) {
      [itemsToRemove addObject:item];
    }
  }
  for (NSMenuItem *item in itemsToRemove) {
    [popup.menu removeItem:item];
  }

  for (NSMenuItem *item in popup.itemArray) {
    if ([[item.representedObject description]
            isEqualToString:normalizedValue]) {
      [popup selectItem:item];
      return;
    }
  }

  [popup selectItemAtIndex:0];
}

- (void)triggerHotkeyChanged:(id)sender {
  [self warnAboutFnConflictIfNeeded];
}

- (void)updateHotkeyRecordingButtons {
  BOOL recordingTrigger =
      [self.recordingHotkeyTarget isEqualToString:@"trigger"];

  self.recordTriggerHotkeyButton.enabled = YES;
  self.resetTriggerHotkeyButton.enabled = !recordingTrigger;
  [self.recordTriggerHotkeyButton
      setTitle:(recordingTrigger ? @"Нажмите…" : @"Записать")];
}

- (void)endHotkeyRecording {
  if (self.hotkeyRecordingMonitor) {
    [NSEvent removeMonitor:self.hotkeyRecordingMonitor];
    self.hotkeyRecordingMonitor = nil;
  }
  self.recordingHotkeyTarget = nil;
  [self setRuntimeHotkeyMonitoringSuspended:NO];
  [self updateHotkeyRecordingButtons];
}

- (void)beginHotkeyRecordingForTarget:(NSString *)target
                                popup:(NSPopUpButton *)popup {
  [self endHotkeyRecording];

  self.recordingHotkeyTarget = target;
  [self setRuntimeHotkeyMonitoringSuspended:YES];
  [self updateHotkeyRecordingButtons];

  __weak typeof(self) weakSelf = self;
  // A modifier counts once it is let go with no key pressed meanwhile: -1 is
  // none yet, -2 a chord, otherwise the keycode of the lone modifier.
  __block NSInteger loneModifier = -1;
  NSUInteger modifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption |
                            NSEventModifierFlagControl | NSEventModifierFlagShift |
                            NSEventModifierFlagFunction;
  self.hotkeyRecordingMonitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown |
                                            NSEventMaskFlagsChanged)
                                   handler:^NSEvent *(NSEvent *event) {
                                     if (![weakSelf.recordingHotkeyTarget
                                             isEqualToString:target]) {
                                       return event;
                                     }

                                     if (event.type == NSEventTypeFlagsChanged) {
                                       if ((event.modifierFlags & modifierMask) != 0) {
                                         loneModifier = loneModifier == -1 ? event.keyCode : -2;
                                       } else {
                                         NSInteger keyCode = loneModifier;
                                         loneModifier = -1;
                                         if (keyCode >= 0) {
                                           [weakSelf finishHotkeyRecording:
                                                         [SPRecordedTrigger triggerForModifierKeyCode:keyCode]
                                                                    popup:popup];
                                         }
                                       }
                                       return nil;
                                     }

                                     if (event.keyCode == 53 &&
                                         (event.modifierFlags & modifierMask) == 0) {
                                       [weakSelf endHotkeyRecording];
                                       return nil;
                                     }

                                     if ([event isARepeat]) {
                                       return nil;
                                     }
                                     loneModifier = -2;
                                     [weakSelf finishHotkeyRecording:
                                                   [SPRecordedTrigger triggerForKeyCode:event.keyCode
                                                                          modifierFlags:event.modifierFlags]
                                                              popup:popup];
                                     return nil;
                                   }];
}

- (void)finishHotkeyRecording:(SPRecordedTrigger *)trigger popup:(NSPopUpButton *)popup {
  [self endHotkeyRecording];
  if (trigger.value.length == 0) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = @"Эту клавишу нельзя назначить";
    alert.informativeText = trigger.refusal ?: @"";
    [alert addButtonWithTitle:@"Понятно"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
    return;
  }
  [self selectHotkeyValue:trigger.value inPopup:popup];
  [self warnAboutFnConflictIfNeeded];
}

/// Fn chosen while the 🌐 key also does something of its own.
- (void)warnAboutFnConflictIfNeeded {
  NSString *selected = [self.hotkeyPopup.selectedItem.representedObject description];
  if (![selected isEqualToString:@"fn"])
    return;
  NSString *conflict = SPFnUsageConflict(SPFnUsageType());
  if (!conflict)
    return;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.alertStyle = NSAlertStyleWarning;
  alert.messageText = @"Клавиша Fn (🌐) занята системой";
  alert.informativeText = SPFnConflictExplanation(conflict);
  [alert addButtonWithTitle:@"Открыть «Клавиатуру»"];
  [alert addButtonWithTitle:@"Оставить Fn"];
  [alert beginSheetModalForWindow:self.window
                completionHandler:^(NSModalResponse response) {
                  if (response == NSAlertFirstButtonReturn) {
                    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:SPKeyboardSettingsURL]];
                  }
                }];
}

- (void)recordTriggerHotkey:(id)sender {
  [self beginHotkeyRecordingForTarget:@"trigger" popup:self.hotkeyPopup];
}

- (void)resetTriggerHotkey:(id)sender {
  [self endHotkeyRecording];
  [self selectHotkeyValue:@"fn" inPopup:self.hotkeyPopup];
  [self warnAboutFnConflictIfNeeded];
}

- (NSView *)buildDictionaryPane {
  CGFloat paneWidth = [self paneContentWidth];
  CGFloat contentHeight = [self paneViewportHeight];
  NSView *pane =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];
  CGFloat contentX = SPTheme.pageMargin;
  CGFloat contentW = paneWidth - 2.0 * contentX;

  CGFloat y = contentHeight - 30.0;

  // Description
  NSTextField *desc =
      [self addSettingsDescriptionText:
                @"Пользовательский словарь — по одному термину в строке. Эти "
                @"термины в приоритете при коррекции через LLM. Строки, "
                @"начинающиеся с #, — комментарии."
                                toPane:pane
                                  topY:y
                                     x:contentX
                                 width:contentW];

  NSTextField *sectionTitle = [self
      sectionTitleLabel:@"Словарь"
                  frame:NSMakeRect(contentX, floor(NSMinY(desc.frame) - 36.0),
                                   contentW, 20)];
  [pane addSubview:sectionTitle];

  // Text editor
  CGFloat editorCardY = SPTheme.pageMargin;
  CGFloat editorTopY = NSMinY(sectionTitle.frame) - 12.0;
  CGFloat editorHeight = editorTopY - editorCardY;
  NSView *editorCard =
      [self surfaceCardViewWithFrame:NSMakeRect(contentX, editorCardY, contentW,
                                                editorHeight)];
  [pane addSubview:editorCard];

  NSScrollView *scrollView = [[NSScrollView alloc]
      initWithFrame:NSMakeRect(12, 12, contentW - 24, editorHeight - 24)];
  scrollView.hasVerticalScroller = YES;
  scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  scrollView.borderType = NSNoBorder;
  scrollView.drawsBackground = NO;
  scrollView.scrollerStyle = NSScrollerStyleOverlay;

  self.dictionaryTextView = [[NSTextView alloc]
      initWithFrame:NSMakeRect(0, 0, contentW - 24, editorHeight - 24)];
  self.dictionaryTextView.minSize = NSMakeSize(0, editorHeight - 24);
  self.dictionaryTextView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
  self.dictionaryTextView.verticallyResizable = YES;
  self.dictionaryTextView.horizontallyResizable = NO;
  self.dictionaryTextView.autoresizingMask = NSViewWidthSizable;
  self.dictionaryTextView.textContainer.containerSize =
      NSMakeSize(contentW - 24, FLT_MAX);
  self.dictionaryTextView.textContainer.widthTracksTextView = YES;
  self.dictionaryTextView.textContainerInset = NSMakeSize(8, 10);
  self.dictionaryTextView.font =
      [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
  self.dictionaryTextView.allowsUndo = YES;

  [self styleEditorTextView:self.dictionaryTextView scrollView:scrollView];
  scrollView.documentView = self.dictionaryTextView;
  [editorCard addSubview:scrollView];

  // Save / Cancel buttons

  return pane;
}

- (NSView *)buildSnippetsPane {
  CGFloat paneWidth = [self paneContentWidth];
  CGFloat contentHeight = [self paneViewportHeight];
  NSView *pane =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];
  CGFloat contentX = SPTheme.pageMargin;
  CGFloat contentW = paneWidth - 2.0 * contentX;

  NSTextField *desc = [self
      addSettingsDescriptionText:@"Короткая фраза превращается в готовый текст: "
                                 @"подпись, почта, ссылка. Срабатывает, когда "
                                 @"вся диктовка — эта фраза, или когда в ней "
                                 @"есть «вставь <фраза>». Текст вставляется "
                                 @"ровно как записан. Перенос строки в тексте — ⌥Return."
                          toPane:pane
                            topY:contentHeight - 30.0
                               x:contentX
                           width:contentW];

  NSTextField *sectionTitle = [self
      sectionTitleLabel:@"Сниппеты"
                  frame:NSMakeRect(contentX, floor(NSMinY(desc.frame) - 36.0),
                                   contentW - 40.0, 20)];
  [pane addSubview:sectionTitle];

  NSButton *plus =
      [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"plus"
                                          accessibilityDescription:@"Добавить сниппет"]
                         target:self
                         action:@selector(addSnippetRow:)];
  plus.frame = NSMakeRect(contentX + contentW - 32.0,
                          NSMinY(sectionTitle.frame) - 4.0, 32, 26);
  plus.bezelStyle = NSBezelStyleRounded;
  plus.toolTip = @"Добавить сниппет";
  plus.accessibilityIdentifier = @"snippets.add";
  [pane addSubview:plus];

  CGFloat cardY = SPTheme.pageMargin;
  CGFloat cardTopY = NSMinY(sectionTitle.frame) - 12.0;
  CGFloat cardHeight = cardTopY - cardY;
  NSView *card = [self surfaceCardViewWithFrame:NSMakeRect(contentX, cardY, contentW, cardHeight)];
  [pane addSubview:card];

  self.snippetScroll = [[NSScrollView alloc]
      initWithFrame:NSMakeRect(12, 12, contentW - 24, cardHeight - 24)];
  self.snippetScroll.hasVerticalScroller = YES;
  self.snippetScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  self.snippetScroll.borderType = NSNoBorder;
  self.snippetScroll.drawsBackground = NO;
  self.snippetScroll.scrollerStyle = NSScrollerStyleOverlay;
  self.snippetRows = [[SPFlippedDocumentView alloc]
      initWithFrame:NSMakeRect(0, 0, contentW - 24, cardHeight - 24)];
  self.snippetScroll.documentView = self.snippetRows;
  [card addSubview:self.snippetScroll];
  self.snippetTriggerFields = [NSMutableArray array];
  self.snippetTextFields = [NSMutableArray array];
  return pane;
}

static const CGFloat kSnippetRowHeight = 58.0;

- (NSArray<NSDictionary *> *)currentSnippetEntries {
  NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
  for (NSUInteger i = 0; i < self.snippetTriggerFields.count; i++) {
    [entries addObject:@{
      @"trigger" : self.snippetTriggerFields[i].stringValue ?: @"",
      @"text" : self.snippetTextFields[i].stringValue ?: @"",
    }];
  }
  return entries;
}

- (void)setSnippetEntries:(NSArray<NSDictionary *> *)entries {
  for (NSView *row in [self.snippetRows.subviews copy])
    [row removeFromSuperview];
  [self.snippetTriggerFields removeAllObjects];
  [self.snippetTextFields removeAllObjects];

  CGFloat width = NSWidth(self.snippetScroll.contentView.bounds);
  CGFloat triggerW = floor(width * 0.30);
  CGFloat arrowW = 22.0;
  CGFloat minusW = 28.0;
  CGFloat textW = width - triggerW - arrowW - minusW - 16.0;
  for (NSUInteger i = 0; i < entries.count; i++) {
    CGFloat y = i * kSnippetRowHeight + 6.0;
    NSTextField *trigger = [self formTextField:NSMakeRect(4, y + 12, triggerW, 22)
                                   placeholder:@"мой имейл"];
    trigger.stringValue = entries[i][@"trigger"] ?: @"";
    trigger.accessibilityIdentifier = [NSString stringWithFormat:@"snippets.trigger.%lu", (unsigned long)i];
    [self.snippetRows addSubview:trigger];

    NSTextField *arrow = [NSTextField labelWithString:@"→"];
    arrow.frame = NSMakeRect(4 + triggerW, y + 13, arrowW, 20);
    arrow.alignment = NSTextAlignmentCenter;
    arrow.textColor = [NSColor secondaryLabelColor];
    [self.snippetRows addSubview:arrow];

    NSTextField *text = [self formTextField:NSMakeRect(8 + triggerW + arrowW, y, textW, kSnippetRowHeight - 12.0)
                                placeholder:@"ivan@example.com"];
    text.usesSingleLineMode = NO;
    text.cell.wraps = YES;
    text.cell.scrollable = NO;
    text.lineBreakMode = NSLineBreakByWordWrapping;
    text.maximumNumberOfLines = 3;
    text.stringValue = entries[i][@"text"] ?: @"";
    text.accessibilityIdentifier = [NSString stringWithFormat:@"snippets.text.%lu", (unsigned long)i];
    [self.snippetRows addSubview:text];

    NSButton *minus = [NSButton
        buttonWithImage:[NSImage imageWithSystemSymbolName:@"minus.circle"
                                  accessibilityDescription:@"Удалить"]
                 target:self
                 action:@selector(removeSnippetRow:)];
    minus.frame = NSMakeRect(12 + triggerW + arrowW + textW, y + 11, 24, 24);
    minus.bordered = NO;
    minus.tag = (NSInteger)i;
    minus.accessibilityIdentifier = [NSString stringWithFormat:@"snippets.remove.%lu", (unsigned long)i];
    [self.snippetRows addSubview:minus];

    [self.snippetTriggerFields addObject:trigger];
    [self.snippetTextFields addObject:text];
  }
  NSRect frame = self.snippetRows.frame;
  frame.size.width = width;
  frame.size.height = MAX(entries.count * kSnippetRowHeight + 12.0,
                          NSHeight(self.snippetScroll.contentView.bounds));
  self.snippetRows.frame = frame;
}

- (void)addSnippetRow:(id)sender {
  NSMutableArray<NSDictionary *> *entries =
      [[self currentSnippetEntries] mutableCopy];
  [entries addObject:@{@"trigger" : @"", @"text" : @""}];
  [self setSnippetEntries:entries];
  NSView *last = self.snippetTriggerFields.lastObject;
  if (last) {
    [self.snippetRows scrollRectToVisible:last.frame];
    [self.window makeFirstResponder:last];
  }
}

- (void)removeSnippetRow:(NSButton *)sender {
  NSMutableArray<NSDictionary *> *entries =
      [[self currentSnippetEntries] mutableCopy];
  if (sender.tag >= 0 && (NSUInteger)sender.tag < entries.count) {
    [entries removeObjectAtIndex:(NSUInteger)sender.tag];
    [self setSnippetEntries:entries];
  }
}

// Rows with a phrase; a row without one cannot match anything.
- (NSArray<NSDictionary *> *)snippetsForSave {
  NSMutableArray<NSDictionary *> *snippets = [NSMutableArray array];
  for (NSDictionary *entry in [self currentSnippetEntries]) {
    NSString *trigger = [entry[@"trigger"] stringByTrimmingCharactersInSet:
                                               [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trigger.length == 0)
      continue;
    [snippets addObject:@{@"trigger" : trigger, @"text" : entry[@"text"] ?: @""}];
  }
  return snippets;
}

- (NSString *)signatureForSnippets:(NSArray<NSDictionary *> *)snippets {
  NSData *data = [NSJSONSerialization dataWithJSONObject:snippets
                                                 options:NSJSONWritingSortedKeys
                                                   error:NULL];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
}

- (NSView *)buildSystemPromptPane {
  CGFloat paneWidth = [self paneContentWidth];
  CGFloat contentHeight = [self paneViewportHeight];
  NSView *pane =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];
  CGFloat contentX = SPTheme.pageMargin;
  CGFloat contentW = paneWidth - 2.0 * contentX;

  CGFloat y = contentHeight - 30.0;

  // Description
  NSTextField *desc = [self
      addSettingsDescriptionText:@"Системный промпт, который отправляется в LLM для коррекции "
                                 @"текста. Измените его, чтобы настроить поведение."
                          toPane:pane
                            topY:y
                               x:contentX
                           width:contentW];

  NSTextField *sectionTitle = [self
      sectionTitleLabel:@"Системный промпт"
                  frame:NSMakeRect(contentX, floor(NSMinY(desc.frame) - 36.0),
                                   contentW, 20)];
  [pane addSubview:sectionTitle];

  // Text editor
  CGFloat editorCardY = SPTheme.pageMargin;
  CGFloat editorTopY = NSMinY(sectionTitle.frame) - 12.0;
  CGFloat editorHeight = editorTopY - editorCardY;
  NSView *editorCard =
      [self surfaceCardViewWithFrame:NSMakeRect(contentX, editorCardY, contentW,
                                                editorHeight)];
  [pane addSubview:editorCard];

  NSScrollView *scrollView = [[NSScrollView alloc]
      initWithFrame:NSMakeRect(12, 12, contentW - 24, editorHeight - 24)];
  scrollView.hasVerticalScroller = YES;
  scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  scrollView.borderType = NSNoBorder;
  scrollView.drawsBackground = NO;
  scrollView.scrollerStyle = NSScrollerStyleOverlay;

  self.systemPromptTextView = [[NSTextView alloc]
      initWithFrame:NSMakeRect(0, 0, contentW - 24, editorHeight - 24)];
  self.systemPromptTextView.minSize = NSMakeSize(0, editorHeight - 24);
  self.systemPromptTextView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
  self.systemPromptTextView.verticallyResizable = YES;
  self.systemPromptTextView.horizontallyResizable = NO;
  self.systemPromptTextView.autoresizingMask = NSViewWidthSizable;
  self.systemPromptTextView.textContainer.containerSize =
      NSMakeSize(contentW - 24, FLT_MAX);
  self.systemPromptTextView.textContainer.widthTracksTextView = YES;
  self.systemPromptTextView.textContainerInset = NSMakeSize(8, 10);
  self.systemPromptTextView.font =
      [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
  self.systemPromptTextView.allowsUndo = YES;

  [self styleEditorTextView:self.systemPromptTextView scrollView:scrollView];
  scrollView.documentView = self.systemPromptTextView;
  [editorCard addSubview:scrollView];

  // Save / Cancel buttons

  return pane;
}

// ─── Templates Pane ────────────────────────────────────────────────

- (NSView *)buildTemplatesPane {
  CGFloat paneWidth = [self paneContentWidth];
  CGFloat contentHeight = [self paneViewportHeight];
  NSView *pane =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];

  CGFloat contentX = SPTheme.pageMargin;
  CGFloat contentW = paneWidth - 2.0 * contentX;
  CGFloat y = contentHeight - 30.0;

  NSTextField *desc =
      [self addSettingsDescriptionText:
                @"Управляйте шаблонами оверлея: меняйте порядок, видимость и "
                @"редактируйте промпт каждого шаблона."
                                toPane:pane
                                  topY:y
                                     x:contentX
                                 width:contentW];
  y = NSMinY(desc.frame) - 16.0;

  self.templatesEnabledSwitch = [self settingsSwitchWithAction:NULL];
  NSView *visibilityCard = [self
      settingsToggleCardWithFrame:NSMakeRect(contentX, y - 48, contentW, 48)
                            title:@"Показывать кнопки шаблонов в оверлее"
                           toggle:self.templatesEnabledSwitch];
  [pane addSubview:visibilityCard];

  CGFloat sectionTitleY = NSMinY(visibilityCard.frame) - 44.0;
  CGFloat mainCardY = SPTheme.pageMargin;
  CGFloat mainCardH = sectionTitleY - mainCardY - 12.0;
  CGFloat listW = 260.0;
  CGFloat cardGap = 16.0;
  CGFloat editorW = contentW - listW - cardGap;
  CGFloat editorX = contentX + listW + cardGap;

  NSTextField *listTitle =
      [self sectionTitleLabel:@"Список шаблонов"
                        frame:NSMakeRect(contentX, sectionTitleY, listW, 20)];
  [pane addSubview:listTitle];

  NSTextField *editorTitle =
      [self sectionTitleLabel:@"Редактор шаблона"
                        frame:NSMakeRect(editorX, sectionTitleY, editorW, 20)];
  [pane addSubview:editorTitle];

  NSView *listCard =
      [self surfaceCardViewWithFrame:NSMakeRect(contentX, mainCardY, listW,
                                                mainCardH)];
  [pane addSubview:listCard];

  NSView *editorCard =
      [self surfaceCardViewWithFrame:NSMakeRect(editorX, mainCardY, editorW,
                                                mainCardH)];
  [pane addSubview:editorCard];

  CGFloat headerH = 34.0;
  CGFloat footerH = 34.0;

  NSTextField *libraryCaption = [NSTextField labelWithString:@"Шаблоны"];
  libraryCaption.font = SPTheme.cardTitleFont;
  libraryCaption.textColor = SPTheme.primaryText;
  libraryCaption.frame = NSMakeRect(14, mainCardH - headerH + 9, 120, 18);
  [listCard addSubview:libraryCaption];

  NSBox *headerSeparator = [[NSBox alloc]
      initWithFrame:NSMakeRect(0, mainCardH - headerH, listW, 1)];
  headerSeparator.boxType = NSBoxSeparator;
  [listCard addSubview:headerSeparator];

  NSBox *footerSeparator =
      [[NSBox alloc] initWithFrame:NSMakeRect(0, footerH, listW, 1)];
  footerSeparator.boxType = NSBoxSeparator;
  [listCard addSubview:footerSeparator];

  self.templatePrimaryActionsControl =
      [self templateActionSegmentedControlWithSymbols:@[ @"plus", @"minus" ]
                                             toolTips:@[
                                               @"Добавить шаблон",
                                               @"Удалить выбранный шаблон"
                                             ]
                                               action:@selector
                                               (handleTemplatePrimaryActions:)];
  self.templatePrimaryActionsControl.frame = NSMakeRect(12, 5, 50, 24);
  [listCard addSubview:self.templatePrimaryActionsControl];

  self.templateReorderActionsControl = [self
      templateActionSegmentedControlWithSymbols:@[ @"arrow.up", @"arrow.down" ]
                                       toolTips:@[
                                         @"Поднять выбранный шаблон выше",
                                         @"Опустить выбранный шаблон ниже"
                                       ]
                                         action:@selector
                                         (handleTemplateReorderActions:)];
  self.templateReorderActionsControl.frame =
      NSMakeRect(listW - 12 - 50, 5, 50, 24);
  [listCard addSubview:self.templateReorderActionsControl];

  NSScrollView *scrollView = [[NSScrollView alloc]
      initWithFrame:NSMakeRect(10, footerH + 10, listW - 20,
                               mainCardH - headerH - footerH - 20)];
  scrollView.hasVerticalScroller = YES;
  scrollView.autohidesScrollers = YES;
  scrollView.borderType = NSNoBorder;
  scrollView.drawsBackground = NO;
  scrollView.wantsLayer = YES;
  scrollView.layer.cornerRadius = 8.0;
  scrollView.layer.borderWidth = 1.0;
  scrollView.layer.borderColor = NSColor.separatorColor.CGColor;
  scrollView.scrollerStyle = NSScrollerStyleOverlay;
  [listCard addSubview:scrollView];

  self.templatesTableView =
      [[NSTableView alloc] initWithFrame:scrollView.bounds];
  NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
  col.title = @"Шаблон";
  col.width = scrollView.bounds.size.width;
  col.resizingMask = NSTableColumnAutoresizingMask;
  [self.templatesTableView addTableColumn:col];
  self.templatesTableView.headerView = nil;
  self.templatesTableView.rowHeight = 34.0;
  self.templatesTableView.intercellSpacing = NSMakeSize(0, 0);
  self.templatesTableView.backgroundColor = [NSColor clearColor];
  self.templatesTableView.selectionHighlightStyle =
      NSTableViewSelectionHighlightStyleRegular;
  self.templatesTableView.focusRingType = NSFocusRingTypeNone;
  self.templatesTableView.columnAutoresizingStyle =
      NSTableViewFirstColumnOnlyAutoresizingStyle;
  self.templatesTableView.delegate = (id)self;
  self.templatesTableView.dataSource = (id)self;
  scrollView.documentView = self.templatesTableView;

  NSTextField *nameLabel =
      [self sectionTitleLabel:@"Название"
                        frame:NSMakeRect(16, mainCardH - 34, editorW - 32, 18)];
  [editorCard addSubview:nameLabel];

  self.templateNameField =
      [self formTextField:NSMakeRect(16, mainCardH - 64, editorW - 32, 24)
              placeholder:@"Название шаблона"];
  self.templateNameField.delegate = self;
  [editorCard addSubview:self.templateNameField];

  self.templateItemEnabledSwitch =
      [self settingsSwitchWithAction:@selector(toggleSelectedTemplateEnabled:)
                         controlSize:NSControlSizeSmall];
  CGFloat templateItemToggleW = self.templateItemEnabledSwitch.frame.size.width;
  CGFloat templateItemToggleH =
      self.templateItemEnabledSwitch.frame.size.height;
  CGFloat templateVisibilityCenterY = mainCardH - 86.0;

  NSTextField *templateVisibilityLabel =
      [self settingsRowLabelWithString:@"Виден в оверлее"];
  templateVisibilityLabel.frame =
      NSMakeRect(16, floor(templateVisibilityCenterY - 10.0),
                 editorW - templateItemToggleW - 44.0, 20);
  [editorCard addSubview:templateVisibilityLabel];

  self.templateItemEnabledSwitch.frame =
      NSMakeRect(editorW - 16 - templateItemToggleW,
                 floor(templateVisibilityCenterY - (templateItemToggleH / 2.0)),
                 templateItemToggleW, templateItemToggleH);
  [editorCard addSubview:self.templateItemEnabledSwitch];

  NSTextField *promptLabel = [self
      sectionTitleLabel:@"Промпт"
                  frame:NSMakeRect(16, mainCardH - 124, editorW - 32, 18)];
  [editorCard addSubview:promptLabel];

  NSScrollView *promptScroll = [[NSScrollView alloc]
      initWithFrame:NSMakeRect(16, 16, editorW - 32, mainCardH - 146)];
  promptScroll.hasVerticalScroller = YES;
  promptScroll.borderType = NSNoBorder;
  promptScroll.drawsBackground = NO;
  promptScroll.wantsLayer = YES;
  promptScroll.layer.cornerRadius = 8.0;
  promptScroll.layer.borderWidth = 1.0;
  promptScroll.layer.borderColor = NSColor.separatorColor.CGColor;

  self.templatePromptTextView = [[NSTextView alloc]
      initWithFrame:NSMakeRect(0, 0, editorW - 48, mainCardH - 146)];
  self.templatePromptTextView.minSize = NSMakeSize(0, mainCardH - 146);
  self.templatePromptTextView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
  self.templatePromptTextView.verticallyResizable = YES;
  self.templatePromptTextView.horizontallyResizable = NO;
  self.templatePromptTextView.textContainerInset = NSMakeSize(8, 10);
  self.templatePromptTextView.textContainer.containerSize =
      NSMakeSize(editorW - 48, CGFLOAT_MAX);
  self.templatePromptTextView.textContainer.widthTracksTextView = YES;
  self.templatePromptTextView.font =
      [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
  self.templatePromptTextView.allowsUndo = YES;
  self.templatePromptTextView.delegate = self;
  [self styleEditorTextView:self.templatePromptTextView scrollView:promptScroll];
  promptScroll.documentView = self.templatePromptTextView;
  [editorCard addSubview:promptScroll];

  // Save / Cancel buttons

  return pane;
}

#pragma mark - Templates Table Data Source & Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
  if (tableView == self.templatesTableView) {
    return (NSInteger)self.templatesData.count;
  }
  if (tableView == self.llmProfileTableView) {
    return (NSInteger)self.llmProfileOrder.count;
  }
  return 0;
}

- (NSView *)tableView:(NSTableView *)tableView
    viewForTableColumn:(NSTableColumn *)tableColumn
                   row:(NSInteger)row {
  if (tableView == self.llmProfileTableView) {
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"LlmProfileCell"
                                                        owner:self];
    NSTextField *titleLabel = nil;
    NSTextField *subtitleLabel = nil;
    if (!cell) {
      cell = [[NSTableCellView alloc]
          initWithFrame:NSMakeRect(0, 0, tableColumn.width,
                                   tableView.rowHeight)];
      cell.identifier = @"LlmProfileCell";
      cell.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

      titleLabel = [NSTextField labelWithString:@""];
      titleLabel.identifier = @"LlmProfileTitle";
      titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
      titleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
      titleLabel.frame = NSMakeRect(10, 22, tableColumn.width - 20, 18);
      titleLabel.autoresizingMask = NSViewWidthSizable;
      [cell addSubview:titleLabel];
      cell.textField = titleLabel;

      subtitleLabel = [NSTextField labelWithString:@""];
      subtitleLabel.identifier = @"LlmProfileSubtitle";
      subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
      subtitleLabel.font = [NSFont systemFontOfSize:11];
      subtitleLabel.textColor = [NSColor secondaryLabelColor];
      subtitleLabel.frame = NSMakeRect(10, 4, tableColumn.width - 20, 14);
      subtitleLabel.autoresizingMask = NSViewWidthSizable;
      [cell addSubview:subtitleLabel];
    } else {
      for (NSView *sub in cell.subviews) {
        if ([sub.identifier isEqualToString:@"LlmProfileTitle"])
          titleLabel = (NSTextField *)sub;
        else if ([sub.identifier isEqualToString:@"LlmProfileSubtitle"])
          subtitleLabel = (NSTextField *)sub;
      }
    }

    if (row >= 0 && row < (NSInteger)self.llmProfileOrder.count) {
      NSString *profileId = self.llmProfileOrder[row];
      NSDictionary *profile = self.llmProfiles[profileId];
      NSString *name = [profile[@"name"] isKindOfClass:[NSString class]] &&
                               [profile[@"name"] length] > 0
                           ? profile[@"name"]
                           : profileId;
      titleLabel.stringValue = name;
      subtitleLabel.stringValue = [self prettyNameForLlmProfile:profile];
    }
    return cell;
  }

  if (tableView != self.templatesTableView)
    return nil;

  NSTableCellView *cell = [tableView makeViewWithIdentifier:@"TemplateCell"
                                                      owner:self];
  if (!cell) {
    cell = [[NSTableCellView alloc]
        initWithFrame:NSMakeRect(0, 0, tableColumn.width, tableView.rowHeight)];
    cell.identifier = @"TemplateCell";
    cell.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSTextField *titleLabel = [NSTextField labelWithString:@""];
    titleLabel.identifier = @"TemplateTitleLabel";
    titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    titleLabel.alignment = NSTextAlignmentLeft;
    titleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    titleLabel.textColor = NSColor.labelColor;
    titleLabel.autoresizingMask = NSViewWidthSizable;
    titleLabel.frame = NSMakeRect(12, 7, tableColumn.width - 24, 20);
    cell.textField = titleLabel;
    [cell addSubview:titleLabel];
  }

  if (row < (NSInteger)self.templatesData.count) {
    NSDictionary *tmpl = self.templatesData[row];
    NSString *name = tmpl[@"name"] ?: @"Без названия";
    BOOL enabled = [self isTemplateEnabled:tmpl];

    NSTextField *titleLabel = nil;
    for (NSView *subview in cell.subviews) {
      if ([subview.identifier isEqualToString:@"TemplateTitleLabel"]) {
        titleLabel = (NSTextField *)subview;
      }
    }

    titleLabel.stringValue = name;
    titleLabel.frame = NSMakeRect(12, 7, tableColumn.width - 24, 20);
    titleLabel.textColor =
        enabled ? NSColor.labelColor : NSColor.secondaryLabelColor;
    titleLabel.alphaValue = enabled ? 1.0 : 0.6;
  }
  return cell;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView
                rowViewForRow:(NSInteger)row {
  if (tableView == self.templatesTableView) {
    return [[SPTemplateRowView alloc]
        initWithFrame:NSMakeRect(0, 0, tableView.bounds.size.width,
                                 tableView.rowHeight)];
  }
  if (tableView == self.llmProfileTableView) {
    return [[SPLlmProfileRowView alloc]
        initWithFrame:NSMakeRect(0, 0, tableView.bounds.size.width,
                                 tableView.rowHeight)];
  }
  return nil;
}

- (NSString *)resolvedPromptTextForTemplate:(NSDictionary *)templateData {
  id inlinePrompt = templateData[@"system_prompt"];
  if ([inlinePrompt isKindOfClass:[NSString class]]) {
    NSString *inlineText = (NSString *)inlinePrompt;
    NSString *trimmedInlineText = [inlineText
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]];
    if (trimmedInlineText.length > 0) {
      return inlineText;
    }
  }

  id promptPath = templateData[@"system_prompt_path"];
  if ([promptPath isKindOfClass:[NSString class]] && [promptPath length] > 0) {
    NSString *path = (NSString *)promptPath;
    NSString *resolvedPath =
        path.isAbsolutePath
            ? path
            : [configDirPath() stringByAppendingPathComponent:path];
    NSString *filePrompt =
        [NSString stringWithContentsOfFile:resolvedPath
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
    if ([filePrompt isKindOfClass:[NSString class]]) {
      NSString *trimmedFilePrompt =
          [filePrompt stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if (trimmedFilePrompt.length > 0) {
        return filePrompt;
      }
    }
  }

  return @"";
}

- (NSString *)editablePromptTextForTemplate:
    (NSMutableDictionary *)templateData {
  id editablePrompt = templateData[kTemplateEditablePromptKey];
  if ([editablePrompt isKindOfClass:[NSString class]]) {
    return editablePrompt ?: @"";
  }

  NSString *resolvedPrompt = [self resolvedPromptTextForTemplate:templateData];
  templateData[kTemplateEditablePromptKey] = resolvedPrompt ?: @"";
  if (![templateData[kTemplateOriginalPromptKey]
          isKindOfClass:[NSString class]]) {
    templateData[kTemplateOriginalPromptKey] = resolvedPrompt ?: @"";
  }
  return resolvedPrompt ?: @"";
}

- (BOOL)isTemplateEnabled:(NSDictionary *)templateData {
  id enabledValue = templateData[@"enabled"];
  return ![enabledValue isKindOfClass:[NSNumber class]] ||
         [enabledValue boolValue];
}

- (NSString *)trimmedResolvedPromptTextForTemplate:
    (NSDictionary *)templateData {
  NSString *resolvedPrompt =
      [self resolvedPromptTextForTemplate:templateData] ?: @"";
  return [resolvedPrompt
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
}

// ─── Template List: selection only loads, NEVER saves back automatically ───
//
// Design: templatesData is the source of truth. The editor fields are just
// a view into one entry. We sync editor→data ONLY on explicit actions:
// (1) user clicks Save button  (2) user clicks + to add  (3) switching tabs
//
// tableViewSelectionDidChange just loads the new row into the editor.
// It first writes back the editor content for the OLD row, which is safe
// because selectedTemplateIndex still points to the old row at that moment.

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
  if (notification.object == self.llmProfileTableView) {
    if (self.suppressLlmProfileSelection)
      return;
    NSInteger row = self.llmProfileTableView.selectedRow;
    if (row < 0 || row >= (NSInteger)self.llmProfileOrder.count)
      return;
    NSString *newId = self.llmProfileOrder[row];
    if ([newId isEqualToString:self.activeLlmProfileId])
      return;

    // Flush editor fields into the OLD active profile before switching
    [self syncActiveLlmProfileFromFields];
    self.activeLlmProfileId = newId;
    [self applyActiveLlmProfileToFields];
    [self updateLlmFieldsEnabled];
    self.llmTestResultLabel.stringValue = @"";
    return;
  }

  if (notification.object != self.templatesTableView)
    return;
  if (self.suppressTemplateSync)
    return;

  NSInteger newRow = self.templatesTableView.selectedRow;
  if (newRow == self.selectedTemplateIndex)
    return;

  // Write editor content back to the OLD row before loading the new one
  [self flushEditorToIndex:self.selectedTemplateIndex];

  self.selectedTemplateIndex = newRow;
  [self loadEditorFromIndex:newRow];
  [self updateTemplateActionButtons];
}

/// Write current editor fields into templatesData[index]. Safe to call with -1.
- (void)flushEditorToIndex:(NSInteger)index {
  if (index < 0 || index >= (NSInteger)self.templatesData.count)
    return;
  if (!self.templateNameField)
    return;
  if (!self.templateEditorDirty)
    return;

  NSMutableDictionary *templateData = self.templatesData[index];
  NSString *editedPrompt = self.templatePromptTextView.string ?: @"";

  templateData[@"name"] = self.templateNameField.stringValue ?: @"";
  templateData[kTemplateEditablePromptKey] = editedPrompt;

  NSString *originalPrompt =
      [templateData[kTemplateOriginalPromptKey] isKindOfClass:[NSString class]]
          ? templateData[kTemplateOriginalPromptKey]
          : [self resolvedPromptTextForTemplate:templateData];
  NSString *inlinePrompt =
      [templateData[@"system_prompt"] isKindOfClass:[NSString class]]
          ? templateData[@"system_prompt"]
          : nil;
  NSString *promptPath =
      [templateData[@"system_prompt_path"] isKindOfClass:[NSString class]]
          ? templateData[@"system_prompt_path"]
          : nil;

  // If this template references an external file, preserve that relationship.
  // Write changes back to the file rather than silently converting to inline.
  if (inlinePrompt.length == 0 && promptPath.length > 0) {
    if (![editedPrompt isEqualToString:(originalPrompt ?: @"")]) {
      NSString *resolvedPath =
          promptPath.isAbsolutePath
              ? promptPath
              : [configDirPath() stringByAppendingPathComponent:promptPath];
      NSError *writeError = nil;
      [editedPrompt writeToFile:resolvedPath
                     atomically:YES
                       encoding:NSUTF8StringEncoding
                          error:&writeError];
      if (writeError) {
        NSLog(@"[VelikiyMoguchiy] Failed to write template file %@: %@", resolvedPath,
              writeError.localizedDescription);
      }
      templateData[kTemplateOriginalPromptKey] = editedPrompt;
    }
    [templateData removeObjectForKey:@"system_prompt"];
    self.templateEditorDirty = NO;
    return;
  }

  templateData[@"system_prompt"] = editedPrompt;
  [templateData removeObjectForKey:@"system_prompt_path"];
  templateData[kTemplateOriginalPromptKey] = editedPrompt;
  self.templateEditorDirty = NO;
}

/// Load templatesData[index] into the editor fields. -1 clears everything.
- (void)loadEditorFromIndex:(NSInteger)index {
  BOOL previousSuppress = self.suppressTemplateSync;
  self.suppressTemplateSync = YES;

  if (index >= 0 && index < (NSInteger)self.templatesData.count) {
    NSMutableDictionary *tmpl = self.templatesData[index];
    self.templateNameField.stringValue = tmpl[@"name"] ?: @"";
    self.templateItemEnabledSwitch.state = [self isTemplateEnabled:tmpl]
                                               ? NSControlStateValueOn
                                               : NSControlStateValueOff;
    self.templatePromptTextView.string =
        [self editablePromptTextForTemplate:tmpl];
    self.templateNameField.enabled = YES;
    self.templateItemEnabledSwitch.enabled = YES;
    self.templatePromptTextView.editable = YES;
  } else {
    self.templateNameField.stringValue = @"";
    self.templateItemEnabledSwitch.state = NSControlStateValueOff;
    self.templatePromptTextView.string = @"";
    self.templateNameField.enabled = NO;
    self.templateItemEnabledSwitch.enabled = NO;
    self.templatePromptTextView.editable = NO;
  }

  self.templateEditorDirty = NO;
  self.suppressTemplateSync = previousSuppress;
}

- (void)controlTextDidChange:(NSNotification *)notification {
  if (notification.object == self.llmProfileNameField) {
    NSMutableDictionary *profile = [self activeLlmProfile];
    if (!profile)
      return;
    profile[@"name"] = self.llmProfileNameField.stringValue ?: @"";
    NSInteger row =
        [self.llmProfileOrder indexOfObject:self.activeLlmProfileId ?: @""];
    if (row != NSNotFound) {
      [self.llmProfileTableView
          reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
                    columnIndexes:[NSIndexSet indexSetWithIndex:0]];
    }
    return;
  }

  if (self.suppressTemplateSync)
    return;
  if (notification.object != self.templateNameField)
    return;
  if (self.selectedTemplateIndex < 0 ||
      self.selectedTemplateIndex >= (NSInteger)self.templatesData.count)
    return;

  self.templateEditorDirty = YES;
  self.templatesData[self.selectedTemplateIndex][@"name"] =
      self.templateNameField.stringValue ?: @"";

  NSIndexSet *rows =
      [NSIndexSet indexSetWithIndex:(NSUInteger)self.selectedTemplateIndex];
  NSIndexSet *columns = [NSIndexSet indexSetWithIndex:0];
  [self.templatesTableView reloadDataForRowIndexes:rows columnIndexes:columns];
}

- (void)textDidChange:(NSNotification *)notification {
  if (self.suppressTemplateSync)
    return;
  if (notification.object != self.templatePromptTextView)
    return;

  self.templateEditorDirty = YES;
}

- (void)toggleSelectedTemplateEnabled:(id)sender {
  if (self.selectedTemplateIndex < 0 ||
      self.selectedTemplateIndex >= (NSInteger)self.templatesData.count)
    return;

  self.templatesData[self.selectedTemplateIndex][@"enabled"] =
      @(self.templateItemEnabledSwitch.state == NSControlStateValueOn);
  NSIndexSet *rows =
      [NSIndexSet indexSetWithIndex:(NSUInteger)self.selectedTemplateIndex];
  NSIndexSet *columns = [NSIndexSet indexSetWithIndex:0];
  [self.templatesTableView reloadDataForRowIndexes:rows columnIndexes:columns];
}

/// Flush editor, then reload table (used by Save button & tab switch).
- (void)saveCurrentTemplateEdits {
  [self flushEditorToIndex:self.selectedTemplateIndex];
  [self reindexTemplateShortcuts];
}

- (void)updateTemplateActionButtons {
  BOOL canAdd = self.templatesData.count < 9;
  BOOL hasSelection = self.templatesTableView.selectedRow >= 0;
  BOOL canMoveUp = hasSelection && self.templatesTableView.selectedRow > 0;
  BOOL canMoveDown =
      hasSelection && self.templatesTableView.selectedRow <
                          (NSInteger)self.templatesData.count - 1;

  [self.templatePrimaryActionsControl setEnabled:canAdd forSegment:0];
  [self.templatePrimaryActionsControl setEnabled:hasSelection forSegment:1];
  [self.templateReorderActionsControl setEnabled:canMoveUp forSegment:0];
  [self.templateReorderActionsControl setEnabled:canMoveDown forSegment:1];
}

- (void)reindexTemplateShortcuts {
  [self.templatesData
      enumerateObjectsUsingBlock:^(NSMutableDictionary *templateData,
                                   NSUInteger idx, BOOL *stop) {
        templateData[@"shortcut"] = @((NSInteger)idx + 1);
        if (![templateData[@"enabled"] isKindOfClass:[NSNumber class]]) {
          templateData[@"enabled"] = @YES;
        }
      }];
}

- (void)reloadTemplateTableSelectingRow:(NSInteger)row {
  NSInteger selectedRow =
      (row >= 0 && row < (NSInteger)self.templatesData.count) ? row : -1;
  self.selectedTemplateIndex = selectedRow;

  self.suppressTemplateSync = YES;
  [self.templatesTableView reloadData];
  if (selectedRow >= 0) {
    [self.templatesTableView
            selectRowIndexes:[NSIndexSet
                                 indexSetWithIndex:(NSUInteger)selectedRow]
        byExtendingSelection:NO];
  } else {
    [self.templatesTableView deselectAll:nil];
  }
  self.suppressTemplateSync = NO;

  [self loadEditorFromIndex:selectedRow];
  [self updateTemplateActionButtons];
}

- (NSArray<NSDictionary *> *)serializedTemplatesData {
  [self reindexTemplateShortcuts];
  NSMutableArray<NSDictionary *> *serialized =
      [NSMutableArray arrayWithCapacity:self.templatesData.count];

  for (NSDictionary *templateData in self.templatesData) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"name"] = [templateData[@"name"] isKindOfClass:[NSString class]]
                          ? templateData[@"name"]
                          : @"";
    result[@"enabled"] = @([self isTemplateEnabled:templateData]);
    result[@"shortcut"] =
        [templateData[@"shortcut"] isKindOfClass:[NSNumber class]]
            ? templateData[@"shortcut"]
            : @0;

    NSString *systemPrompt =
        [templateData[@"system_prompt"] isKindOfClass:[NSString class]]
            ? templateData[@"system_prompt"]
            : nil;
    NSString *systemPromptPath =
        [templateData[@"system_prompt_path"] isKindOfClass:[NSString class]]
            ? templateData[@"system_prompt_path"]
            : nil;
    if (systemPrompt != nil) {
      result[@"system_prompt"] = systemPrompt;
    }
    if (systemPromptPath.length > 0) {
      result[@"system_prompt_path"] = systemPromptPath;
    }

    [serialized addObject:result];
  }

  return serialized;
}

- (BOOL)validateTemplatesDataWithMessage:(NSString **)message {
  if (self.templatesData.count > 9) {
    if (message)
      *message = @"You can add up to 9 prompt templates.";
    return NO;
  }

  NSMutableSet<NSNumber *> *used = [NSMutableSet set];
  for (NSDictionary *tmpl in self.templatesData) {
    NSNumber *shortcut = [tmpl[@"shortcut"] isKindOfClass:[NSNumber class]]
                             ? tmpl[@"shortcut"]
                             : nil;
    NSInteger value = shortcut.integerValue;
    if (!shortcut || value < 1 || value > 9) {
      if (message)
        *message = @"Each prompt template needs a shortcut between 1 and 9.";
      return NO;
    }
    if ([used containsObject:@(value)]) {
      if (message)
        *message = @"Each prompt template shortcut must be unique.";
      return NO;
    }
    if ([self trimmedResolvedPromptTextForTemplate:tmpl].length == 0) {
      if (message)
        *message = @"Each prompt template needs a non-empty prompt.";
      return NO;
    }
    [used addObject:@(value)];
  }

  return YES;
}

- (void)addTemplate:(id)sender {
  if (self.templatesData.count >= 9) {
    [self showAlert:@"Достигнут лимит шаблонов"
               info:@"Можно добавить не больше 9 шаблонов: оверлей поддерживает только "
                    @"клавиши 1–9."];
    return;
  }

  [self flushEditorToIndex:self.selectedTemplateIndex];
  [self.templatesData
      addObject:[NSMutableDictionary dictionaryWithDictionary:@{
        @"name" : @"Новый шаблон",
        @"enabled" : @YES,
        @"shortcut" : @((NSInteger)self.templatesData.count + 1),
        @"system_prompt" : @"",
        kTemplateEditablePromptKey : @"",
        kTemplateOriginalPromptKey : @"",
      }]];

  NSInteger newRow = (NSInteger)self.templatesData.count - 1;
  [self reindexTemplateShortcuts];
  [self reloadTemplateTableSelectingRow:newRow];
}

- (void)handleTemplatePrimaryActions:(NSSegmentedControl *)sender {
  NSInteger segment = sender.selectedSegment;
  if (segment == 0) {
    [self addTemplate:sender];
  } else if (segment == 1) {
    [self removeTemplate:sender];
  }
}

- (void)handleTemplateReorderActions:(NSSegmentedControl *)sender {
  NSInteger segment = sender.selectedSegment;
  if (segment == 0) {
    [self moveTemplateUp:sender];
  } else if (segment == 1) {
    [self moveTemplateDown:sender];
  }
}

- (void)removeTemplate:(id)sender {
  NSInteger row = self.templatesTableView.selectedRow;
  if (row < 0 || row >= (NSInteger)self.templatesData.count)
    return;

  [self flushEditorToIndex:self.selectedTemplateIndex];
  [self.templatesData removeObjectAtIndex:row];
  [self reindexTemplateShortcuts];

  NSInteger nextSelection = MIN(row, (NSInteger)self.templatesData.count - 1);
  [self reloadTemplateTableSelectingRow:nextSelection];
}

- (void)moveTemplateUp:(id)sender {
  NSInteger row = self.templatesTableView.selectedRow;
  if (row <= 0 || row >= (NSInteger)self.templatesData.count)
    return;

  [self flushEditorToIndex:self.selectedTemplateIndex];
  NSMutableDictionary *templateData = self.templatesData[row];
  [self.templatesData removeObjectAtIndex:row];
  [self.templatesData insertObject:templateData atIndex:row - 1];
  [self reindexTemplateShortcuts];
  [self reloadTemplateTableSelectingRow:row - 1];
}

- (void)moveTemplateDown:(id)sender {
  NSInteger row = self.templatesTableView.selectedRow;
  if (row < 0 || row >= (NSInteger)self.templatesData.count - 1)
    return;

  [self flushEditorToIndex:self.selectedTemplateIndex];
  NSMutableDictionary *templateData = self.templatesData[row];
  [self.templatesData removeObjectAtIndex:row];
  [self.templatesData insertObject:templateData atIndex:row + 1];
  [self reindexTemplateShortcuts];
  [self reloadTemplateTableSelectingRow:row + 1];
}

- (NSView *)buildAboutPane {
  CGFloat paneWidth = [self paneContentWidth];
  CGFloat margin = SPTheme.pageMargin;
  NSTextField *desc = [self
      descriptionLabel:@"Фоновый инструмент голосового ввода для macOS.\nНажмите горячую "
                       @"клавишу, говорите — и исправленный текст вставится в любое "
                       @"приложение."];
  desc.alignment = NSTextAlignmentCenter;
  CGFloat descH = [self fittingHeightForWrappingLabel:desc
                                                width:paneWidth - 120];
  NSImage *painting = [NSImage imageNamed:@"AboutPainting"];
  NSSize paintingSize = painting ? painting.size : NSZeroSize;
  CGFloat paintingW = MIN(paintingSize.width * 0.8, paneWidth - 2.0 * margin);
  CGFloat paintingH = paintingSize.width > 0
                          ? round(paintingSize.height * paintingW / paintingSize.width)
                          : 0.0;

  // Laid out top to bottom: each entry is a view and the height it takes, with
  // the gap above it.
  NSMutableArray<NSArray *> *stack = [NSMutableArray array];
  void (^add)(NSView *, CGFloat, CGFloat, CGFloat) =
      ^(NSView *view, CGFloat gapAbove, CGFloat width, CGFloat height) {
        [stack addObject:@[ view, @(gapAbove), @(width), @(height) ]];
      };

  NSImageView *iconView =
      [NSImageView imageViewWithImage:[NSImage imageNamed:@"AppIcon"] ?: [NSApp applicationIconImage]];
  iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
  add(iconView, 0, 72, 72);

  NSImage *logo = [NSImage imageNamed:@"Logo"];
  NSImageView *appName = [NSImageView imageViewWithImage:logo];
  appName.imageScaling = NSImageScaleProportionallyUpOrDown;
  appName.accessibilityLabel = @"Великий & Могучий";
  CGFloat logoW = MIN(paneWidth - 120, 440);
  add(appName, 8, logoW, round(logo.size.height * logoW / MAX(logo.size.width, 1)));

  NSString *version =
      [[NSBundle mainBundle]
          objectForInfoDictionaryKey:@"CFBundleShortVersionString"]
          ?: @"dev";
  NSString *build =
      [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]
          ?: @"0";
  NSTextField *versionLabel = [NSTextField
      labelWithString:[NSString stringWithFormat:@"Версия %@ (%@)", version, build]];
  versionLabel.font = [SPTheme bookHandFontOfSize:16];
  versionLabel.textColor = SPTheme.secondaryLabel;
  versionLabel.alignment = NSTextAlignmentCenter;
  add(versionLabel, 2, paneWidth - 48, 20);

  SPOrnamentDividerView *divider = [SPOrnamentDividerView new];
  add(divider, 12, paneWidth - 2.0 * margin - 80, 20);

  if (painting) {
    NSImageView *paintingView = [NSImageView imageViewWithImage:painting];
    paintingView.imageScaling = NSImageScaleProportionallyUpOrDown;
    paintingView.accessibilityLabel = @"В. М. Васнецов, «Богатыри»";
    add(paintingView, 14, paintingW, paintingH);
    NSTextField *credit = [NSTextField
        labelWithString:@"В. М. Васнецов. «Богатыри». 1881–1898. Третьяковская галерея"];
    credit.font = [SPTheme oldStyleItalicFontOfSize:12];
    credit.textColor = SPTheme.secondaryLabel;
    credit.alignment = NSTextAlignmentCenter;
    add(credit, 6, paneWidth - 48, 16);
  }

  add(desc, 12, paneWidth - 120, descH);

  NSButton *githubButton = [NSButton buttonWithTitle:@"Репозиторий на GitHub"
                                              target:self
                                              action:@selector(openGitHub:)];
  githubButton.bezelStyle = NSBezelStyleRounded;
  githubButton.image = [NSImage imageWithSystemSymbolName:@"arrow.up.right"
                                 accessibilityDescription:nil];
  githubButton.imagePosition = NSImageTrailing;
  NSButton *docsButton = [NSButton buttonWithTitle:@"Документация"
                                            target:self
                                            action:@selector(openDocs:)];
  docsButton.bezelStyle = NSBezelStyleRounded;
  docsButton.image = [NSImage imageWithSystemSymbolName:@"arrow.up.right"
                               accessibilityDescription:nil];
  docsButton.imagePosition = NSImageTrailing;
  // Third-party notices bundled with the app
  NSButton *licensesButton = [NSButton buttonWithTitle:@"Лицензии"
                                                target:self
                                                action:@selector(openLicenses:)];
  licensesButton.bezelStyle = NSBezelStyleRounded;
  NSStackView *buttons = [NSStackView
      stackViewWithViews:@[ githubButton, docsButton, licensesButton ]];
  buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  buttons.spacing = 10;
  add(buttons, 14, paneWidth - 48, 32);

  NSTextField *license = [self
      descriptionLabel:@"Лицензия MIT · Rust и Objective-C · шрифты Oglavie, Monomakh и Old Standard (SIL OFL)"];
  license.alignment = NSTextAlignmentCenter;
  add(license, 10, paneWidth - 48, 18);

  CGFloat contentHeight = 12.0;
  for (NSArray *entry in stack)
    contentHeight += [entry[1] doubleValue] + [entry[3] doubleValue];
  NSView *pane =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, paneWidth, contentHeight)];
  CGFloat top = contentHeight;
  for (NSArray *entry in stack) {
    NSView *view = entry[0];
    CGFloat width = [entry[2] doubleValue];
    CGFloat height = [entry[3] doubleValue];
    top -= [entry[1] doubleValue] + height;
    if ([view isKindOfClass:NSStackView.class]) {
      width = ((NSStackView *)view).fittingSize.width;
    }
    view.frame = NSMakeRect(round((paneWidth - width) / 2.0), top, width, height);
    [pane addSubview:view];
  }
  return pane;
}

- (void)openGitHub:(id)sender {
  [[NSWorkspace sharedWorkspace]
      openURL:[NSURL URLWithString:@"https://github.com/zigansh1n/velikiy-moguchiy"]];
}

// Shows Licenses/ThirdPartyNotices.txt from the bundle: this project's license,
// the upstream MIT notice, the bundled helpers and every Rust crate linked into the app
// (generated by tools/third-party-notices/generate.py).
- (void)openLicenses:(id)sender {
  if (!self.licensesWindow) {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"ThirdPartyNotices"
                                                     ofType:@"txt"];
    NSString *text = path ? [NSString stringWithContentsOfFile:path
                                                      encoding:NSUTF8StringEncoding
                                                         error:NULL]
                          : nil;
    if (text.length == 0) {
      text = @"Файл с лицензиями не найден в этой сборке. Полный список "
             @"сторонних компонентов: THIRD_PARTY.md в репозитории "
             @"https://github.com/zigansh1n/velikiy-moguchiy";
    }
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 680, 560)
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable |
                             NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"Лицензии";
    window.releasedWhenClosed = NO;
    window.minSize = NSMakeSize(420, 300);
    NSScrollView *scrollView = [NSTextView scrollableTextView];
    NSTextView *textView = (NSTextView *)scrollView.documentView;
    textView.editable = NO;
    textView.selectable = YES;
    textView.richText = NO;
    textView.string = text;
    textView.font = [NSFont monospacedSystemFontOfSize:11
                                                weight:NSFontWeightRegular];
    textView.textContainerInset = NSMakeSize(12, 12);
    window.contentView = scrollView;
    [window center];
    self.licensesWindow = window;
  }
  [self.licensesWindow makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

- (void)openDocs:(id)sender {
  [[NSWorkspace sharedWorkspace]
      openURL:[NSURL URLWithString:
                         @"https://github.com/zigansh1n/velikiy-moguchiy#readme"]];
}

// ─── Shared button bar ──────────────────────────────────────────────

// ─── UI Helpers ─────────────────────────────────────────────────────

- (NSTextField *)formLabel:(NSString *)title frame:(NSRect)frame {
  NSTextField *label = [NSTextField labelWithString:title];
  label.frame = frame;
  label.alignment = NSTextAlignmentRight;
  label.font = [SPTheme formLabelFont];
  label.textColor = SPTheme.label;
  return label;
}

// Width of the label column needed so none of the given form labels clip.
- (CGFloat)formLabelColumnWidthForTitles:(NSArray<NSString *> *)titles {
  NSDictionary *attrs = @{NSFontAttributeName : [SPTheme formLabelFont]};
  CGFloat width = 0.0;
  for (NSString *title in titles)
    width = MAX(width, ceil([title sizeWithAttributes:attrs].width));
  return width + 4.0;
}

- (NSTextField *)formTextField:(NSRect)frame
                   placeholder:(NSString *)placeholder {
  NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
  field.placeholderString = placeholder;
  field.font = [NSFont systemFontOfSize:13];
  field.lineBreakMode = NSLineBreakByTruncatingTail;
  field.usesSingleLineMode = YES;
  return field;
}

- (NSSlider *)overlaySliderWithMin:(double)minValue
                               max:(double)maxValue
                            action:(SEL)action {
  NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(0, 0, 228, 24)];
  slider.minValue = minValue;
  slider.maxValue = maxValue;
  slider.numberOfTickMarks = 0;
  slider.continuous = YES;
  slider.target = self;
  slider.action = action;
  return slider;
}

- (NSTextField *)overlayValueLabel {
  NSTextField *label = [NSTextField labelWithString:@""];
  label.alignment = NSTextAlignmentRight;
  label.font = [NSFont monospacedDigitSystemFontOfSize:12
                                                weight:NSFontWeightMedium];
  label.textColor = [NSColor secondaryLabelColor];
  label.frame = NSMakeRect(0, 0, 54, 18);
  return label;
}

- (NSArray<NSString *> *)availableOverlayFontFamilies {
  if (self.overlayAvailableFontFamilies.count > 0) {
    return self.overlayAvailableFontFamilies;
  }

  NSMutableOrderedSet<NSString *> *families = [NSMutableOrderedSet orderedSet];
  for (NSString *family in
       [[NSFontManager sharedFontManager] availableFontFamilies]) {
    NSString *normalized = normalizedOverlayFontFamilyValue(family);
    if (!overlayUsesSystemFontFamily(normalized)) {
      [families addObject:normalized];
    }
  }

  NSArray<NSString *> *sortedFamilies = [[families array]
      sortedArrayUsingComparator:^NSComparisonResult(NSString *lhs,
                                                     NSString *rhs) {
        return [lhs localizedStandardCompare:rhs];
      }];
  self.overlayAvailableFontFamilies = sortedFamilies;
  return sortedFamilies;
}

- (NSAttributedString *)overlayFontMenuTitleWithLabel:(NSString *)label
                                                value:(NSString *)value {
  NSFont *font = overlayFontForFamily(value, 13.0);
  return [[NSAttributedString alloc]
      initWithString:label
          attributes:@{
            NSFontAttributeName : font,
            NSForegroundColorAttributeName : [NSColor labelColor],
          }];
}

- (NSPopUpButton *)overlayFontFamilyPopupControl {
  NSPopUpButton *popup =
      [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 290, 26)
                                 pullsDown:NO];
  popup.target = self;
  popup.action = @selector(overlayControlChanged:);

  [popup removeAllItems];

  NSMenuItem *systemItem =
      [[NSMenuItem alloc] initWithTitle:kOverlayFontFamilySystemLabel
                                 action:nil
                          keyEquivalent:@""];
  systemItem.representedObject = kOverlayFontFamilyDefault;
  systemItem.attributedTitle =
      [self overlayFontMenuTitleWithLabel:kOverlayFontFamilySystemLabel
                                    value:kOverlayFontFamilyDefault];
  [popup.menu addItem:systemItem];

  for (NSString *family in [self availableOverlayFontFamilies]) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:family
                                                  action:nil
                                           keyEquivalent:@""];
    item.representedObject = family;
    item.attributedTitle = [self overlayFontMenuTitleWithLabel:family
                                                         value:family];
    [popup.menu addItem:item];
  }

  return popup;
}

- (NSPopUpButton *)overlayMaxVisibleLinesPopupControl {
  NSPopUpButton *popup =
      [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 118.0, 28.0)
                                 pullsDown:NO];
  popup.target = self;
  popup.action = @selector(overlayControlChanged:);

  for (NSInteger value = kOverlayMaxVisibleLinesMin;
       value <= kOverlayMaxVisibleLinesMax; value++) {
    NSString *title = [NSString stringWithFormat:@"строк: %ld", (long)value];
    [popup addItemWithTitle:title];
    popup.lastItem.representedObject = @(value);
  }

  [popup selectItemAtIndex:0];
  return popup;
}

- (NSString *)selectedOverlayFontFamilyValue {
  NSString *selectedValue =
      self.overlayFontFamilyPopup.selectedItem.representedObject;
  return normalizedOverlayFontFamilyValue(selectedValue);
}

- (NSInteger)selectedOverlayMaxVisibleLinesValue {
  NSNumber *selectedValue =
      [self.overlayMaxVisibleLinesPopup.selectedItem.representedObject
          isKindOfClass:[NSNumber class]]
          ? self.overlayMaxVisibleLinesPopup.selectedItem.representedObject
          : nil;
  return clampedOverlayMaxVisibleLinesValue(
      selectedValue.integerValue > 0 ? selectedValue.integerValue
                                     : kOverlayMaxVisibleLinesDefault);
}

- (void)selectOverlayFontFamilyValue:(NSString *)value {
  NSString *normalized = normalizedOverlayFontFamilyValue(value);

  for (NSMenuItem *item in self.overlayFontFamilyPopup.itemArray) {
    NSString *representedValue = item.representedObject;
    if (representedValue.length == 0)
      continue;
    if ([representedValue isEqualToString:normalized]) {
      [self.overlayFontFamilyPopup selectItem:item];
      return;
    }
  }

  [self.overlayFontFamilyPopup selectItemAtIndex:0];
}

- (void)selectOverlayMaxVisibleLinesValue:(NSInteger)value {
  NSInteger clampedValue = clampedOverlayMaxVisibleLinesValue(value);
  for (NSMenuItem *item in self.overlayMaxVisibleLinesPopup.itemArray) {
    NSNumber *representedValue =
        [item.representedObject isKindOfClass:[NSNumber class]]
            ? item.representedObject
            : nil;
    if (representedValue.integerValue == clampedValue) {
      [self.overlayMaxVisibleLinesPopup selectItem:item];
      return;
    }
  }

  [self.overlayMaxVisibleLinesPopup selectItemAtIndex:0];
}

- (void)updateOverlayLineLimitControlsEnabled {
  self.overlayMaxVisibleLinesPopup.enabled =
      self.overlayLimitVisibleLinesSwitch.state == NSControlStateValueOn;
}

- (NSView *)sliderControlWithSlider:(NSSlider *)slider
                         valueLabel:(NSTextField *)valueLabel
                              width:(CGFloat)width {
  CGFloat spacing = 10.0;
  CGFloat height = MAX(slider.frame.size.height, valueLabel.frame.size.height);
  NSView *container =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];

  slider.frame = NSMakeRect(0, floor((height - slider.frame.size.height) / 2.0),
                            width - valueLabel.frame.size.width - spacing,
                            slider.frame.size.height);
  valueLabel.frame =
      NSMakeRect(CGRectGetMaxX(slider.frame) + spacing,
                 floor((height - valueLabel.frame.size.height) / 2.0),
                 valueLabel.frame.size.width, valueLabel.frame.size.height);
  [container addSubview:slider];
  [container addSubview:valueLabel];
  return container;
}

- (NSTextField *)descriptionLabel:(NSString *)text {
  NSTextField *label = [NSTextField wrappingLabelWithString:text];
  label.font = SPTheme.descriptionFont;
  label.textColor = SPTheme.secondaryLabel;
  return label;
}

- (CGFloat)fittingHeightForWrappingLabel:(NSTextField *)label
                                   width:(CGFloat)width {
  NSTextFieldCell *cell = (NSTextFieldCell *)label.cell;
  NSSize measuredSize =
      [cell cellSizeForBounds:NSMakeRect(0, 0, width, CGFLOAT_MAX)];
  return ceil(MAX(18.0, measuredSize.height));
}

- (NSTextField *)addSettingsDescriptionText:(NSString *)text
                                     toPane:(NSView *)pane
                                       topY:(CGFloat)topY
                                          x:(CGFloat)x
                                      width:(CGFloat)width {
  NSTextField *label = [self descriptionLabel:text];
  CGFloat height = [self fittingHeightForWrappingLabel:label width:width];
  label.frame = NSMakeRect(x, floor(topY - height), width, height);
  [pane addSubview:label];
  return label;
}

- (NSTextField *)settingsRowLabelWithString:(NSString *)text {
  NSTextField *label = [NSTextField labelWithString:text];
  label.font = SPTheme.bodyFont;
  label.textColor = SPTheme.label;
  // A label's intrinsic width is its whole string, which Auto Layout treats as
  // near-required — a long row title would widen its card instead of eliding.
  label.lineBreakMode = NSLineBreakByTruncatingTail;
  [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                  forOrientation:NSLayoutConstraintOrientationHorizontal];
  return label;
}

- (NSSwitch *)settingsSwitchWithAction:(SEL)action {
  return [self settingsSwitchWithAction:action
                            controlSize:NSControlSizeRegular];
}

- (NSSwitch *)settingsSwitchWithAction:(SEL)action
                           controlSize:(NSControlSize)controlSize {
  NSSwitch *toggle = [[NSSwitch alloc] initWithFrame:NSZeroRect];
  toggle.controlSize = controlSize;
  toggle.target = self;
  toggle.action = action;
  [toggle sizeToFit];
  return toggle;
}

- (void)enumerateSubviewsRecursivelyInView:(NSView *)view
                                usingBlock:(void (^)(NSView *subview))block {
  for (NSView *subview in view.subviews) {
    block(subview);
    [self enumerateSubviewsRecursivelyInView:subview usingBlock:block];
  }
}

- (void)setHidden:(BOOL)hidden
    forViewsMatchingTags:(NSIndexSet *)tags
                  inView:(NSView *)view {
  [self enumerateSubviewsRecursivelyInView:view
                                usingBlock:^(NSView *subview) {
                                  if ([tags containsIndex:(NSUInteger)
                                                              subview.tag]) {
                                    subview.hidden = hidden;
                                  }
                                }];
}

- (void)setHidden:(BOOL)hidden
    forViewsWithTagInRange:(NSRange)range
                    inView:(NSView *)view {
  [self enumerateSubviewsRecursivelyInView:view
                                usingBlock:^(NSView *subview) {
                                  if (NSLocationInRange((NSUInteger)subview.tag,
                                                        range)) {
                                    subview.hidden = hidden;
                                  }
                                }];
}

- (NSTextField *)sectionTitleLabel:(NSString *)title frame:(NSRect)frame {
  SPCaptionLabel *label = [SPCaptionLabel captionWithString:title];
  label.frame = frame;
  return label;
}

- (NSView *)surfaceCardViewWithFrame:(NSRect)frame {
  SPCardView *card = [[SPCardView alloc] initWithFrame:frame];
  return card;
}

- (NSView *)settingsToggleCardWithFrame:(NSRect)frame
                                  title:(NSString *)title
                                 toggle:(NSSwitch *)toggle {
  NSView *card = [self surfaceCardViewWithFrame:frame];
  CGFloat toggleW = toggle.frame.size.width;
  CGFloat toggleH = toggle.frame.size.height;
  if (toggleW <= 0.0 || toggleH <= 0.0) {
    [toggle sizeToFit];
    toggleW = toggle.frame.size.width;
    toggleH = toggle.frame.size.height;
  }

  NSTextField *label = [self settingsRowLabelWithString:title];
  label.frame = NSMakeRect(14.0, floor((frame.size.height - 20.0) / 2.0),
                           MAX(80.0, frame.size.width - toggleW - 40.0), 20.0);
  [card addSubview:label];

  toggle.frame =
      NSMakeRect(frame.size.width - 14.0 - toggleW,
                 floor((frame.size.height - toggleH) / 2.0), toggleW, toggleH);
  [card addSubview:toggle];

  return card;
}

- (NSSegmentedControl *)
    templateActionSegmentedControlWithSymbols:(NSArray<NSString *> *)symbolNames
                                     toolTips:(NSArray<NSString *> *)toolTips
                                       action:(SEL)action {
  NSSegmentedControl *control =
      [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(0, 0, 50, 24)];
  control.segmentCount = symbolNames.count;
  control.segmentStyle = NSSegmentStyleTexturedRounded;
  control.trackingMode = NSSegmentSwitchTrackingMomentary;
  control.controlSize = NSControlSizeSmall;
  control.target = self;
  control.action = action;

  for (NSInteger idx = 0; idx < (NSInteger)symbolNames.count; idx++) {
    NSString *symbolName = symbolNames[idx];
    NSString *toolTip = idx < (NSInteger)toolTips.count ? toolTips[idx] : @"";
    NSImage *image = [NSImage imageWithSystemSymbolName:symbolName
                               accessibilityDescription:toolTip];
    image.size = NSMakeSize(12, 12);
    [control setImage:image forSegment:idx];
    [control setWidth:24 forSegment:idx];
    [[control cell] setToolTip:toolTip forSegment:idx];
  }

  return control;
}

// ─── Card Layout Helpers ───────────────────────────────────────────

- (NSView *)cardWithTitle:(NSString *)title
                     rows:(NSArray<NSView *> *)rows
                    width:(CGFloat)width {
  CGFloat rowHeight = 44.0;
  CGFloat cardPad = SPTheme.cardPadding;

  CGFloat cardHeight = rows.count * rowHeight;
  // Section heading → card is 12; the caption itself is 20 tall.
  CGFloat titleHeight = title.length > 0 ? 20.0 + SPTheme.sectionHeadingGap : 0.0;
  CGFloat totalHeight = titleHeight + cardHeight;

  NSView *container =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, totalHeight)];

  if (title.length > 0) {
    // The caption sits outside the card, aligned to the page margin rather than
    // the card's inner padding.
    SPCaptionLabel *titleLabel = [SPCaptionLabel captionWithString:title];
    titleLabel.frame =
        NSMakeRect(2.0, cardHeight + SPTheme.sectionHeadingGap, width - 4.0, 20);
    [container addSubview:titleLabel];
  }

  NSView *card =
      [self surfaceCardViewWithFrame:NSMakeRect(0, 0, width, cardHeight)];
  [container addSubview:card];

  for (NSUInteger i = 0; i < rows.count; i++) {
    NSView *row = rows[i];
    CGFloat rowY = cardHeight - (i + 1) * rowHeight;
    row.frame = NSMakeRect(0, rowY, width, rowHeight);
    [card addSubview:row];

    if (i < rows.count - 1) {
      NSView *separator = [[NSView alloc]
          initWithFrame:NSMakeRect(cardPad, rowY, width - 2 * cardPad, 1)];
      separator.wantsLayer = YES;
      [separator.effectiveAppearance performAsCurrentDrawingAppearance:^{
        separator.layer.backgroundColor = SPTheme.separator.CGColor;
      }];
      [card addSubview:separator];
    }
  }

  return container;
}

- (NSView *)cardRowWithLabel:(NSString *)label control:(NSView *)control {
  CGFloat rowHeight = 44.0;
  CGFloat pad = SPTheme.cardPadding;
  NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, rowHeight)];

  NSTextField *lbl = [self settingsRowLabelWithString:label];
  // Center the text's REAL height: a fixed 20pt frame draws the ~17pt text
  // bottom-aligned inside it, which reads as sitting below the row's middle.
  [lbl sizeToFit];
  CGFloat lblH = lbl.frame.size.height;
  lbl.frame =
      NSMakeRect(pad, floor((rowHeight - lblH) / 2.0), 200, lblH);
  [row addSubview:lbl];

  CGFloat controlW = control.frame.size.width;
  CGFloat controlH = control.frame.size.height;
  // Will be repositioned when parent sets the row's frame width
  control.frame =
      NSMakeRect(0, (rowHeight - controlH) / 2.0, controlW, controlH);
  control.autoresizingMask = NSViewMinXMargin;
  [row addSubview:control];

  return row;
}

- (void)layoutCardRowControls:(NSView *)card width:(CGFloat)width {
  CGFloat pad = SPTheme.cardPadding;
  for (NSView *row in card.subviews) {
    NSView *control = nil;
    for (NSView *sub in row.subviews) {
      if (sub.autoresizingMask & NSViewMinXMargin) {
        control = sub;
        CGFloat controlW = sub.frame.size.width;
        CGFloat controlH = sub.frame.size.height;
        sub.frame = NSMakeRect(width - pad - controlW,
                               (row.frame.size.height - controlH) / 2.0,
                               controlW, controlH);
      }
    }
    // Give the row label all remaining space up to the control so long
    // titles never clip against a fixed label width.
    for (NSView *sub in row.subviews) {
      if (sub != control && [sub isKindOfClass:[NSTextField class]]) {
        NSRect frame = sub.frame;
        CGFloat rightEdge = control ? NSMinX(control.frame) : width - pad;
        frame.size.width = MAX(40.0, rightEdge - 12.0 - NSMinX(frame));
        sub.frame = frame;
      }
    }
  }
}

- (NSButton *)eyeButtonWithFrame:(NSRect)frame action:(SEL)action {
  NSButton *button = [[NSButton alloc] initWithFrame:frame];
  button.bezelStyle = NSBezelStyleInline;
  button.bordered = NO;
  button.image = [NSImage imageWithSystemSymbolName:@"eye.slash"
                           accessibilityDescription:@"Показать"];
  button.imageScaling = NSImageScaleProportionallyUpOrDown;
  button.target = self;
  button.action = action;
  button.tag = 0; // 0 = hidden, 1 = visible
  return button;
}

- (void)toggleAsrAccessKeyVisibility:(NSButton *)sender {
  if (sender.tag == 0) {
    // Show plain text
    self.asrAccessKeyField.stringValue =
        self.asrAccessKeySecureField.stringValue;
    self.asrAccessKeySecureField.hidden = YES;
    self.asrAccessKeyField.hidden = NO;
    sender.image = [NSImage imageWithSystemSymbolName:@"eye"
                             accessibilityDescription:@"Скрыть"];
    sender.tag = 1;
  } else {
    // Show secure
    self.asrAccessKeySecureField.stringValue =
        self.asrAccessKeyField.stringValue;
    self.asrAccessKeyField.hidden = YES;
    self.asrAccessKeySecureField.hidden = NO;
    sender.image = [NSImage imageWithSystemSymbolName:@"eye.slash"
                             accessibilityDescription:@"Показать"];
    sender.tag = 0;
  }
}

// ─── Qwen: key list and per-app modes ───────────────────────────────

static NSString *maskedQwenKey(NSString *key) {
  if (key.length <= 8)
    return @"••••";
  return [NSString stringWithFormat:@"%@••••••••%@", [key substringToIndex:3],
                                    [key substringFromIndex:key.length - 4]];
}

static NSArray<NSString *> *parsedQwenKeys(NSString *text) {
  NSMutableArray<NSString *> *keys = [NSMutableArray array];
  NSMutableCharacterSet *separators =
      [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
  [separators addCharactersInString:@",;"];
  for (NSString *part in [text componentsSeparatedByCharactersInSet:separators]) {
    if (part.length > 0 && ![keys containsObject:part])
      [keys addObject:part];
  }
  return keys;
}

- (void)showQwenKeysMasked {
  NSMutableArray<NSString *> *lines = [NSMutableArray array];
  for (NSString *key in self.asrQwenKeys)
    [lines addObject:maskedQwenKey(key)];
  self.asrQwenKeysTextView.string = [lines componentsJoinedByString:@"\n"];
}

- (void)qwenKeysFocusChanged:(BOOL)focused {
  if (focused && !self.asrQwenKeysEditing) {
    self.asrQwenKeysEditing = YES;
    self.asrQwenKeysTextView.string =
        [self.asrQwenKeys componentsJoinedByString:@"\n"];
  } else if (!focused && self.asrQwenKeysEditing) {
    self.asrQwenKeys = parsedQwenKeys(self.asrQwenKeysTextView.string);
    self.asrQwenKeysEditing = NO;
    [self showQwenKeysMasked];
  }
}

- (NSArray<NSString *> *)currentQwenKeys {
  return self.asrQwenKeysEditing
             ? parsedQwenKeys(self.asrQwenKeysTextView.string)
             : (self.asrQwenKeys ?: @[]);
}

- (void)loadQwenKeysFromConfig {
  NSMutableArray<NSString *> *keys = [NSMutableArray array];
  id list = configGetJSON(@"asr.qwen.api_keys");
  if ([list isKindOfClass:[NSArray class]]) {
    for (id item in list) {
      if ([item isKindOfClass:[NSString class]] && [item length] > 0)
        [keys addObject:item];
    }
  }
  if (keys.count == 0) {
    NSString *single = configGet(@"asr.qwen.api_key");
    if (single.length > 0)
      [keys addObject:single];
  }
  self.asrQwenKeys = keys;
  self.asrQwenKeysEditing = NO;
  [self showQwenKeysMasked];
}

- (NSArray<NSDictionary *> *)currentQwenAppModeEntries {
  NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
  for (NSUInteger i = 0; i < self.asrQwenAppModeFields.count; i++) {
    NSString *app = [self.asrQwenAppModeFields[i].stringValue
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]];
    NSString *mode = self.asrQwenAppModePopups[i].selectedItem.representedObject
                         ?: @"raw";
    [entries addObject:@{@"app" : app ?: @"", @"mode" : mode}];
  }
  return entries;
}

- (void)setQwenAppModeEntries:(NSArray<NSDictionary *> *)entries {
  for (NSView *row in [self.asrQwenAppModesRows.subviews copy])
    [row removeFromSuperview];
  [self.asrQwenAppModeFields removeAllObjects];
  [self.asrQwenAppModePopups removeAllObjects];

  const CGFloat rowH = 28.0;
  CGFloat width = NSWidth(self.asrQwenAppModesScroll.contentView.bounds);
  NSArray<NSArray<NSString *> *> *modes = @[
    @[ @"Как сказал", @"raw" ],
    @[ @"Лёгкая правка", @"light" ],
    @[ @"Структура", @"structured" ],
    @[ @"Деловой стиль", @"formal" ],
  ];
  for (NSUInteger i = 0; i < entries.count; i++) {
    CGFloat y = i * rowH + 3;
    CGFloat popupW = 130.0;
    CGFloat fieldW = width - popupW - 30.0 - 16.0;
    NSTextField *field = [self
        formTextField:NSMakeRect(4, y, fieldW, 22)
          placeholder:@"com.apple.mail или Mail"];
    field.stringValue = entries[i][@"app"] ?: @"";
    [self.asrQwenAppModesRows addSubview:field];
    NSPopUpButton *popup = [[NSPopUpButton alloc]
        initWithFrame:NSMakeRect(8 + fieldW, y - 2, popupW, 26)
            pullsDown:NO];
    for (NSArray<NSString *> *mode in modes) {
      [popup addItemWithTitle:mode[0]];
      [popup lastItem].representedObject = mode[1];
    }
    for (NSInteger m = 0; m < popup.numberOfItems; m++) {
      if ([[popup itemAtIndex:m].representedObject
              isEqualToString:entries[i][@"mode"]])
        [popup selectItemAtIndex:m];
    }
    [self.asrQwenAppModesRows addSubview:popup];
    NSButton *minus = [NSButton
        buttonWithImage:[NSImage imageWithSystemSymbolName:@"minus.circle"
                                  accessibilityDescription:@"Удалить"]
                 target:self
                 action:@selector(removeQwenAppModeRow:)];
    minus.frame = NSMakeRect(12 + fieldW + popupW, y - 1, 24, 24);
    minus.bordered = NO;
    minus.tag = (NSInteger)i;
    [self.asrQwenAppModesRows addSubview:minus];
    [self.asrQwenAppModeFields addObject:field];
    [self.asrQwenAppModePopups addObject:popup];
  }
  NSRect frame = self.asrQwenAppModesRows.frame;
  frame.size.width = width;
  frame.size.height = MAX(entries.count * rowH + 6,
                          NSHeight(self.asrQwenAppModesScroll.contentView.bounds));
  self.asrQwenAppModesRows.frame = frame;
}

- (void)loadQwenAppModesFromConfig {
  NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
  id map = configGetJSON(@"asr.qwen.app_modes");
  if ([map isKindOfClass:[NSDictionary class]]) {
    for (NSString *app in [[map allKeys]
             sortedArrayUsingSelector:@selector(compare:)]) {
      if ([map[app] isKindOfClass:[NSString class]])
        [entries addObject:@{@"app" : app, @"mode" : map[app]}];
    }
  }
  [self setQwenAppModeEntries:entries];
}

- (void)addQwenAppModeRow:(id)sender {
  [self addQwenAppModeEntryForApp:@""];
}

- (void)addQwenAppModeEntryForApp:(NSString *)app {
  NSMutableArray<NSDictionary *> *entries =
      [[self currentQwenAppModeEntries] mutableCopy];
  [entries addObject:@{@"app" : app ?: @"", @"mode" : @"raw"}];
  [self setQwenAppModeEntries:entries];
  NSView *last = self.asrQwenAppModeFields.lastObject;
  if (last)
    [self.asrQwenAppModesRows scrollRectToVisible:last.frame];
}

- (void)removeQwenAppModeRow:(NSButton *)sender {
  NSMutableArray<NSDictionary *> *entries =
      [[self currentQwenAppModeEntries] mutableCopy];
  if (sender.tag >= 0 && (NSUInteger)sender.tag < entries.count) {
    [entries removeObjectAtIndex:(NSUInteger)sender.tag];
    [self setQwenAppModeEntries:entries];
  }
}

- (void)showRunningAppsMenu:(NSButton *)sender {
  NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  NSArray<NSRunningApplication *> *apps =
      [[NSWorkspace sharedWorkspace].runningApplications
          sortedArrayUsingComparator:^NSComparisonResult(
              NSRunningApplication *a, NSRunningApplication *b) {
            return [(a.localizedName ?: @"") localizedCaseInsensitiveCompare:
                                                 (b.localizedName ?: @"")];
          }];
  for (NSRunningApplication *app in apps) {
    if (app.activationPolicy != NSApplicationActivationPolicyRegular ||
        app.bundleIdentifier.length == 0 ||
        [app.bundleIdentifier isEqualToString:
                 [NSBundle mainBundle].bundleIdentifier] ||
        [seen containsObject:app.bundleIdentifier])
      continue;
    [seen addObject:app.bundleIdentifier];
    NSMenuItem *item = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:@"%@ — %@",
                                                 app.localizedName ?: @"",
                                                 app.bundleIdentifier]
               action:@selector(addRunningAppFromMenu:)
        keyEquivalent:@""];
    item.target = self;
    item.representedObject = app.bundleIdentifier;
    [menu addItem:item];
  }
  [menu popUpMenuPositioningItem:nil
                      atLocation:NSMakePoint(0, NSHeight(sender.bounds))
                          inView:sender];
}

- (void)addRunningAppFromMenu:(NSMenuItem *)item {
  [self addQwenAppModeEntryForApp:item.representedObject];
}

// A typed application name ("Mail") becomes its bundle id when the app is
// installed; anything with a dot is taken as a bundle id or prefix as typed.
static NSString *bundleIdForTypedApp(NSString *typed) {
  if (typed.length == 0 || [typed containsString:@"."])
    return typed;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  NSString *path = [[NSWorkspace sharedWorkspace] fullPathForApplication:typed];
#pragma clang diagnostic pop
  NSString *bundleId = path ? [NSBundle bundleWithPath:path].bundleIdentifier : nil;
  return bundleId.length > 0 ? bundleId : typed;
}

- (NSDictionary<NSString *, NSString *> *)qwenAppModesForSave {
  NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
  for (NSDictionary *entry in [self currentQwenAppModeEntries]) {
    NSString *app = bundleIdForTypedApp(entry[@"app"]);
    if (app.length > 0)
      map[app] = entry[@"mode"];
  }
  return map;
}

- (void)toggleGlmApiKeyVisibility:(NSButton *)sender {
  if (sender.tag == 0) {
    // Show plain text
    self.asrGlmApiKeyField.stringValue =
        self.asrGlmApiKeySecureField.stringValue;
    self.asrGlmApiKeySecureField.hidden = YES;
    self.asrGlmApiKeyField.hidden = NO;
    sender.image = [NSImage imageWithSystemSymbolName:@"eye"
                             accessibilityDescription:@"Скрыть"];
    sender.tag = 1;
  } else {
    // Show secure
    self.asrGlmApiKeySecureField.stringValue =
        self.asrGlmApiKeyField.stringValue;
    self.asrGlmApiKeyField.hidden = YES;
    self.asrGlmApiKeySecureField.hidden = NO;
    sender.image = [NSImage imageWithSystemSymbolName:@"eye.slash"
                             accessibilityDescription:@"Показать"];
    sender.tag = 0;
  }
}

- (void)toggleMimoApiKeyVisibility:(NSButton *)sender {
  if (sender.tag == 0) {
    // Show plain text
    self.asrMimoApiKeyField.stringValue =
        self.asrMimoApiKeySecureField.stringValue;
    self.asrMimoApiKeySecureField.hidden = YES;
    self.asrMimoApiKeyField.hidden = NO;
    sender.image = [NSImage imageWithSystemSymbolName:@"eye"
                             accessibilityDescription:@"Скрыть"];
    sender.tag = 1;
  } else {
    // Show secure
    self.asrMimoApiKeySecureField.stringValue =
        self.asrMimoApiKeyField.stringValue;
    self.asrMimoApiKeyField.hidden = YES;
    self.asrMimoApiKeySecureField.hidden = NO;
    sender.image = [NSImage imageWithSystemSymbolName:@"eye.slash"
                             accessibilityDescription:@"Показать"];
    sender.tag = 0;
  }
}

- (void)toggleAsrApiKeyVisibility:(NSButton *)sender {
  if (sender.tag == 0) {
    self.asrApiKeyField.stringValue = self.asrApiKeySecureField.stringValue;
    self.asrApiKeySecureField.hidden = YES;
    self.asrApiKeyField.hidden = NO;
    sender.image = [NSImage imageWithSystemSymbolName:@"eye"
                             accessibilityDescription:@"Скрыть"];
    sender.tag = 1;
  } else {
    self.asrApiKeySecureField.stringValue = self.asrApiKeyField.stringValue;
    self.asrApiKeyField.hidden = YES;
    self.asrApiKeySecureField.hidden = NO;
    sender.image = [NSImage imageWithSystemSymbolName:@"eye.slash"
                             accessibilityDescription:@"Показать"];
    sender.tag = 0;
  }
}

- (void)asrAuthModeChanged:(NSSegmentedControl *)sender {
  BOOL isNewConsole = (sender.selectedSegment == 0);
  // Show/hide API Key (new console) vs App Key + Access Key (legacy)
  [self setHidden:!isNewConsole
      forViewsMatchingTags:[NSIndexSet indexSetWithIndex:1007]
                    inView:self.currentPaneView];
  self.asrApiKeySecureField.hidden = !isNewConsole;
  self.asrApiKeyField.hidden = YES;
  self.asrApiKeyToggle.hidden = !isNewConsole;
  self.asrApiKeyToggle.tag = 0;

  [self setHidden:isNewConsole
      forViewsMatchingTags:[NSIndexSet
                               indexSetWithIndexesInRange:NSMakeRange(1001, 2)]
                    inView:self.currentPaneView];
  self.asrAppKeyField.hidden = isNewConsole;
  self.asrAccessKeySecureField.hidden = isNewConsole;
  self.asrAccessKeyField.hidden = YES;
  self.asrAccessKeyToggle.hidden = isNewConsole;
  self.asrAccessKeyToggle.tag = 0;
}

- (void)asrAdvancedToggled:(NSButton *)sender {
  BOOL expanded = (sender.state == NSControlStateValueOn);
  self.asrAdvancedContainer.hidden = !expanded;
  [self resizeAsrPaneToCurrentProvider];
}

// ASR settings pane uses different vertical footprints depending on which
// provider is selected. The pane is built at the maximum footprint (Doubao +
// advanced expanded) and then sized down via autoresizing here — Save/Cancel
// stick to the bottom edge, everything else sticks to the top.
// Height of the strip kept clear at the bottom of the ASR form card for the
// bottom-pinned test-result line, so no provider's last row lands on top of it.
static const CGFloat kAsrStatusStripHeight = 34.0;

// The card keeps ONE fixed footprint for every provider — sized to the
// tallest form (Doubao with Advanced expanded) and to the measured provider
// notes. Compact providers simply leave empty card space; a card that
// resized per provider made the whole pane jump on every switch.
- (CGFloat)targetAsrPaneHeightForProvider:(NSString *)provider
                         advancedExpanded:(BOOL)expanded {
  CGFloat height = 460.0 + kAsrStatusStripHeight;
  height = MAX(height, self.asrMimoRequiredPaneHeight + kAsrStatusStripHeight);
  height = MAX(height,
               self.asrWetypeRequiredPaneHeight + kAsrStatusStripHeight);
  if ([provider isEqualToString:@"qwen"]) {
    height = MAX(height, self.asrQwenRequiredPaneHeight + kAsrStatusStripHeight);
  }
  return height;
}

// Each provider needs a different amount of the pane. The window no longer
// follows — it is a fixed shape — so only the pane and the scroll document it
// sits in are resized.
- (void)resizeAsrPaneToCurrentProvider {
  if (!self.currentPaneView) return;
  if (![self.currentPaneIdentifier isEqualToString:kToolbarASR]) return;

  NSString *provider =
      self.asrProviderPopup.selectedItem.representedObject ?: @"qwen";
  BOOL advExpanded =
      ([provider isEqualToString:@"doubao"] &&
       self.asrAdvancedDisclosure.state == NSControlStateValueOn);
  CGFloat targetHeight =
      [self targetAsrPaneHeightForProvider:provider
                          advancedExpanded:advExpanded];

  NSRect paneFrame = self.currentPaneView.frame;
  if (fabs(paneFrame.size.height - targetHeight) < 1.0) return;
  paneFrame.size.height = targetHeight;
  self.currentPaneView.frame = paneFrame;
  [self refreshHostedPaneHeight];
}

- (void)asrProviderChanged:(NSPopUpButton *)sender {
  NSString *selectedProvider =
      sender.selectedItem.representedObject ?: @"qwen";
  BOOL isDoubao = [selectedProvider isEqualToString:@"doubao"];
  BOOL isQwen = [selectedProvider isEqualToString:@"qwen"];
  BOOL isGlm = [selectedProvider isEqualToString:@"glm"];
  BOOL isMimo = [selectedProvider isEqualToString:@"mimo"];
  BOOL isAppleSpeech = [selectedProvider isEqualToString:@"apple-speech"];
  BOOL isModelBasedLocal =
      !isDoubao && !isQwen && !isGlm && !isMimo && !isAppleSpeech;

  // Show/hide Doubao auth mode control and credential fields
  [self setHidden:!isDoubao
      forViewsMatchingTags:[NSIndexSet indexSetWithIndex:1006]
                    inView:self.currentPaneView];
  self.asrAuthModeControl.hidden = !isDoubao;

  if (isDoubao) {
    // Delegate to auth mode handler to show correct credential fields
    [self asrAuthModeChanged:self.asrAuthModeControl];
  } else {
    // Hide all Doubao credential fields
    [self setHidden:YES
        forViewsMatchingTags:[NSIndexSet
                                 indexSetWithIndexesInRange:NSMakeRange(1001,
                                                                        2)]
                      inView:self.currentPaneView];
    self.asrAppKeyField.hidden = YES;
    self.asrAccessKeyField.hidden = YES;
    self.asrAccessKeySecureField.hidden = YES;
    self.asrAccessKeyToggle.hidden = YES;
    [self setHidden:YES
        forViewsMatchingTags:[NSIndexSet indexSetWithIndex:1007]
                      inView:self.currentPaneView];
    self.asrApiKeySecureField.hidden = YES;
    self.asrApiKeyField.hidden = YES;
    self.asrApiKeyToggle.hidden = YES;
  }

  // Show/hide language popup and advanced (Doubao only)
  BOOL showLanguage = isDoubao;
  [self setHidden:!showLanguage
      forViewsMatchingTags:[NSIndexSet indexSetWithIndex:1008]
                    inView:self.currentPaneView];
  self.asrLanguagePopup.hidden = !showLanguage;
  // Reload language value when Doubao is selected
  if (showLanguage) {
    NSString *lang = configGet(@"asr.doubao.language");
    BOOL found = NO;
    for (NSInteger i = 0; i < self.asrLanguagePopup.numberOfItems; i++) {
      if ([[self.asrLanguagePopup itemAtIndex:i].representedObject
              isEqualToString:lang]) {
        [self.asrLanguagePopup selectItemAtIndex:i];
        found = YES;
        break;
      }
    }
    if (!found)
      [self.asrLanguagePopup selectItemAtIndex:0];
  }
  self.asrAdvancedDisclosure.hidden = !isDoubao;
  if (!isDoubao) {
    self.asrAdvancedContainer.hidden = YES;
  } else {
    self.asrAdvancedContainer.hidden =
        (self.asrAdvancedDisclosure.state == NSControlStateValueOff);
  }

  // Show/hide Qwen fields
  self.asrTestButton.title = isQwen ? @"Проверить ключ" : @"Проверить";
  [self.asrTestButton sizeToFit];
  NSRect testFrame = self.asrTestButton.frame;
  testFrame.size.height = 28;
  self.asrTestButton.frame = testFrame;
  [self setHidden:!isQwen
      forViewsMatchingTags:[NSIndexSet indexSetWithIndex:1003]
                    inView:self.currentPaneView];
  [self setHidden:!isQwen
      forViewsMatchingTags:[NSIndexSet indexSetWithIndex:1016]
                    inView:self.currentPaneView];
  self.asrQwenKeysTextView.enclosingScrollView.hidden = !isQwen;
  self.asrQwenAppModesScroll.hidden = !isQwen;
  [self setHidden:!isQwen
      forViewsMatchingTags:[NSIndexSet indexSetWithIndex:1014]
                    inView:self.currentPaneView];
  [self setHidden:!isQwen
      forViewsMatchingTags:[NSIndexSet indexSetWithIndex:1015]
                    inView:self.currentPaneView];
  self.asrQwenOutputModePopup.hidden = !isQwen;
  self.asrQwenTranslateToField.hidden = !isQwen;
  [self setHidden:!isQwen
      forViewsMatchingTags:[NSIndexSet indexSetWithIndex:1017]
                    inView:self.currentPaneView];
  [self layoutQwenModelRowShowingProvider:isQwen];

  // Show/hide GLM fields
  [self setHidden:!isGlm
      forViewsMatchingTags:[NSIndexSet indexSetWithIndex:1010]
                    inView:self.currentPaneView];
  self.asrGlmApiKeyField.hidden = YES; // Always start hidden (secure mode)
  self.asrGlmApiKeySecureField.hidden = !isGlm;
  self.asrGlmApiKeyToggle.hidden = !isGlm;

  // Show/hide MiMo fields
  [self setHidden:!isMimo
      forViewsMatchingTags:[NSIndexSet indexSetWithIndex:1011]
                    inView:self.currentPaneView];
  self.asrMimoApiKeyField.hidden = YES; // Always start hidden (secure mode)
  self.asrMimoApiKeySecureField.hidden = !isMimo;
  self.asrMimoApiKeyToggle.hidden = !isMimo;

  // Show/hide Apple Speech locale popup and asset status
  self.appleSpeechLocalePopup.hidden = !isAppleSpeech;
  [self setHidden:!isAppleSpeech
      forViewsMatchingTags:[NSIndexSet indexSetWithIndex:1005]
                    inView:self.currentPaneView];

  // Show/hide local model popup, status, and download button
  self.localModelPopup.hidden = !isModelBasedLocal;
  if (!isModelBasedLocal && !isAppleSpeech) {
    self.modelStatusLabel.hidden = YES;
    self.modelDownloadButton.hidden = YES;
    self.modelDeleteButton.hidden = YES;
    self.modelProgressBar.hidden = YES;
    self.modelProgressSizeLabel.hidden = YES;
  } else if (isAppleSpeech) {
    // Reuse model status row for Apple Speech asset status
    self.modelStatusLabel.hidden = NO;
    self.modelDownloadButton.hidden = NO;
    self.modelDeleteButton.hidden = NO;
    self.modelProgressBar.hidden = YES;
    self.modelProgressSizeLabel.hidden = YES;
    [self updateAppleSpeechAssetStatus];
  } else {
    self.modelStatusLabel.hidden = NO;
    self.modelDownloadButton.hidden = NO;
    self.modelDeleteButton.hidden = NO;
    self.modelProgressBar.hidden = YES;
    self.modelProgressSizeLabel.hidden = YES;
    [self updateModelStatusLabel];
  }
  [self setHidden:!isModelBasedLocal
      forViewsMatchingTags:[NSIndexSet indexSetWithIndex:1004]
                    inView:self.currentPaneView];
  if (isModelBasedLocal) {
    [self populateLocalModelPopup:selectedProvider mode:@"asr"];
    [self updateModelStatusLabel];
  }

  // Provider-specific note: WeType's Chinese-only note (developer builds
  // with the wetype-offline feature only).
  BOOL isWetype = [selectedProvider isEqualToString:@"wetype"];
  [self setHidden:!isWetype
      forViewsMatchingTags:[NSIndexSet indexSetWithIndex:1013]
                    inView:self.currentPaneView];

  // Hide test button for local providers (no remote connection to test)
  BOOL isLocal = !isDoubao && !isQwen && !isGlm && !isMimo;
  self.asrTestButton.hidden = isLocal;
  self.asrTestResultLabel.hidden = isLocal;

  // Clear test result when switching provider
  self.asrTestResultLabel.stringValue = @"";
  self.asrTestButton.enabled = YES;

  // Each provider has a different vertical footprint — resize the pane so
  // there isn't a giant empty area below the visible controls.
  [self resizeAsrPaneToCurrentProvider];
}

- (void)localModelChanged:(id)sender {
  [self updateModelStatusLabel];
}

- (void)updateModelStatusLabel {
  NSString *modelPath = self.localModelPopup.selectedItem.representedObject;
  if (!modelPath) {
    self.modelStatusLabel.stringValue = @"";
    self.modelDownloadButton.enabled = NO;
    self.modelDeleteButton.enabled = NO;
    self.modelProgressBar.hidden = YES;
    self.modelProgressSizeLabel.hidden = YES;
    return;
  }

  // If selected model is currently downloading, show progress UI
  if ([self.downloadingModels containsObject:modelPath]) {
    self.modelStatusLabel.stringValue = @"Скачивание";
    self.modelStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.modelDownloadButton.image =
        [NSImage imageWithSystemSymbolName:@"stop.circle"
                  accessibilityDescription:@"Стоп"];
    self.modelDownloadButton.enabled = YES;
    self.modelDeleteButton.enabled = NO;
    self.modelProgressBar.hidden = NO;
    self.modelProgressSizeLabel.hidden = NO;
    return;
  }

  // 1. Cache-only lookup (~1ms)
  NSInteger cachedStatus = [self.rustBridge modelStatus:modelPath
                                                   mode:SPModelVerifyCacheOnly];
  if (cachedStatus == 2) {
    [self applyModelStatus:cachedStatus];
    return;
  }

  // 2. Cache miss or incomplete — show "Verifying…" and dispatch async
  [self applyModelStatus:(cachedStatus > 0 ? cachedStatus : 1) verifying:YES];
  self.pendingVerificationPath = modelPath;

  dispatch_async(_verifyQueue, ^{
    NSInteger verified = [self.rustBridge modelStatus:modelPath
                                                 mode:SPModelVerifyNormal];
    dispatch_async(dispatch_get_main_queue(), ^{
      if ([self.pendingVerificationPath isEqualToString:modelPath]) {
        self.pendingVerificationPath = nil;
        [self applyModelStatus:verified];
      }
    });
  });
}

- (void)applyModelStatus:(NSInteger)status {
  [self applyModelStatus:status verifying:NO];
}

- (void)applyModelStatus:(NSInteger)status verifying:(BOOL)verifying {
  self.modelProgressBar.hidden = YES;
  self.modelProgressSizeLabel.hidden = YES;
  self.modelDownloadButton.image =
      [NSImage imageWithSystemSymbolName:@"arrow.down.circle"
                accessibilityDescription:@"Скачать"];
  switch (status) {
  case 2:
    self.modelStatusLabel.stringValue =
        verifying ? @"● Проверка…" : @"● Установлена";
    self.modelStatusLabel.textColor =
        verifying ? [NSColor secondaryLabelColor] : SPTheme.success;
    self.modelDownloadButton.enabled = NO;
    self.modelDeleteButton.enabled = YES;
    break;
  case 1:
    self.modelStatusLabel.stringValue =
        verifying ? @"◐ Проверка…" : @"◐ Не завершена";
    self.modelStatusLabel.textColor =
        verifying ? [NSColor secondaryLabelColor] : SPTheme.warning;
    self.modelDownloadButton.enabled = YES;
    self.modelDeleteButton.enabled = YES;
    break;
  default:
    self.modelStatusLabel.stringValue = @"○ Не установлена";
    self.modelStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.modelDownloadButton.enabled = YES;
    self.modelDeleteButton.enabled = NO;
    break;
  }
}

- (void)downloadSelectedModel:(id)sender {
  // Dispatch to Apple Speech asset download if that provider is selected
  NSString *selectedProvider =
      self.asrProviderPopup.selectedItem.representedObject ?: @"qwen";
  if ([selectedProvider isEqualToString:@"apple-speech"]) {
    [self downloadAppleSpeechAsset];
    return;
  }

  NSString *modelPath = self.localModelPopup.selectedItem.representedObject;
  if (!modelPath)
    return;

  // If this model is downloading, cancel it
  if ([self.downloadingModels containsObject:modelPath]) {
    [self.rustBridge cancelDownload:modelPath];
    return;
  }

  if (!self.downloadingModels) {
    self.downloadingModels = [NSMutableSet new];
  }
  [self.downloadingModels addObject:modelPath];

  // Switch to stop icon and show progress bar
  self.modelDownloadButton.image =
      [NSImage imageWithSystemSymbolName:@"stop.circle"
                accessibilityDescription:@"Стоп"];
  self.modelDownloadButton.hidden = NO;
  self.modelStatusLabel.stringValue = @"Скачивание…";
  self.modelStatusLabel.textColor = [NSColor secondaryLabelColor];
  self.modelProgressBar.hidden = NO;
  self.modelProgressBar.doubleValue = 0;
  self.modelProgressSizeLabel.hidden = NO;
  self.modelProgressSizeLabel.stringValue = @"";

  // Get total size from scan_models data
  __block uint64_t totalBytesAllFiles = 0;
  for (NSDictionary *m in [self.rustBridge scanModels]) {
    if ([m[@"path"] isEqualToString:modelPath]) {
      totalBytesAllFiles = [m[@"total_size"] unsignedLongLongValue];
      break;
    }
  }
  __block NSMutableDictionary<NSNumber *, NSNumber *> *fileDownloaded =
      [NSMutableDictionary new];

  __weak typeof(self) weakSelf = self;
  [self.rustBridge downloadModel:modelPath
      progress:^(NSUInteger fileIndex, NSUInteger fileCount,
                 uint64_t downloaded, uint64_t total, NSString *filename) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf)
          return;

        // Only update UI if this model is still selected
        NSString *selected =
            strongSelf.localModelPopup.selectedItem.representedObject;
        if (![modelPath isEqualToString:selected])
          return;

        fileDownloaded[@(fileIndex)] = @(downloaded);

        uint64_t totalDownloaded = 0;
        for (NSNumber *v in fileDownloaded.allValues)
          totalDownloaded += v.unsignedLongLongValue;

        double pct =
            (totalBytesAllFiles > 0)
                ? (double)totalDownloaded / (double)totalBytesAllFiles * 100.0
                : 0;
        strongSelf.modelProgressBar.doubleValue = pct;
        strongSelf.modelStatusLabel.stringValue = @"Скачивание";
        strongSelf.modelProgressSizeLabel.stringValue =
            [NSString stringWithFormat:@"%.1f / %.1f МБ",
                                       (double)totalDownloaded / 1048576.0,
                                       (double)totalBytesAllFiles / 1048576.0];
      }
      completion:^(BOOL success, NSString *message) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf)
          return;
        [strongSelf.downloadingModels removeObject:modelPath];
        [strongSelf updateModelStatusLabel];
      }];
}

- (void)deleteSelectedModel:(id)sender {
  // Dispatch to Apple Speech asset release if that provider is selected
  NSString *selectedProvider =
      self.asrProviderPopup.selectedItem.representedObject ?: @"qwen";
  if ([selectedProvider isEqualToString:@"apple-speech"]) {
    [self releaseAppleSpeechAsset];
    return;
  }

  NSString *modelPath = self.localModelPopup.selectedItem.representedObject;
  if (!modelPath)
    return;

  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Удалить файлы модели?";
  alert.informativeText = @"Скачанные файлы модели будут удалены. Модель можно скачать "
                          @"снова.";
  [alert addButtonWithTitle:@"Удалить"];
  [alert addButtonWithTitle:@"Отмена"];
  alert.alertStyle = NSAlertStyleWarning;

  if ([alert runModal] == NSAlertFirstButtonReturn) {
    [self.rustBridge removeModelFiles:modelPath];
    [self updateModelStatusLabel];
  }
}

// MARK: - Apple Speech Asset Management

- (void)populateAppleSpeechLocalePopup {
  [self.appleSpeechLocalePopup removeAllItems];

  uint32_t blobLen = 0;
  uint8_t *blob = sp_apple_speech_supported_locales(&blobLen);
  if (blob && blobLen > 0) {
    // Parse "id\0displayName\0\0id\0displayName\0\0..." blob
    NSData *data = [NSData dataWithBytesNoCopy:blob
                                        length:blobLen
                                  freeWhenDone:YES];
    const uint8_t *bytes = data.bytes;
    NSUInteger pos = 0;
    while (pos < blobLen) {
      // Read identifier (until first \0)
      NSUInteger idStart = pos;
      while (pos < blobLen && bytes[pos] != 0)
        pos++;
      if (pos >= blobLen)
        break;
      NSString *identifier =
          [[NSString alloc] initWithBytes:bytes + idStart
                                   length:pos - idStart
                                 encoding:NSUTF8StringEncoding];
      pos++; // skip \0

      // Read display name (until next \0)
      NSUInteger nameStart = pos;
      while (pos < blobLen && bytes[pos] != 0)
        pos++;
      NSString *displayName =
          [[NSString alloc] initWithBytes:bytes + nameStart
                                   length:pos - nameStart
                                 encoding:NSUTF8StringEncoding];
      pos++; // skip \0

      // Skip trailing \0 (double-null separator)
      if (pos < blobLen && bytes[pos] == 0)
        pos++;

      if (identifier && displayName) {
        [self.appleSpeechLocalePopup addItemWithTitle:displayName];
        [self.appleSpeechLocalePopup lastItem].representedObject = identifier;
      }
    }
  } else {
    // Fallback if API unavailable
    [self.appleSpeechLocalePopup addItemWithTitle:@"Нет доступных языков"];
    self.appleSpeechLocalePopup.enabled = NO;
  }
}

- (void)updateAppleSpeechAssetStatus {
  NSString *locale = self.appleSpeechLocalePopup.selectedItem.representedObject;
  int32_t status = sp_apple_speech_asset_status(locale.UTF8String);

  switch (status) {
  case 3: { // installed
    self.modelStatusLabel.stringValue = @"● Установлена";
    self.modelStatusLabel.textColor = SPTheme.success;
    self.modelDownloadButton.image =
        [NSImage imageWithSystemSymbolName:@"arrow.down.circle"
                  accessibilityDescription:@"Скачать"];
    self.modelDownloadButton.enabled = NO;
    self.modelDeleteButton.enabled = YES;
    break;
  }
  case 2: // downloading
    self.modelStatusLabel.stringValue = @"◐ Скачивание…";
    self.modelStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.modelDownloadButton.enabled = NO;
    self.modelDeleteButton.enabled = NO;
    break;
  case 1: // supported (downloadable)
    self.modelStatusLabel.stringValue = @"○ Не установлена";
    self.modelStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.modelDownloadButton.image =
        [NSImage imageWithSystemSymbolName:@"arrow.down.circle"
                  accessibilityDescription:@"Скачать"];
    self.modelDownloadButton.enabled = YES;
    self.modelDeleteButton.enabled = NO;
    break;
  default: // unsupported
    self.modelStatusLabel.stringValue = @"✕ Для этого языка не поддерживается";
    self.modelStatusLabel.textColor = SPTheme.failure;
    self.modelDownloadButton.enabled = NO;
    self.modelDeleteButton.enabled = NO;
    break;
  }
}

static void appleSpeechInstallCallback(void *ctx, int32_t eventType,
                                       const char *text) {
  SPSetupWizardWindowController *controller =
      (__bridge SPSetupWizardWindowController *)ctx;
  NSString *textStr = text ? [NSString stringWithUTF8String:text] : nil;
  dispatch_async(dispatch_get_main_queue(), ^{
    switch (eventType) {
    case 0: // progress
      controller.modelStatusLabel.stringValue = textStr ?: @"Скачивание…";
      controller.modelStatusLabel.textColor = [NSColor secondaryLabelColor];
      break;
    case 1: // completed
      [controller updateAppleSpeechAssetStatus];
      break;
    case 2: // error
      controller.modelStatusLabel.stringValue = textStr ?: @"Не удалось скачать";
      controller.modelStatusLabel.textColor = SPTheme.failure;
      controller.modelDownloadButton.enabled = YES;
      break;
    }
  });
}

- (void)appleSpeechLocaleChanged:(id)sender {
  [self updateAppleSpeechAssetStatus];
}

- (void)releaseAppleSpeechAsset {
  NSString *locale = self.appleSpeechLocalePopup.selectedItem.representedObject;

  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Освободить речевые ресурсы?";
  alert.informativeText = @"Система может освободить место, занятое речевой моделью этого "
                          @"языка. Её можно скачать снова.";
  [alert addButtonWithTitle:@"Освободить"];
  [alert addButtonWithTitle:@"Отмена"];
  alert.alertStyle = NSAlertStyleWarning;

  if ([alert runModal] == NSAlertFirstButtonReturn) {
    sp_apple_speech_release_asset(locale.UTF8String);
    [self updateAppleSpeechAssetStatus];
  }
}

- (void)downloadAppleSpeechAsset {
  NSString *locale = self.appleSpeechLocalePopup.selectedItem.representedObject;
  self.modelStatusLabel.stringValue = @"Скачивание…";
  self.modelStatusLabel.textColor = [NSColor secondaryLabelColor];
  self.modelDownloadButton.enabled = NO;
  sp_apple_speech_install_asset(locale.UTF8String, appleSpeechInstallCallback,
                                 (__bridge void *)self);
}

- (void)populateLocalModelPopup:(NSString *)provider {
  [self populateLocalModelPopup:provider mode:nil];
}

- (void)populateLocalModelPopup:(NSString *)provider mode:(NSString *)mode {
  [self.localModelPopup removeAllItems];

  NSArray<NSDictionary *> *models = [self.rustBridge scanModels];
  for (NSDictionary *model in models) {
    if (![model[@"provider"] isEqualToString:provider])
      continue;
    // Filter by mode: treat empty/missing mode as "asr" for backward compat
    if (mode) {
      NSString *modelMode = model[@"mode"];
      if (!modelMode || modelMode.length == 0)
        modelMode = @"asr";
      if (![modelMode isEqualToString:mode])
        continue;
    }

    NSString *path = model[@"path"];
    NSString *title = model[@"description"] ?: path;

    [self.localModelPopup addItemWithTitle:title];
    [self.localModelPopup lastItem].representedObject = path;
  }

  if (self.localModelPopup.numberOfItems == 0) {
    [self.localModelPopup addItemWithTitle:@"Модели не найдены"];
    self.localModelPopup.enabled = NO;
  } else {
    self.localModelPopup.enabled = YES;
  }
}

- (void)toggleLlmApiKeyVisibility:(NSButton *)sender {
  if (sender.tag == 0) {
    self.llmApiKeyField.stringValue = self.llmApiKeySecureField.stringValue;
    self.llmApiKeySecureField.hidden = YES;
    self.llmApiKeyField.hidden = NO;
    sender.image = [NSImage imageWithSystemSymbolName:@"eye"
                             accessibilityDescription:@"Скрыть"];
    sender.tag = 1;
  } else {
    self.llmApiKeySecureField.stringValue = self.llmApiKeyField.stringValue;
    self.llmApiKeyField.hidden = YES;
    self.llmApiKeySecureField.hidden = NO;
    sender.image = [NSImage imageWithSystemSymbolName:@"eye.slash"
                             accessibilityDescription:@"Показать"];
    sender.tag = 0;
  }
}

- (NSMutableDictionary *)mutableLlmProfileFromDictionary:
    (NSDictionary *)profile {
  NSMutableDictionary *copy =
      [profile mutableCopy] ?: [NSMutableDictionary dictionary];
  NSDictionary *mlx = copy[@"mlx"];
  copy[@"mlx"] = [mlx isKindOfClass:[NSDictionary class]]
                     ? [mlx mutableCopy]
                     : [@{@"model" : @"mlx/Qwen3-0.6B-4bit"} mutableCopy];
  NSString *protocol = [self apiProtocolForLlmProfile:copy];
  copy[@"api_protocol"] = protocol;
  NSString *endpointPath =
      [copy[@"endpoint_path"] isKindOfClass:[NSString class]]
          ? copy[@"endpoint_path"]
          : ([copy[@"chat_completions_path"] isKindOfClass:[NSString class]]
                 ? copy[@"chat_completions_path"]
                 : @"");
  if (endpointPath.length == 0)
    endpointPath = [self defaultEndpointPathForLlmProtocol:protocol];
  copy[@"endpoint_path"] = endpointPath;
  [copy removeObjectForKey:@"chat_completions_path"];
  return copy;
}

- (NSMutableDictionary *)defaultOpenAILlmProfileWithName:(NSString *)name
                                                 protocol:(NSString *)protocol {
  BOOL usesResponses = [protocol isEqualToString:kLlmProtocolOpenAIResponses];
  return [@{
    @"name" : name ?: (usesResponses ? @"OpenAI Responses"
                                     : @"OpenAI Chat Completions"),
    @"provider" : @"openai",
    @"api_protocol" : protocol ?: kLlmProtocolOpenAIChat,
    @"base_url" : @"https://api.openai.com/v1",
    @"api_key" : @"",
    @"model" : @"gpt-5.4-nano",
    @"endpoint_path" : usesResponses ? kDefaultLlmResponsesPath
                                      : kDefaultLlmChatCompletionsPath,
    @"max_token_parameter" : @"max_completion_tokens",
    @"no_reasoning_control" : @"none",
    @"mlx" : @{@"model" : @"mlx/Qwen3-0.6B-4bit"},
  } mutableCopy];
}

- (NSMutableDictionary *)defaultAnthropicLlmProfile {
  return [@{
    @"name" : @"Anthropic Messages",
    @"provider" : @"anthropic",
    @"api_protocol" : kLlmProtocolAnthropicMessages,
    @"base_url" : @"https://api.anthropic.com/v1",
    @"api_key" : @"",
    @"model" : @"",
    @"endpoint_path" : kDefaultLlmAnthropicMessagesPath,
    @"max_token_parameter" : @"max_tokens",
    @"no_reasoning_control" : @"none",
    @"mlx" : @{@"model" : @"mlx/Qwen3-0.6B-4bit"},
  } mutableCopy];
}

- (NSMutableDictionary *)defaultApfelLlmProfile {
  return [@{
    @"name" : @"APFEL",
    @"provider" : @"apfel",
    @"api_protocol" : kLlmProtocolOpenAIChat,
    @"base_url" : @"http://127.0.0.1:11434/v1",
    @"api_key" : @"",
    @"model" : @"apple-foundationmodel",
    @"endpoint_path" : kDefaultLlmChatCompletionsPath,
    @"max_token_parameter" : @"max_tokens",
    @"no_reasoning_control" : @"none",
    @"mlx" : @{@"model" : @"mlx/Qwen3-0.6B-4bit"},
  } mutableCopy];
}

- (NSMutableDictionary *)defaultMlxLlmProfileWithName:(NSString *)name {
  return [@{
    @"name" : name ?: @"MLX (Apple Silicon)",
    @"provider" : @"mlx",
    @"api_protocol" : kLlmProtocolOpenAIChat,
    @"base_url" : @"",
    @"api_key" : @"",
    @"model" : @"",
    @"endpoint_path" : @"",
    @"max_token_parameter" : @"max_completion_tokens",
    @"no_reasoning_control" : @"none",
    @"mlx" : @{@"model" : @"mlx/Qwen3-0.6B-4bit"},
  } mutableCopy];
}

- (NSString *)apiProtocolForLlmProfile:(NSDictionary *)profile {
  NSString *provider = [profile[@"provider"] isKindOfClass:[NSString class]]
                           ? profile[@"provider"]
                           : @"openai";
  if ([provider isEqualToString:@"anthropic"])
    return kLlmProtocolAnthropicMessages;
  if ([provider isEqualToString:@"apfel"] ||
      [provider isEqualToString:@"mlx"])
    return kLlmProtocolOpenAIChat;
  NSString *protocol =
      [profile[@"api_protocol"] isKindOfClass:[NSString class]]
          ? profile[@"api_protocol"]
          : kLlmProtocolOpenAIChat;
  return protocol.length > 0 ? protocol : kLlmProtocolOpenAIChat;
}

- (NSString *)defaultEndpointPathForLlmProtocol:(NSString *)protocol {
  if ([protocol isEqualToString:kLlmProtocolOpenAIResponses])
    return kDefaultLlmResponsesPath;
  if ([protocol isEqualToString:kLlmProtocolAnthropicMessages])
    return kDefaultLlmAnthropicMessagesPath;
  return kDefaultLlmChatCompletionsPath;
}

- (NSString *)prettyNameForLlmProfile:(NSDictionary *)profile {
  NSString *provider = [profile[@"provider"] isKindOfClass:[NSString class]]
                           ? profile[@"provider"]
                           : @"openai";
  if ([provider isEqualToString:@"apfel"])
    return @"APFEL";
  if ([provider isEqualToString:@"mlx"])
    return @"MLX (Apple Silicon)";
  if ([provider isEqualToString:@"anthropic"])
    return @"Anthropic Messages";
  if ([[self apiProtocolForLlmProfile:profile]
          isEqualToString:kLlmProtocolOpenAIResponses])
    return @"OpenAI Responses";
  return @"OpenAI Chat Completions";
}

- (void)loadLlmProfilesFromCore {
  char *raw = sp_llm_profiles_json();
  NSString *jsonStr = raw ? [NSString stringWithUTF8String:raw] : @"";
  if (raw)
    sp_core_free_string(raw);

  NSDictionary *payload = nil;
  if (jsonStr.length > 0) {
    payload = [NSJSONSerialization
        JSONObjectWithData:[jsonStr dataUsingEncoding:NSUTF8StringEncoding]
                   options:0
                     error:nil];
  }

  self.llmProfiles = [NSMutableDictionary dictionary];
  NSDictionary *profiles =
      [payload[@"profiles"] isKindOfClass:[NSDictionary class]]
          ? payload[@"profiles"]
          : nil;
  for (NSString *profileId in profiles) {
    NSDictionary *profile = profiles[profileId];
    if ([profile isKindOfClass:[NSDictionary class]]) {
      self.llmProfiles[profileId] =
          [self mutableLlmProfileFromDictionary:profile];
    }
  }

  if (self.llmProfiles.count == 0) {
    self.llmProfiles[@"openai"] =
        [self defaultOpenAILlmProfileWithName:@"OpenAI Chat Completions"
                                      protocol:kLlmProtocolOpenAIChat];
    self.llmProfiles[@"openai-responses"] =
        [self defaultOpenAILlmProfileWithName:@"OpenAI Responses"
                                      protocol:kLlmProtocolOpenAIResponses];
    self.llmProfiles[@"anthropic"] = [self defaultAnthropicLlmProfile];
    self.llmProfiles[@"apfel"] = [self defaultApfelLlmProfile];
    self.llmProfiles[@"mlx"] =
        [self defaultMlxLlmProfileWithName:@"MLX (Apple Silicon)"];
  }

  NSString *activeProfile =
      [payload[@"active_profile"] isKindOfClass:[NSString class]]
          ? payload[@"active_profile"]
          : @"openai";
  self.activeLlmProfileId = self.llmProfiles[activeProfile]
                                ? activeProfile
                                : self.llmProfiles.allKeys.firstObject;
  [self reloadLlmProfileTable];
  [self applyActiveLlmProfileToFields];
}

- (void)reloadLlmProfileTable {
  self.llmProfileOrder = [[self.llmProfiles.allKeys
      sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]
      mutableCopy];
  BOOL previousSuppress = self.suppressLlmProfileSelection;
  self.suppressLlmProfileSelection = YES;
  [self.llmProfileTableView reloadData];
  NSInteger activeRow =
      [self.llmProfileOrder indexOfObject:self.activeLlmProfileId ?: @""];
  if (activeRow != NSNotFound &&
      activeRow < (NSInteger)self.llmProfileOrder.count) {
    [self.llmProfileTableView
            selectRowIndexes:[NSIndexSet
                                 indexSetWithIndex:(NSUInteger)activeRow]
        byExtendingSelection:NO];
  }
  self.suppressLlmProfileSelection = previousSuppress;
}

- (NSMutableDictionary *)activeLlmProfile {
  if (!self.activeLlmProfileId)
    return nil;
  return self.llmProfiles[self.activeLlmProfileId];
}

- (void)syncActiveLlmProfileFromFields {
  NSMutableDictionary *profile = [self activeLlmProfile];
  if (!profile)
    return;

  // Provider is LOCKED at creation — read it from the profile dict, not UI.
  NSString *provider = [profile[@"provider"] isKindOfClass:[NSString class]]
                           ? profile[@"provider"]
                           : @"openai";
  NSString *name = [self.llmProfileNameField.stringValue
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  if (name.length > 0)
    profile[@"name"] = name;
  profile[@"base_url"] = self.llmBaseUrlField.stringValue ?: @"";
  NSString *apiKey = self.llmApiKeyToggle.tag == 1
                         ? self.llmApiKeyField.stringValue
                         : self.llmApiKeySecureField.stringValue;
  profile[@"api_key"] = apiKey ?: @"";
  profile[@"model"] = self.llmModelField.stringValue ?: @"";
  NSString *endpointPath = [[self.llmChatCompletionsPathField.stringValue ?: @""
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]]
      copy];
  NSString *protocol = [self apiProtocolForLlmProfile:profile];
  profile[@"api_protocol"] = protocol;
  profile[@"endpoint_path"] =
      (endpointPath.length > 0)
          ? endpointPath
          : [self defaultEndpointPathForLlmProtocol:protocol];
  profile[@"max_token_parameter"] =
      self.maxTokenParamPopup.selectedItem.representedObject
          ?: @"max_completion_tokens";
  if (!profile[@"no_reasoning_control"]) {
    profile[@"no_reasoning_control"] = @"none";
  }

  if ([provider isEqualToString:@"mlx"]) {
    NSMutableDictionary *mlx =
        [profile[@"mlx"] isKindOfClass:[NSMutableDictionary class]]
            ? profile[@"mlx"]
            : [@{} mutableCopy];
    NSString *modelPath =
        self.llmLocalModelPopup.selectedItem.representedObject;
    if (modelPath)
      mlx[@"model"] = modelPath;
    profile[@"mlx"] = mlx;
  }
}

- (void)applyActiveLlmProfileToFields {
  NSDictionary *profile = [self activeLlmProfile];
  if (!profile)
    return;

  NSString *provider = [profile[@"provider"] isKindOfClass:[NSString class]]
                           ? profile[@"provider"]
                           : @"openai";
  NSString *name = [profile[@"name"] isKindOfClass:[NSString class]]
                       ? profile[@"name"]
                       : @"";
  self.llmProfileNameField.stringValue = name;
  self.llmProfileTypeLabel.stringValue =
      [self prettyNameForLlmProfile:profile];

  self.llmBaseUrlField.stringValue =
      [profile[@"base_url"] isKindOfClass:[NSString class]]
          ? profile[@"base_url"]
          : @"";
  NSString *apiKey = [profile[@"api_key"] isKindOfClass:[NSString class]]
                         ? profile[@"api_key"]
                         : @"";
  self.llmApiKeySecureField.stringValue = apiKey;
  self.llmApiKeyField.stringValue = apiKey;
  self.llmApiKeySecureField.hidden = NO;
  self.llmApiKeyField.hidden = YES;
  self.llmApiKeyToggle.image = [NSImage imageWithSystemSymbolName:@"eye.slash"
                                         accessibilityDescription:@"Показать"];
  self.llmApiKeyToggle.tag = 0;
  self.llmModelField.stringValue =
      [profile[@"model"] isKindOfClass:[NSString class]] ? profile[@"model"]
                                                         : @"";
  NSString *protocol = [self apiProtocolForLlmProfile:profile];
  NSString *chatPath =
      [profile[@"endpoint_path"] isKindOfClass:[NSString class]]
          ? profile[@"endpoint_path"]
          : [self defaultEndpointPathForLlmProtocol:protocol];
  self.llmChatCompletionsPathField.stringValue =
      chatPath.length > 0 ? chatPath
                          : [self defaultEndpointPathForLlmProtocol:protocol];
  self.llmChatCompletionsPathField.placeholderString =
      [self defaultEndpointPathForLlmProtocol:protocol];

  NSString *maxTokenParam =
      [profile[@"max_token_parameter"] isKindOfClass:[NSString class]]
          ? profile[@"max_token_parameter"]
          : @"max_completion_tokens";
  for (NSInteger i = 0; i < self.maxTokenParamPopup.numberOfItems; i++) {
    if ([[self.maxTokenParamPopup itemAtIndex:i].representedObject
            isEqualToString:maxTokenParam]) {
      [self.maxTokenParamPopup selectItemAtIndex:i];
      break;
    }
  }

  if ([provider isEqualToString:@"mlx"]) {
    [self populateLlmLocalModelPopup];
    NSString *mlxModel = [profile[@"mlx"] isKindOfClass:[NSDictionary class]]
                             ? profile[@"mlx"][@"model"]
                             : nil;
    if (mlxModel.length > 0) {
      for (NSInteger i = 0; i < self.llmLocalModelPopup.numberOfItems; i++) {
        if ([[self.llmLocalModelPopup itemAtIndex:i].representedObject
                isEqualToString:mlxModel]) {
          [self.llmLocalModelPopup selectItemAtIndex:i];
          break;
        }
      }
    }
    [self updateLlmModelStatusLabel];
  } else if (self.llmRemoteModelPickerExpanded) {
    [self refreshLlmRemoteModels:nil];
  }

  [self updateLlmFieldsEnabled];
}

- (NSString *)newLlmProfileIdWithPrefix:(NSString *)prefix {
  NSString *base = prefix ?: @"profile";
  if (!self.llmProfiles[base])
    return base;
  NSInteger index = 2;
  while (self.llmProfiles[
      [NSString stringWithFormat:@"%@-%ld", base, (long)index]]) {
    index++;
  }
  return [NSString stringWithFormat:@"%@-%ld", base, (long)index];
}

- (void)llmProfileNameChanged:(id)sender {
  NSMutableDictionary *profile = [self activeLlmProfile];
  if (!profile)
    return;
  NSString *name = [self.llmProfileNameField.stringValue
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  profile[@"name"] = name.length > 0 ? name : profile[@"name"] ?: @"";
  NSInteger row =
      [self.llmProfileOrder indexOfObject:self.activeLlmProfileId ?: @""];
  if (row != NSNotFound) {
    [self.llmProfileTableView
        reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
                  columnIndexes:[NSIndexSet indexSetWithIndex:0]];
  }
}

- (void)showAddLlmProfileMenu:(id)sender {
  NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
  NSMenuItem *openaiChatItem =
      [[NSMenuItem alloc] initWithTitle:@"OpenAI Chat Completions"
                                 action:@selector(addLlmProfileFromMenu:)
                          keyEquivalent:@""];
  openaiChatItem.target = self;
  openaiChatItem.representedObject = @"openai_chat";
  [menu addItem:openaiChatItem];
  NSMenuItem *openaiResponsesItem =
      [[NSMenuItem alloc] initWithTitle:@"OpenAI Responses"
                                 action:@selector(addLlmProfileFromMenu:)
                          keyEquivalent:@""];
  openaiResponsesItem.target = self;
  openaiResponsesItem.representedObject = @"openai_responses";
  [menu addItem:openaiResponsesItem];
  NSMenuItem *anthropicItem =
      [[NSMenuItem alloc] initWithTitle:@"Anthropic Messages"
                                 action:@selector(addLlmProfileFromMenu:)
                          keyEquivalent:@""];
  anthropicItem.target = self;
  anthropicItem.representedObject = @"anthropic";
  [menu addItem:anthropicItem];
  NSMenuItem *apfelItem =
      [[NSMenuItem alloc] initWithTitle:@"APFEL"
                                 action:@selector(addLlmProfileFromMenu:)
                          keyEquivalent:@""];
  apfelItem.target = self;
  apfelItem.representedObject = @"apfel";
  [menu addItem:apfelItem];
  NSMenuItem *mlxItem =
      [[NSMenuItem alloc] initWithTitle:@"MLX (Apple Silicon)"
                                 action:@selector(addLlmProfileFromMenu:)
                          keyEquivalent:@""];
  mlxItem.target = self;
  mlxItem.representedObject = @"mlx";
  [menu addItem:mlxItem];

  NSButton *button = (NSButton *)sender;
  NSPoint origin = NSMakePoint(0, NSHeight(button.bounds) + 2);
  [menu popUpMenuPositioningItem:nil atLocation:origin inView:button];
}

- (void)addLlmProfileFromMenu:(NSMenuItem *)item {
  NSString *type = item.representedObject;
  if (!type)
    return;
  [self syncActiveLlmProfileFromFields];

  NSString *prefix =
      [type isEqualToString:@"mlx"]
          ? @"mlx"
          : ([type isEqualToString:@"apfel"]
                 ? @"apfel"
                 : ([type isEqualToString:@"anthropic"]
                        ? @"anthropic"
                        : ([type isEqualToString:@"openai_responses"]
                               ? @"openai-responses"
                               : @"openai")));
  NSString *profileId = [self newLlmProfileIdWithPrefix:prefix];
  NSMutableDictionary *profile = nil;
  if ([type isEqualToString:@"apfel"]) {
    profile = [self defaultApfelLlmProfile];
    profile[@"name"] = @"APFEL";
  } else if ([type isEqualToString:@"mlx"]) {
    profile = [self defaultMlxLlmProfileWithName:@"MLX (Apple Silicon)"];
  } else if ([type isEqualToString:@"anthropic"]) {
    profile = [self defaultAnthropicLlmProfile];
  } else if ([type isEqualToString:@"openai_responses"]) {
    profile = [self defaultOpenAILlmProfileWithName:@"OpenAI Responses"
                                            protocol:kLlmProtocolOpenAIResponses];
  } else {
    profile = [self defaultOpenAILlmProfileWithName:@"OpenAI Chat Completions"
                                            protocol:kLlmProtocolOpenAIChat];
  }
  self.llmProfiles[profileId] = profile;
  self.activeLlmProfileId = profileId;
  [self reloadLlmProfileTable];
  [self applyActiveLlmProfileToFields];
  self.llmTestResultLabel.stringValue = @"";
  [self updateLlmFieldsEnabled];
}

- (void)deleteLlmProfile:(id)sender {
  if (self.llmProfiles.count <= 1 || !self.activeLlmProfileId)
    return;
  NSString *oldId = self.activeLlmProfileId;
  [self.llmProfiles removeObjectForKey:oldId];
  self.activeLlmProfileId =
      [self.llmProfiles.allKeys
          sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]
          .firstObject;
  [self reloadLlmProfileTable];
  [self applyActiveLlmProfileToFields];
  self.llmTestResultLabel.stringValue = @"";
  [self updateLlmFieldsEnabled];
}

- (NSDictionary *)runtimeLlmProfileForActiveProfile {
  [self syncActiveLlmProfileFromFields];
  NSMutableDictionary *profile = [[self activeLlmProfile] mutableCopy];
  if (!profile)
    return nil;
  profile[@"id"] = self.activeLlmProfileId ?: @"";
  return profile;
}

// ─── Load / Save ────────────────────────────────────────────────────

- (void)loadCurrentValues {
  [self loadValuesForPane:self.currentPaneIdentifier];
}

- (void)rememberLoadedBooleanValue:(BOOL)value forKey:(NSString *)key {
  self.loadedBooleanValues[key] = @(value);
}

- (BOOL)shouldPersistBooleanValue:(BOOL)value forKey:(NSString *)key {
  NSNumber *loadedValue = self.loadedBooleanValues[key];
  return loadedValue == nil || loadedValue.boolValue != value;
}

- (void)rememberLoadedStringValue:(NSString *)value forKey:(NSString *)key {
  self.loadedStringValues[key] = value ?: @"";
}

/// A string setting is written only when its control now differs from what
/// was loaded into it. A control that was never loaded, or that still shows
/// the loaded value, must not overwrite what config.yaml holds now (the file
/// may have been edited since the pane was built).
- (BOOL)shouldPersistStringValue:(NSString *)value forKey:(NSString *)key {
  NSString *loadedValue = self.loadedStringValues[key];
  return loadedValue != nil && ![loadedValue isEqualToString:value ?: @""];
}

- (BOOL)saveStringValue:(NSString *)value forKey:(NSString *)key {
  if (![self shouldPersistStringValue:value forKey:key])
    return YES;
  BOOL ok = configSet(key, value ?: @"");
  if (ok)
    [self rememberLoadedStringValue:value forKey:key];
  return ok;
}

- (void)loadValuesForPane:(NSString *)identifier {
  NSString *dir = configDirPath();

  if ([identifier isEqualToString:kToolbarASR]) {
    NSString *provider = configGet(@"asr.provider");
    // DoubaoIME was removed; the core reads such a config as Qwen.
    if (provider.length == 0 || [provider isEqualToString:@"doubaoime"])
      provider = @"qwen";
    for (NSInteger i = 0; i < self.asrProviderPopup.numberOfItems; i++) {
      if ([[self.asrProviderPopup itemAtIndex:i].representedObject
              isEqualToString:provider]) {
        [self.asrProviderPopup selectItemAtIndex:i];
        break;
      }
    }
    // Load Doubao fields
    self.asrAppKeyField.stringValue = configGet(@"asr.doubao.app_key");
    NSString *accessKey = configGet(@"asr.doubao.access_key");
    self.asrAccessKeySecureField.stringValue = accessKey;
    self.asrAccessKeyField.stringValue = accessKey;
    // Load Doubao API Key (new console auth)
    NSString *apiKey = configGet(@"asr.doubao.api_key");
    self.asrApiKeySecureField.stringValue = apiKey;
    self.asrApiKeyField.stringValue = apiKey;
    // Select auth mode: if api_key is set, use New Console mode
    if (apiKey.length > 0) {
      [self.asrAuthModeControl setSelectedSegment:0];
    } else if (self.asrAppKeyField.stringValue.length > 0 ||
               accessKey.length > 0) {
      [self.asrAuthModeControl setSelectedSegment:1];
    } else {
      [self.asrAuthModeControl setSelectedSegment:0];
    }
    // Load language (Doubao only)
    NSString *doubaoLang = configGet(@"asr.doubao.language");
    if (doubaoLang.length > 0) {
      BOOL found = NO;
      for (NSInteger i = 0; i < self.asrLanguagePopup.numberOfItems; i++) {
        if ([[self.asrLanguagePopup itemAtIndex:i].representedObject
                isEqualToString:doubaoLang]) {
          [self.asrLanguagePopup selectItemAtIndex:i];
          found = YES;
          break;
        }
      }
      if (!found)
        [self.asrLanguagePopup selectItemAtIndex:0];
    } else {
      [self.asrLanguagePopup selectItemAtIndex:0];
    }
    // Load Doubao advanced settings
    self.asrEndWindowField.stringValue =
        configGet(@"asr.doubao.end_window_size");
    NSString *outputVariant = configGet(@"asr.doubao.output_zh_variant");
    if (outputVariant.length > 0) {
      for (NSInteger i = 0; i < self.asrOutputVariantPopup.numberOfItems; i++) {
        if ([[self.asrOutputVariantPopup itemAtIndex:i].representedObject
                isEqualToString:outputVariant]) {
          [self.asrOutputVariantPopup selectItemAtIndex:i];
          break;
        }
      }
    } else {
      [self.asrOutputVariantPopup selectItemAtIndex:0];
    }
    BOOL accelerate = configBooleanValue(
        configGet(@"asr.doubao.enable_accelerate_text"), NO);
    self.asrAccelerateCheckbox.state =
        accelerate ? NSControlStateValueOn : NSControlStateValueOff;
    [self rememberLoadedBooleanValue:accelerate
                              forKey:@"asr.doubao.enable_accelerate_text"];
    // Restore the advanced-expanded state. The advanced VALUES persist in
    // config, but the disclosure checkbox defaults to collapsed — so reopening
    // Settings hid the section and the settings looked lost (they weren't).
    // If any Doubao advanced value is non-default, pre-check the disclosure so
    // the asrProviderChanged call below unhides the container and resizes.
    BOOL hasAdvancedValues = (self.asrEndWindowField.stringValue.length > 0) ||
                             (outputVariant.length > 0) ||
                             accelerate;
    self.asrAdvancedDisclosure.state =
        hasAdvancedValues ? NSControlStateValueOn : NSControlStateValueOff;
    // Load Qwen fields
    [self loadQwenKeysFromConfig];
    self.asrQwenFieldContextCheckbox.state =
        configBooleanValue(configGet(@"asr.qwen.use_field_context"), YES)
            ? NSControlStateValueOn
            : NSControlStateValueOff;
    [self loadQwenAppModesFromConfig];
    NSString *qwenOutputMode = configGet(@"asr.qwen.output_mode");
    [self.asrQwenOutputModePopup selectItemAtIndex:0];
    for (NSInteger i = 0; i < self.asrQwenOutputModePopup.numberOfItems; i++) {
      if ([[self.asrQwenOutputModePopup itemAtIndex:i].representedObject
              isEqualToString:qwenOutputMode]) {
        [self.asrQwenOutputModePopup selectItemAtIndex:i];
        break;
      }
    }
    self.asrQwenTranslateToField.stringValue =
        configGet(@"asr.qwen.translate_to");
    [self loadQwenModelFromConfig];
    // Load GLM fields
    NSString *glmApiKey = configGet(@"asr.glm.api_key");
    self.asrGlmApiKeySecureField.stringValue = glmApiKey;
    self.asrGlmApiKeyField.stringValue = glmApiKey;
    // Load MiMo fields
    NSString *mimoApiKey = configGet(@"asr.mimo.api_key");
    self.asrMimoApiKeySecureField.stringValue = mimoApiKey;
    self.asrMimoApiKeyField.stringValue = mimoApiKey;
    // Reset visibility based on selected provider
    [self asrProviderChanged:self.asrProviderPopup];
    // Select saved Apple Speech locale (always, so switching to apple-speech
    // shows the right default)
    {
      NSString *locale = configGet(@"asr.apple-speech.locale");
      if (locale.length > 0) {
        // Try exact match first, then fall back to language-equivalent match
        NSInteger exactIdx = -1, equivIdx = -1;
        NSLocale *configLocale = [NSLocale localeWithLocaleIdentifier:locale];
        for (NSInteger i = 0; i < self.appleSpeechLocalePopup.numberOfItems;
             i++) {
          NSString *itemId =
              [self.appleSpeechLocalePopup itemAtIndex:i].representedObject;
          if ([itemId isEqualToString:locale]) {
            exactIdx = i;
            break;
          }
          if (equivIdx < 0) {
            NSLocale *itemLocale = [NSLocale localeWithLocaleIdentifier:itemId];
            if ([configLocale.languageCode
                    isEqualToString:itemLocale.languageCode] &&
                [configLocale.countryCode
                    isEqualToString:itemLocale.countryCode]) {
              equivIdx = i;
            }
          }
        }
        NSInteger matchIdx = (exactIdx >= 0) ? exactIdx : equivIdx;
        if (matchIdx >= 0) {
          [self.appleSpeechLocalePopup selectItemAtIndex:matchIdx];
          [self updateAppleSpeechAssetStatus];
        }
      }
    }
    // Select current local model if applicable
    NSString *currentModel = nil;
    if ([provider isEqualToString:@"mlx"]) {
      currentModel = configGet(@"asr.mlx.model");
    } else if ([provider isEqualToString:@"sherpa-onnx"]) {
      currentModel = configGet(@"asr.sherpa-onnx.model");
    } else if ([provider isEqualToString:@"wetype"]) {
      currentModel = configGet(@"asr.wetype.model");
    }
    if (currentModel.length > 0) {
      for (NSInteger i = 0; i < self.localModelPopup.numberOfItems; i++) {
        if ([[self.localModelPopup itemAtIndex:i].representedObject
                isEqualToString:currentModel]) {
          [self.localModelPopup selectItemAtIndex:i];
          break;
        }
      }
      [self updateModelStatusLabel];
    }
    // Clear test result when loading
    self.asrTestResultLabel.stringValue = @"";
    self.asrTestButton.enabled = YES;
  } else if ([identifier isEqualToString:kToolbarLLM]) {
    BOOL enabled = configBooleanValue(configGet(@"llm.enabled"), YES);
    self.llmEnabledCheckbox.state =
        enabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self rememberLoadedBooleanValue:enabled forKey:@"llm.enabled"];

    // auto_paste_processed_text defaults to true when unset.
    NSString *autoPaste = configGet(@"llm.auto_paste_processed_text");
    BOOL autoPasteEnabled = ![autoPaste isEqualToString:@"false"];
    self.llmAutoPasteProcessedTextSwitch.state =
        autoPasteEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self rememberLoadedBooleanValue:autoPasteEnabled
                              forKey:@"llm.auto_paste_processed_text"];

    [self loadLlmProfilesFromCore];
    self.llmTestResultLabel.stringValue = @"";
    [self updateLlmFieldsEnabled];
  } else if ([identifier isEqualToString:kToolbarOverlay]) {
    NSString *fontFamilyRaw = configGet(@"overlay.font_family");
    NSString *fontSizeRaw = configGet(@"overlay.font_size");
    NSString *bottomMarginRaw = configGet(@"overlay.bottom_margin");
    NSString *limitVisibleLinesRaw = configGet(@"overlay.limit_visible_lines");
    NSString *maxVisibleLinesRaw = configGet(@"overlay.max_visible_lines");
    NSString *fontFamily = fontFamilyRaw.length > 0
                               ? normalizedOverlayFontFamilyValue(fontFamilyRaw)
                               : kOverlayFontFamilyDefault;
    NSInteger fontSize =
        fontSizeRaw.length > 0
            ? clampedOverlayFontSizeValue(fontSizeRaw.integerValue)
            : kOverlayFontSizeDefault;
    NSInteger bottomMargin =
        bottomMarginRaw.length > 0
            ? clampedOverlayBottomMarginValue(bottomMarginRaw.integerValue)
            : kOverlayBottomMarginDefault;
    BOOL limitVisibleLines = configBooleanValue(
        limitVisibleLinesRaw, kOverlayLimitVisibleLinesDefault);
    NSInteger maxVisibleLines = maxVisibleLinesRaw.length > 0
                                    ? clampedOverlayMaxVisibleLinesValue(
                                          maxVisibleLinesRaw.integerValue)
                                    : kOverlayMaxVisibleLinesDefault;

    [self selectOverlayFontFamilyValue:fontFamily];
    self.overlayFontSizeSlider.integerValue = fontSize;
    self.overlayBottomMarginSlider.integerValue = bottomMargin;
    self.overlayLimitVisibleLinesSwitch.state =
        limitVisibleLines ? NSControlStateValueOn : NSControlStateValueOff;
    [self rememberLoadedBooleanValue:limitVisibleLines
                              forKey:@"overlay.limit_visible_lines"];
    [self selectOverlayMaxVisibleLinesValue:maxVisibleLines];
    [self syncOverlayPreviewFromControls];
  } else if ([identifier isEqualToString:kToolbarHotkey]) {
    NSString *triggerKeyRaw = configGet(@"hotkey.trigger_key");
    NSString *triggerKey = normalizedHotkeyValue(triggerKeyRaw);

    [self selectHotkeyValue:triggerKey inPopup:self.hotkeyPopup];

    // Load trigger mode
    NSString *triggerMode = configGet(@"hotkey.trigger_mode");
    if ([triggerMode isEqualToString:@"double_tap"]) {
      [self.triggerModePopup selectItemAtIndex:2];
    } else if ([triggerMode isEqualToString:@"toggle"]) {
      [self.triggerModePopup selectItemAtIndex:1];
    } else if ([triggerMode isEqualToString:@"auto"]) {
      [self.triggerModePopup selectItemAtIndex:3];
    } else {
      [self.triggerModePopup selectItemAtIndex:0];
    }

    BOOL startSound =
        configBooleanValue(configGet(@"feedback.start_sound"), NO);
    BOOL stopSound =
        configBooleanValue(configGet(@"feedback.stop_sound"), NO);
    BOOL errorSound =
        configBooleanValue(configGet(@"feedback.error_sound"), NO);
    BOOL muteSystemOutput =
        configBooleanValue(configGet(@"feedback.mute_system_output"), NO);
    BOOL autoReturn = configBooleanValue(configGet(@"paste.auto_return"), NO);
    [self selectExtraHotkeyValue:configGet(@"hotkey.translate_key")
                         inPopup:self.translateKeyPopup];
    [self selectExtraHotkeyValue:configGet(@"hotkey.ask_key")
                         inPopup:self.askKeyPopup];
    char *abortKeyJSON = sp_config_get_json("hotkey.abort_key");
    BOOL abortKeyIsSet = abortKeyJSON && abortKeyJSON[0] != '\0';
    if (abortKeyJSON)
      sp_core_free_string(abortKeyJSON);
    [self selectAbortKeyValue:configGet(@"hotkey.abort_key")
                        isSet:abortKeyIsSet
                      inPopup:self.abortKeyPopup];
    [self selectExtraHotkeyValue:configGet(@"hotkey.mode_key")
                         inPopup:self.modeKeyPopup];
    [self selectExtraHotkeyValue:configGet(@"hotkey.edit_key")
                         inPopup:self.editKeyPopup];
    [self selectExtraHotkeyValue:configGet(@"hotkey.undo_key")
                         inPopup:self.undoKeyPopup];
    [self selectExtraHotkeyValue:configGet(@"hotkey.repaste_key")
                         inPopup:self.repasteKeyPopup];
    [self selectValue:configGet(@"hotkey.mouse_button")
              inPopup:self.mouseButtonPopup
          customTitle:^NSString *(NSString *value) {
            return [NSString stringWithFormat:@"Кнопка %@", value];
          }];
    [self selectValue:configGet(@"recording.auto_stop_silence_s")
              inPopup:self.autoStopSilencePopup
          customTitle:^NSString *(NSString *value) {
            return [NSString stringWithFormat:@"%@ с", value];
          }];
    [self selectValue:configGet(@"recording.max_duration_s")
              inPopup:self.recordingCapPopup
          customTitle:^NSString *(NSString *value) {
            return [NSString stringWithFormat:@"%@ с", value];
          }];
    BOOL voiceCommands = configBooleanValue(configGet(@"commands.enabled"), YES);
    self.voiceCommandsSwitch.state =
        voiceCommands ? NSControlStateValueOn : NSControlStateValueOff;
    [self rememberLoadedBooleanValue:voiceCommands forKey:@"commands.enabled"];
    // Snapshot what the popups show now; saving writes only what changes.
    [self rememberLoadedStringValue:self.modeKeyPopup.selectedItem.representedObject ?: @""
                             forKey:@"hotkey.mode_key"];
    [self rememberLoadedStringValue:self.editKeyPopup.selectedItem.representedObject ?: @""
                             forKey:@"hotkey.edit_key"];
    [self rememberLoadedStringValue:self.undoKeyPopup.selectedItem.representedObject ?: @""
                             forKey:@"hotkey.undo_key"];
    [self rememberLoadedStringValue:self.repasteKeyPopup.selectedItem.representedObject ?: @""
                             forKey:@"hotkey.repaste_key"];
    [self rememberLoadedStringValue:self.mouseButtonPopup.selectedItem.representedObject ?: @"0"
                             forKey:@"hotkey.mouse_button"];
    [self rememberLoadedStringValue:self.autoStopSilencePopup.selectedItem.representedObject ?: @"0"
                             forKey:@"recording.auto_stop_silence_s"];
    [self rememberLoadedStringValue:self.recordingCapPopup.selectedItem.representedObject ?: @"0"
                             forKey:@"recording.max_duration_s"];
    [self rememberLoadedStringValue:self.hotkeyPopup.selectedItem.representedObject ?: @"fn"
                             forKey:@"hotkey.trigger_key"];
    [self rememberLoadedStringValue:self.triggerModePopup.selectedItem.representedObject ?: @"hold"
                             forKey:@"hotkey.trigger_mode"];
    [self rememberLoadedStringValue:self.translateKeyPopup.selectedItem.representedObject ?: @""
                             forKey:@"hotkey.translate_key"];
    [self rememberLoadedStringValue:self.askKeyPopup.selectedItem.representedObject ?: @""
                             forKey:@"hotkey.ask_key"];
    [self rememberLoadedStringValue:self.abortKeyPopup.selectedItem.representedObject ?: @"escape"
                             forKey:@"hotkey.abort_key"];
    NSArray<NSArray *> *extraSwitches = @[
      @[ self.mediaPlayPauseSwitch, @"hotkey.media_play_pause" ],
      @[ self.keepLastDictationSwitch, @"clipboard.keep_last_dictation" ],
      @[ self.pasteAsrFirstSwitch, @"experimental.paste_asr_first" ],
      @[ self.streamingInsertSwitch, @"experimental.streaming_insert" ],
      @[ self.liveInsertSwitch, @"experimental.live_insert" ],
      @[ self.keepMicWarmSwitch, @"experimental.keep_mic_warm" ],
      @[ self.lipflowSwitch, @"experimental.lipflow" ],
    ];
    for (NSArray *entry in extraSwitches) {
      NSString *key = entry[1];
      BOOL value = configBooleanValue(configGet(key), NO);
      ((NSSwitch *)entry[0]).state =
          value ? NSControlStateValueOn : NSControlStateValueOff;
      [self rememberLoadedBooleanValue:value forKey:key];
    }
    BOOL saveRecordings =
        configBooleanValue(configGet(@"history.save_recordings"), YES);
    self.saveRecordingsSwitch.state =
        saveRecordings ? NSControlStateValueOn : NSControlStateValueOff;
    [self rememberLoadedBooleanValue:saveRecordings
                              forKey:@"history.save_recordings"];
    BOOL autoRetry =
        configBooleanValue(configGet(@"history.auto_retry_on_error"), YES);
    self.autoRetryOnErrorSwitch.state =
        autoRetry ? NSControlStateValueOn : NSControlStateValueOff;
    [self rememberLoadedBooleanValue:autoRetry
                              forKey:@"history.auto_retry_on_error"];
    BOOL lipdataOn = configBooleanValue(configGet(@"lipdata.capture_video"), NO);
    self.lipdataCaptureSwitch.state =
        lipdataOn ? NSControlStateValueOn : NSControlStateValueOff;
    [self rememberLoadedBooleanValue:lipdataOn forKey:@"lipdata.capture_video"];
    BOOL contributeOn = configBooleanValue(configGet(@"training.contribute"), NO);
    self.trainingContributeSwitch.state =
        contributeOn ? NSControlStateValueOn : NSControlStateValueOff;
    [self rememberLoadedBooleanValue:contributeOn forKey:@"training.contribute"];
    [self refreshLipdataCounter];
    [self refreshLipsModeRow];
    NSString *retentionRaw = configGet(@"history.recordings_retention_days");
    NSInteger retention = retentionRaw.length > 0 ? retentionRaw.integerValue
                                                  : kRecordingsRetentionDefault;
    [self setRecordingsRetentionValue:retention];
    self.loadedRecordingsRetentionDays = [self recordingsRetentionValue];
    self.startSoundCheckbox.state =
        startSound ? NSControlStateValueOn : NSControlStateValueOff;
    self.stopSoundCheckbox.state =
        stopSound ? NSControlStateValueOn : NSControlStateValueOff;
    self.errorSoundCheckbox.state =
        errorSound ? NSControlStateValueOn : NSControlStateValueOff;
    self.muteSystemOutputCheckbox.state =
        muteSystemOutput ? NSControlStateValueOn : NSControlStateValueOff;
    self.autoReturnSwitch.state =
        autoReturn ? NSControlStateValueOn : NSControlStateValueOff;
    [self rememberLoadedBooleanValue:startSound
                              forKey:@"feedback.start_sound"];
    [self rememberLoadedBooleanValue:stopSound
                              forKey:@"feedback.stop_sound"];
    [self rememberLoadedBooleanValue:errorSound
                              forKey:@"feedback.error_sound"];
    [self rememberLoadedBooleanValue:muteSystemOutput
                              forKey:@"feedback.mute_system_output"];
    [self rememberLoadedBooleanValue:autoReturn forKey:@"paste.auto_return"];
  } else if ([identifier isEqualToString:kToolbarSnippets]) {
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    id stored = configGetJSON(@"snippets");
    if ([stored isKindOfClass:[NSArray class]]) {
      for (id entry in stored) {
        if (![entry isKindOfClass:[NSDictionary class]])
          continue;
        NSString *trigger = [entry[@"trigger"] isKindOfClass:[NSString class]] ? entry[@"trigger"] : @"";
        NSString *text = [entry[@"text"] isKindOfClass:[NSString class]] ? entry[@"text"] : @"";
        [entries addObject:@{@"trigger" : trigger, @"text" : text}];
      }
    }
    [self setSnippetEntries:entries];
    self.loadedSnippetsSignature = [self signatureForSnippets:[self snippetsForSave]];
  } else if ([identifier isEqualToString:kToolbarDictionary]) {
    NSString *dictPath = [dir stringByAppendingPathComponent:kDictionaryFile];
    NSString *dictContent =
        [NSString stringWithContentsOfFile:dictPath
                                  encoding:NSUTF8StringEncoding
                                     error:nil]
            ?: @"";
    [self.dictionaryTextView setString:dictContent];
    self.loadedDictionaryContent = dictContent;
  } else if ([identifier isEqualToString:kToolbarSystemPrompt]) {
    NSString *promptPath =
        [dir stringByAppendingPathComponent:kSystemPromptFile];
    NSString *promptContent =
        [NSString stringWithContentsOfFile:promptPath
                                  encoding:NSUTF8StringEncoding
                                     error:nil]
            ?: @"";
    [self.systemPromptTextView setString:promptContent];
    self.loadedSystemPromptContent = promptContent;
  } else if ([identifier isEqualToString:kToolbarTemplates]) {
    BOOL templatesEnabled = configBooleanValue(
        configGet(@"llm.prompt_templates_enabled"), NO);
    self.templatesEnabledSwitch.state =
        templatesEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self rememberLoadedBooleanValue:templatesEnabled
                              forKey:@"llm.prompt_templates_enabled"];

    NSArray *templates = [self.rustBridge promptTemplates];
    self.templatesData = [NSMutableArray array];
    for (NSDictionary *t in templates) {
      NSMutableDictionary *templateData =
          [t mutableCopy] ?: [NSMutableDictionary dictionary];
      if (![templateData[@"enabled"] isKindOfClass:[NSNumber class]]) {
        templateData[@"enabled"] = @YES;
      }
      NSString *resolvedPrompt =
          [self resolvedPromptTextForTemplate:templateData];
      templateData[kTemplateEditablePromptKey] = resolvedPrompt ?: @"";
      templateData[kTemplateOriginalPromptKey] = resolvedPrompt ?: @"";
      [self.templatesData addObject:templateData];
    }
    [self reindexTemplateShortcuts];
    [self reloadTemplateTableSelectingRow:(self.templatesData.count > 0 ? 0
                                                                        : -1)];
    self.loadedTemplatesSnapshot = [[self serializedTemplatesData] copy];
  }
}

- (void)saveConfig:(id)sender {
  [self endHotkeyRecording];

  // Warn if a local provider is selected but assets/models are not installed
  if (self.asrProviderPopup) {
    NSString *provider =
        self.asrProviderPopup.selectedItem.representedObject ?: @"qwen";
    // Check Apple Speech asset status
    if ([provider isEqualToString:@"apple-speech"]) {
      NSString *locale =
          self.appleSpeechLocalePopup.selectedItem.representedObject;
      int32_t assetStatus = sp_apple_speech_asset_status(locale.UTF8String);
      if (assetStatus != 3) { // not installed
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Речевые ресурсы не установлены";
        alert.informativeText =
            @"Речевая модель для выбранного языка ещё не скачана. При "
            @"сохранении скачивание начнётся автоматически.";
        [alert addButtonWithTitle:@"Сохранить и скачать"];
        [alert addButtonWithTitle:@"Отмена"];
        alert.alertStyle = NSAlertStyleWarning;
        if ([alert runModal] != NSAlertFirstButtonReturn) {
          return;
        }
        // Trigger background download immediately
        [self downloadAppleSpeechAsset];
      }
    }
    // Check model-based local provider model status
    BOOL isModelBasedLocal = ![provider isEqualToString:@"doubao"] &&
                             ![provider isEqualToString:@"qwen"] &&
                             ![provider isEqualToString:@"glm"] &&
                             ![provider isEqualToString:@"mimo"] &&
                             ![provider isEqualToString:@"apple-speech"];
    if (isModelBasedLocal) {
      NSString *modelPath = self.localModelPopup.selectedItem.representedObject;
      if (modelPath) {
        NSInteger status = [self.rustBridge modelStatus:modelPath
                                                   mode:SPModelVerifyCacheOnly];
        if (status != 2) { // not installed
          NSAlert *alert = [[NSAlert alloc] init];
          alert.messageText = @"Модель не установлена";
          alert.informativeText =
              @"Выбранная модель ещё не скачана. Пока она не установлена, "
              @"распознавание работать не будет.";
          [alert addButtonWithTitle:@"Всё равно сохранить"];
          [alert addButtonWithTitle:@"Отмена"];
          alert.alertStyle = NSAlertStyleWarning;
          if ([alert runModal] != NSAlertFirstButtonReturn) {
            return;
          }
        }
      }
    }
  }

  NSString *dir = configDirPath();

  // Ensure directory exists
  [[NSFileManager defaultManager] createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];

  NSArray<NSDictionary *> *serializedTemplates = nil;
  if (self.templatesData) {
    [self saveCurrentTemplateEdits];
    NSArray<NSDictionary *> *currentTemplates = [self serializedTemplatesData];
    if (!self.loadedTemplatesSnapshot ||
        ![currentTemplates isEqualToArray:self.loadedTemplatesSnapshot]) {
      NSString *templateError = nil;
      if (![self validateTemplatesDataWithMessage:&templateError]) {
        [self showAlert:@"Некорректные шаблоны промптов"
                   info:templateError ?: @"Проверьте шаблоны и повторите попытку."];
        return;
      }
      serializedTemplates = currentTemplates;
    }
  }

  NSString *configPath = configFilePath();
  BOOL configExisted =
      [[NSFileManager defaultManager] fileExistsAtPath:configPath];
  NSString *originalConfigSnapshot =
      [NSString stringWithContentsOfFile:configPath
                                encoding:NSUTF8StringEncoding
                                   error:nil]
          ?: @"";
  __block BOOL shouldRollbackConfig = NO;
  void (^rollbackConfigIfNeeded)(void) = ^{
    if (!shouldRollbackConfig)
      return;

    NSError *rollbackError = nil;
    if (!restoreConfigSnapshot(originalConfigSnapshot, configExisted,
                               &rollbackError)) {
      NSLog(@"[VelikiyMoguchiy] Failed to restore config snapshot: %@",
            rollbackError.localizedDescription);
    }
    [self.rustBridge reloadConfig];
  };

  // Track whether any config write fails
  shouldRollbackConfig = YES;
  BOOL saveOk = YES;

  // Update ASR fields (always save — fields may be nil if pane not visited,
  // check first)
  if (self.asrAppKeyField) {
    NSString *selectedProvider =
        self.asrProviderPopup.selectedItem.representedObject ?: @"qwen";
    saveOk &= configSet(@"asr.provider", selectedProvider);
    // Save Doubao fields based on auth mode
    BOOL isNewConsoleMode = (self.asrAuthModeControl.selectedSegment == 0);
    if (isNewConsoleMode) {
      NSString *apiKey = self.asrApiKeyToggle.tag == 1
                             ? self.asrApiKeyField.stringValue
                             : self.asrApiKeySecureField.stringValue;
      saveOk &= configSet(@"asr.doubao.api_key", apiKey);
      saveOk &= configSet(@"asr.doubao.app_key", @"");
      saveOk &= configSet(@"asr.doubao.access_key", @"");
    } else {
      saveOk &= configSet(@"asr.doubao.api_key", @"");
      saveOk &=
          configSet(@"asr.doubao.app_key", self.asrAppKeyField.stringValue);
      NSString *accessKey = self.asrAccessKeyToggle.tag == 1
                                ? self.asrAccessKeyField.stringValue
                                : self.asrAccessKeySecureField.stringValue;
      saveOk &= configSet(@"asr.doubao.access_key", accessKey);
    }
    // Save language only when Doubao is selected
    if ([selectedProvider isEqualToString:@"doubao"]) {
      NSString *langValue =
          self.asrLanguagePopup.selectedItem.representedObject ?: @"";
      saveOk &= configSet(@"asr.doubao.language", langValue);
    }
    // Save Doubao advanced settings only when Doubao is selected
    if ([selectedProvider isEqualToString:@"doubao"]) {
      NSString *endWindowValue = self.asrEndWindowField.stringValue;
      saveOk &= configSet(@"asr.doubao.end_window_size",
                          endWindowValue.length > 0 ? endWindowValue : @"");
      NSString *variantValue =
          self.asrOutputVariantPopup.selectedItem.representedObject ?: @"";
      saveOk &= configSet(@"asr.doubao.output_zh_variant", variantValue);
      NSString *accelerateValue =
          (self.asrAccelerateCheckbox.state == NSControlStateValueOn)
              ? @"true"
              : @"false";
      if ([self shouldPersistBooleanValue:
                    self.asrAccelerateCheckbox.state == NSControlStateValueOn
                                  forKey:@"asr.doubao.enable_accelerate_text"]) {
        saveOk &=
            configSet(@"asr.doubao.enable_accelerate_text", accelerateValue);
      }
    }
    // Save Qwen fields
    NSArray<NSString *> *qwenKeys = [self currentQwenKeys];
    saveOk &= configSetJSON(@"asr.qwen.api_keys", qwenKeys);
    saveOk &= configSet(@"asr.qwen.api_key", qwenKeys.firstObject ?: @"");
    saveOk &= configSet(@"asr.qwen.use_field_context",
                        self.asrQwenFieldContextCheckbox.state ==
                                NSControlStateValueOn
                            ? @"true"
                            : @"false");
    saveOk &= configSetJSON(@"asr.qwen.app_modes", [self qwenAppModesForSave]);
    if ([selectedProvider isEqualToString:@"qwen"]) {
      NSString *qwenModel = [self selectedQwenModel];
      if (qwenModel && ![qwenModel isEqualToString:self.asrQwenLoadedModel]) {
        saveOk &= configSet(@"asr.qwen.model", qwenModel);
        if (saveOk) self.asrQwenLoadedModel = qwenModel;
      }
      saveOk &= configSet(
          @"asr.qwen.output_mode",
          self.asrQwenOutputModePopup.selectedItem.representedObject ?: @"raw");
      NSString *translateTo = [self.asrQwenTranslateToField.stringValue
          stringByTrimmingCharactersInSet:[NSCharacterSet
                                              whitespaceAndNewlineCharacterSet]];
      if (translateTo.length > 0) {
        saveOk &= configSet(@"asr.qwen.translate_to", translateTo);
      }
    }
    // Save GLM fields
    NSString *glmApiKey = self.asrGlmApiKeyToggle.tag == 1
                              ? self.asrGlmApiKeyField.stringValue
                              : self.asrGlmApiKeySecureField.stringValue;
    saveOk &= configSet(@"asr.glm.api_key", glmApiKey);
    // Save MiMo fields
    NSString *mimoApiKey = self.asrMimoApiKeyToggle.tag == 1
                               ? self.asrMimoApiKeyField.stringValue
                               : self.asrMimoApiKeySecureField.stringValue;
    saveOk &= configSet(@"asr.mimo.api_key", mimoApiKey);
    // Save Apple Speech locale
    if ([selectedProvider isEqualToString:@"apple-speech"]) {
      NSString *locale =
          self.appleSpeechLocalePopup.selectedItem.representedObject;
      saveOk &= configSet(@"asr.apple-speech.locale", locale);
    }
    // Save local model selection
    if ([selectedProvider isEqualToString:@"mlx"]) {
      NSString *modelPath = self.localModelPopup.selectedItem.representedObject;
      if (modelPath)
        saveOk &= configSet(@"asr.mlx.model", modelPath);
    } else if ([selectedProvider isEqualToString:@"sherpa-onnx"]) {
      NSString *modelPath = self.localModelPopup.selectedItem.representedObject;
      if (modelPath)
        saveOk &= configSet(@"asr.sherpa-onnx.model", modelPath);
    } else if ([selectedProvider isEqualToString:@"wetype"]) {
      NSString *modelPath = self.localModelPopup.selectedItem.representedObject;
      if (modelPath)
        saveOk &= configSet(@"asr.wetype.model", modelPath);
    }
  }

  // Update LLM fields
  if (self.llmEnabledCheckbox) {
    NSString *enabledStr =
        (self.llmEnabledCheckbox.state == NSControlStateValueOn) ? @"true"
                                                                 : @"false";
    if ([self shouldPersistBooleanValue:
                  self.llmEnabledCheckbox.state == NSControlStateValueOn
                                forKey:@"llm.enabled"]) {
      saveOk &= configSet(@"llm.enabled", enabledStr);
    }
    BOOL autoPasteProcessedText =
        self.llmAutoPasteProcessedTextSwitch.state == NSControlStateValueOn;
    if ([self shouldPersistBooleanValue:autoPasteProcessedText
                                 forKey:@"llm.auto_paste_processed_text"]) {
      saveOk &= configSet(@"llm.auto_paste_processed_text",
                          autoPasteProcessedText ? @"true" : @"false");
    }

    [self syncActiveLlmProfileFromFields];
    NSDictionary *payload = @{
      @"active_profile" : self.activeLlmProfileId ?: @"openai",
      @"profiles" : self.llmProfiles ?: @{},
    };
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload
                                                       options:0
                                                         error:nil];
    NSString *json = jsonData
                         ? [[NSString alloc] initWithData:jsonData
                                                 encoding:NSUTF8StringEncoding]
                         : nil;
    if (!json || sp_llm_save_profiles_json(json.UTF8String) != 0) {
      saveOk = NO;
    }
  }

  // Update hotkey. Each key is written only if its control changed since the
  // pane was loaded: the controls hold a snapshot, and config.yaml may have
  // been edited by hand (or by another window) in the meantime.
  if (self.hotkeyPopup) {
    NSString *selectedTriggerHotkey = normalizedHotkeyValue(
        self.hotkeyPopup.selectedItem.representedObject ?: @"fn");
    saveOk &= [self saveStringValue:selectedTriggerHotkey
                             forKey:@"hotkey.trigger_key"];
    saveOk &= [self saveStringValue:self.triggerModePopup.selectedItem
                                        .representedObject ?: @"hold"
                             forKey:@"hotkey.trigger_mode"];
    saveOk &= [self saveStringValue:self.translateKeyPopup.selectedItem
                                        .representedObject ?: @""
                             forKey:@"hotkey.translate_key"];
    saveOk &= [self saveStringValue:self.askKeyPopup.selectedItem
                                        .representedObject ?: @""
                             forKey:@"hotkey.ask_key"];
    saveOk &= [self saveStringValue:self.abortKeyPopup.selectedItem
                                        .representedObject ?: @"escape"
                             forKey:@"hotkey.abort_key"];
    saveOk &= [self saveStringValue:self.modeKeyPopup.selectedItem
                                        .representedObject ?: @""
                             forKey:@"hotkey.mode_key"];
    saveOk &= [self saveStringValue:self.editKeyPopup.selectedItem
                                        .representedObject ?: @""
                             forKey:@"hotkey.edit_key"];
    saveOk &= [self saveStringValue:self.undoKeyPopup.selectedItem
                                        .representedObject ?: @""
                             forKey:@"hotkey.undo_key"];
    saveOk &= [self saveStringValue:self.repasteKeyPopup.selectedItem
                                        .representedObject ?: @""
                             forKey:@"hotkey.repaste_key"];
    saveOk &= [self saveStringValue:self.mouseButtonPopup.selectedItem
                                        .representedObject ?: @"0"
                             forKey:@"hotkey.mouse_button"];
    saveOk &= [self saveStringValue:self.autoStopSilencePopup.selectedItem
                                        .representedObject ?: @"0"
                             forKey:@"recording.auto_stop_silence_s"];
    saveOk &= [self saveStringValue:self.recordingCapPopup.selectedItem
                                        .representedObject ?: @"0"
                             forKey:@"recording.max_duration_s"];
  }
  if (self.voiceCommandsSwitch) {
    BOOL value = self.voiceCommandsSwitch.state == NSControlStateValueOn;
    if ([self shouldPersistBooleanValue:value forKey:@"commands.enabled"]) {
      saveOk &= configSet(@"commands.enabled", value ? @"true" : @"false");
    }
  }
  if (self.snippetRows) {
    NSArray<NSDictionary *> *snippets = [self snippetsForSave];
    NSString *signature = [self signatureForSnippets:snippets];
    if (![signature isEqualToString:self.loadedSnippetsSignature ?: @""]) {
      saveOk &= configSetJSON(@"snippets", snippets);
      if (saveOk)
        self.loadedSnippetsSignature = signature;
    }
  }
  if (self.mediaPlayPauseSwitch) {
    NSArray<NSArray *> *extraSwitches = @[
      @[ self.mediaPlayPauseSwitch, @"hotkey.media_play_pause" ],
      @[ self.keepLastDictationSwitch, @"clipboard.keep_last_dictation" ],
      @[ self.pasteAsrFirstSwitch, @"experimental.paste_asr_first" ],
      @[ self.streamingInsertSwitch, @"experimental.streaming_insert" ],
      @[ self.liveInsertSwitch, @"experimental.live_insert" ],
      @[ self.keepMicWarmSwitch, @"experimental.keep_mic_warm" ],
      @[ self.lipflowSwitch, @"experimental.lipflow" ],
    ];
    for (NSArray *entry in extraSwitches) {
      NSString *key = entry[1];
      BOOL value = ((NSSwitch *)entry[0]).state == NSControlStateValueOn;
      if ([self shouldPersistBooleanValue:value forKey:key]) {
        saveOk &= configSet(key, value ? @"true" : @"false");
      }
    }
  }
  if (self.saveRecordingsSwitch) {
    BOOL value = self.saveRecordingsSwitch.state == NSControlStateValueOn;
    if ([self shouldPersistBooleanValue:value forKey:@"history.save_recordings"]) {
      saveOk &= configSet(@"history.save_recordings", value ? @"true" : @"false");
    }
    BOOL autoRetry = self.autoRetryOnErrorSwitch.state == NSControlStateValueOn;
    if ([self shouldPersistBooleanValue:autoRetry forKey:@"history.auto_retry_on_error"]) {
      saveOk &= configSet(@"history.auto_retry_on_error", autoRetry ? @"true" : @"false");
    }
    BOOL lipdata = self.lipdataCaptureSwitch.state == NSControlStateValueOn;
    if ([self shouldPersistBooleanValue:lipdata forKey:@"lipdata.capture_video"]) {
      saveOk &= configSet(@"lipdata.capture_video", lipdata ? @"true" : @"false");
    }
    BOOL contribute = self.trainingContributeSwitch.state == NSControlStateValueOn;
    if ([self shouldPersistBooleanValue:contribute forKey:@"training.contribute"]) {
      saveOk &= configSet(@"training.contribute", contribute ? @"true" : @"false");
    }
    NSInteger retention = [self recordingsRetentionValue];
    if (retention != self.loadedRecordingsRetentionDays) {
      saveOk &= configSet(@"history.recordings_retention_days",
                          [NSString stringWithFormat:@"%ld", (long)retention]);
      self.loadedRecordingsRetentionDays = retention;
    }
  }
  if (self.overlayFontSizeSlider) {
    NSString *fontFamily = [self selectedOverlayFontFamilyValue];
    NSInteger fontSize = clampedOverlayFontSizeValue(
        lround(self.overlayFontSizeSlider.doubleValue));
    NSInteger bottomMargin = clampedOverlayBottomMarginValue(
        lround(self.overlayBottomMarginSlider.doubleValue));
    BOOL limitVisibleLines =
        self.overlayLimitVisibleLinesSwitch.state == NSControlStateValueOn;
    NSInteger maxVisibleLines = [self selectedOverlayMaxVisibleLinesValue];
    saveOk &= configSet(@"overlay.font_family", fontFamily);
    saveOk &= configSet(@"overlay.font_size",
                        [NSString stringWithFormat:@"%ld", (long)fontSize]);
    saveOk &= configSet(@"overlay.bottom_margin",
                        [NSString stringWithFormat:@"%ld", (long)bottomMargin]);
    if ([self shouldPersistBooleanValue:limitVisibleLines
                                 forKey:@"overlay.limit_visible_lines"]) {
      saveOk &= configSet(@"overlay.limit_visible_lines",
                          limitVisibleLines ? @"true" : @"false");
    }
    saveOk &=
        configSet(@"overlay.max_visible_lines",
                  [NSString stringWithFormat:@"%ld", (long)maxVisibleLines]);
  }
  if (self.startSoundCheckbox) {
    NSString *startSound =
        (self.startSoundCheckbox.state == NSControlStateValueOn) ? @"true"
                                                                 : @"false";
    NSString *stopSound =
        (self.stopSoundCheckbox.state == NSControlStateValueOn) ? @"true"
                                                                : @"false";
    NSString *errorSound =
        (self.errorSoundCheckbox.state == NSControlStateValueOn) ? @"true"
                                                                 : @"false";
    if ([self shouldPersistBooleanValue:
                  self.startSoundCheckbox.state == NSControlStateValueOn
                                forKey:@"feedback.start_sound"]) {
      saveOk &= configSet(@"feedback.start_sound", startSound);
    }
    if ([self shouldPersistBooleanValue:
                  self.stopSoundCheckbox.state == NSControlStateValueOn
                                forKey:@"feedback.stop_sound"]) {
      saveOk &= configSet(@"feedback.stop_sound", stopSound);
    }
    if ([self shouldPersistBooleanValue:
                  self.errorSoundCheckbox.state == NSControlStateValueOn
                                forKey:@"feedback.error_sound"]) {
      saveOk &= configSet(@"feedback.error_sound", errorSound);
    }
  }
  if (self.muteSystemOutputCheckbox) {
    NSString *muteSystemOutput =
        (self.muteSystemOutputCheckbox.state == NSControlStateValueOn)
            ? @"true"
            : @"false";
    if ([self shouldPersistBooleanValue:
                  self.muteSystemOutputCheckbox.state == NSControlStateValueOn
                                forKey:@"feedback.mute_system_output"]) {
      saveOk &=
          configSet(@"feedback.mute_system_output", muteSystemOutput);
    }
  }
  if (self.autoReturnSwitch) {
    NSString *autoReturn =
        (self.autoReturnSwitch.state == NSControlStateValueOn) ? @"true"
                                                               : @"false";
    if ([self shouldPersistBooleanValue:
                  self.autoReturnSwitch.state == NSControlStateValueOn
                                forKey:@"paste.auto_return"]) {
      saveOk &= configSet(@"paste.auto_return", autoReturn);
    }
  }
  if (self.templatesEnabledSwitch) {
    NSString *templatesEnabled =
        (self.templatesEnabledSwitch.state == NSControlStateValueOn) ? @"true"
                                                                     : @"false";
    if ([self shouldPersistBooleanValue:
                  self.templatesEnabledSwitch.state == NSControlStateValueOn
                                forKey:@"llm.prompt_templates_enabled"]) {
      saveOk &=
          configSet(@"llm.prompt_templates_enabled", templatesEnabled);
    }
  }

  if (!saveOk) {
    rollbackConfigIfNeeded();
    [self
        showAlert:@"Не все настройки удалось сохранить"
             info:[NSString stringWithFormat:@"Убедитесь, что %@ доступен для записи, и повторите.",
                                             [configFilePath() stringByAbbreviatingWithTildeInPath]]];
    return;
  }

  // Save prompt templates
  if (serializedTemplates) {
    if (![self.rustBridge setPromptTemplates:serializedTemplates]) {
      rollbackConfigIfNeeded();
      [self showAlert:@"Не удалось сохранить шаблоны промптов"
                 info:[NSString stringWithFormat:@"Проверьте шаблоны промптов и %@ и повторите попытку.",
                                                 [configFilePath() stringByAbbreviatingWithTildeInPath]]];
      return;
    }
  }

  // Write dictionary.txt
  NSError *error = nil;
  if (self.dictionaryTextView &&
      ![self.dictionaryTextView.string
          isEqualToString:self.loadedDictionaryContent ?: @""]) {
    NSString *dictPath = [dir stringByAppendingPathComponent:kDictionaryFile];
    [self.dictionaryTextView.string writeToFile:dictPath
                                     atomically:YES
                                       encoding:NSUTF8StringEncoding
                                          error:&error];
    if (error) {
      NSLog(@"[VelikiyMoguchiy] Failed to write dictionary.txt: %@",
            error.localizedDescription);
      rollbackConfigIfNeeded();
      [self showAlert:@"Не удалось сохранить dictionary.txt"
                 info:error.localizedDescription];
      return;
    }
  }

  // Write system_prompt.txt
  if (self.systemPromptTextView &&
      ![self.systemPromptTextView.string
          isEqualToString:self.loadedSystemPromptContent ?: @""]) {
    NSString *promptPath =
        [dir stringByAppendingPathComponent:kSystemPromptFile];
    [self.systemPromptTextView.string writeToFile:promptPath
                                       atomically:YES
                                         encoding:NSUTF8StringEncoding
                                            error:&error];
    if (error) {
      NSLog(@"[VelikiyMoguchiy] Failed to write system_prompt.txt: %@",
            error.localizedDescription);
      rollbackConfigIfNeeded();
      [self showAlert:@"Не удалось сохранить system_prompt.txt"
                 info:error.localizedDescription];
      return;
    }
  }

  shouldRollbackConfig = NO;
  NSLog(@"[VelikiyMoguchiy] Settings saved");

  // Notify delegate to reload
  if ([self.delegate respondsToSelector:@selector(setupWizardDidSaveConfig)]) {
    [self.delegate setupWizardDidSaveConfig];
  }

  // Close the settings window on successful save so the user gets clear
  // feedback that the action completed. (Previously the click looked like
  // a no-op.)
  [self hideRuntimeOverlayPreview];
  [self.window close];
}

- (void)cancelSetup:(id)sender {
  [self endHotkeyRecording];
  [self hideRuntimeOverlayPreview];
  [self.window close];
}

- (void)llmEnabledToggled:(id)sender {
  [self updateLlmFieldsEnabled];
}

- (void)toggleLlmRemoteModelPicker:(id)sender {
  self.llmRemoteModelPickerExpanded = !self.llmRemoteModelPickerExpanded;
  if (self.llmRemoteModelPickerExpanded) {
    [self updateLlmFieldsEnabled];
    [self refreshLlmRemoteModels:nil];
  } else {
    [self updateLlmFieldsEnabled];
  }
}

- (void)setLlmRemoteModelPickerRowVisible:(BOOL)visible {
  if (_llmRemoteModelPickerRowVisible == visible) {
    return;
  }
  _llmRemoteModelPickerRowVisible = visible;

  // Keep the model picker row height in sync with layout built in buildLlmPane.
  CGFloat pickerRowHeight = 36.0; // rowH (32) + extra gap (4)
  CGFloat deltaY = visible ? -pickerRowHeight : pickerRowHeight;

  // Move all OpenAI controls below the model picker row (tags 2005-2008).
  for (NSView *view in self.currentPaneView.subviews) {
    if (view.tag >= 2005 && view.tag <= 2008) {
      NSRect frame = view.frame;
      frame.origin.y += deltaY;
      view.frame = frame;
    }
  }
}

- (void)populateLlmRemoteModelPopupWithModels:(NSArray<NSString *> *)models
                                selectedModel:(NSString *)selectedModel {
  [self.llmRemoteModelPopup removeAllItems];

  if (models.count == 0) {
    [self.llmRemoteModelPopup addItemWithTitle:@"Нет доступных моделей"];
    self.llmRemoteModelPopup.lastItem.representedObject = nil;
    self.llmRemoteModelPopup.enabled = NO;
    return;
  }

  for (NSString *modelId in models) {
    [self.llmRemoteModelPopup addItemWithTitle:modelId];
    self.llmRemoteModelPopup.lastItem.representedObject = modelId;
  }

  if (selectedModel.length > 0) {
    for (NSInteger i = 0; i < self.llmRemoteModelPopup.numberOfItems; i++) {
      if ([[self.llmRemoteModelPopup itemAtIndex:i].representedObject
              isEqualToString:selectedModel]) {
        [self.llmRemoteModelPopup selectItemAtIndex:i];
        break;
      }
    }
  }
  self.llmRemoteModelPopup.enabled =
      (self.llmEnabledCheckbox.state == NSControlStateValueOn);
}

- (void)llmRemoteModelChanged:(id)sender {
  NSString *model = self.llmRemoteModelPopup.selectedItem.representedObject;
  if (model.length > 0) {
    self.llmModelField.stringValue = model;
    [self syncActiveLlmProfileFromFields];
    self.llmTestResultLabel.stringValue = @"";
  }
}

- (void)refreshLlmRemoteModels:(id)sender {
  NSDictionary *activeProfile = [self runtimeLlmProfileForActiveProfile];
  NSString *provider =
      [activeProfile[@"provider"] isKindOfClass:[NSString class]]
          ? activeProfile[@"provider"]
          : @"openai";
  BOOL isRemote = ![provider isEqualToString:@"mlx"];
  if (!isRemote)
    return;
  [self updateLlmFieldsEnabled];

  NSString *baseURL = [self.llmBaseUrlField.stringValue
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  NSString *currentModel = [self.llmModelField.stringValue copy] ?: @"";
  if (baseURL.length == 0) {
    [self.llmRemoteModelPopup removeAllItems];
    [self.llmRemoteModelPopup addItemWithTitle:@"Сначала укажите Base URL"];
    self.llmRemoteModelPopup.enabled = NO;
    return;
  }

  [self.llmRemoteModelPopup removeAllItems];
  [self.llmRemoteModelPopup addItemWithTitle:@"Загрузка моделей…"];
  self.llmRemoteModelPopup.enabled = NO;
  self.llmRefreshModelsButton.enabled = NO;

  __weak typeof(self) weakSelf = self;
  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf)
          return;

        NSDictionary *result =
            [strongSelf.rustBridge llmRemoteModelsForProfile:activeProfile];
        BOOL success = [result[@"success"] boolValue];
        NSArray *modelsRaw = [result[@"models"] isKindOfClass:[NSArray class]]
                                 ? result[@"models"]
                                 : @[];
        NSMutableArray<NSString *> *models =
            [NSMutableArray arrayWithCapacity:modelsRaw.count];
        for (id item in modelsRaw) {
          if ([item isKindOfClass:[NSString class]] && [item length] > 0) {
            [models addObject:item];
          }
        }
        NSString *message = [result[@"message"] isKindOfClass:[NSString class]]
                                ? result[@"message"]
                                : @"";

        dispatch_async(dispatch_get_main_queue(), ^{
          typeof(self) innerSelf = weakSelf;
          if (!innerSelf)
            return;
          NSDictionary *innerActive = [innerSelf activeLlmProfile];
          NSString *activeProvider =
              [innerActive[@"provider"] isKindOfClass:[NSString class]]
                  ? innerActive[@"provider"]
                  : @"openai";
          BOOL stillRemote = ![activeProvider isEqualToString:@"mlx"];
          if (!stillRemote)
            return;

          innerSelf.llmRefreshModelsButton.enabled =
              (innerSelf.llmEnabledCheckbox.state == NSControlStateValueOn);
          if (success) {
            [innerSelf populateLlmRemoteModelPopupWithModels:models
                                               selectedModel:currentModel];
          } else {
            [innerSelf.llmRemoteModelPopup removeAllItems];
            [innerSelf.llmRemoteModelPopup addItemWithTitle:@"Не удалось загрузить"];
            innerSelf.llmRemoteModelPopup.enabled = NO;
            if (message.length > 0) {
              innerSelf.llmTestResultLabel.stringValue =
                  [NSString stringWithFormat:@"Список моделей: %@", message];
              innerSelf.llmTestResultLabel.textColor =
                  SPTheme.warning;
            }
          }
        });
      });
}

/// Set the LLM test result line and make sure it is actually on screen: the
/// pane reserves room for it below the Test button, which can sit past the
/// viewport fold on short windows (issue #118).
- (void)showLlmTestResult:(NSString *)text color:(NSColor *)color {
  self.llmTestResultLabel.stringValue = text ?: @"";
  self.llmTestResultLabel.textColor = color;
  if (text.length > 0) {
    [self.llmTestResultLabel
        scrollRectToVisible:NSInsetRect(self.llmTestResultLabel.bounds, 0, -8.0)];
  }
}

- (void)updateLlmFieldsEnabled {
  BOOL enabled = (self.llmEnabledCheckbox.state == NSControlStateValueOn);
  self.llmProfileTableView.enabled = enabled;
  self.llmAddProfileButton.enabled = enabled;
  self.llmDeleteProfileButton.enabled = enabled && self.llmProfiles.count > 1;
  self.llmProfileNameField.enabled = enabled;

  NSDictionary *activeProfile = [self activeLlmProfile];
  NSString *provider =
      [activeProfile[@"provider"] isKindOfClass:[NSString class]]
          ? activeProfile[@"provider"]
          : @"openai";
  BOOL isMlx = [provider isEqualToString:@"mlx"];
  BOOL isRemote = !isMlx;
  NSString *protocol = [self apiProtocolForLlmProfile:activeProfile];
  BOOL isOpenAIChat = [protocol isEqualToString:kLlmProtocolOpenAIChat];

  // Toggle OpenAI fields (tag 2001-2008). Tag 2004 (Model List row) is
  // managed separately below because its visibility is gated by the
  // expand/collapse state of the Choose button.
  [self setHidden:!isRemote
      forViewsWithTagInRange:NSMakeRange(2001, 8)
                      inView:self.currentPaneView];
  [self setHidden:!isOpenAIChat
      forViewsWithTagInRange:NSMakeRange(2006, 2)
                      inView:self.currentPaneView];
  // Eye toggle doesn't use tag for show/hide (tag is used for 0/1 state)
  self.llmApiKeyToggle.hidden = !isRemote;
  // Preserve API key visibility state when showing OpenAI fields
  if (isRemote) {
    BOOL showPlain = (self.llmApiKeyToggle.tag == 1);
    self.llmApiKeyField.hidden = !showPlain;
    self.llmApiKeySecureField.hidden = showPlain;
  }

  self.llmBaseUrlField.enabled = enabled;
  self.llmApiKeyField.enabled = enabled;
  self.llmApiKeySecureField.enabled = enabled;
  self.llmModelField.enabled = enabled;
  self.llmToggleModelPickerButton.hidden = !isRemote;
  self.llmToggleModelPickerButton.enabled = enabled && isRemote;
  [self.llmToggleModelPickerButton
      setTitle:(self.llmRemoteModelPickerExpanded ? @"Скрыть" : @"Выбрать")];
  BOOL showRemoteModelPicker =
      isRemote && self.llmRemoteModelPickerExpanded;
  [self setLlmRemoteModelPickerRowVisible:showRemoteModelPicker];
  [self setHidden:!showRemoteModelPicker
      forViewsWithTagInRange:NSMakeRange(2004, 1)
                      inView:self.currentPaneView];
  BOOL hasSelectableRemoteModel =
      (self.llmRemoteModelPopup.selectedItem.representedObject != nil);
  self.llmRemoteModelPopup.enabled =
      enabled && showRemoteModelPicker && hasSelectableRemoteModel;
  self.llmRefreshModelsButton.enabled = enabled && showRemoteModelPicker;
  self.llmChatCompletionsPathField.enabled = enabled && isRemote;
  self.maxTokenParamPopup.enabled = enabled && isOpenAIChat;
  self.llmTestButton.enabled = enabled;

  // Toggle MLX fields (tag 2010-2012)
  [self setHidden:!isMlx
      forViewsWithTagInRange:NSMakeRange(2010, 3)
                      inView:self.currentPaneView];
  if (isMlx) {
    self.llmLocalModelPopup.enabled = enabled;
    self.llmModelDownloadButton.enabled = enabled;
    self.llmModelDeleteButton.enabled = enabled;
    // Progress bar stays hidden unless downloading
    self.llmModelProgressBar.hidden = YES;
    self.llmModelProgressSizeLabel.hidden = YES;
  }
}

- (void)populateLlmLocalModelPopup {
  [self.llmLocalModelPopup removeAllItems];

  NSArray<NSDictionary *> *models = [self.rustBridge scanModels];
  for (NSDictionary *model in models) {
    if (![model[@"provider"] isEqualToString:@"mlx"])
      continue;
    NSString *modelMode = model[@"mode"];
    if (!modelMode || modelMode.length == 0)
      modelMode = @"asr";
    if (![modelMode isEqualToString:@"llm"])
      continue;

    NSString *path = model[@"path"];
    NSString *title = model[@"description"] ?: path;

    [self.llmLocalModelPopup addItemWithTitle:title];
    [self.llmLocalModelPopup lastItem].representedObject = path;
  }

  if (self.llmLocalModelPopup.numberOfItems == 0) {
    [self.llmLocalModelPopup addItemWithTitle:@"Модели не найдены"];
    self.llmLocalModelPopup.enabled = NO;
  } else {
    self.llmLocalModelPopup.enabled = YES;
  }
}

- (void)llmLocalModelChanged:(id)sender {
  [self updateLlmModelStatusLabel];
}

- (void)updateLlmModelStatusLabel {
  NSString *modelPath = self.llmLocalModelPopup.selectedItem.representedObject;
  if (!modelPath) {
    self.llmModelStatusLabel.stringValue = @"";
    self.llmModelDownloadButton.enabled = NO;
    self.llmModelDeleteButton.enabled = NO;
    self.llmModelProgressBar.hidden = YES;
    self.llmModelProgressSizeLabel.hidden = YES;
    return;
  }

  if ([self.downloadingModels containsObject:modelPath]) {
    self.llmModelStatusLabel.stringValue = @"Скачивание";
    self.llmModelStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.llmModelDownloadButton.image =
        [NSImage imageWithSystemSymbolName:@"stop.circle"
                  accessibilityDescription:@"Стоп"];
    self.llmModelDownloadButton.enabled = YES;
    self.llmModelDeleteButton.enabled = NO;
    self.llmModelProgressBar.hidden = NO;
    self.llmModelProgressSizeLabel.hidden = NO;
    return;
  }

  NSInteger cachedStatus = [self.rustBridge modelStatus:modelPath
                                                   mode:SPModelVerifyCacheOnly];
  if (cachedStatus == 2) {
    [self applyLlmModelStatus:cachedStatus];
    return;
  }

  [self applyLlmModelStatus:(cachedStatus > 0 ? cachedStatus : 1)
                  verifying:YES];

  dispatch_async(_verifyQueue, ^{
    NSInteger verified = [self.rustBridge modelStatus:modelPath
                                                 mode:SPModelVerifyNormal];
    dispatch_async(dispatch_get_main_queue(), ^{
      NSString *current =
          self.llmLocalModelPopup.selectedItem.representedObject;
      if ([current isEqualToString:modelPath]) {
        [self applyLlmModelStatus:verified];
      }
    });
  });
}

- (void)applyLlmModelStatus:(NSInteger)status {
  [self applyLlmModelStatus:status verifying:NO];
}

- (void)applyLlmModelStatus:(NSInteger)status verifying:(BOOL)verifying {
  self.llmModelProgressBar.hidden = YES;
  self.llmModelProgressSizeLabel.hidden = YES;
  self.llmModelDownloadButton.image =
      [NSImage imageWithSystemSymbolName:@"arrow.down.circle"
                accessibilityDescription:@"Скачать"];
  switch (status) {
  case 2:
    self.llmModelStatusLabel.stringValue =
        verifying ? @"● Проверка…" : @"● Установлена";
    self.llmModelStatusLabel.textColor =
        verifying ? [NSColor secondaryLabelColor] : SPTheme.success;
    self.llmModelDownloadButton.enabled = NO;
    self.llmModelDeleteButton.enabled = YES;
    break;
  case 1:
    self.llmModelStatusLabel.stringValue =
        verifying ? @"◐ Проверка…" : @"◐ Не завершена";
    self.llmModelStatusLabel.textColor =
        verifying ? [NSColor secondaryLabelColor] : SPTheme.warning;
    self.llmModelDownloadButton.enabled = YES;
    self.llmModelDeleteButton.enabled = YES;
    break;
  default:
    self.llmModelStatusLabel.stringValue = @"○ Не установлена";
    self.llmModelStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.llmModelDownloadButton.enabled = YES;
    self.llmModelDeleteButton.enabled = NO;
    break;
  }
}

- (void)llmDownloadSelectedModel:(id)sender {
  NSString *modelPath = self.llmLocalModelPopup.selectedItem.representedObject;
  if (!modelPath)
    return;

  if ([self.downloadingModels containsObject:modelPath]) {
    [self.rustBridge cancelDownload:modelPath];
    return;
  }

  if (!self.downloadingModels) {
    self.downloadingModels = [NSMutableSet new];
  }
  [self.downloadingModels addObject:modelPath];

  self.llmModelDownloadButton.image =
      [NSImage imageWithSystemSymbolName:@"stop.circle"
                accessibilityDescription:@"Стоп"];
  self.llmModelDownloadButton.hidden = NO;
  self.llmModelStatusLabel.stringValue = @"Скачивание…";
  self.llmModelStatusLabel.textColor = [NSColor secondaryLabelColor];
  self.llmModelProgressBar.hidden = NO;
  self.llmModelProgressBar.doubleValue = 0;
  self.llmModelProgressSizeLabel.hidden = NO;
  self.llmModelProgressSizeLabel.stringValue = @"";

  __block uint64_t totalBytesAllFiles = 0;
  for (NSDictionary *m in [self.rustBridge scanModels]) {
    if ([m[@"path"] isEqualToString:modelPath]) {
      totalBytesAllFiles = [m[@"total_size"] unsignedLongLongValue];
      break;
    }
  }
  __block NSMutableDictionary<NSNumber *, NSNumber *> *fileDownloaded =
      [NSMutableDictionary new];

  __weak typeof(self) weakSelf = self;
  [self.rustBridge downloadModel:modelPath
      progress:^(NSUInteger fileIndex, NSUInteger fileCount,
                 uint64_t downloaded, uint64_t total, NSString *filename) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf)
          return;

        NSString *selected =
            strongSelf.llmLocalModelPopup.selectedItem.representedObject;
        if (![modelPath isEqualToString:selected])
          return;

        fileDownloaded[@(fileIndex)] = @(downloaded);

        uint64_t totalDownloaded = 0;
        for (NSNumber *v in fileDownloaded.allValues)
          totalDownloaded += v.unsignedLongLongValue;

        double pct =
            (totalBytesAllFiles > 0)
                ? (double)totalDownloaded / (double)totalBytesAllFiles * 100.0
                : 0;
        strongSelf.llmModelProgressBar.doubleValue = pct;
        strongSelf.llmModelStatusLabel.stringValue = @"Скачивание";
        strongSelf.llmModelProgressSizeLabel.stringValue =
            [NSString stringWithFormat:@"%.1f / %.1f МБ",
                                       (double)totalDownloaded / 1048576.0,
                                       (double)totalBytesAllFiles / 1048576.0];
      }
      completion:^(BOOL success, NSString *message) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf)
          return;
        [strongSelf.downloadingModels removeObject:modelPath];
        [strongSelf updateLlmModelStatusLabel];
      }];
}

- (void)llmDeleteSelectedModel:(id)sender {
  NSString *modelPath = self.llmLocalModelPopup.selectedItem.representedObject;
  if (!modelPath)
    return;

  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Удалить файлы модели?";
  alert.informativeText = @"Скачанные файлы модели будут удалены. Модель можно скачать "
                          @"снова.";
  [alert addButtonWithTitle:@"Удалить"];
  [alert addButtonWithTitle:@"Отмена"];
  alert.alertStyle = NSAlertStyleWarning;

  if ([alert runModal] == NSAlertFirstButtonReturn) {
    [self.rustBridge removeModelFiles:modelPath];
    [self updateLlmModelStatusLabel];
  }
}

- (void)testLlmConnection:(id)sender {
  NSDictionary *profile = [self runtimeLlmProfileForActiveProfile];
  if (!profile) {
    self.llmTestResultLabel.stringValue =
        @"Сначала выберите профиль LLM.";
    self.llmTestResultLabel.textColor = SPTheme.warning;
    return;
  }

  NSString *provider = [profile[@"provider"] isKindOfClass:[NSString class]]
                           ? profile[@"provider"]
                           : @"openai";
  NSString *baseUrl = [profile[@"base_url"] isKindOfClass:[NSString class]]
                          ? profile[@"base_url"]
                          : @"";
  NSString *model = [profile[@"model"] isKindOfClass:[NSString class]]
                        ? profile[@"model"]
                        : @"";
  if (![provider isEqualToString:@"mlx"] &&
      (baseUrl.length == 0 || model.length == 0)) {
    self.llmTestResultLabel.stringValue =
        @"Сначала заполните Base URL и модель.";
    self.llmTestResultLabel.textColor = SPTheme.warning;
    return;
  }

  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:profile
                                                     options:0
                                                       error:nil];
  NSString *profileJson =
      jsonData ? [[NSString alloc] initWithData:jsonData
                                       encoding:NSUTF8StringEncoding]
               : nil;
  if (profileJson.length == 0) {
    [self showLlmTestResult:@"Ошибка проверки: некорректные данные профиля"
                      color:SPTheme.failure];
    return;
  }

  self.llmTestButton.enabled = NO;
  self.llmTestResultLabel.stringValue = @"Проверка…";
  self.llmTestResultLabel.textColor = [NSColor secondaryLabelColor];

  // Run the Rust-side test on a background thread; the profile path matches
  // runtime correction.
  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        char *raw = sp_llm_test_profile_json(profileJson.UTF8String);
        NSString *jsonStr = raw ? [NSString stringWithUTF8String:raw] : @"";
        if (raw)
          sp_core_free_string(raw);

        NSDictionary *result = nil;
        if (jsonStr.length > 0) {
          result = [NSJSONSerialization
              JSONObjectWithData:[jsonStr
                                     dataUsingEncoding:NSUTF8StringEncoding]
                         options:0
                           error:nil];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
          self.llmTestButton.enabled =
              (self.llmEnabledCheckbox.state == NSControlStateValueOn);

          if (!result) {
            [self showLlmTestResult:@"Ошибка проверки: некорректный ответ ядра"
                              color:SPTheme.failure];
            return;
          }

          BOOL success = [result[@"success"] boolValue];
          NSString *message = result[@"message"] ?: @"Неизвестный результат";
          NSNumber *elapsedMs = result[@"elapsed_ms"];
          NSString *timeStr =
              elapsedMs
                  ? [NSString stringWithFormat:@" (%.1f с)",
                                               elapsedMs.doubleValue / 1000.0]
                  : @"";

          NSString *display =
              success ? message : SPCondensedProviderError(message);
          [self showLlmTestResult:[NSString stringWithFormat:@"%@%@", display,
                                                             timeStr]
                            color:success ? SPTheme.success
                                          : SPTheme.failure];
          // The tooltip carries the provider's untouched response for anyone
          // debugging a failure the condensed line does not explain.
          if (!success && ![display isEqualToString:message]) {
            self.llmTestResultLabel.toolTip = message;
          }
        });
      });
}

// ─── ASR Test Connection ────────────────────────────────────────────

- (void)testAsrConnection:(id)sender {
  NSString *provider =
      self.asrProviderPopup.selectedItem.representedObject ?: @"qwen";
  if ([provider isEqualToString:@"doubao"]) {
    [self testDoubaoConnection];
  } else if ([provider isEqualToString:@"qwen"]) {
    [self testQwenConnection];
  } else if ([provider isEqualToString:@"glm"]) {
    [self testGlmConnection];
  } else if ([provider isEqualToString:@"mimo"]) {
    [self testMimoConnection];
  }
}

- (void)testDoubaoConnection {
  // Determine auth mode
  BOOL isNewConsoleMode = (self.asrAuthModeControl.selectedSegment == 0);
  NSString *apiKey = self.asrApiKeyToggle.tag == 1
                         ? self.asrApiKeyField.stringValue
                         : self.asrApiKeySecureField.stringValue;
  NSString *appKey = self.asrAppKeyField.stringValue;
  NSString *accessKey = self.asrAccessKeyToggle.tag == 1
                            ? self.asrAccessKeyField.stringValue
                            : self.asrAccessKeySecureField.stringValue;

  NSDictionary<NSString *, NSString *> *customHeaders =
      asrCustomHeaders(@"doubao");

  if (customHeaders == nil) {
    if (isNewConsoleMode && apiKey.length == 0) {
      self.asrTestResultLabel.stringValue = @"Сначала укажите API-ключ";
      self.asrTestResultLabel.textColor = SPTheme.warning;
      return;
    } else if (!isNewConsoleMode &&
               (appKey.length == 0 || accessKey.length == 0)) {
      self.asrTestResultLabel.stringValue =
          @"Сначала укажите App Key и Access Key";
      self.asrTestResultLabel.textColor = SPTheme.warning;
      return;
    }
  }

  self.asrTestButton.enabled = NO;
  self.asrTestResultLabel.stringValue = @"Проверка…";
  self.asrTestResultLabel.textColor = [NSColor secondaryLabelColor];

  // Create WebSocket connection test
  NSString *doubaoUrl = configGet(@"asr.doubao.url");
  if (doubaoUrl.length == 0)
    doubaoUrl = @"wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async";
  NSURL *url = [NSURL URLWithString:doubaoUrl];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.timeoutInterval = 5;

  if (customHeaders) {
    for (NSString *headerName in customHeaders) {
      [request setValue:customHeaders[headerName]
          forHTTPHeaderField:headerName];
    }
  } else if (isNewConsoleMode) {
    [request setValue:apiKey forHTTPHeaderField:@"X-Api-Key"];
    [request setValue:@"volc.seedasr.sauc.duration"
        forHTTPHeaderField:@"X-Api-Resource-Id"];
    NSString *connectId = [[NSUUID UUID] UUIDString];
    [request setValue:connectId forHTTPHeaderField:@"X-Api-Connect-Id"];
    [request setValue:connectId forHTTPHeaderField:@"X-Api-Request-Id"];
    [request setValue:@"-1" forHTTPHeaderField:@"X-Api-Sequence"];
  } else {
    [request setValue:appKey forHTTPHeaderField:@"X-Api-App-Key"];
    [request setValue:accessKey forHTTPHeaderField:@"X-Api-Access-Key"];
    [request setValue:@"volc.seedasr.sauc.duration"
        forHTTPHeaderField:@"X-Api-Resource-Id"];
    NSString *connectId = [[NSUUID UUID] UUIDString];
    [request setValue:connectId forHTTPHeaderField:@"X-Api-Connect-Id"];
    [request setValue:connectId forHTTPHeaderField:@"X-Api-Request-Id"];
    [request setValue:@"-1" forHTTPHeaderField:@"X-Api-Sequence"];
  }

  NSURLSessionConfiguration *config =
      [NSURLSessionConfiguration defaultSessionConfiguration];
  config.timeoutIntervalForRequest = 5;
  NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
  NSURLSessionWebSocketTask *wsTask =
      [session webSocketTaskWithRequest:request];

  __weak typeof(self) weakSelf = self;
  __block BOOL hasCompleted = NO;

  // Try to receive a message (Doubao may not send one immediately)
  [wsTask receiveMessageWithCompletionHandler:^(
              NSURLSessionWebSocketMessage *_Nullable message,
              NSError *_Nullable error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (hasCompleted)
        return;
      hasCompleted = YES;

      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf)
        return;

      [wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure
                           reason:nil];
      strongSelf.asrTestButton.enabled = YES;

      if (error) {
        NSString *errorMsg = error.localizedDescription;

        // Check userInfo for HTTP status code
        NSHTTPURLResponse *response =
            error.userInfo[@"NSURLSessionDownloadTaskResumeData"];
        NSInteger statusCode = 0;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
          statusCode = response.statusCode;
        }

        NSString *authHint =
            isNewConsoleMode
                ? @"Ошибка авторизации: проверьте API-ключ"
                : @"Ошибка авторизации: проверьте App Key и Access Key";
        if ([errorMsg containsString:@"401"] ||
            [errorMsg containsString:@"403"] ||
            [error.localizedFailureReason containsString:@"401"] ||
            statusCode == 401) {
          strongSelf.asrTestResultLabel.stringValue = authHint;
        } else if ([errorMsg containsString:@"time"] ||
                   error.code == NSURLErrorTimedOut) {
          strongSelf.asrTestResultLabel.stringValue =
              @"Превышено время ожидания: проверьте сеть";
        } else if ([errorMsg containsString:@"bad response"] ||
                   [errorMsg containsString:@"Bad response"] ||
                   statusCode == 400 || statusCode == 403) {
          strongSelf.asrTestResultLabel.stringValue = authHint;
        } else if ([errorMsg containsString:@"unable"] ||
                   [errorMsg containsString:@"Unable"] ||
                   [errorMsg containsString:@"Cannot connect"] ||
                   [errorMsg containsString:@"Network"]) {
          strongSelf.asrTestResultLabel.stringValue =
              @"Ошибка сети: проверьте настройки сети";
        } else {
          strongSelf.asrTestResultLabel.stringValue =
              @"Не удалось подключиться: проверьте настройки";
        }
        strongSelf.asrTestResultLabel.textColor = SPTheme.failure;
        return;
      }

      strongSelf.asrTestResultLabel.stringValue = @"Подключено";
      strongSelf.asrTestResultLabel.textColor = SPTheme.success;
    });
  }];

  [wsTask resume];

  // Doubao may not send a message immediately; treat no error within 2s as
  // success
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        if (hasCompleted)
          return;
        hasCompleted = YES;

        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
          return;

        [wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure
                             reason:nil];

        if (!strongSelf.asrTestButton.enabled) {
          strongSelf.asrTestButton.enabled = YES;
          strongSelf.asrTestResultLabel.stringValue = @"Подключено";
          strongSelf.asrTestResultLabel.textColor = SPTheme.success;
        }
      });

  // Fallback timeout
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        if (hasCompleted)
          return;
        hasCompleted = YES;

        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
          return;

        [wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure
                             reason:nil];
        strongSelf.asrTestButton.enabled = YES;
        strongSelf.asrTestResultLabel.stringValue =
            @"Превышено время ожидания: проверьте сеть";
        strongSelf.asrTestResultLabel.textColor = SPTheme.failure;
      });
}

- (void)loadQwenModelFromConfig {
  NSString *model =
      [SPQwenModelChoice effectiveModelForConfigValue:configGet(@"asr.qwen.model")];
  self.asrQwenLoadedModel = model;
  if ([SPQwenModelChoice isPresetModel:model]) {
    for (NSMenuItem *item in self.asrQwenModelPopup.itemArray) {
      if ([item.representedObject isEqual:model]) {
        [self.asrQwenModelPopup selectItem:item];
        break;
      }
    }
    self.asrQwenModelCustomField.stringValue = @"";
  } else {
    [self.asrQwenModelPopup selectItem:self.asrQwenModelPopup.lastItem];
    self.asrQwenModelCustomField.stringValue = model;
  }
  [self layoutQwenModelRowShowingProvider:!self.asrQwenModelPopup.hidden];
}

/// nil while "Другая…" is chosen with an empty field.
- (NSString *)selectedQwenModel {
  return [SPQwenModelChoice
      modelToSaveForPreset:self.asrQwenModelPopup.selectedItem.representedObject
                customText:self.asrQwenModelCustomField.stringValue];
}

- (void)qwenModelChanged:(NSPopUpButton *)sender {
  [self layoutQwenModelRowShowingProvider:YES];
  if (!self.asrQwenModelCustomField.hidden) {
    [self.window makeFirstResponder:self.asrQwenModelCustomField];
  }
}

/// "Другая…" narrows the popup and shows the custom field beside it.
- (void)layoutQwenModelRowShowingProvider:(BOOL)providerShown {
  BOOL custom = self.asrQwenModelPopup.selectedItem.representedObject == nil;
  NSRect popupFrame = self.asrQwenModelPopup.frame;
  CGFloat fullWidth = self.asrQwenModelRowWidth;
  popupFrame.size.width = custom ? 120.0 : fullWidth;
  self.asrQwenModelPopup.frame = popupFrame;
  NSRect fieldFrame = self.asrQwenModelCustomField.frame;
  fieldFrame.origin.x = NSMinX(popupFrame) + 128.0;
  fieldFrame.size.width = fullWidth - 128.0;
  self.asrQwenModelCustomField.frame = fieldFrame;
  self.asrQwenModelCustomField.hidden = !(providerShown && custom);
}

static NSString *const kDashScopeKeyHelpURL =
    @"https://github.com/zigansh1n/velikiy-moguchiy/blob/main/docs/DASHSCOPE-KEY.md";
// What the core reads for a config without asr.qwen.url (default_qwen_url).
static NSString *const kDashScopeDefaultURL = @"wss://dashscope.aliyuncs.com/api-ws/v1/realtime";

- (NSButton *)linkButtonWithTitle:(NSString *)title action:(SEL)action {
  NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
  button.bordered = NO;
  button.alignment = NSTextAlignmentLeft;
  button.attributedTitle = [[NSAttributedString alloc]
      initWithString:title
          attributes:@{
            NSFontAttributeName : [NSFont systemFontOfSize:11],
            NSForegroundColorAttributeName : NSColor.linkColor,
            NSUnderlineStyleAttributeName : @(NSUnderlineStyleSingle),
          }];
  return button;
}

- (void)openDashScopeKeyHelp:(id)sender {
  [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:kDashScopeKeyHelpURL]];
}

static NSString *dashScopeRegionName(NSString *url) {
  if ([url containsString:@"dashscope-intl.aliyuncs.com"])
    return @"международный регион";
  if ([url containsString:@"dashscope.aliyuncs.com"])
    return @"регион Китай";
  return @"свой адрес";
}

/// «Проверить ключ»: every key goes through the core's own connection (the
/// session is set up and closed before any audio, so it costs nothing).
- (void)testQwenConnection {
  if (asrCustomHeaders(@"qwen") != nil) {
    [self testQwenConnectionWithCustomHeaders];
    return;
  }
  NSArray<NSString *> *keys = [self currentQwenKeys];
  if (keys.count == 0) {
    self.asrTestResultLabel.stringValue =
        @"Сначала вставьте ключ. Где его взять — «Как получить ключ» слева.";
    self.asrTestResultLabel.textColor = SPTheme.warning;
    return;
  }
  NSString *model = [self selectedQwenModel];
  if (model.length == 0) {
    self.asrTestResultLabel.stringValue = @"Сначала укажите модель";
    self.asrTestResultLabel.textColor = SPTheme.warning;
    return;
  }
  NSString *url = configGet(@"asr.qwen.url");
  if (url.length == 0)
    url = kDashScopeDefaultURL;

  self.asrTestButton.enabled = NO;
  self.asrTestResultLabel.stringValue =
      keys.count == 1 ? @"Проверка ключа…"
                      : [NSString stringWithFormat:@"Проверка ключей: %lu…", (unsigned long)keys.count];
  self.asrTestResultLabel.textColor = [NSColor secondaryLabelColor];

  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    for (NSString *key in keys) {
      char *raw = sp_dashscope_check_key(url.UTF8String, key.UTF8String, model.UTF8String);
      NSDictionary *result = nil;
      if (raw) {
        NSData *data = [NSData dataWithBytes:raw length:strlen(raw)];
        sp_core_free_string(raw);
        result = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
      }
      [results addObject:[result isKindOfClass:[NSDictionary class]] ? result : @{ @"ok" : @NO }];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakSelf showQwenKeyCheckResults:results url:url model:model];
    });
  });
}

- (void)showQwenKeyCheckResults:(NSArray<NSDictionary *> *)results
                            url:(NSString *)url
                          model:(NSString *)model {
  self.asrTestButton.enabled = YES;
  NSUInteger failed = 0;
  NSInteger firstFailure = -1;
  NSString *otherRegionURL = nil;
  BOOL everyFailureWorksElsewhere = YES;
  for (NSUInteger i = 0; i < results.count; i++) {
    NSDictionary *result = results[i];
    if ([result[@"ok"] boolValue])
      continue;
    failed++;
    if (firstFailure < 0)
      firstFailure = (NSInteger)i;
    NSString *worksAt = [result[@"works_at"] isKindOfClass:[NSString class]] ? result[@"works_at"] : nil;
    if (worksAt.length > 0 && (!otherRegionURL || [otherRegionURL isEqualToString:worksAt])) {
      otherRegionURL = worksAt;
    } else {
      everyFailureWorksElsewhere = NO;
    }
    NSLog(@"[VelikiyMoguchiy] DashScope key #%lu check failed: %@", (unsigned long)i + 1,
          result[@"message"] ?: @"no result");
  }

  NSString *region = dashScopeRegionName(url);
  self.asrTestResultLabel.toolTip = nil;
  if (failed == 0) {
    self.asrTestResultLabel.stringValue =
        results.count == 1
            ? [NSString stringWithFormat:@"Ключ работает (%@)", region]
            : [NSString stringWithFormat:@"Все ключи работают: %lu (%@)", (unsigned long)results.count, region];
    self.asrTestResultLabel.textColor = SPTheme.success;
    return;
  }

  NSDictionary *first = results[(NSUInteger)firstFailure];
  NSString *message = [first[@"message"] isKindOfClass:[NSString class]] ? first[@"message"] : @"";
  NSString *reason;
  if (otherRegionURL && everyFailureWorksElsewhere) {
    reason = [NSString stringWithFormat:@"создан для другого региона (%@)", dashScopeRegionName(otherRegionURL)];
  } else {
    switch ([SPErrorExplainer kindForMessage:message]) {
      case SPErrorKindBadKey:
        reason = @"сервис его не принял: скопируйте ключ целиком";
        break;
      case SPErrorKindNoBalance:
        reason = @"закончился баланс или бесплатный лимит";
        break;
      case SPErrorKindRateLimit:
        reason = @"слишком много запросов, повторите через минуту";
        break;
      case SPErrorKindAccessDenied:
        reason = [NSString stringWithFormat:@"нет доступа к модели «%@»", model];
        break;
      case SPErrorKindTimeout:
      case SPErrorKindNetwork:
      case SPErrorKindService:
        reason = @"нет связи с DashScope, проверьте интернет или VPN";
        break;
      default:
        reason = [[SPErrorExplainer explanationForMessage:message recordingKept:NO].shortText lowercaseString];
        break;
    }
  }
  NSString *which = results.count == 1
                        ? @"Ключ"
                        : [NSString stringWithFormat:@"Ключ %ld из %lu", (long)firstFailure + 1,
                                                     (unsigned long)results.count];
  NSString *text = [NSString stringWithFormat:@"%@: %@", which, reason];
  if (failed > 1)
    text = [text stringByAppendingFormat:@" (не работают: %lu)", (unsigned long)failed];
  self.asrTestResultLabel.stringValue = text;
  self.asrTestResultLabel.toolTip = text;
  self.asrTestResultLabel.textColor = SPTheme.failure;

  if (otherRegionURL && everyFailureWorksElsewhere) {
    [self offerDashScopeRegionSwitchTo:otherRegionURL from:url];
  }
}

/// Only on the user's click: the endpoint changes, nothing else does.
- (void)offerDashScopeRegionSwitchTo:(NSString *)otherURL from:(NSString *)currentURL {
  NSAlert *alert = [[NSAlert alloc] init];
  alert.alertStyle = NSAlertStyleInformational;
  alert.messageText = @"Ключ из другого региона";
  alert.informativeText = [NSString stringWithFormat:
      @"Ключ работает в %@, а приложение сейчас подключается к %@ адресу. Переключить адрес?\n\n"
      @"Остальные настройки не изменятся. Вернуть прежний адрес можно в config.yaml: asr.qwen.url.",
      [otherURL containsString:@"dashscope-intl"] ? @"международном регионе" : @"регионе Китай",
      [currentURL containsString:@"dashscope-intl"] ? @"международному" : @"китайскому"];
  [alert addButtonWithTitle:@"Переключить"];
  [alert addButtonWithTitle:@"Оставить"];
  __weak typeof(self) weakSelf = self;
  [alert beginSheetModalForWindow:self.window
                completionHandler:^(NSModalResponse response) {
                  __strong typeof(weakSelf) strongSelf = weakSelf;
                  if (!strongSelf || response != NSAlertFirstButtonReturn)
                    return;
                  if (!configSet(@"asr.qwen.url", otherURL)) {
                    strongSelf.asrTestResultLabel.stringValue = @"Не удалось сохранить адрес";
                    strongSelf.asrTestResultLabel.textColor = SPTheme.failure;
                    return;
                  }
                  NSLog(@"[VelikiyMoguchiy] asr.qwen.url switched by the user to %@", otherURL);
                  strongSelf.asrTestResultLabel.stringValue =
                      [NSString stringWithFormat:@"Адрес переключён, ключ работает (%@)",
                                                 dashScopeRegionName(otherURL)];
                  strongSelf.asrTestResultLabel.textColor = SPTheme.success;
                  if ([strongSelf.delegate respondsToSelector:@selector(setupWizardDidSaveConfig)]) {
                    [strongSelf.delegate setupWizardDidSaveConfig];
                  }
                }];
}

/// With asr.qwen.headers the core sends those headers instead of the key, so
/// only the handshake can be checked.
- (void)testQwenConnectionWithCustomHeaders {
  // Get current key value (account for plain/secure toggle state)
  NSString *apiKey = [self currentQwenKeys].firstObject ?: @"";

  NSDictionary<NSString *, NSString *> *customHeaders =
      asrCustomHeaders(@"qwen");

  if (customHeaders == nil && apiKey.length == 0) {
    self.asrTestResultLabel.stringValue = @"Сначала укажите API-ключ";
    self.asrTestResultLabel.textColor = SPTheme.warning;
    return;
  }

  self.asrTestButton.enabled = NO;
  self.asrTestResultLabel.stringValue = @"Проверка…";
  self.asrTestResultLabel.textColor = [NSColor secondaryLabelColor];

  // Create WebSocket connection test
  NSString *qwenBaseUrl = configGet(@"asr.qwen.url");
  if (qwenBaseUrl.length == 0)
    qwenBaseUrl = @"wss://dashscope.aliyuncs.com/api-ws/v1/realtime";
  NSString *qwenModel = [self selectedQwenModel];
  if (qwenModel.length == 0) {
    self.asrTestResultLabel.stringValue = @"Сначала укажите модель";
    self.asrTestResultLabel.textColor = SPTheme.warning;
    return;
  }
  NSURL *url =
      [NSURL URLWithString:[NSString stringWithFormat:@"%@?model=%@",
                                                      qwenBaseUrl, qwenModel]];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.timeoutInterval = 10;

  if (customHeaders) {
    // Runtime fully replaces the Authorization header when asr.qwen.headers is
    // set.
    for (NSString *headerName in customHeaders) {
      [request setValue:customHeaders[headerName]
          forHTTPHeaderField:headerName];
    }
  } else {
    // Set Qwen DashScope auth header
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
        forHTTPHeaderField:@"Authorization"];
  }

  NSURLSessionConfiguration *config2 =
      [NSURLSessionConfiguration defaultSessionConfiguration];
  config2.timeoutIntervalForRequest = 10;
  NSURLSession *session = [NSURLSession sessionWithConfiguration:config2];
  NSURLSessionWebSocketTask *wsTask =
      [session webSocketTaskWithRequest:request];

  __weak typeof(self) weakSelf = self;
  __weak NSURLSessionWebSocketTask *weakWsTask = wsTask;

  // Qwen DashScope returns a session.created message on connect
  [wsTask receiveMessageWithCompletionHandler:^(
              NSURLSessionWebSocketMessage *_Nullable message,
              NSError *_Nullable error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf)
        return;

      [weakWsTask
          cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure
                       reason:nil];

      strongSelf.asrTestButton.enabled = YES;

      if (error) {
        NSString *errorMsg = error.localizedDescription;
        NSInteger statusCode = 0;

        // Try to extract HTTP status code from error
        if (error.userInfo[@"_kCFStreamErrorDomainKey"]) {
          NSNumber *code = error.userInfo[@"_kCFStreamErrorDomainKey"];
          if (code)
            statusCode = code.integerValue;
        }

        if ([errorMsg containsString:@"401"] ||
            [errorMsg containsString:@"403"] || statusCode == 401) {
          strongSelf.asrTestResultLabel.stringValue =
              @"Ошибка авторизации: проверьте API-ключ";
        } else if ([errorMsg containsString:@"time"] ||
                   error.code == NSURLErrorTimedOut) {
          strongSelf.asrTestResultLabel.stringValue =
              @"Превышено время ожидания: проверьте сеть";
        } else if ([errorMsg containsString:@"bad response"] ||
                   [errorMsg containsString:@"Bad response"]) {
          // HTTP error during WebSocket handshake
          strongSelf.asrTestResultLabel.stringValue =
              @"Ошибка авторизации: проверьте API-ключ";
        } else if ([errorMsg containsString:@"unable"] ||
                   [errorMsg containsString:@"Unable"] ||
                   [errorMsg containsString:@"Cannot connect"]) {
          strongSelf.asrTestResultLabel.stringValue =
              @"Ошибка сети: проверьте настройки сети";
        } else {
          strongSelf.asrTestResultLabel.stringValue =
              @"Не удалось подключиться: проверьте настройки";
        }
        strongSelf.asrTestResultLabel.textColor = SPTheme.failure;
        return;
      }

      if (message) {
        strongSelf.asrTestResultLabel.stringValue = @"Подключено";
        strongSelf.asrTestResultLabel.textColor = SPTheme.success;
      } else {
        strongSelf.asrTestResultLabel.stringValue =
            @"Не удалось подключиться: сервер не отвечает";
        strongSelf.asrTestResultLabel.textColor = SPTheme.failure;
      }
    });
  }];

  [wsTask resume];

  // Timeout handler
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.asrTestButton.enabled)
          return;

        [wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure
                             reason:nil];
        strongSelf.asrTestButton.enabled = YES;
        strongSelf.asrTestResultLabel.stringValue =
            @"Превышено время ожидания: проверьте сеть";
        strongSelf.asrTestResultLabel.textColor = SPTheme.failure;
      });
}

- (void)testGlmConnection {
  // Get current key value (account for plain/secure toggle state)
  NSString *apiKey = self.asrGlmApiKeyToggle.tag == 1
                         ? self.asrGlmApiKeyField.stringValue
                         : self.asrGlmApiKeySecureField.stringValue;

  if (apiKey.length == 0) {
    self.asrTestResultLabel.stringValue = @"Сначала укажите API-ключ";
    self.asrTestResultLabel.textColor = SPTheme.warning;
    return;
  }

  self.asrTestButton.enabled = NO;
  self.asrTestResultLabel.stringValue = @"Проверка…";
  self.asrTestResultLabel.textColor = [NSColor secondaryLabelColor];

  // GLM Realtime uses WebSocket, test by connecting to the WS endpoint
  NSString *glmUrl = configGet(@"asr.glm.url");
  if (glmUrl.length == 0)
    glmUrl = @"wss://open.bigmodel.cn/api/paas/v4/realtime";
  NSString *glmModel = configGet(@"asr.glm.model");
  if (glmModel.length == 0)
    glmModel = @"glm-realtime";

  NSURL *url = [NSURL URLWithString:glmUrl];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.timeoutInterval = 10;
  [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
      forHTTPHeaderField:@"Authorization"];

  NSURLSessionConfiguration *config2 =
      [NSURLSessionConfiguration defaultSessionConfiguration];
  config2.timeoutIntervalForRequest = 10;
  NSURLSession *session = [NSURLSession sessionWithConfiguration:config2];
  NSURLSessionWebSocketTask *wsTask =
      [session webSocketTaskWithRequest:request];

  __weak typeof(self) weakSelf = self;
  __weak NSURLSessionWebSocketTask *weakWsTask = wsTask;

  // GLM Realtime returns a session.created message on connect
  [wsTask receiveMessageWithCompletionHandler:^(
              NSURLSessionWebSocketMessage *_Nullable message,
              NSError *_Nullable error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf)
        return;

      [weakWsTask
          cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure
                       reason:nil];

      strongSelf.asrTestButton.enabled = YES;

      if (error) {
        NSString *errorMsg = error.localizedDescription;
        NSInteger statusCode = 0;

        if (error.userInfo[@"_kCFStreamErrorDomainKey"]) {
          NSNumber *code = error.userInfo[@"_kCFStreamErrorDomainKey"];
          if (code)
            statusCode = code.integerValue;
        }

        if ([errorMsg containsString:@"401"] ||
            [errorMsg containsString:@"403"] || statusCode == 401) {
          strongSelf.asrTestResultLabel.stringValue =
              @"Ошибка авторизации: проверьте API-ключ";
        } else if ([errorMsg containsString:@"time"] ||
                   error.code == NSURLErrorTimedOut) {
          strongSelf.asrTestResultLabel.stringValue =
              @"Превышено время ожидания: проверьте сеть";
        } else if ([errorMsg containsString:@"bad response"] ||
                   [errorMsg containsString:@"Bad response"]) {
          strongSelf.asrTestResultLabel.stringValue =
              @"Ошибка авторизации: проверьте API-ключ";
        } else if ([errorMsg containsString:@"unable"] ||
                   [errorMsg containsString:@"Unable"] ||
                   [errorMsg containsString:@"Cannot connect"]) {
          strongSelf.asrTestResultLabel.stringValue =
              @"Ошибка сети: проверьте настройки сети";
        } else {
          strongSelf.asrTestResultLabel.stringValue =
              @"Не удалось подключиться: проверьте настройки";
        }
        strongSelf.asrTestResultLabel.textColor = SPTheme.failure;
        return;
      }

      if (message) {
        strongSelf.asrTestResultLabel.stringValue = @"Подключено";
        strongSelf.asrTestResultLabel.textColor = SPTheme.success;
      } else {
        strongSelf.asrTestResultLabel.stringValue =
            @"Не удалось подключиться: сервер не отвечает";
        strongSelf.asrTestResultLabel.textColor = SPTheme.failure;
      }
    });
  }];

  [wsTask resume];

  // Timeout handler
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.asrTestButton.enabled)
          return;

        [wsTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure
                             reason:nil];
        strongSelf.asrTestButton.enabled = YES;
        strongSelf.asrTestResultLabel.stringValue =
            @"Превышено время ожидания: проверьте сеть";
        strongSelf.asrTestResultLabel.textColor = SPTheme.failure;
      });
}

- (void)testMimoConnection {
  NSString *apiKey = self.asrMimoApiKeyToggle.tag == 1
                         ? self.asrMimoApiKeyField.stringValue
                         : self.asrMimoApiKeySecureField.stringValue;

  if (apiKey.length == 0) {
    self.asrTestResultLabel.stringValue = @"Сначала укажите API-ключ";
    self.asrTestResultLabel.textColor = SPTheme.warning;
    return;
  }

  self.asrTestButton.enabled = NO;
  self.asrTestResultLabel.stringValue = @"Проверка…";
  self.asrTestResultLabel.textColor = [NSColor secondaryLabelColor];

  // MiMo uses HTTP POST — send a minimal request to verify API key
  NSString *mimoUrl = configGet(@"asr.mimo.url");
  if (mimoUrl.length == 0)
    mimoUrl = @"https://api.xiaomimimo.com/v1/chat/completions";

  NSURL *url = [NSURL URLWithString:mimoUrl];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  request.timeoutInterval = 10;
  [request setValue:apiKey forHTTPHeaderField:@"api-key"];
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

  // Minimal body — just model + empty message to test auth
  NSDictionary *body = @{
    @"model" : @"mimo-v2.5-asr",
    @"messages" : @[
      @{@"role" : @"user", @"content" : @"test"}
    ]
  };
  request.HTTPBody =
      [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

  __weak typeof(self) weakSelf = self;
  NSURLSessionDataTask *task =
      [[NSURLSession sharedSession]
          dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response,
                                NSError *error) {
              dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf)
                  return;
                strongSelf.asrTestButton.enabled = YES;

                if (error) {
                  NSString *errorMsg = error.localizedDescription;
                  if (error.code == NSURLErrorTimedOut) {
                    strongSelf.asrTestResultLabel.stringValue =
                        @"Превышено время ожидания: проверьте сеть";
                  } else if ([errorMsg containsString:@"Cannot connect"] ||
                             [errorMsg containsString:@"unable"]) {
                    strongSelf.asrTestResultLabel.stringValue =
                        @"Ошибка сети: проверьте настройки сети";
                  } else {
                    strongSelf.asrTestResultLabel.stringValue =
                        [NSString stringWithFormat:@"Ошибка: %@", errorMsg];
                  }
                  strongSelf.asrTestResultLabel.textColor =
                      SPTheme.failure;
                  return;
                }

                NSHTTPURLResponse *httpResponse =
                    (NSHTTPURLResponse *)response;
                if (httpResponse.statusCode == 200 ||
                    httpResponse.statusCode == 400) {
                  // 400 = bad request (expected with minimal body), but auth
                  // worked
                  strongSelf.asrTestResultLabel.stringValue = @"Подключено";
                  strongSelf.asrTestResultLabel.textColor =
                      SPTheme.success;
                } else if (httpResponse.statusCode == 401 ||
                           httpResponse.statusCode == 403) {
                  strongSelf.asrTestResultLabel.stringValue =
                      @"Ошибка авторизации: проверьте API-ключ";
                  strongSelf.asrTestResultLabel.textColor =
                      SPTheme.failure;
                } else {
                  strongSelf.asrTestResultLabel.stringValue =
                      [NSString stringWithFormat:@"HTTP %ld: неожиданный ответ",
                                                 (long)httpResponse.statusCode];
                  strongSelf.asrTestResultLabel.textColor =
                      SPTheme.warning;
                }
              });
            }];
  [task resume];
}

- (void)showAlert:(NSString *)message info:(NSString *)info {
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = message;
  alert.informativeText = info ?: @"";
  alert.alertStyle = NSAlertStyleWarning;
  [alert addButtonWithTitle:@"OK"];
  [alert runModal];
}

@end
