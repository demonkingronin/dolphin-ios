// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "SoftwareListiOSViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "Common/CommonPaths.h"
#import "Common/FileUtil.h"

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

#import "Common/IniFile.h"
#import "DiscIO/GameModDescriptor.h"


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
      NSString* key = [NSString stringWithFormat:@"%@Profile%d",
          [type isEqualToString:@"GCPad"] ? @"Pad" : @"Wiimote", controllerPort + 1];
      // Dolphin uses controller index 0-3 for these keys, not 1-4.
      key = [NSString stringWithFormat:@"%@Profile%d",
          [type isEqualToString:@"GCPad"] ? @"Pad" : @"Wiimote", controllerPort];
      [controllerSettings addObject:@{
        @"title": [NSString stringWithFormat:@"%@ Port %d", displayType, controllerPort + 1],
        @"section": [type isEqualToString:@"GCPad"] ? @"GCPad.Controls" : @"WiiPad.Controls",
        @"key": key, @"choices": profileNames, @"values": profileNames
      }];
    }
  }
  NSMutableArray<NSArray<NSDictionary*>*>* groups = [_sections mutableCopy];
  NSMutableArray<NSString*>* titles = [@[@"Graphics", @"Emulation", @"Audio"] mutableCopy];
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
    return @"Only the selected game's configuration is changed. Other games keep global settings.";
  if (section == (NSInteger)_sections.count)
    return @"Clears only the overrides shown above. Existing cheat codes and other GameINI data are preserved.";
  if (section == 3 && _sections.count > 3)
    return @"Select a controller profile already saved in Dolphin. Settings are loaded only for this game.";
  return nil;
}

- (NSString*)valueForSetting:(NSDictionary*)setting {
  std::string value;
  const auto* group = _ini.GetSection(FoundationToCppString(setting[@"section"]));
  if (group == nullptr || !group->Get(FoundationToCppString(setting[@"key"]), &value))
    return @"Inherit Global";
  NSUInteger index = [setting[@"values"] indexOfObject:CppToFoundationString(value)];
  if (index != NSNotFound && index < [setting[@"choices"] count])
    return setting[@"choices"][index];
  return [NSString stringWithFormat:@"Custom (%@)", CppToFoundationString(value)];
}

- (UITableViewCell*)tableView:(UITableView*)tableView
         cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:@"GameSetting"];
  if (cell == nil)
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                reuseIdentifier:@"GameSetting"];
  if (indexPath.section == (NSInteger)_sections.count) {
    cell.textLabel.text = @"Reset These Overrides";
    cell.textLabel.textColor = [UIColor systemRedColor];
    cell.detailTextLabel.text = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
  } else {
    NSDictionary* setting = _sections[indexPath.section][indexPath.row];
    cell.textLabel.text = setting[@"title"];
    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.text = [self valueForSetting:setting];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  }
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
                      message:@"Choose an override for this game only."
               preferredStyle:UIAlertControllerStyleActionSheet];
  [choices addAction:[UIAlertAction actionWithTitle:@"Inherit Global Setting"
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
  NSURL* _openedUrl;
  GameFilePtrWrapper* _profileImportGame;
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
  if (game == nil || ![url startAccessingSecurityScopedResource]) {
    [self presentProfileError:@"The selected JSON could not be opened."];
    return;
  }

  NSString* problem = nil;
  auto descriptor = DiscIO::ParseGameModDescriptorFile(FoundationToCppString(url.path));
  if (!descriptor) {
    problem = @"This is not a supported Dolphin game-mod descriptor JSON.";
  } else if (!descriptor->riivolution || descriptor->riivolution->patches.empty()) {
    problem = @"This profile contains no Riivolution patches.";
  } else {
    UICommon::GameFile sourceGame(descriptor->base_file);
    if (!sourceGame.IsValid() ||
        sourceGame.GetGameID() != game.gameFile->GetGameID() ||
        sourceGame.GetRevision() != game.gameFile->GetRevision()) {
      problem = @"This profile targets a different game or revision.";
    }
  }

  if (problem == nil) {
    for (const auto& patch : descriptor->riivolution->patches) {
      if (!File::Exists(patch.xml) ||
          ![[NSFileManager defaultManager] fileExistsAtPath:CppToFoundationString(patch.root)]) {
        problem = @"Required Riivolution XML or patch root files are missing. Import those assets into DolphiniOS first.";
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
  [url stopAccessingSecurityScopedResource];

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
  [picker addAction:[UIAlertAction actionWithTitle:@"Original Game"
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
  NSArray<NSString*>* profiles = [self profilesForGame:game];
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
  if (profiles.count) {
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
