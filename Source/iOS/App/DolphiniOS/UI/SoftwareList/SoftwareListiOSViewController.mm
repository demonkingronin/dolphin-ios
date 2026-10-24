// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "SoftwareListiOSViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "Common/CommonPaths.h"
#import "Common/FileUtil.h"
#import "Common/Config/Config.h"
#import "Common/StringUtil.h"

#import "Core/Config/GraphicsSettings.h"
#import "Core/Config/SYSCONFSettings.h"

#import "Core/CommonTitles.h"
#import "Core/Config/MainSettings.h"
#import "Core/IOS/ES/ES.h"
#import "Core/IOS/IOS.h"

#import "DiscIO/NANDImporter.h"

#import "UICommon/GameFile.h"

#import "EmulationBootParameter.h"
#import "FoundationStringUtil.h"
#import "GameFilePtrWrapper.h"
#import "ImportFileManager.h"
#import "LocalizationUtil.h"
#import "SoftwarePropertiesInfoViewController.h"
#import "GameFileCacheManager.h"

#import "Common/IniFile.h"
#import "DiscIO/GameModDescriptor.h"
#import "DiscIO/RiivolutionParser.h"

#include <algorithm>
#include <string>


#pragma mark - Per-game settings (uses Dolphin's existing revision-specific GameINI)

// Use native UIKit tables, matching the original DolphiniOS Settings UI. Only
// settings explicitly supported by the Dolphin configuration loader appear here.
@interface DOLPerGameSettingsViewController : UITableViewController
- (instancetype)initWithGame:(GameFilePtrWrapper*)game;
@end

@implementation DOLPerGameSettingsViewController {
  GameFilePtrWrapper* _game;
  NSString* _iniPath;
  Common::IniFile _ini;
  NSArray<NSArray<NSDictionary*>*>* _sections;
  NSArray<NSString*>* _sectionTitles;
}

- (instancetype)initWithGame:(GameFilePtrWrapper*)game {
  self = [super initWithStyle:UITableViewStyleInsetGrouped];
  if (!self)
    return nil;
  _game = game;
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Game Settings";
  self.tableView.rowHeight = UITableViewAutomaticDimension;
  self.tableView.estimatedRowHeight = 112;
  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                   target:self
                                                   action:@selector(closeSettings)];

  // These exact sections and keys are recognized by GameConfigLoader.cpp.
  _sections = @[
    @[
      @{@"title": @"Aspect Ratio", @"section": @"Video_Settings", @"key": @"AspectRatio",
        @"choices": @[@"Auto", @"Force 16:9", @"Force 4:3", @"Stretch"],
        @"values": @[@"0", @"1", @"2", @"3"]},
      @{@"title": @"Internal Resolution", @"section": @"Video_Settings", @"key": @"InternalResolution",
        @"choices": @[@"Auto", @"Native (1x)", @"2x", @"3x", @"4x", @"5x", @"6x"],
        @"values": @[@"0", @"1", @"2", @"3", @"4", @"5", @"6"]},
      @{@"title": @"Widescreen Hack", @"section": @"Video_Settings", @"key": @"wideScreenHack",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"V-Sync", @"section": @"Video_Hardware", @"key": @"VSync",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"HD Textures", @"section": @"Video_Settings", @"key": @"HiresTextures",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"Cache HD Textures", @"section": @"Video_Settings", @"key": @"CacheHiresTextures",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"Show FPS", @"section": @"Video_Settings", @"key": @"ShowFPS",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"Anisotropic Filtering", @"section": @"Video_Enhancements", @"key": @"MaxAnisotropy",
        @"choices": @[@"Default", @"1x", @"2x", @"4x", @"8x", @"16x"],
        @"values": @[@"-1", @"0", @"1", @"2", @"3", @"4"]},
      @{@"title": @"Pixel Lighting", @"section": @"Video_Settings", @"key": @"EnablePixelLighting",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"GPU Texture Decoding", @"section": @"Video_Settings", @"key": @"EnableGPUTextureDecoding",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"Force True Color", @"section": @"Video_Enhancements", @"key": @"ForceTrueColor",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"Disable Fog", @"section": @"Video_Settings", @"key": @"DisableFog",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"EFB Copies to Texture", @"section": @"Video_Hacks", @"key": @"EFBToTextureEnable",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"XFB Copies to Texture", @"section": @"Video_Hacks", @"key": @"XFBToTextureEnable",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"Scaled EFB Copies", @"section": @"Video_Hacks", @"key": @"EFBScaledCopy",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"Shader Compilation", @"section": @"Video_Settings", @"key": @"ShaderCompilationMode",
        @"choices": @[@"Specialized", @"Exclusive Ubershaders", @"Hybrid Ubershaders", @"Skip Drawing"],
        @"values": @[@"0", @"1", @"2", @"3"]}
    ],
    @[
      @{@"title": @"Dual Core", @"section": @"Core", @"key": @"CPUThread",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"Enable Cheats", @"section": @"Core", @"key": @"EnableCheats",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"MMU Emulation", @"section": @"Core", @"key": @"MMU",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"Custom CPU Clock", @"section": @"Core", @"key": @"OverclockEnable",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"CPU Clock Multiplier", @"section": @"Core", @"key": @"Overclock",
        @"choices": @[@"50%", @"75%", @"100%", @"125%", @"150%", @"200%"],
        @"values": @[@"0.5", @"0.75", @"1", @"1.25", @"1.5", @"2"]},
      @{@"title": @"Emulation Speed", @"section": @"Core", @"key": @"EmulationSpeed",
        @"choices": @[@"50%", @"75%", @"100%", @"125%", @"150%", @"Unlimited"],
        @"values": @[@"0.5", @"0.75", @"1", @"1.25", @"1.5", @"0"]}
    ],
    @[
      @{@"title": @"DSP HLE", @"section": @"Core", @"key": @"DSPHLE",
        @"choices": @[@"Off (LLE)", @"On (HLE)"], @"values": @[@"False", @"True"]},
      @{@"title": @"DSP on Separate Thread", @"section": @"DSP", @"key": @"DSPThread",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"Audio Latency", @"section": @"Core", @"key": @"AudioLatency",
        @"choices": @[@"10 ms", @"20 ms", @"40 ms", @"60 ms", @"100 ms"],
        @"values": @[@"10", @"20", @"40", @"60", @"100"]}
    ],
    @[
      @{@"title": @"Force True Color", @"section": @"Video_Enhancements", @"key": @"ForceTrueColor",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"Disable Copy Filter", @"section": @"Video_Enhancements", @"key": @"DisableCopyFilter",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"Arbitrary Mipmap Detection", @"section": @"Video_Enhancements", @"key": @"ArbitraryMipmapDetection",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"Pixel Lighting", @"section": @"Video_Settings", @"key": @"EnablePixelLighting",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]}
    ],
    @[
      @{@"title": @"EFB Access", @"section": @"Video_Hacks", @"key": @"EFBAccessEnable",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"Store EFB Copies to Texture", @"section": @"Video_Hacks", @"key": @"EFBToTextureEnable",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"Store XFB Copies to Texture", @"section": @"Video_Hacks", @"key": @"XFBToTextureEnable",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"Skip Duplicate XFBs", @"section": @"Video_Hacks", @"key": @"SkipDuplicateXFBs",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"Fast Depth Calculation", @"section": @"Video_Settings", @"key": @"FastDepthCalc",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"Disable Fog", @"section": @"Video_Settings", @"key": @"DisableFog",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"VBI Skip", @"section": @"Video_Hacks", @"key": @"VISkip",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]}
    ],
    @[
      @{@"title": @"Wii Widescreen", @"section": @"Wii", @"key": @"Widescreen",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"Progressive Scan", @"section": @"Core", @"key": @"ProgressiveScan",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]},
      @{@"title": @"PAL60", @"section": @"Core", @"key": @"PAL60",
        @"choices": @[@"Off", @"On"], @"values": @[@"False", @"True"]}
    ]
  ];

  // Game-specific controller profile names are loaded from Dolphin's real
  // Profiles/GCPad and Profiles/Wiimote directories, not fabricated options.
  NSMutableArray<NSDictionary*>* controllerSettings = [NSMutableArray array];
  NSString* configRoot = CppToFoundationString(File::GetUserPath(D_CONFIG_IDX));
  for (int controllerPort = 0; controllerPort < 4; ++controllerPort) {
    for (NSString* type in @[@"GCPad", @"Wiimote"]) {
      NSString* profileDir = [[configRoot stringByAppendingPathComponent:@"Profiles"]
                                 stringByAppendingPathComponent:type];
      NSArray<NSString*>* found =
          [[NSFileManager defaultManager] contentsOfDirectoryAtPath:profileDir error:nil];
      NSMutableArray<NSString*>* profileNames = [NSMutableArray array];
      for (NSString* filename in found) {
        if ([[filename.pathExtension lowercaseString] isEqualToString:@"ini"])
          [profileNames addObject:[filename stringByDeletingPathExtension]];
      }
      if (profileNames.count == 0)
        continue;
      [profileNames sortUsingSelector:@selector(localizedStandardCompare:)];
      NSString* displayType = [type isEqualToString:@"GCPad"] ? @"GameCube" : @"Wii Remote";
      // Dolphin GameConfigLoader uses 1-based profile slot names.
      NSString* key = [NSString stringWithFormat:@"%@Profile%d",
          [type isEqualToString:@"GCPad"] ? @"Pad" : @"Wiimote", controllerPort + 1];
      [controllerSettings addObject:@{
        @"title": [NSString stringWithFormat:@"%@ Port %d", displayType, controllerPort + 1],
        @"section": [type isEqualToString:@"GCPad"] ? @"GCPad.Controls" : @"Wiimote.Controls",
        @"key": key, @"choices": profileNames, @"values": profileNames
      }];
    }
  }
  NSMutableArray<NSArray<NSDictionary*>*>* groups = [_sections mutableCopy];
  NSMutableArray<NSString*>* titles = [@[@"Graphics", @"Emulation", @"Audio", @"Enhancements", @"Graphics Hacks", @"Wii"] mutableCopy];
  if (controllerSettings.count > 0) {
    [groups addObject:controllerSettings];
    [titles addObject:@"Controller Profiles"];
  }
  _sections = groups;
  _sectionTitles = titles;

  std::string gameId = _game.gameFile->GetGameID();
  std::string rev = std::to_string(_game.gameFile->GetRevision());
  const std::string iniPath = File::GetUserPath(D_GAMESETTINGS_IDX) +
                              gameId + "r" + rev + ".ini";
  _iniPath = CppToFoundationString(iniPath);
  _ini.Load(FoundationToCppString(_iniPath));
}

