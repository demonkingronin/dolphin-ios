// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "EmulationiOSViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <algorithm>
#include <cmath>

#import "Common/IOFile.h"

#import "Core/ConfigManager.h"
#import "Core/Config/iOSSettings.h"
#import "Core/Config/GraphicsSettings.h"
#import "VideoCommon/VideoConfig.h"
#import "Core/Config/MainSettings.h"
#import "Core/Config/GraphicsSettings.h"
#import "Core/Config/WiimoteSettings.h"
#import "Core/HW/GCPad.h"
#import "Core/HW/SI/SI_Device.h"
#import "Core/HW/Wiimote.h"
#import "Core/HW/WiimoteEmu/WiimoteEmu.h"
#import "Core/IOS/USB/Emulated/Skylanders/Skylander.h"
#import "Core/State.h"
#import "Core/System.h"

#import "InputCommon/InputConfig.h"
#import "InputCommon/ControllerEmu/ControllerEmu.h"
#import "InputCommon/ControllerInterface/ControllerInterface.h"

#import "VideoCommon/Present.h"
#import "VideoCommon/VideoConfig.h"
#import "FoundationStringUtil.h"

#import "EmulationCoordinator.h"
#import "HostNotifications.h"
#import "HostQueue.h"
#import "LocalizationUtil.h"
#import "VirtualMFiControllerManager.h"

typedef NS_ENUM(NSInteger, DOLEmulationVisibleTouchPad) {
  DOLEmulationVisibleTouchPadNone,
  DOLEmulationVisibleTouchPadGameCube,
  DOLEmulationVisibleTouchPadWiimote,
  DOLEmulationVisibleTouchPadSidewaysWiimote,
  DOLEmulationVisibleTouchPadClassic
};

@interface EmulationiOSViewController ()

@end

@implementation EmulationiOSViewController {
  DOLEmulationVisibleTouchPad _visibleTouchPad;
  int _stateSlot;
  BOOL _controllerEditorWasPaused;
  BOOL _controllerEditorOpen;
  BOOL _controllerEditorWasPaused;
}

- (void)viewDidLoad {
  [super viewDidLoad];

  for (int i = 0; i < [self.touchPads count]; i++) {
    TCView* padView = self.touchPads[i];

    if (i + 1 == DOLEmulationVisibleTouchPadGameCube) {
      padView.port = 0;
    } else {
      // Wii pads are mapped to touchscreen device 4
      padView.port = 4;
    }
  }

  if (@available(iOS 15.0, *)) {
    // Stupidity - iOS 15 now uses the scrollEdgeAppearance when the UINavigationBar is off screen.
    // https://developer.apple.com/forums/thread/682420
    UINavigationBar* bar = self.navigationController.navigationBar;
    bar.scrollEdgeAppearance = bar.standardAppearance;

    VirtualMFiControllerManager* virtualMfi = [VirtualMFiControllerManager shared];
    if (virtualMfi.shouldConnectController) {
      [virtualMfi connectControllerToView:self.view];
    }
  }

  _stateSlot = Config::GetBase(Config::MAIN_SELECTED_STATE_SLOT);
  
  // On iPadOS 26, the pull down button in the upper left can be blocked by window controls.
  if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
    self.pullDownLeftConstraint.active = false;
    self.pullDownCenterConstraint.active = true;
  }
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];

  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receiveTitleChangedNotificationiOS) name:DOLHostTitleChangedNotification object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receiveRequestRenderWindowSizeNotificationiOS) name:DOLHostRequestRenderWindowSizeNotification object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receiveEmulationEndNotificationiOS) name:DOLEmulationDidEndNotification object:nil];
}

- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];

  [[NSNotificationCenter defaultCenter] removeObserver:self name:DOLHostTitleChangedNotification object:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:DOLHostRequestRenderWindowSizeNotification object:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:DOLEmulationDidEndNotification object:nil];
}


#pragma mark - In-game controller configuration

// Present the existing Dolphin controller screens above the current game.
// The emulation session stays loaded. Temporarily pause to avoid button presses
// leaking into the game during mapping or input detection.
- (void)openControllerEditor {
  UIViewController* root = [[UIStoryboard storyboardWithName:@"ControllersSettings"
                                                        bundle:nil] instantiateInitialViewController];
  if (!root)
    return;
  _controllerEditorWasPaused = [EmulationCoordinator shared].userRequestedPause;
  if (!_controllerEditorWasPaused)
    [self pausePressed];

  UINavigationController* navigation = [[UINavigationController alloc]
      initWithRootViewController:root];
  root.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                          target:self action:@selector(closeControllerEditor)];
  navigation.modalPresentationStyle = UIModalPresentationPageSheet;
  navigation.modalInPresentation = YES; // Done restores the prior pause state.
  [self presentViewController:navigation animated:YES completion:nil];
}

- (void)closeControllerEditor {
  [self dismissViewControllerAnimated:YES completion:^{
    if (!self->_controllerEditorWasPaused &&
        Core::IsRunningOrStarting(Core::System::GetInstance()))
      [self playPressed];
    if (Core::System::GetInstance().IsWii())
      [self updateVisibleTouchPadToWii];
    else
      [self updateVisibleTouchPadToGameCube];
    [self recreateMenu];
  }];
}