- (void)closeSettings {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
  return _sections.count + 1;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  return section < (NSInteger)_sections.count ? _sections[section].count : 1;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
  return section < (NSInteger)_sectionTitles.count ? _sectionTitles[section] : @"Overrides";
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
  if (section == 0)
    return @"Use Global follows the main Dolphin setting. Other choices override it for this game only.";
  if (section == (NSInteger)_sections.count)
    return @"Clears only the overrides shown above. Existing cheat codes and other GameINI data are preserved.";
  if (section == (NSInteger)_sections.count - 1 && _sections.count > 6)
    return @"Select a controller profile already saved in Dolphin. Settings are loaded only for this game.";
  return nil;
}

// Read the base (global) Dolphin configuration, not a game's overrides.
// Use the same typed config keys as Dolphin so defaults are shown correctly
// even when no explicit setting is stored in the global INI.
- (NSString*)globalChoiceForSetting:(NSDictionary*)setting {
  NSString* key = setting[@"key"];
  std::string raw;
#define DOL_GLOBAL(K, INFO) if ([key isEqualToString:@K]) raw = ValueToString(Config::GetBase(Config::INFO))
  DOL_GLOBAL("AspectRatio", GFX_ASPECT_RATIO);
  else DOL_GLOBAL("InternalResolution", GFX_EFB_SCALE);
  else DOL_GLOBAL("wideScreenHack", GFX_WIDESCREEN_HACK);
  else DOL_GLOBAL("VSync", GFX_VSYNC);
  else DOL_GLOBAL("HiresTextures", GFX_HIRES_TEXTURES);
  else DOL_GLOBAL("CacheHiresTextures", GFX_CACHE_HIRES_TEXTURES);
  else DOL_GLOBAL("ShowFPS", GFX_SHOW_FPS);
  else DOL_GLOBAL("MaxAnisotropy", GFX_ENHANCE_MAX_ANISOTROPY);
  else DOL_GLOBAL("EnablePixelLighting", GFX_ENABLE_PIXEL_LIGHTING);
  else DOL_GLOBAL("EnableGPUTextureDecoding", GFX_ENABLE_GPU_TEXTURE_DECODING);
  else DOL_GLOBAL("ForceTrueColor", GFX_ENHANCE_FORCE_TRUE_COLOR);
  else DOL_GLOBAL("DisableFog", GFX_DISABLE_FOG);
  else DOL_GLOBAL("EFBToTextureEnable", GFX_HACK_SKIP_EFB_COPY_TO_RAM);
  else DOL_GLOBAL("XFBToTextureEnable", GFX_HACK_SKIP_XFB_COPY_TO_RAM);
  else DOL_GLOBAL("EFBScaledCopy", GFX_HACK_COPY_EFB_SCALED);
  else DOL_GLOBAL("ShaderCompilationMode", GFX_SHADER_COMPILATION_MODE);
  else DOL_GLOBAL("CPUThread", MAIN_CPU_THREAD);
  else DOL_GLOBAL("EnableCheats", MAIN_ENABLE_CHEATS);
  else DOL_GLOBAL("MMU", MAIN_MMU);
  else DOL_GLOBAL("OverclockEnable", MAIN_OVERCLOCK_ENABLE);
  else DOL_GLOBAL("Overclock", MAIN_OVERCLOCK);
  else DOL_GLOBAL("EmulationSpeed", MAIN_EMULATION_SPEED);
  else DOL_GLOBAL("DSPHLE", MAIN_DSP_HLE);
  else DOL_GLOBAL("DSPThread", MAIN_DSP_THREAD);
  else DOL_GLOBAL("AudioLatency", MAIN_AUDIO_LATENCY);
  else DOL_GLOBAL("DisableCopyFilter", GFX_ENHANCE_DISABLE_COPY_FILTER);
  else DOL_GLOBAL("ArbitraryMipmapDetection", GFX_ENHANCE_ARBITRARY_MIPMAP_DETECTION);
  else DOL_GLOBAL("EFBAccessEnable", GFX_HACK_EFB_ACCESS_ENABLE);
  else DOL_GLOBAL("SkipDuplicateXFBs", GFX_HACK_SKIP_DUPLICATE_XFBS);
  else DOL_GLOBAL("FastDepthCalc", GFX_FAST_DEPTH_CALC);
  else DOL_GLOBAL("VISkip", GFX_HACK_VI_SKIP);
  else DOL_GLOBAL("Widescreen", SYSCONF_WIDESCREEN);
  else DOL_GLOBAL("ProgressiveScan", SYSCONF_PROGRESSIVE_SCAN);
  else DOL_GLOBAL("PAL60", SYSCONF_PAL60);
#undef DOL_GLOBAL
  if (raw.empty())
    return nil;  // A saved controller profile need not have an enumerated global value.
  NSUInteger index = [setting[@"values"] indexOfObject:CppToFoundationString(raw)];
  if (index != NSNotFound && index < [setting[@"choices"] count])
    return setting[@"choices"][index];
  return CppToFoundationString(raw);
}

- (NSString*)useGlobalLabelForSetting:(NSDictionary*)setting {
  NSString* globalChoice = [self globalChoiceForSetting:setting];
  return globalChoice.length ?
      [NSString stringWithFormat:@"Use Global (%@)", globalChoice] : @"Use Global";
}

// Each configuration option explains the effect of overriding the global value.
// This is display-only: Dolphin's actual GameINI setting keys remain unchanged.
- (NSString*)descriptionForSetting:(NSDictionary*)setting {
  static NSDictionary<NSString*, NSString*>* descriptions;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    descriptions = @{
      @"AspectRatio": @"Changes the screen proportions. Auto follows the game, 16:9 or 4:3 forces an aspect ratio, and Stretch can distort the image. It does not add new widescreen scenery.",
      @"InternalResolution": @"Controls 3D rendering resolution. Higher values sharpen the picture but use more GPU power and may lower FPS. Native 1x is closest to the original console.",
      @"wideScreenHack": @"Attempts to expand a game's 3D view for widescreen. On may reveal more scenery but can cause pop-in, broken effects, or stretched menus.",
      @"VSync": @"Synchronizes displayed frames with the screen to reduce tearing. On can add input delay or stutter; Off may respond faster but can show torn frames.",
      @"HiresTextures": @"Loads custom replacement textures from Load/Textures for this game's ID. On requires an existing texture pack; Off ignores it. More detailed textures can use extra memory.",
      @"CacheHiresTextures": @"Keeps replacement textures in memory. On may reduce loading stutter but uses more RAM; Off loads textures as needed.",
      @"ShowFPS": @"Displays an FPS counter while playing. On shows performance; Off hides it without meaningfully changing gameplay speed.",
      @"MaxAnisotropy": @"Improves sharpness of floor, road, and other angled textures. Higher filtering levels may increase GPU workload.",
      @"EnablePixelLighting": @"Calculates some lighting effects per pixel for more accurate visuals. On may improve lighting but use more GPU resources.",
      @"EnableGPUTextureDecoding": @"Lets the GPU decode supported game textures instead of the CPU. On may run faster on some hardware; Off may work better for compatibility.",
      @"ForceTrueColor": @"Uses greater color precision to reduce banding. On may clean up gradients but alter the original look or performance.",
      @"DisableFog": @"Removes game fog when set to On. This can improve visibility but expose glitches and change the game's intended atmosphere.",
      @"EFBToTextureEnable": @"Controls embedded-framebuffer copies. On uses faster texture copies; Off uses RAM copies for effects needing more accurate readback, potentially at a speed cost.",
      @"XFBToTextureEnable": @"Controls external-framebuffer copies. On favors faster texture copies; Off can improve compatibility with games needing RAM copies.",
      @"EFBScaledCopy": @"Scales copied framebuffer effects to the internal resolution. On can sharpen reflections and effects; Off preserves original-size copies and may prevent glitches.",
      @"ShaderCompilationMode": @"Controls shader preparation. Specialized can stutter during compilation; ubershaders demand more GPU power but reduce some stutter; Skip Drawing may hide effects temporarily.",
      @"CPUThread": @"Runs CPU and graphics processing on different threads. On often improves performance; Off may avoid timing bugs but can be slower.",
      @"EnableCheats": @"Allows enabled Action Replay and Gecko codes to take effect in this game. On does nothing unless cheats are configured; Off disables them.",
      @"MMU": @"Emulates the console's memory management more accurately. On can fix compatibility but can be significantly slower.",
      @"OverclockEnable": @"Allows a custom emulated console CPU speed. On applies the multiplier below; Off keeps the normal clock.",
      @"Overclock": @"Changes the emulated console CPU clock, not the iPhone clock. Above 100% may help CPU-limited games; other values can change timing or stability. Requires Custom CPU Clock.",
      @"EmulationSpeed": @"Sets target gameplay speed. 100% is normal, lower values are slow motion, and Unlimited removes the speed cap if your device can keep up.",
      @"DSPHLE": @"Selects audio emulation method. On uses faster high-level emulation (HLE); Off uses potentially more accurate but slower low-level emulation (LLE).",
      @"DSPThread": @"Processes console audio on a separate thread. On can improve speed but may introduce audio synchronization problems.",
      @"AudioLatency": @"Changes sound buffering. Lower values reduce audio delay but risk crackling; higher values smooth sound but increase delay.",
      @"DisableCopyFilter": @"Removes some original console image filters from framebuffer copies. On may look sharper; Off preserves the original effects.",
      @"ArbitraryMipmapDetection": @"Changes detection of unusual texture mipmap levels. On may fix some texture artifacts; Off can affect texture sharpness or performance.",
      @"EFBAccessEnable": @"Allows the game to access embedded-framebuffer contents. On supports screen-reading effects; Off may be faster but can break them.",
      @"SkipDuplicateXFBs": @"Skips repeated copies of identical output frames. On can help performance or pacing; Off may work better with unusual video effects.",
      @"FastDepthCalc": @"Uses faster, simplified depth calculations. On can improve performance; Off favors accuracy and can fix layering or shadow glitches.",
      @"VISkip": @"Adjusts video-interface updates when the emulator falls behind. On may keep gameplay running but change frame pacing; Off preserves normal presentation.",
      @"Widescreen": @"Sets the Wii system's 16:9 preference for supported games. On requests widescreen; Off requests 4:3. Games without support still need a patch.",
      @"ProgressiveScan": @"Requests progressive video output for games that support it. On can improve picture clarity, but some titles ignore the request.",
      @"PAL60": @"Requests 60 Hz output in PAL Wii games that support it. On can improve motion smoothness; Off uses the default PAL video mode.",
    };
  });
  NSString* key = setting[@"key"];
  NSString* description = descriptions[key];
  if (description.length)
    return description;
  if ([key hasPrefix:@"PadProfile"])
    return @"Select a saved GameCube controller mapping for this port and this game only. Use Global keeps the regular controller mapping.";
  if ([key hasPrefix:@"WiimoteProfile"])
    return @"Select a saved Wii Remote controller mapping for this player and this game only. Use Global keeps the regular controller mapping.";
  return @"Use Global follows Dolphin's main setting. Selecting a different value changes it only for this game.";
}

- (NSString*)valueForSetting:(NSDictionary*)setting {
  std::string value;
  const auto* group = _ini.GetSection(FoundationToCppString(setting[@"section"]));
  if (group == nullptr || !group->Get(FoundationToCppString(setting[@"key"]), &value))
    return [self useGlobalLabelForSetting:setting];
  NSUInteger index = [setting[@"values"] indexOfObject:CppToFoundationString(value)];
  if (index != NSNotFound && index < [setting[@"choices"] count])
    return setting[@"choices"][index];
  return [NSString stringWithFormat:@"Custom (%@)", CppToFoundationString(value)];
}