#pragma mark - Live-changeable graphics and emulation settings

- (UIMenu*)liveGraphicsMenu {
  NSMutableArray<UIMenuElement*>* resolutionActions = [NSMutableArray array];
  NSInteger selectedScale = Config::Get(Config::GFX_EFB_SCALE);
  // Existing Dolphin video config responds to EFB scale changes without a reboot.
  NSInteger maximum = MAX(6, MIN((NSInteger)Config::Get(Config::GFX_MAX_EFB_SCALE),
                                   MAX(selectedScale, (NSInteger)6)));
  for (NSInteger scale = 0; scale <= maximum; scale++) {
    NSString* title = scale == 0 ? @"Auto" :
        [NSString stringWithFormat:@"%ld× Native", (long)scale];
    const NSInteger newScale = scale;
    UIAction* action = [UIAction actionWithTitle:title image:nil identifier:nil
        handler:^(__unused UIAction* sender) {
      Config::SetBaseOrCurrent(Config::GFX_EFB_SCALE, (int)newScale);
      [self recreateMenu];
    }];
    action.state = scale == selectedScale ? UIMenuElementStateOn : UIMenuElementStateOff;
    [resolutionActions addObject:action];
  }
  UIMenu* resolutionMenu = [UIMenu menuWithTitle:@"Internal Resolution"
      image:[UIImage systemImageNamed:@"square.dashed.inset.filled"]
      identifier:nil options:0 children:resolutionActions];

  NSArray<NSString*>* aspectTitles = @[@"Auto", @"Force 16:9", @"Force 4:3",
                                       @"Stretch to Window"];
  const AspectMode modes[] = {AspectMode::Auto, AspectMode::ForceWide,
                               AspectMode::ForceStandard, AspectMode::Stretch};
  NSMutableArray<UIMenuElement*>* aspectActions = [NSMutableArray array];
  for (NSUInteger index = 0; index < aspectTitles.count; index++) {
    const AspectMode value = modes[index];
    UIAction* action = [UIAction actionWithTitle:aspectTitles[index] image:nil
        identifier:nil handler:^(__unused UIAction* sender) {
      Config::SetBaseOrCurrent(Config::GFX_ASPECT_RATIO, value);
      [self recreateMenu];
    }];
    action.state = value == Config::Get(Config::GFX_ASPECT_RATIO) ?
        UIMenuElementStateOn : UIMenuElementStateOff;
    [aspectActions addObject:action];
  }
  UIMenu* aspectMenu = [UIMenu menuWithTitle:@"Aspect Ratio"
      image:[UIImage systemImageNamed:@"aspectratio"] identifier:nil
      options:0 children:aspectActions];

  NSArray<NSString*>* filterTitles = @[@"Default", @"Force Nearest", @"Force Linear"];
  const TextureFilteringMode filters[] = {TextureFilteringMode::Default,
      TextureFilteringMode::Nearest, TextureFilteringMode::Linear};
  NSMutableArray<UIMenuElement*>* filterActions = [NSMutableArray array];
  for (NSUInteger index = 0; index < filterTitles.count; index++) {
    const TextureFilteringMode value = filters[index];
    UIAction* action = [UIAction actionWithTitle:filterTitles[index] image:nil
        identifier:nil handler:^(__unused UIAction* sender) {
      Config::SetBaseOrCurrent(Config::GFX_ENHANCE_FORCE_TEXTURE_FILTERING, value);
      [self recreateMenu];
    }];
    action.state = value == Config::Get(Config::GFX_ENHANCE_FORCE_TEXTURE_FILTERING) ?
        UIMenuElementStateOn : UIMenuElementStateOff;
    [filterActions addObject:action];
  }
  UIMenu* filteringMenu = [UIMenu menuWithTitle:@"Texture Filtering"
      image:[UIImage systemImageNamed:@"line.3.horizontal.decrease"] identifier:nil
      options:0 children:filterActions];

  NSArray<NSString*>* anisotropyTitles = @[@"Default", @"1×", @"2×", @"4×", @"8×", @"16×"];
  const AnisotropicFilteringMode anisotropyValues[] = {
      AnisotropicFilteringMode::Default, AnisotropicFilteringMode::Force1x,
      AnisotropicFilteringMode::Force2x, AnisotropicFilteringMode::Force4x,
      AnisotropicFilteringMode::Force8x, AnisotropicFilteringMode::Force16x};
  NSMutableArray<UIMenuElement*>* anisotropyActions = [NSMutableArray array];
  for (NSUInteger index = 0; index < anisotropyTitles.count; index++) {
    const AnisotropicFilteringMode value = anisotropyValues[index];
    UIAction* action = [UIAction actionWithTitle:anisotropyTitles[index]
        image:nil identifier:nil handler:^(__unused UIAction* sender) {
      Config::SetBaseOrCurrent(Config::GFX_ENHANCE_MAX_ANISOTROPY, value);
      [self recreateMenu];
    }];
    action.state = value == Config::Get(Config::GFX_ENHANCE_MAX_ANISOTROPY) ?
        UIMenuElementStateOn : UIMenuElementStateOff;
    [anisotropyActions addObject:action];
  }
  UIMenu* anisotropyMenu = [UIMenu menuWithTitle:@"Anisotropic Filtering"
      image:nil identifier:nil options:0 children:anisotropyActions];

  UIAction* vsyncAction = [UIAction actionWithTitle:@"V-Sync"
      image:nil identifier:nil handler:^(__unused UIAction* sender) {
    Config::SetBaseOrCurrent(Config::GFX_VSYNC, !Config::Get(Config::GFX_VSYNC));
    [self recreateMenu];
  }];
  vsyncAction.state = Config::Get(Config::GFX_VSYNC) ?
      UIMenuElementStateOn : UIMenuElementStateOff;

  UIAction* fpsAction = [UIAction actionWithTitle:@"Show FPS"
      image:nil identifier:nil handler:^(__unused UIAction* sender) {
    Config::SetBaseOrCurrent(Config::GFX_SHOW_FPS, !Config::Get(Config::GFX_SHOW_FPS));
    [self recreateMenu];
  }];
  fpsAction.state = Config::Get(Config::GFX_SHOW_FPS) ?
      UIMenuElementStateOn : UIMenuElementStateOff;

  return [UIMenu menuWithTitle:@"Graphics" image:[UIImage systemImageNamed:@"slider.horizontal.3"]
      identifier:nil options:UIMenuOptionsDisplayInline
      children:@[resolutionMenu, aspectMenu, filteringMenu, anisotropyMenu,
                 vsyncAction, fpsAction]];
}

- (UIMenu*)liveGameSettingsMenu {
  NSMutableArray<UIMenuElement*>* speedActions = [NSMutableArray array];
  const float speeds[] = {0.5f, 0.75f, 1.0f, 1.25f, 1.5f, 2.0f, 0.0f};
  NSArray<NSString*>* names = @[@"50%", @"75%", @"100% (Normal)",
                                 @"125%", @"150%", @"200%", @"Unlimited"];
  const float current = Config::Get(Config::MAIN_EMULATION_SPEED);
  for (NSUInteger index = 0; index < names.count; index++) {
    float speed = speeds[index];
    UIAction* action = [UIAction actionWithTitle:names[index] image:nil
        identifier:nil handler:^(__unused UIAction* sender) {
      Config::SetBaseOrCurrent(Config::MAIN_EMULATION_SPEED, speed);
      [self recreateMenu];
    }];
    action.state = fabsf(current - speed) < 0.001f ?
        UIMenuElementStateOn : UIMenuElementStateOff;
    [speedActions addObject:action];
  }
  UIMenu* speedsMenu = [UIMenu menuWithTitle:@"Emulation Speed"
      image:[UIImage systemImageNamed:@"speedometer"] identifier:nil
      options:0 children:speedActions];
  return [UIMenu menuWithTitle:@"Game Settings"
      image:[UIImage systemImageNamed:@"gearshape.2"] identifier:nil
      options:UIMenuOptionsDisplayInline children:@[speedsMenu]];
}

// Present Dolphin's existing complete controller editor without ending emulation.
// The game is paused while the editor captures physical button presses.
- (void)openInGameControllerEditor {
  if (_controllerEditorOpen)
    return;
  UIStoryboard* storyboard = [UIStoryboard storyboardWithName:@"ControllersSettings" bundle:nil];
  UIViewController* root = [storyboard instantiateInitialViewController];
  if (!root)
    return;
  _controllerEditorOpen = YES;
  _controllerEditorWasPaused = [EmulationCoordinator shared].userRequestedPause;
  [EmulationCoordinator shared].userRequestedPause = YES;
  root.navigationItem.title = @"Controllers";
  root.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                  target:self action:@selector(closeInGameControllerEditor)];
  UINavigationController* sheet = [[UINavigationController alloc] initWithRootViewController:root];
  sheet.modalPresentationStyle = UIModalPresentationPageSheet;
  sheet.presentationController.delegate = self;
  [self presentViewController:sheet animated:YES completion:nil];
}

- (void)finishInGameControllerEditor {
  if (!_controllerEditorOpen)
    return;
  _controllerEditorOpen = NO;
  [EmulationCoordinator shared].userRequestedPause = _controllerEditorWasPaused;
  [self recreateMenu];
}

- (void)closeInGameControllerEditor {
  [self dismissViewControllerAnimated:YES completion:^{
    [self finishInGameControllerEditor];
  }];
}

- (void)presentationControllerDidDismiss:(UIPresentationController*)presentationController {
  [self finishInGameControllerEditor];
}