- (UITableViewCell*)tableView:(UITableView*)tableView
         cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  if (indexPath.section == (NSInteger)_sections.count) {
    UITableViewCell* resetCell = [tableView dequeueReusableCellWithIdentifier:@"ResetGameOverrides"];
    if (resetCell == nil)
      resetCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                         reuseIdentifier:@"ResetGameOverrides"];
    resetCell.textLabel.text = @"Reset These Overrides";
    resetCell.textLabel.textColor = [UIColor systemRedColor];
    resetCell.accessoryType = UITableViewCellAccessoryNone;
    return resetCell;
  }

  // Three labels let every setting show a title, its inherited or overridden
  // value, and a readable explanation even on narrow phones or large text.
  static const NSInteger nameTag = 7301;
  static const NSInteger valueTag = 7302;
  static const NSInteger descriptionTag = 7303;
  UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:@"ExplainedGameSetting"];
  if (cell == nil) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                 reuseIdentifier:@"ExplainedGameSetting"];
    UILabel* name = [[UILabel alloc] init];
    name.tag = nameTag;
    name.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    name.adjustsFontForContentSizeCategory = YES;
    name.textColor = [UIColor labelColor];
    name.numberOfLines = 0;

    UILabel* value = [[UILabel alloc] init];
    value.tag = valueTag;
    value.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    value.adjustsFontForContentSizeCategory = YES;
    value.textColor = [UIColor systemBlueColor];
    value.numberOfLines = 0;

    UILabel* detail = [[UILabel alloc] init];
    detail.tag = descriptionTag;
    detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    detail.adjustsFontForContentSizeCategory = YES;
    detail.textColor = [UIColor secondaryLabelColor];
    detail.numberOfLines = 0;

    UIStackView* stack = [[UIStackView alloc] initWithArrangedSubviews:@[name, value, detail]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 3;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
      [stack.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
      [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-10],
      [stack.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12],
      [stack.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12]
    ]];
  }
  NSDictionary* setting = _sections[indexPath.section][indexPath.row];
  ((UILabel*)[cell.contentView viewWithTag:nameTag]).text = setting[@"title"];
  ((UILabel*)[cell.contentView viewWithTag:valueTag]).text = [self valueForSetting:setting];
  ((UILabel*)[cell.contentView viewWithTag:descriptionTag]).text =
      [self descriptionForSetting:setting];
  cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  return cell;
}

- (void)saveGameIni {
  NSFileManager* fm = [NSFileManager defaultManager];
  [fm createDirectoryAtPath:[_iniPath stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES attributes:nil error:nil];
  if (!_ini.Save(FoundationToCppString(_iniPath))) {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Save Failed"
        message:@"Could not save this game's settings." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
  }
  [self.tableView reloadData];
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (indexPath.section == (NSInteger)_sections.count) {
    UIAlertController* confirm = [UIAlertController alertControllerWithTitle:@"Reset Game Overrides"
       message:@"Clear just the settings displayed here? Other GameINI entries will be kept."
       preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Reset"
        style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction* action) {
      for (NSArray<NSDictionary*>* group in self->_sections) {
        for (NSDictionary* setting in group) {
          self->_ini.DeleteKey(FoundationToCppString(setting[@"section"]),
                               FoundationToCppString(setting[@"key"]));
        }
      }
      [self saveGameIni];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
    return;
  }

  NSDictionary* setting = _sections[indexPath.section][indexPath.row];
  UIAlertController* choices = [UIAlertController
      alertControllerWithTitle:setting[@"title"]
                      message:[NSString stringWithFormat:
                          @"%@\n\nCurrent: %@\n\nUse Global follows Dolphin's main setting. Other choices override it for this game only.",
                          [self descriptionForSetting:setting],
                          [self valueForSetting:setting]]
               preferredStyle:UIAlertControllerStyleActionSheet];
  [choices addAction:[UIAlertAction actionWithTitle:[self useGlobalLabelForSetting:setting]
      style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* action) {
    self->_ini.DeleteKey(FoundationToCppString(setting[@"section"]),
                         FoundationToCppString(setting[@"key"]));
    [self saveGameIni];
  }]];
  NSArray<NSString*>* labels = setting[@"choices"];
  NSArray<NSString*>* values = setting[@"values"];
  for (NSUInteger i = 0; i < labels.count; ++i) {
    NSString* label = labels[i];
    NSString* value = values[i];
    [choices addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction* action) {
      auto* section = self->_ini.GetOrCreateSection(
          FoundationToCppString(setting[@"section"]));
      section->Set(FoundationToCppString(setting[@"key"]), FoundationToCppString(value));
      [self saveGameIni];
    }]];
  }
  [choices addAction:[UIAlertAction actionWithTitle:@"Cancel"
      style:UIAlertActionStyleCancel handler:nil]];
  choices.popoverPresentationController.sourceView = tableView;
  choices.popoverPresentationController.sourceRect =
      [tableView rectForRowAtIndexPath:indexPath];
  [self presentViewController:choices animated:YES completion:nil];
}

@end

typedef NS_ENUM(NSInteger, DOLSoftwareListDocumentPickerType) {
  DOLSoftwareListDocumentPickerTypeImportSoftware,
  DOLSoftwareListDocumentPickerTypeImportNAND,
  DOLSoftwareListDocumentPickerTypeOpenExternal,
  DOLSoftwareListDocumentPickerTypeImportPatchProfile,
};


@implementation SoftwareListiOSViewController {
  DOLSoftwareListDocumentPickerType _pickerType;
  UIBarButtonItem* _sortButton;
  NSURL* _openedUrl;
  GameFilePtrWrapper* _profileImportGame;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  // Keep Dolphin's original Open and Add buttons, and use the same native iOS
  // translucent UIMenu UI for sorting game covers.
  UIBarButtonItem* addButton = self.navigationItem.rightBarButtonItem;
  _sortButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease"]
                                                style:UIBarButtonItemStylePlain target:nil action:nil];
  _sortButton.accessibilityLabel = @"Sort Games";
  _sortButton.menu = [self gameSortingMenu];
  self.navigationItem.rightBarButtonItems = addButton ? @[addButton, _sortButton] : @[_sortButton];
}