// Use Dolphin's current device list and native iOS submenu checkmarks. Changing
// the source never automatically overwrites a saved user's controller mappings.
- (UIMenu*)inputDeviceMenuForGameCube:(BOOL)isGameCube {
  InputConfig* config = isGameCube ? Pad::GetConfig() : Wiimote::GetConfig();
  ControllerEmu::EmulatedController* controller = config->GetController(0);
  if (!controller)
    return [UIMenu menuWithTitle:isGameCube ? @"GameCube Port 1" : @"Wii Remote 1"
                           children:@[]];
  const std::string selected = controller->GetDefaultDevice().ToString();
  NSMutableArray<UIMenuElement*>* actions = [NSMutableArray array];
  for (const std::string& device : g_controller_interface.GetAllDeviceStrings()) {
    ciface::Core::DeviceQualifier qualifier;
    qualifier.FromString(device);
    // Port 1 GameCube touchpad is device 0; Wii touchpad is device 4.
    if (qualifier.source == "iOS" && qualifier.name == "Touchscreen" &&
        qualifier.cid != (isGameCube ? 0 : 4))
      continue;
    NSString* value = CppToFoundationString(device);
    NSString* label = qualifier.source == "iOS" && qualifier.name == "Touchscreen" ?
        @"Touchscreen" : value;
    UIAction* action = [UIAction actionWithTitle:label image:nil identifier:nil
                                        handler:^(__unused UIAction* sender) {
      controller->SetDefaultDevice(FoundationToCppString(value));
      controller->UpdateReferences(g_controller_interface);
      config->SaveConfig();
      [self recreateMenu];
    }];
    action.state = selected == device ? UIMenuElementStateOn : UIMenuElementStateOff;
    [actions addObject:action];
  }
  if (actions.count == 0) {
    UIAction* unavailable = [UIAction actionWithTitle:@"No input devices detected" image:nil
                                          identifier:nil handler:^(__unused UIAction* action) {}];
    unavailable.attributes = UIMenuElementAttributesDisabled;
    [actions addObject:unavailable];
  }
  return [UIMenu menuWithTitle:isGameCube ? @"GameCube Port 1" : @"Wii Remote 1"
                        image:[UIImage systemImageNamed:@"gamecontroller"]
                   identifier:nil options:0 children:actions];
}

- (void)refreshGearAfterLiveChange {
  [self recreateMenu];
  [self.navigationController setNavigationBarHidden:YES animated:YES];
}

// Changes here are known to be observed by Dolphin's running video renderer.
// Exclude backend, shader-startup and other restart-only options.
- (UIMenu*)liveGraphicsMenu {
  NSMutableArray<UIMenuElement*>* resolutions = [NSMutableArray array];
  const int currentScale = Config::Get(Config::GFX_EFB_SCALE);
  const int maxScale = std::max(1, Config::Get(Config::GFX_MAX_EFB_SCALE));
  for (int scale = 0; scale <= std::min(maxScale, 8); ++scale) {
    NSString* title = scale == 0 ? @"Auto" :
        [NSString stringWithFormat:@"%d× Native", scale];
    UIAction* action = [UIAction actionWithTitle:title image:nil identifier:nil
                                        handler:^(__unused UIAction* sender) {
      Config::SetBaseOrCurrent(Config::GFX_EFB_SCALE, scale);
      [self refreshGearAfterLiveChange];
    }];
    action.state = currentScale == scale ? UIMenuElementStateOn : UIMenuElementStateOff;
    [resolutions addObject:action];
  }
  if (currentScale > 8) {
    UIAction* current = [UIAction actionWithTitle:[NSString stringWithFormat:@"%d× Native", currentScale]
                                           image:nil identifier:nil handler:^(__unused UIAction* sender) {}];
    current.state = UIMenuElementStateOn;
    [resolutions addObject:current];
  }

  NSMutableArray<UIMenuElement*>* aspectChoices = [NSMutableArray array];
  for (NSDictionary* option in @[
      @{@"name": @"Auto", @"value": @(static_cast<int>(AspectMode::Auto))},
      @{@"name": @"Force 16:9", @"value": @(static_cast<int>(AspectMode::ForceWide))},
      @{@"name": @"Force 4:3", @"value": @(static_cast<int>(AspectMode::ForceStandard))},
      @{@"name": @"Stretch to Window", @"value": @(static_cast<int>(AspectMode::Stretch))}]) {
    AspectMode mode = static_cast<AspectMode>([option[@"value"] intValue]);
    UIAction* action = [UIAction actionWithTitle:option[@"name"] image:nil identifier:nil
                                        handler:^(__unused UIAction* sender) {
      Config::SetBaseOrCurrent(Config::GFX_ASPECT_RATIO, mode);
      [self refreshGearAfterLiveChange];
    }];
    action.state = mode == Config::Get(Config::GFX_ASPECT_RATIO) ?
        UIMenuElementStateOn : UIMenuElementStateOff;
    [aspectChoices addObject:action];
  }

  NSMutableArray<UIMenuElement*>* filters = [NSMutableArray array];
  for (NSDictionary* option in @[
      @{@"name": @"Default", @"value": @(-1)},
      @{@"name": @"1× Anisotropic", @"value": @(0)},
      @{@"name": @"2× Anisotropic", @"value": @(1)},
      @{@"name": @"4× Anisotropic", @"value": @(2)},
      @{@"name": @"8× Anisotropic", @"value": @(3)},
      @{@"name": @"16× Anisotropic", @"value": @(4)}]) {
    AnisotropicFilteringMode mode = static_cast<AnisotropicFilteringMode>([option[@"value"] intValue]);
    UIAction* action = [UIAction actionWithTitle:option[@"name"] image:nil identifier:nil
                                        handler:^(__unused UIAction* sender) {
      Config::SetBaseOrCurrent(Config::GFX_ENHANCE_MAX_ANISOTROPY, mode);
      [self refreshGearAfterLiveChange];
    }];
    action.state = mode == Config::Get(Config::GFX_ENHANCE_MAX_ANISOTROPY) ?
        UIMenuElementStateOn : UIMenuElementStateOff;
    [filters addObject:action];
  }
  BOOL vsyncEnabled = Config::Get(Config::GFX_VSYNC);
  UIAction* vsync = [UIAction actionWithTitle:@"V-Sync" image:nil identifier:nil
                                    handler:^(__unused UIAction* sender) {
    Config::SetBaseOrCurrent(Config::GFX_VSYNC, !Config::Get(Config::GFX_VSYNC));
    [self refreshGearAfterLiveChange];
  }];
  vsync.state = vsyncEnabled ? UIMenuElementStateOn : UIMenuElementStateOff;
  UIAction* fps = [UIAction actionWithTitle:@"Show FPS" image:nil identifier:nil
                                  handler:^(__unused UIAction* sender) {
    Config::SetBaseOrCurrent(Config::GFX_SHOW_FPS, !Config::Get(Config::GFX_SHOW_FPS));
    [self refreshGearAfterLiveChange];
  }];
  fps.state = Config::Get(Config::GFX_SHOW_FPS) ?
      UIMenuElementStateOn : UIMenuElementStateOff;

  return [UIMenu menuWithTitle:@"Graphics" image:[UIImage systemImageNamed:@"slider.horizontal.3"]
                   identifier:nil options:0 children:@[
    [UIMenu menuWithTitle:@"Internal Resolution" image:nil identifier:nil
                 options:0 children:resolutions],
    [UIMenu menuWithTitle:@"Aspect Ratio" image:nil identifier:nil
                 options:0 children:aspectChoices],
    [UIMenu menuWithTitle:@"Anisotropic Filtering" image:nil identifier:nil
                 options:0 children:filters],
    vsync, fps
  ]];
}