- (UIMenu*)gameSortingMenu {
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  NSString* selected = [defaults stringForKey:@"DOLSoftwareSortKey"] ?: @"recent";
  BOOL ascending = [defaults objectForKey:@"DOLSoftwareSortAscending"] ?
      [defaults boolForKey:@"DOLSoftwareSortAscending"] : NO;

  NSMutableArray<UIMenuElement*>* sortChoices = [NSMutableArray array];
  for (NSDictionary* choice in @[
      @{@"key": @"recent", @"title": @"Recently Played"},
      @{@"key": @"name", @"title": @"Name"},
      @{@"key": @"time", @"title": @"Time Played"}]) {
    NSString* key = choice[@"key"];
    UIAction* action = [UIAction actionWithTitle:choice[@"title"] image:nil identifier:nil handler:^(__unused UIAction* selectedAction) {
      [[NSUserDefaults standardUserDefaults] setObject:key forKey:@"DOLSoftwareSortKey"];
      [self sortGameFiles];
      [self.collectionView reloadData];
      self->_sortButton.menu = [self gameSortingMenu];
    }];
    action.state = [key isEqualToString:selected] ? UIMenuElementStateOn : UIMenuElementStateOff;
    [sortChoices addObject:action];
  }

  NSMutableArray<UIMenuElement*>* orderChoices = [NSMutableArray array];
  for (NSNumber* number in @[@YES, @NO]) {
    BOOL isAscending = number.boolValue;
    UIAction* action = [UIAction actionWithTitle:isAscending ? @"Ascending" : @"Descending"
                                          image:nil identifier:nil handler:^(__unused UIAction* selectedAction) {
      [[NSUserDefaults standardUserDefaults] setBool:isAscending forKey:@"DOLSoftwareSortAscending"];
      [self sortGameFiles];
      [self.collectionView reloadData];
      self->_sortButton.menu = [self gameSortingMenu];
    }];
    action.state = isAscending == ascending ? UIMenuElementStateOn : UIMenuElementStateOff;
    [orderChoices addObject:action];
  }

  return [UIMenu menuWithChildren:@[
      [UIMenu menuWithTitle:@"Sort By" image:nil identifier:nil
                   options:UIMenuOptionsDisplayInline children:sortChoices],
      [UIMenu menuWithTitle:@"Order" image:nil identifier:nil
                   options:UIMenuOptionsDisplayInline children:orderChoices]
  ]];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receiveImportFileFinishedNotification) name:DOLImportFileFinishedNotification object:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  
  [[NSNotificationCenter defaultCenter] removeObserver:self name:DOLImportFileFinishedNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  
  if (_openedUrl != nil) {
    [_openedUrl stopAccessingSecurityScopedResource];
    _openedUrl = nil;
  }
  
  NSArray<UIMenuElement*>* wiiActions;
  
  UIMenuElement* wiiNandElement = [UIMenu menuWithTitle:DOLCoreLocalizedString(@"Manage NAND") image:[UIImage systemImageNamed:@"wrench.and.screwdriver"] identifier:nil options:0 children:@[
    [UIAction actionWithTitle:DOLCoreLocalizedString(@"Import BootMii NAND Backup...") image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil handler:^(UIAction*) {
      [self openDocumentPickerWithContentTypes:@[
        [UTType typeWithFilenameExtension:@"bin"]
      ] pickerType:DOLSoftwareListDocumentPickerTypeImportNAND];
    }]
  ]];
  
  // Get the system menu TMD
  IOS::HLE::Kernel ios;
  const auto tmd = ios.GetESCore().FindInstalledTMD(Titles::SYSTEM_MENU);
  
  if (tmd.IsValid()) {
    NSString* loadFormat;
    
    if (tmd.IsvWii()) {
      loadFormat = DOLCoreLocalizedStringWithArgs(@"Load vWii System Menu %1", @"@");
    } else {
      loadFormat = DOLCoreLocalizedStringWithArgs(@"Load Wii System Menu %1", @"@");
    }
    
    std::string version = DiscIO::GetSysMenuVersionString(tmd.GetTitleVersion(), tmd.IsvWii());
    
    wiiActions = @[
      [UIAction actionWithTitle:[NSString stringWithFormat:loadFormat, CppToFoundationString(version)] image:[UIImage systemImageNamed:@"power.circle"] identifier:nil handler:^(UIAction*) {
        self->_bootParameter = [[EmulationBootParameter alloc] init];
        self->_bootParameter.bootType = EmulationBootTypeSystemMenu;
        
        [self performSegueWithIdentifier:@"emulation" sender:nil];
      }],
      wiiNandElement,
      [UIAction actionWithTitle:DOLCoreLocalizedString(@"Perform Online System Update") image:[UIImage systemImageNamed:@"icloud.and.arrow.down"] identifier:nil handler:^(UIAction*) {
        [self performSegueForWiiUpdateWithSource:@"" isOnline:true];
      }]
    ];
  } else {
    wiiActions = @[
      wiiNandElement,
      [UIMenu menuWithTitle:DOLCoreLocalizedString(@"Perform Online System Update") image:[UIImage systemImageNamed:@"icloud.and.arrow.down"] identifier:nil options:0 children:@[
        [UIAction actionWithTitle:DOLCoreLocalizedString(@"Europe") image:nil identifier:nil handler:^(UIAction*) {
          [self performSegueForWiiUpdateWithSource:@"EUR" isOnline:true];
        }],
        [UIAction actionWithTitle:DOLCoreLocalizedString(@"Japan") image:nil identifier:nil handler:^(UIAction*) {
          [self performSegueForWiiUpdateWithSource:@"JPN" isOnline:true];
        }],
        [UIAction actionWithTitle:DOLCoreLocalizedString(@"Korea") image:nil identifier:nil handler:^(UIAction*) {
          [self performSegueForWiiUpdateWithSource:@"KOR" isOnline:true];
        }],
        [UIAction actionWithTitle:DOLCoreLocalizedString(@"United States") image:nil identifier:nil handler:^(UIAction*) {
          [self performSegueForWiiUpdateWithSource:@"USA" isOnline:true];
        }]
      ]
    ]];
  }
  
  NSMutableArray<UIMenuElement*>* iplActions = [[NSMutableArray alloc] init];
  
  void(^addIPLAction)(DiscIO::Region, NSString*, std::string) = ^(DiscIO::Region region, NSString* regionName, std::string regionDir) {
    UIAction* iplAction = [UIAction actionWithTitle:DOLCoreLocalizedString(regionName) image:nil identifier:nil handler:^(UIAction*) {
      [self loadGameCubeIPLForRegion:region];
    }];
    
    if (!File::Exists(Config::GetBootROMPath(regionDir))) {
      [iplAction setAttributes:UIMenuElementAttributesDisabled];
    }
    
    [iplActions addObject:iplAction];
  };
  
  addIPLAction(DiscIO::Region::NTSC_J, @"NTSC-J", JAP_DIR);
  addIPLAction(DiscIO::Region::NTSC_U, @"NTSC-U", USA_DIR);
  addIPLAction(DiscIO::Region::PAL, @"PAL", EUR_DIR);
  
  self.navigationItem.leftBarButtonItem.menu = [UIMenu menuWithChildren:@[
    [UIAction actionWithTitle:DOLCoreLocalizedString(@"Open") image:[UIImage systemImageNamed:@"externaldrive"] identifier:nil handler:^(UIAction*) {
      [self openDocumentPickerWithSoftwareContentTypesAndPickerType:DOLSoftwareListDocumentPickerTypeOpenExternal];
    }],
    [UIMenu menuWithTitle:DOLCoreLocalizedString(@"GameCube") image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
      [UIMenu menuWithTitle:@"Load GameCube Main Menu" image:[UIImage systemImageNamed:@"power.circle"] identifier:nil options:0 children:iplActions]
    ]],
    [UIMenu menuWithTitle:DOLCoreLocalizedString(@"Wii") image:nil identifier:nil options:UIMenuOptionsDisplayInline children:wiiActions]
  ]];
}

- (void)openDocumentPickerWithSoftwareContentTypesAndPickerType:(DOLSoftwareListDocumentPickerType)pickerType {
  NSArray<UTType*>* types = @[
    [UTType exportedTypeWithIdentifier:@"me.oatmealdome.dolphinios.generic-software"],
    [UTType exportedTypeWithIdentifier:@"me.oatmealdome.dolphinios.gamecube-software"],
    [UTType exportedTypeWithIdentifier:@"me.oatmealdome.dolphinios.wii-software"]
  ];
  
  [self openDocumentPickerWithContentTypes:types pickerType:pickerType];
}

- (void)openDocumentPickerWithContentTypes:(NSArray<UTType*>*)contentTypes pickerType:(DOLSoftwareListDocumentPickerType)pickerType {
  UIDocumentPickerViewController* pickerController = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:contentTypes];
  pickerController.delegate = self;
  pickerController.modalPresentationStyle = UIModalPresentationPageSheet;
  pickerController.allowsMultipleSelection = false;
  
  _pickerType = pickerType;
  
  [self presentViewController:pickerController animated:true completion:nil];
}

- (IBAction)addButtonPressed:(id)sender {
  [self openDocumentPickerWithSoftwareContentTypesAndPickerType:DOLSoftwareListDocumentPickerTypeImportSoftware];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  void (^showError)(NSString*) = ^(NSString* error) {
    UIAlertController* errorAlert = [UIAlertController alertControllerWithTitle:DOLCoreLocalizedString(@"Error") message:error preferredStyle:UIAlertControllerStyleAlert];
    
    [errorAlert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"OK") style:UIAlertActionStyleDefault
      handler:nil]];
    
    [self presentViewController:errorAlert animated:true completion:nil];
  };
  
  if (_pickerType == DOLSoftwareListDocumentPickerTypeImportSoftware) {
    [[ImportFileManager shared] importFileAtUrl:urls[0]];
  } else if (_pickerType == DOLSoftwareListDocumentPickerTypeOpenExternal) {
    NSURL* url = urls[0];
    
    if (![url startAccessingSecurityScopedResource]) {
      showError(@"Failed to start accessing security scoped resource.");
      return;
    }
    
    _openedUrl = url;
    
    NSString* sourcePath = [_openedUrl path];
    
    GameFilePtrWrapper* gameFileWrapper = [[GameFilePtrWrapper alloc] init];
    gameFileWrapper.gameFile = std::make_shared<UICommon::GameFile>(FoundationToCppString(sourcePath));
    
    if (!gameFileWrapper.gameFile->IsValid()) {
      [_openedUrl stopAccessingSecurityScopedResource];
      
      showError(@"File is invalid.");
      
      return;
    }
    
    [self loadGameFile:gameFileWrapper];
  } else if (_pickerType == DOLSoftwareListDocumentPickerTypeImportPatchProfile) {
    if (urls.count > 0)
      [self finishImportPatchProfile:urls[0]];
  } else if (_pickerType == DOLSoftwareListDocumentPickerTypeImportNAND) {
    NSURL* url = urls[0];
    
    if (![url startAccessingSecurityScopedResource]) {
      showError(@"Failed to start accessing security scoped resource.");
      return;
    }
    
    UIAlertController* waitAlert = [UIAlertController alertControllerWithTitle:DOLCoreLocalizedString(@"Importing NAND backup") message:nil preferredStyle:UIAlertControllerStyleAlert];
    
    [self presentViewController:waitAlert animated:true completion:^{
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        DiscIO::NANDImporter().ImportNANDBin(FoundationToCppString([url path]), [] {
          // Called to update the GUI. We don't need to do this.
        }, [] {
          // Called if we need to find NAND keys. Android doesn't implement this, so let's not do it either.
          PanicAlertFmtT("The decryption keys need to be appended to the NAND backup file.");
          return "";
        });
        
        [url stopAccessingSecurityScopedResource];
        
        dispatch_async(dispatch_get_main_queue(), ^{
          [waitAlert dismissViewControllerAnimated:true completion:nil];
        });
      });
    }];
  }
}

- (UIContextMenuConfiguration*)collectionView:(UICollectionView*)collectionView contextMenuConfigurationForItemAtIndexPath:(NSIndexPath*)indexPath point:(CGPoint)point {
  return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^(NSArray<UIMenuElement*>*) {
    GameFilePtrWrapper* gameFileWrapper = [self->_gameFiles objectAtIndex:indexPath.row];
    
    NSMutableArray<UIAction*>* actions = [[NSMutableArray alloc] init];
    
    [actions addObject:[UIAction actionWithTitle:DOLCoreLocalizedString(@"Game Info")
                                               image:[UIImage systemImageNamed:@"info.circle"]
                                          identifier:nil handler:^(UIAction*) {
      UIStoryboard* storyboard = [UIStoryboard storyboardWithName:@"SoftwareProperties" bundle:nil];
      SoftwarePropertiesInfoViewController* info =
          [storyboard instantiateViewControllerWithIdentifier:@"GameInfo"];
      info.gameFileWrapper = gameFileWrapper;
      info.navigationItem.title = DOLCoreLocalizedString(@"Game Info");
      info.navigationItem.rightBarButtonItem =
          [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                       target:self
                                                       action:@selector(dismissGameInfo)];
      UINavigationController* nav = [[UINavigationController alloc] initWithRootViewController:info];
      [self presentViewController:nav animated:YES completion:nil];
    }]];

    [actions addObject:[UIAction actionWithTitle:@"Game Settings"
                                               image:[UIImage systemImageNamed:@"slider.horizontal.3"]
                                          identifier:nil handler:^(__unused UIAction* action) {
      [self openGameSettings:gameFileWrapper];
    }]];

    [actions addObject:[UIAction actionWithTitle:@"Launch Profiles"
                                               image:[UIImage systemImageNamed:@"square.stack"]
                                          identifier:nil handler:^(__unused UIAction* action) {
      [self showLaunchProfilesForGame:gameFileWrapper];
    }]];

    [actions addObject:[UIAction actionWithTitle:@"Import Patch Profile…"
                                               image:[UIImage systemImageNamed:@"doc.badge.plus"]
                                          identifier:nil handler:^(__unused UIAction* action) {
      [self importPatchProfileForGame:gameFileWrapper];
    }]];

    [actions addObject:[UIAction actionWithTitle:DOLCoreLocalizedString(@"Cheat Codes")
                                               image:[UIImage systemImageNamed:@"chevron.left.forwardslash.chevron.right"]
                                          identifier:nil handler:^(UIAction*) {
      self->_selectedFile = gameFileWrapper;
      [self performSegueWithIdentifier:@"properties" sender:nil];
    }]];
    
    UIAction* deleteAction = [UIAction actionWithTitle:DOLCoreLocalizedString(@"Delete") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction*) {
      UIAlertController* confirmAlert = [UIAlertController alertControllerWithTitle:DOLCoreLocalizedString(@"Confirm") message:DOLCoreLocalizedString(@"Are you sure you want to delete this file?") preferredStyle:UIAlertControllerStyleAlert];
        
      [confirmAlert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"No") style:UIAlertActionStyleDefault handler:nil]];
      
      [confirmAlert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"Yes") style:UIAlertActionStyleDestructive handler:^(UIAlertAction*) {
        if (File::Delete(gameFileWrapper.gameFile->GetFilePath())) {
          [self reloadGameFiles];
        }
      }]];
      
      [self presentViewController:confirmAlert animated:true completion:nil];
    }];
    
    [deleteAction setAttributes:UIMenuElementAttributesDestructive];
    
    [actions addObject:deleteAction];
    
    NSString* gameName = CppToFoundationString(gameFileWrapper.gameFile->GetName(UICommon::GameFile::Variant::LongAndPossiblyCustom));
    
    return [UIMenu menuWithTitle:gameName children:[actions copy]];
  }];
}

- (void)dismissGameInfo {
  [self dismissViewControllerAnimated:YES completion:nil];
}


#pragma mark - Per-game settings and launch profiles

- (NSString*)profileGameKey:(GameFilePtrWrapper*)game {
  const std::string& gameId = game.gameFile->GetGameID();
  return [NSString stringWithFormat:@"%@r%u",
      CppToFoundationString(gameId), (unsigned)game.gameFile->GetRevision()];
}

- (NSString*)profileDirectory:(GameFilePtrWrapper*)game {
  NSString* profiles = [NSHomeDirectory() stringByAppendingPathComponent:
      @"Documents/DolphiniOSLaunchProfiles"];
  return [profiles stringByAppendingPathComponent:[self profileGameKey:game]];
}

- (NSString*)profileDefaultKey:(GameFilePtrWrapper*)game {
  return [@"DolphiniOSDefaultLaunchProfile:" stringByAppendingString:
      [self profileGameKey:game]];
}