- (UIMenu*)liveGameOptionsMenu {
  float current = Config::Get(Config::MAIN_EMULATION_SPEED);
  NSMutableArray<UIMenuElement*>* speeds = [NSMutableArray array];
  for (NSNumber* number in @[@(0.5f), @(0.75f), @(1.0f), @(1.25f), @(1.5f), @(2.0f)]) {
    float speed = number.floatValue;
    NSString* title = [NSString stringWithFormat:@"%d%%", (int)(speed * 100)];
    UIAction* action = [UIAction actionWithTitle:title image:nil identifier:nil
                                        handler:^(__unused UIAction* sender) {
      Config::SetBaseOrCurrent(Config::MAIN_EMULATION_SPEED, speed);
      [self refreshGearAfterLiveChange];
    }];
    action.state = fabsf(current - speed) < 0.01f ?
        UIMenuElementStateOn : UIMenuElementStateOff;
    [speeds addObject:action];
  }
  return [UIMenu menuWithTitle:@"Game Options" image:[UIImage systemImageNamed:@"speedometer"]
                   identifier:nil options:0 children:@[
      [UIMenu menuWithTitle:@"Emulation Speed" image:nil identifier:nil options:0 children:speeds]
  ]];
}

- (void)recreateMenu {
  NSMutableArray<UIMenuElement*>* controllerActions = [[NSMutableArray alloc] init];

  NSMutableArray<UIMenuElement*>* visibleControllerActions = [[NSMutableArray alloc] init];

  bool wiimoteTouchPadAttached = [self isWiimoteTouchPadAttached] && Core::System::GetInstance().IsWii();
  bool gamecubeTouchPadAttached = [self isGameCubeTouchPadAttached];

  if (wiimoteTouchPadAttached) {
    UIAction* wiimoteAction = [UIAction actionWithTitle:DOLCoreLocalizedString(@"Wii Remote") image:nil identifier:nil handler:^(UIAction*) {
      [self updateVisibleTouchPadToWii];
      [self recreateMenu];

      [self.navigationController setNavigationBarHidden:true animated:true];
    }];

    if (_visibleTouchPad == DOLEmulationVisibleTouchPadWiimote ||
        _visibleTouchPad == DOLEmulationVisibleTouchPadSidewaysWiimote ||
        _visibleTouchPad == DOLEmulationVisibleTouchPadClassic) {
      wiimoteAction.state = UIMenuElementStateOn;
    } else {
      wiimoteAction.state = UIMenuElementStateOff;
    }

    [visibleControllerActions addObject:wiimoteAction];
  }

  if (gamecubeTouchPadAttached) {
    UIAction* gamecubeAction = [UIAction actionWithTitle:DOLCoreLocalizedString(@"GameCube Controller") image:nil identifier:nil handler:^(UIAction*) {
      [self updateVisibleTouchPadToGameCube];
      [self recreateMenu];

      [self.navigationController setNavigationBarHidden:true animated:true];
    }];

    if (_visibleTouchPad == DOLEmulationVisibleTouchPadGameCube) {
      gamecubeAction.state = UIMenuElementStateOn;
    } else {
      gamecubeAction.state = UIMenuElementStateOff;
    }

    [visibleControllerActions addObject:gamecubeAction];
  }

  if (wiimoteTouchPadAttached || gamecubeTouchPadAttached) {
    UIAction* noneAction = [UIAction actionWithTitle:DOLCoreLocalizedString(@"Hide") image:nil identifier:nil handler:^(UIAction*) {
      [self updateVisibleTouchPadWithType:DOLEmulationVisibleTouchPadNone];
      [self recreateMenu];

      [self.navigationController setNavigationBarHidden:true animated:true];
    }];

    if (_visibleTouchPad == DOLEmulationVisibleTouchPadNone) {
      noneAction.state = UIMenuElementStateOn;
    } else {
      noneAction.state = UIMenuElementStateOff;
    }

    [visibleControllerActions addObject:noneAction];
  }

  UIMenu* visibleControllerMenu = [UIMenu menuWithTitle:@"Touch Controller" image:[UIImage systemImageNamed:@"gamecontroller"] identifier:nil options:0 children:visibleControllerActions];
  [controllerActions addObject:visibleControllerMenu];
  // Connected devices and full mapping remain accessible without exiting the game.
  [controllerActions addObject:[self inputDeviceMenuForGameCube:YES]];
  if (Core::System::GetInstance().IsWii())
    [controllerActions addObject:[self inputDeviceMenuForGameCube:NO]];
  [controllerActions addObject:[UIAction actionWithTitle:@"Configure Controllers…"
                                                    image:[UIImage systemImageNamed:@"slider.horizontal.3"]
                                               identifier:nil handler:^(__unused UIAction* action) {
    [self openInGameControllerEditor];
  }]];
  [controllerActions addObject:[UIAction actionWithTitle:@"Configure Controllers…"
      image:[UIImage systemImageNamed:@"gamecontroller"] identifier:nil
      handler:^(__unused UIAction* action) {
    [self openControllerEditor];
  }]];

  if (wiimoteTouchPadAttached) {
    TCWiiTouchIRMode irMode = (TCWiiTouchIRMode)Config::Get(Config::MAIN_TOUCH_PAD_IR_MODE);

    UIMenu* menu = [UIMenu menuWithTitle:@"Touch IR Pointer" image:[UIImage systemImageNamed:@"hand.point.up.left"] identifier:nil options:0 children:@[
      [UIAction actionWithTitle:@"Disabled" image:nil identifier:nil handler:^(UIAction*) {
        Config::SetBaseOrCurrent(Config::MAIN_TOUCH_PAD_IR_MODE, TCWiiTouchIRModeNone);

        [self updatePointerValuesOnWiiTouchPads];
        [self recreateMenu];

        [self.navigationController setNavigationBarHidden:true animated:true];
      }],
      [UIAction actionWithTitle:@"Follow" image:nil identifier:nil handler:^(UIAction*) {
        Config::SetBaseOrCurrent(Config::MAIN_TOUCH_PAD_IR_MODE, TCWiiTouchIRModeFollow);

        [self updatePointerValuesOnWiiTouchPads];
        [self recreateMenu];

        [self.navigationController setNavigationBarHidden:true animated:true];
      }],
      [UIAction actionWithTitle:@"Drag" image:nil identifier:nil handler:^(UIAction*) {
        Config::SetBaseOrCurrent(Config::MAIN_TOUCH_PAD_IR_MODE, TCWiiTouchIRModeDrag);

        [self updatePointerValuesOnWiiTouchPads];
        [self recreateMenu];

        [self.navigationController setNavigationBarHidden:true animated:true];
      }]
    ]];

    UIAction* selectedAction = (UIAction*)menu.children[(int)irMode];
    selectedAction.state = UIMenuElementStateOn;

    [controllerActions addObject:menu];
  }

  NSMutableArray<UIMenuElement*>* stateSlotActions = [[NSMutableArray alloc] init];

  for (int i = 1; i <= State::NUM_STATES; i++) {
    [stateSlotActions addObject:[UIAction actionWithTitle:[NSString stringWithFormat:@"Slot %d", i] image:nil identifier:nil handler:^(UIAction* action) {
      self->_stateSlot = i;
      Config::SetBase(Config::MAIN_SELECTED_STATE_SLOT, i);

      [self recreateMenu];
    }]];
  }

  UIAction* selectedSlotElement = (UIAction*)[stateSlotActions objectAtIndex:Config::GetBase(Config::MAIN_SELECTED_STATE_SLOT) - 1];
  selectedSlotElement.state = UIMenuElementStateOn;
  
  NSMutableArray<UIMenuElement*>* menuItems = [[NSMutableArray alloc] init];
  [menuItems addObject:[UIMenu menuWithTitle:DOLCoreLocalizedString(@"Controllers") image:nil identifier:nil options:UIMenuOptionsDisplayInline children:controllerActions]];
  [menuItems addObject:[self liveGraphicsMenu]];
  [menuItems addObject:[self liveGameSettingsMenu]];
  [menuItems addObject:[UIMenu menuWithTitle:@"Live Settings" image:nil identifier:nil
                            options:UIMenuOptionsDisplayInline children:@[
    [self liveGraphicsMenu], [self liveGameOptionsMenu]
  ]]];
  [menuItems addObject:[UIMenu menuWithTitle:DOLCoreLocalizedString(@"Save State") image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
    [UIMenu menuWithTitle:DOLCoreLocalizedString(@"Select State Slot") image:nil identifier:nil options:0 children:stateSlotActions],
    [UIAction actionWithTitle:DOLCoreLocalizedString(@"Load State") image:[UIImage systemImageNamed:@"tray.and.arrow.down"] identifier:nil handler:^(UIAction*) {
      DOLHostQueueRunAsync(^{
        State::Load(Core::System::GetInstance(), self->_stateSlot);
      });

      [self.navigationController setNavigationBarHidden:true animated:true];
    }],
    [UIAction actionWithTitle:DOLCoreLocalizedString(@"Save State") image:[UIImage systemImageNamed:@"tray.and.arrow.up"] identifier:nil handler:^(UIAction*) {
      DOLHostQueueRunAsync(^{
        State::Save(Core::System::GetInstance(), self->_stateSlot);
      });

      [self.navigationController setNavigationBarHidden:true animated:true];
    }]
  ]]];
  
  // Keep the original gear menu's Controllers and Save State actions intact.
  // Reports are accessed here rather than floating over the game and exit arrow.
  [menuItems addObject:[UIMenu menuWithTitle:@"Diagnostics"
      image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
    [UIAction actionWithTitle:@"Boot Info"
        image:[UIImage systemImageNamed:@"info.circle"]
        identifier:nil handler:^(__unused UIAction* action) {
      [self showLaunchDiagnostics];
    }],
    [UIAction actionWithTitle:@"Texture Diagnostics"
        image:[UIImage systemImageNamed:@"photo.on.rectangle.angled"]
        identifier:nil handler:^(__unused UIAction* action) {
      [self showTextureDiagnostics];
    }]
  ]]];

  if ([self emulateSkylanderPortal] && Core::System::GetInstance().IsWii()) {
    [menuItems addObject:[UIMenu menuWithTitle:DOLCoreLocalizedString(@"Tools") image:nil identifier:nil options:UIMenuOptionsDisplayInline
                 children:@[
        [UIAction actionWithTitle:DOLCoreLocalizedString(@"Skylanders Portal") image:[UIImage systemImageNamed:@"externalDrive"] identifier:nil handler:^(UIAction*) {
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Skylanders Manager"
                                       message:nil
                                       preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction* loadAction = [UIAlertAction actionWithTitle:@"Load" style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction* action) {
            NSArray<UTType*>* types = @[
                [UTType exportedTypeWithIdentifier:@"me.oatmealdome.dolphinios.skylander-dumps"]
              ];
            UIDocumentPickerViewController* pickerController = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types];
            pickerController.delegate = self;
            pickerController.modalPresentationStyle = UIModalPresentationPageSheet;
            pickerController.allowsMultipleSelection = false;

            [self presentViewController:pickerController animated:true completion:nil];

        }];
        UIAlertAction* clearAction = [UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction* action) {
            auto& system = Core::System::GetInstance();
            if (self.skylanderSlot) {
              bool removed = system.GetSkylanderPortal().RemoveSkylander(self.skylanderSlot - 1);
              if (removed && self.skylanderSlot != 0) {
                  self.skylanderSlot--;
              }
            }
        }];
        UIAlertAction* clearAllAction = [UIAlertAction actionWithTitle:@"Clear All" style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction* action) {
            auto& system = Core::System::GetInstance();
            if (self.skylanderSlot) {
              for (int i = 0; i < 16; i++) {
                  system.GetSkylanderPortal().RemoveSkylander(i);
              }
            }
            self.skylanderSlot = 0;
        }];
        [alert addAction:loadAction];
        [alert addAction:clearAction];
        [alert addAction:clearAllAction];
        [self presentViewController:alert animated:YES completion:nil];
    }]
    ]]];
  }

  self.navigationItem.leftBarButtonItem.menu = [UIMenu menuWithChildren:menuItems];
}