- (NSArray<NSString*>*)profilesForGame:(GameFilePtrWrapper*)game {
  NSString* directory = [self profileDirectory:game];
  NSArray<NSString*>* files =
      [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil];
  NSMutableArray<NSString*>* paths = [NSMutableArray array];
  for (NSString* filename in files) {
    if ([[filename.pathExtension lowercaseString] isEqualToString:@"json"]) {
      NSString* path = [directory stringByAppendingPathComponent:filename];
      auto descriptor = DiscIO::ParseGameModDescriptorFile(FoundationToCppString(path));
      if (descriptor)
        [paths addObject:path];
    }
  }
  // Recognize existing descriptor JSONs already imported as games. These are
  // hidden from the library when their base disc exists, but remain launchable
  // here without copying or deleting any of the user's original files.
  for (GameFilePtrWrapper* candidate in [[GameFileCacheManager sharedManager] getGames]) {
    if (candidate.gameFile->GetBlobType() != DiscIO::BlobType::MOD_DESCRIPTOR)
      continue;
    auto descriptor =
        DiscIO::ParseGameModDescriptorFile(candidate.gameFile->GetFilePath());
    if (descriptor && descriptor->base_file == game.gameFile->GetFilePath()) {
      NSString* path = CppToFoundationString(candidate.gameFile->GetFilePath());
      if (![paths containsObject:path])
        [paths addObject:path];
    }
  }
  [paths sortUsingSelector:@selector(localizedStandardCompare:)];
  return paths;
}

- (NSString*)profileLabel:(NSString*)path {
  auto descriptor = DiscIO::ParseGameModDescriptorFile(FoundationToCppString(path));
  if (descriptor && !descriptor->display_name.empty())
    return CppToFoundationString(descriptor->display_name);
  return [[path lastPathComponent] stringByDeletingPathExtension];
}

- (void)presentProfileError:(NSString*)message {
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Launch Profiles"
      message:message preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK"
      style:UIAlertActionStyleDefault handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)openGameSettings:(GameFilePtrWrapper*)game {
  DOLPerGameSettingsViewController* settings =
      [[DOLPerGameSettingsViewController alloc] initWithGame:game];
  UINavigationController* nav = [[UINavigationController alloc]
      initWithRootViewController:settings];
  [self presentViewController:nav animated:YES completion:nil];
}

- (void)importPatchProfileForGame:(GameFilePtrWrapper*)game {
  _profileImportGame = game;
  UTType* json = [UTType typeWithFilenameExtension:@"json"];
  [self openDocumentPickerWithContentTypes:@[json]
      pickerType:DOLSoftwareListDocumentPickerTypeImportPatchProfile];
}

- (void)finishImportPatchProfile:(NSURL*)url {
  GameFilePtrWrapper* game = _profileImportGame;
  _profileImportGame = nil;
  BOOL scopedAccess = [url startAccessingSecurityScopedResource];
  if (game == nil || ![[NSFileManager defaultManager] isReadableFileAtPath:url.path]) {
    if (scopedAccess) [url stopAccessingSecurityScopedResource];
    [self presentProfileError:@"The selected JSON could not be opened."];
    return;
  }

  NSString* problem = nil;
  auto descriptor = DiscIO::ParseGameModDescriptorFile(FoundationToCppString(url.path));

  // The Files document picker may copy a JSON into a temporary Inbox or
  // security-scoped location. Dolphin normally resolves relative patch paths
  // against the JSON directory, but importing a profile beside the game can
  // unexpectedly resolve "../Load/Riivolution" against that temporary folder.
  // Retry the exact same JSON as though it is beside the selected game.
  if (descriptor && descriptor->riivolution) {
    BOOL allFilesPresent = YES;
    for (const auto& patch : descriptor->riivolution->patches) {
      if (!File::Exists(patch.xml) || !File::Exists(patch.root)) {
        allFilesPresent = NO;
        break;
      }
    }
    if (!allFilesPresent) {
      NSString* jsonText = [NSString stringWithContentsOfURL:url
          encoding:NSUTF8StringEncoding error:nil];
      NSString* selectedGamePath =
          CppToFoundationString(game.gameFile->GetFilePath());
      NSString* virtualJSONPath = [[selectedGamePath stringByDeletingLastPathComponent]
          stringByAppendingPathComponent:url.lastPathComponent];
      if (jsonText != nil) {
        auto relocated = DiscIO::ParseGameModDescriptorString(
            FoundationToCppString(jsonText), FoundationToCppString(virtualJSONPath));
        if (relocated && relocated->riivolution &&
            !relocated->riivolution->patches.empty()) {
          descriptor = std::move(relocated);  // Report intended paths if assets are absent.
        }
      }
    }
  }

  // JSON files created in another LiveContainer guest can contain the old
  // guest's absolute path (including its container UUID). Recover only files
  // that already exist under this installation's real Load/Riivolution folder.
  // Never fabricate XML or silently accept a missing patch.
  if (descriptor && descriptor->riivolution) {
    NSString* loadRoot = [CppToFoundationString(File::GetUserPath(D_USER_IDX))
        stringByAppendingPathComponent:@"Load/Riivolution"];
    NSFileManager* fm = [NSFileManager defaultManager];
    for (auto& patch : descriptor->riivolution->patches) {
      if (!File::Exists(patch.xml)) {
        NSString* oldXML = CppToFoundationString(patch.xml);
        NSRange marker = [oldXML rangeOfString:@"/Load/Riivolution/"
                                       options:NSBackwardsSearch];
        NSString* suffix = marker.location != NSNotFound
            ? [oldXML substringFromIndex:NSMaxRange(marker)]
            : [oldXML lastPathComponent];
        NSString* localXML = [loadRoot stringByAppendingPathComponent:suffix];
        if ([fm isReadableFileAtPath:localXML])
          patch.xml = FoundationToCppString(localXML);
      }
      if (!File::Exists(patch.root)) {
        NSString* oldRoot = CppToFoundationString(patch.root);
        NSRange marker = [oldRoot rangeOfString:@"/Load/Riivolution/"
                                        options:NSBackwardsSearch];
        NSString* suffix = marker.location != NSNotFound
            ? [oldRoot substringFromIndex:NSMaxRange(marker)]
            : @"";
        NSString* localRoot = suffix.length
            ? [loadRoot stringByAppendingPathComponent:suffix] : loadRoot;
        BOOL isDirectory = NO;
        if ([fm fileExistsAtPath:localRoot isDirectory:&isDirectory] && isDirectory)
          patch.root = FoundationToCppString(localRoot);
      }
    }
  }

  if (!descriptor) {
    problem = @"This is not a supported Dolphin game-mod descriptor JSON.";
  } else if (!descriptor->riivolution || descriptor->riivolution->patches.empty()) {
    problem = @"This profile contains no Riivolution patches.";
  }

  if (problem == nil) {
    // JSON descriptors can originate on another device, so their base-file
    // path may differ. The user selected the target game in the library.
    // Validate the actual XML game filters before re-targeting the descriptor.
    for (const auto& patch : descriptor->riivolution->patches) {
      if (!File::Exists(patch.xml) ||
          !File::Exists(patch.root)) {
        problem = !File::Exists(patch.xml)
            ? [NSString stringWithFormat:
                @"Missing Riivolution patch XML:\n%@\n\nThe JSON is a launch profile, not the patch itself. Put the actual Widescreen Patch.xml and any related patch files inside this Dolphin installation's Documents/Load/Riivolution folder, then import again.",
                CppToFoundationString(patch.xml)]
            : [NSString stringWithFormat:
                @"Riivolution patch folder not found at:\\n%@\\n\\nPlace the patch assets in this folder and import the JSON again.",
                CppToFoundationString(patch.root)];
        break;
      }
      auto parsed = DiscIO::Riivolution::ParseFile(patch.xml);
      if (!parsed ||
          !parsed->IsValidForGame(game.gameFile->GetGameID(),
                                  game.gameFile->GetRevision(),
                                  game.gameFile->GetDiscNumber())) {
        problem = @"A Riivolution XML file is invalid or targets another game/revision.";
        break;
      }
    }
  }

  if (problem == nil) {
    descriptor->base_file = game.gameFile->GetFilePath();
    NSString* directory = [self profileDirectory:game];
    NSError* error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
        withIntermediateDirectories:YES attributes:nil error:&error];
    if (error != nil) {
      problem = @"Could not create the profile folder.";
    } else {
      NSString* baseName = [[url lastPathComponent] stringByDeletingPathExtension];
      NSString* destination = [directory stringByAppendingPathComponent:
          [baseName stringByAppendingPathExtension:@"json"]];
      int suffix = 2;
      while ([[NSFileManager defaultManager] fileExistsAtPath:destination]) {
        destination = [directory stringByAppendingPathComponent:
            [[NSString stringWithFormat:@"%@ (%d)", baseName, suffix++]
                stringByAppendingPathExtension:@"json"]];
      }
      if (!DiscIO::WriteGameModDescriptorFile(FoundationToCppString(destination),
                                               *descriptor, true)) {
        problem = @"Failed to save the imported launch profile.";
      }
    }
  }
  if (scopedAccess) [url stopAccessingSecurityScopedResource];

  if (problem) {
    [self presentProfileError:problem];
  } else {
    [self presentProfileError:@"Profile imported. Use Launch Profiles to play it or set it as your default. Keep its XML and patch assets in Dolphin's accessible storage."];
  }
}