- (void)viewDidLayoutSubviews {
  if (g_presenter) {
    g_presenter->ResizeSurface();
  }

  [[TCDeviceMotion shared] statusBarOrientationChanged];

  [self updatePointerValuesOnWiiTouchPads];
}

- (BOOL)prefersHomeIndicatorAutoHidden {
  return true;
}

- (void)receiveTitleChangedNotificationiOS {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (Core::System::GetInstance().IsWii()) {
      [self updateVisibleTouchPadToWii];
    } else {
      [self updateVisibleTouchPadToGameCube];
    }

    [self recreateMenu];
  });
}

- (void)receiveRequestRenderWindowSizeNotificationiOS {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (Core::System::GetInstance().IsWii()) {
      [self updatePointerValuesOnWiiTouchPads];
    }
  });
}

- (bool)isWiimoteTouchPadAttached {
  if (Config::Get(Config::GetInfoForWiimoteSource(0)) != WiimoteSource::Emulated) {
    // Nothing is plugged in to this port.
    return false;
  }

  const auto wiimote = static_cast<WiimoteEmu::Wiimote*>(Wiimote::GetConfig()->GetController(0));

  if (wiimote->GetDefaultDevice().source != "iOS") {
    // A real controller is mapped to this port.
    return false;
  }

  return true;
}

- (bool)emulateSkylanderPortal {
  return Config::Get(Config::MAIN_EMULATE_SKYLANDER_PORTAL);
}

- (bool)isGameCubeTouchPadAttached {
  if (Config::Get(Config::GetInfoForSIDevice(0)) == SerialInterface::SIDEVICE_NONE) {
    // Nothing is plugged in to this port.
    return false;
  }

  const auto device = Pad::GetConfig()->GetController(0);

  if (device->GetDefaultDevice().source != "iOS") {
    // A real controller is mapped to this port.
    return false;
  }

  return true;
}

- (void)updateVisibleTouchPadToWii {
  if (![self isWiimoteTouchPadAttached]) {
    // Fallback to GameCube in case port 1 is bound to the touchscreen.
    [self updateVisibleTouchPadToGameCube];

    return;
  }

  DOLEmulationVisibleTouchPad targetTouchPad;

  const auto wiimote = static_cast<WiimoteEmu::Wiimote*>(Wiimote::GetConfig()->GetController(0));

  if (wiimote->GetActiveExtensionNumber() == WiimoteEmu::ExtensionNumber::CLASSIC) {
    targetTouchPad = DOLEmulationVisibleTouchPadClassic;
  } else if (wiimote->IsSideways()) {
    targetTouchPad = DOLEmulationVisibleTouchPadSidewaysWiimote;
  } else {
    targetTouchPad = DOLEmulationVisibleTouchPadWiimote;
  }

  [self updateVisibleTouchPadWithType:targetTouchPad];

  [self updatePointerValuesOnWiiTouchPads];
}