- (void)showDefaultProfilePickerForGame:(GameFilePtrWrapper*)game {
  NSArray<NSString*>* profiles = [self profilesForGame:game];
  UIAlertController* picker = [UIAlertController alertControllerWithTitle:@"Default Launch"
      message:@"Your library cover will launch the chosen profile."
      preferredStyle:UIAlertControllerStyleActionSheet];
  NSString* key = [self profileDefaultKey:game];
  [picker addAction:[UIAlertAction actionWithTitle:@"Original Game (No Patches)"
      style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* action) {
        [[NSUserDefaults standardUserDefaults] setObject:@"__dolphinios_original__" forKey:key];
      }]];
  [picker addAction:[UIAlertAction actionWithTitle:@"Automatic (Use Single Available Patch)"
      style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* action) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
      }]];
  for (NSString* path in profiles) {
    [picker addAction:[UIAlertAction actionWithTitle:[self profileLabel:path]
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* action) {
          [[NSUserDefaults standardUserDefaults] setObject:path forKey:key];
        }]];
  }
  [picker addAction:[UIAlertAction actionWithTitle:@"Cancel"
      style:UIAlertActionStyleCancel handler:nil]];
  picker.popoverPresentationController.sourceView = self.collectionView;
  picker.popoverPresentationController.sourceRect =
      CGRectMake(CGRectGetMidX(self.collectionView.bounds), 0, 1, 1);
  [self presentViewController:picker animated:YES completion:nil];
}

- (void)showProfileRemovalForGame:(GameFilePtrWrapper*)game {
  // Never delete a pre-existing JSON from the user's Games directory.
  NSString* managedDirectory = [[self profileDirectory:game] stringByStandardizingPath];
  NSMutableArray<NSString*>* managedProfiles = [NSMutableArray array];
  for (NSString* path in [self profilesForGame:game]) {
    if ([[[path stringByDeletingLastPathComponent] stringByStandardizingPath]
             isEqualToString:managedDirectory])
      [managedProfiles addObject:path];
  }
  NSArray<NSString*>* profiles = managedProfiles;
  UIAlertController* picker = [UIAlertController alertControllerWithTitle:@"Remove Profile"
      message:@"This only removes the imported JSON from Dolphin's managed profiles, not the game, XML, or patch assets."
      preferredStyle:UIAlertControllerStyleActionSheet];
  for (NSString* path in profiles) {
    [picker addAction:[UIAlertAction actionWithTitle:[self profileLabel:path]
        style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction* action) {
          NSError* error = nil;
          [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
          if (error != nil) {
            [self presentProfileError:@"Could not delete that profile."];
          } else {
            NSString* key = [self profileDefaultKey:game];
            if ([[[NSUserDefaults standardUserDefaults] stringForKey:key] isEqualToString:path])
              [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
          }
        }]];
  }
  [picker addAction:[UIAlertAction actionWithTitle:@"Cancel"
      style:UIAlertActionStyleCancel handler:nil]];
  picker.popoverPresentationController.sourceView = self.collectionView;
  picker.popoverPresentationController.sourceRect =
      CGRectMake(CGRectGetMidX(self.collectionView.bounds), 0, 1, 1);
  [self presentViewController:picker animated:YES completion:nil];
}

- (void)showLaunchProfilesForGame:(GameFilePtrWrapper*)game {
  NSArray<NSString*>* profiles = [self profilesForGame:game];
  UIAlertController* picker = [UIAlertController alertControllerWithTitle:@"Launch Profiles"
      message:@"Choose a profile to play once, or change the default launch."
      preferredStyle:UIAlertControllerStyleActionSheet];

  [picker addAction:[UIAlertAction actionWithTitle:@"Play Original Game"
      style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* action) {
        [self loadGameFile:game withLaunchProfile:nil];
      }]];
  [picker addAction:[UIAlertAction actionWithTitle:@"Safe Boot (Troubleshoot Black Screen)"
      style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* action) {
        // One launch: no patch profile, cached interpreter, stock backend and
        // conservative startup settings. Existing config and saves stay intact.
        [self loadGameFile:game withLaunchProfile:nil safeBoot:YES];
      }]];
  for (NSString* path in profiles) {
    [picker addAction:[UIAlertAction actionWithTitle:
        [@"Play: " stringByAppendingString:[self profileLabel:path]]
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* action) {
          [self loadGameFile:game withLaunchProfile:path];
        }]];
  }
  [picker addAction:[UIAlertAction actionWithTitle:@"Set Default Launch…"
      style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* action) {
        [self showDefaultProfilePickerForGame:game];
      }]];
  BOOL hasManagedProfile = NO;
  for (NSString* path in profiles) {
    if ([[[path stringByDeletingLastPathComponent] stringByStandardizingPath]
        isEqualToString:[[self profileDirectory:game] stringByStandardizingPath]]) {
      hasManagedProfile = YES;
      break;
    }
  }
  if (hasManagedProfile) {
    [picker addAction:[UIAlertAction actionWithTitle:@"Remove Imported Profile…"
        style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction* action) {
          [self showProfileRemovalForGame:game];
        }]];
  }
  [picker addAction:[UIAlertAction actionWithTitle:@"Import Patch Profile…"
      style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* action) {
        [self importPatchProfileForGame:game];
      }]];
  [picker addAction:[UIAlertAction actionWithTitle:@"Cancel"
      style:UIAlertActionStyleCancel handler:nil]];
  picker.popoverPresentationController.sourceView = self.collectionView;
  picker.popoverPresentationController.sourceRect =
      CGRectMake(CGRectGetMidX(self.collectionView.bounds), 0, 1, 1);
  [self presentViewController:picker animated:YES completion:nil];
}

- (void)receiveImportFileFinishedNotification {
  [self reloadGameFiles];
}

@end