- (void)updateVisibleTouchPadToGameCube {
  if (![self isGameCubeTouchPadAttached]) {
    return;
  }

  [self updateVisibleTouchPadWithType:DOLEmulationVisibleTouchPadGameCube];
}

- (void)updateVisibleTouchPadWithType:(DOLEmulationVisibleTouchPad)touchPad {
  if (_visibleTouchPad == touchPad) {
    return;
  }

  TCDeviceMotion* motion = [TCDeviceMotion shared];

  if (touchPad == DOLEmulationVisibleTouchPadWiimote || touchPad == DOLEmulationVisibleTouchPadSidewaysWiimote || touchPad == DOLEmulationVisibleTouchPadClassic) {
    [motion setMotionEnabled:true];
    [motion setPort:4]; // Touchscreen device 4 is used for the Wiimote
  } else {
    [motion setMotionEnabled:false];
  }

  NSInteger targetIdx = touchPad - 1;

  for (int i = 0; i < [self.touchPads count]; i++) {
    TCView* padView = self.touchPads[i];
    padView.userInteractionEnabled = i == targetIdx;
  }

  const float targetOpacity = Config::Get(Config::MAIN_TOUCH_PAD_OPACITY);

  [UIView animateWithDuration:0.5f animations:^{
    for (int i = 0; i < [self.touchPads count]; i++) {
      TCView* padView = self.touchPads[i];
      padView.alpha = i == targetIdx ? targetOpacity : 0.0f;
    }
  }];

  _visibleTouchPad = touchPad;
}

- (void)updatePointerValuesOnWiiTouchPads {
  if (!g_presenter) {
    return;
  }

  TCWiiTouchIRMode irMode = TCWiiTouchIRModeNone;

  if ([self isWiimoteTouchPadAttached]) {
    irMode = (TCWiiTouchIRMode)Config::Get(Config::MAIN_TOUCH_PAD_IR_MODE);

    ControllerEmu::ControlGroup* group = Wiimote::GetWiimoteGroup(0, WiimoteEmu::WiimoteGroup::IMUPoint);
    group->enabled.SetValue(irMode == TCWiiTouchIRModeNone);
  }

  for (int i = 0; i < [self.touchPads count]; i++) {
    TCView* padView = self.touchPads[i];

    if ([padView isKindOfClass:[TCWiiPad class]]) {
      TCWiiPad* wiiPadView = (TCWiiPad*)padView;

      [wiiPadView setTouchIRMode:irMode];
      [wiiPadView resetPointer];
      [wiiPadView recalculatePointerValuesWithNew_rect:self.rendererView.bounds game_aspect:g_presenter->CalculateDrawAspectRatio()];
    }
  }
}

- (IBAction)pullDownPressed:(id)sender {
  [self updateNavigationBar:false];
}

- (void)receiveEmulationEndNotificationiOS {
  if (@available(iOS 15.0, *)) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [[VirtualMFiControllerManager shared] disconnectController];
    });
  }

  [[TCDeviceMotion shared] setMotionEnabled:false];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    NSString* sourcePath = [urls[0] path];
    std::string path = std::string([sourcePath UTF8String]);
    File::IOFile sky_file(path, "r+b");
    if (!sky_file)
    {
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Failed to Open Skylander File!"
                                       message:nil
                                       preferredStyle:UIAlertControllerStyleAlert];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    std::array<u8, 0x40 * 0x10> file_data;
    if (!sky_file.ReadBytes(file_data.data(), file_data.size()))
    {
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Failed to Read Skylander File!"
                                       message:nil
                                       preferredStyle:UIAlertControllerStyleAlert];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    auto& system = Core::System::GetInstance();
    std::pair<u16, u16> id_var = system.GetSkylanderPortal().CalculateIDs(file_data);
    u8 portal_slot = system.GetSkylanderPortal().LoadSkylander(std::make_unique<IOS::HLE::USB::SkylanderFigure>(std::move(sky_file)));
    if (portal_slot == 0xFF)
    {
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Failed to Load Skylander File!"
                                       message:nil
                                       preferredStyle:UIAlertControllerStyleAlert];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    self.skylanderSlot = portal_slot + 1;
}

@end
