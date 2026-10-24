// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "EmulationViewController.h"

#import <FirebaseAnalytics/FirebaseAnalytics.h>

#import <GameController/GameController.h>

#import "Common/Config/Config.h"

#include <map>
#include <optional>
#include <string>
#include <vector>

#import "Core/ConfigManager.h"
#import "Core/Config/MainSettings.h"
#import "Core/Core.h"
#import "Core/Host.h"
#import "Core/PowerPC/PowerPC.h"
#import "Core/System.h"

#import "EmulationBootParameter.h"
#import "EmulationCoordinator.h"
#import "FoundationStringUtil.h"
#import "HostNotifications.h"
#import "LocalizationUtil.h"
#import "JitManager.h"
#import "NKitWarningViewController.h"

@interface EmulationViewController ()

@end

@implementation EmulationViewController {
  bool _didStartEmulation;
  bool _safeBootSettingsApplied;
  std::map<Config::Location, std::optional<std::string>> _previousSafeBootSettings;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  
  _didStartEmulation = false;
  // This test changes only the temporary CurrentRun configuration layer.
  // It does not touch user's existing global or per-game INI files.
  if (self.bootParameter.safeBoot)
    [self applySafeBootSettings];
  
  [[EmulationCoordinator shared] registerMainDisplayView:self.rendererView];
  
  self.rendererView.alpha = 1.0f;

  // Temporary diagnostic button stays visible even when the renderer is black
  // and the regular navigation bar has been hidden.
  UIButton* diagnosticButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [diagnosticButton setTitle:@"Boot Info" forState:UIControlStateNormal];
  [diagnosticButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
  diagnosticButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
  diagnosticButton.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.72];
  diagnosticButton.layer.cornerRadius = 8;
  diagnosticButton.translatesAutoresizingMaskIntoConstraints = NO;
  [diagnosticButton addTarget:self action:@selector(showLaunchDiagnostics)
            forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:diagnosticButton];
  [NSLayoutConstraint activateConstraints:@[
    [diagnosticButton.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor
                                                   constant:10],
    [diagnosticButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor
                                               constant:8],
    [diagnosticButton.widthAnchor constraintEqualToConstant:90],
    [diagnosticButton.heightAnchor constraintEqualToConstant:32]
  ]];
  
  // Create right bar button items
  self.stopButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemStop target:self action:@selector(stopPressed)];
  self.pauseButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemPause target:self action:@selector(pausePressed)];
  self.playButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemPlay target:self action:@selector(playPressed)];
  self.hideBarButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"eye.slash"] style:UIBarButtonItemStylePlain target:self action:@selector(hideBarPressed)];
  
  self.navigationItem.rightBarButtonItems = @[
    self.stopButton,
    self.pauseButton,
    self.hideBarButton
  ];
  
  [self.navigationController setNavigationBarHidden:true animated:true];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receiveTitleChangedNotification) name:DOLHostTitleChangedNotification object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receiveEmulationEndNotification) name:DOLEmulationDidEndNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  
  if (!_didStartEmulation) {
    const PowerPC::CPUCore current_core = Config::Get(Config::MAIN_CPU_CORE);
    const bool is_interpreter_core = current_core == PowerPC::CPUCore::Interpreter || current_core == PowerPC::CPUCore::CachedInterpreter;
    
    if (![JitManager shared].acquiredJit && !is_interpreter_core) {
      JitWaitViewController* jitController = [[JitWaitViewController alloc] initWithNibName:@"JitWait" bundle:nil];
      jitController.delegate = self;
      jitController.modalInPresentation = true;
      
      [self presentViewController:jitController animated:true completion:nil];
    } else if ([self checkIfNeedToShowNKitWarning]) {
      [self showNKitWarning];
    } else {
      [self startEmulation];
    }
    
    _didStartEmulation = true;
  }
}

- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  
  [[NSNotificationCenter defaultCenter] removeObserver:self name:DOLHostTitleChangedNotification object:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:DOLEmulationDidEndNotification object:nil];
}

- (void)didFinishJitScreenWithResult:(JitWaitViewControllerResult)result sender:(id)sender {
  [self dismissViewControllerAnimated:true completion:^{
    if (result == JitWaitViewControllerResultCancel) {
      [self.navigationController dismissViewControllerAnimated:true completion:nil];
      return;
    }
    
    if (result == JitWaitViewControllerResultNoJitRequested) {
      Config::Set(Config::LayerType::CurrentRun, Config::MAIN_CPU_CORE, PowerPC::CPUCore::CachedInterpreter);
    }
    
    if ([self checkIfNeedToShowNKitWarning]) {
      [self showNKitWarning];
    } else {
      [self startEmulation];
    }
  }];
}

- (BOOL)checkIfNeedToShowNKitWarning {
  if (Config::GetBase(Config::MAIN_SKIP_NKIT_WARNING)) {
    return false;
  }
  
  return self.bootParameter.isNKit;
}

- (void)showNKitWarning {
  NKitWarningViewController* nkitController = [[NKitWarningViewController alloc] initWithNibName:@"NKitWarning" bundle:nil];
  nkitController.delegate = self;
  nkitController.modalInPresentation = true;
  
  [self presentViewController:nkitController animated:true completion:nil];
}

- (void)didFinishNKitWarningScreenWithResult:(BOOL)result sender:(id)sender {
  [self dismissViewControllerAnimated:true completion:^{
    if (result) {
      [self startEmulation];
    } else {
      [self.navigationController dismissViewControllerAnimated:true completion:nil];
    }
  }];
}

- (void)applySafeBootSettings {
  if (_safeBootSettingsApplied)
    return;
  auto layer = Config::GetLayer(Config::LayerType::CurrentRun);
  if (!layer)
    return;

  const std::vector<Config::Location> locations = {
      Config::MAIN_CPU_CORE.GetLocation(),
      Config::MAIN_GFX_BACKEND.GetLocation(),
      Config::MAIN_ENABLE_CHEATS.GetLocation(),
      Config::MAIN_SKIP_IPL.GetLocation(),
      Config::MAIN_CPU_THREAD.GetLocation(),
      Config::MAIN_OVERCLOCK_ENABLE.GetLocation()};
  for (const auto& location : locations)
    _previousSafeBootSettings[location] = layer->Get<std::string>(location);
  _safeBootSettingsApplied = true;

  // Cached Interpreter avoids JIT permission failures; the backend is reset to
  // Dolphin's iOS default. These values override saved GameINI keys for this run.
  Config::SetCurrent(Config::MAIN_CPU_CORE, PowerPC::CPUCore::CachedInterpreter);
  Config::SetCurrent(Config::MAIN_GFX_BACKEND,
                     Config::MAIN_GFX_BACKEND.GetDefaultValue());
  Config::SetCurrent(Config::MAIN_ENABLE_CHEATS, false);
  Config::SetCurrent(Config::MAIN_SKIP_IPL, true);
  Config::SetCurrent(Config::MAIN_CPU_THREAD, false);
  Config::SetCurrent(Config::MAIN_OVERCLOCK_ENABLE, false);
}

- (void)restoreSafeBootSettings {
  if (!_safeBootSettingsApplied)
    return;
  _safeBootSettingsApplied = false;

  auto layer = Config::GetLayer(Config::LayerType::CurrentRun);
  if (layer) {
    for (const auto& [location, previousValue] : _previousSafeBootSettings) {
      if (previousValue)
        layer->Set(location, *previousValue);
      else
        layer->DeleteKey(location);
    }
    Config::OnConfigChanged();
  }
  _previousSafeBootSettings.clear();
}

- (void)dealloc {
  // Also covers closing the test screen without ever starting emulation.
  [self restoreSafeBootSettings];
}

- (void)startEmulation {
  [[EmulationCoordinator shared] runEmulationWithBootParameter:self.bootParameter];
}

// A read-only snapshot for the black-screen investigation. No settings are changed.
- (void)showLaunchDiagnostics {
  Core::State state = Core::GetState(Core::System::GetInstance());
  NSString* stateName = @"Unknown";
  switch (state) {
    case Core::State::Uninitialized: stateName = @"Uninitialized"; break;
    case Core::State::Paused: stateName = @"Paused"; break;
    case Core::State::Running: stateName = @"Running"; break;
    case Core::State::Stopping: stateName = @"Stopping"; break;
    case Core::State::Starting: stateName = @"Starting"; break;
  }

  PowerPC::CPUCore cpu = Config::Get(Config::MAIN_CPU_CORE);
  NSString* cpuName = @"Other";
  switch (cpu) {
    case PowerPC::CPUCore::Interpreter: cpuName = @"Interpreter"; break;
    case PowerPC::CPUCore::CachedInterpreter: cpuName = @"Cached Interpreter"; break;
    case PowerPC::CPUCore::JITARM64: cpuName = @"ARM64 JIT"; break;
    case PowerPC::CPUCore::JIT64: cpuName = @"x64 JIT"; break;
  }

  NSString* gamePath = self.bootParameter.path ?: @"(system menu / IPL)";
  BOOL readable = self.bootParameter.path ?
      [[NSFileManager defaultManager] isReadableFileAtPath:self.bootParameter.path] : YES;
  JitManager* jit = [JitManager shared];
  NSString* backend = CppToFoundationString(Config::Get(Config::MAIN_GFX_BACKEND));
  CGSize surface = self.rendererView.bounds.size;
  NSString* report = [NSString stringWithFormat:
      @"DolphiniOS launch diagnostics\n"
      @"Core state: %@\n"
      @"Boot stage: %@\n"
      @"Game readable: %@\n"
      @"Game path: %@\n"
      @"CPU engine: %@\n"
      @"JIT acquired: %@\n"
      @"TXM: %@\n"
      @"JIT error: %@\n"
      @"Graphics backend: %@\n"
      @"Renderer size: %.0f x %.0f\n"
      @"iOS version: %@\n"
      @"Safe Boot: %@\n",
      stateName, [EmulationCoordinator shared].lastBootOutcome ?: @"Unknown",
      readable ? @"Yes" : @"NO", gamePath, cpuName,
      jit.acquiredJit ? @"Yes" : @"NO", jit.deviceHasTxm ? @"Yes" : @"No",
      jit.acquisitionError ?: @"(none)", backend,
      surface.width, surface.height, [UIDevice currentDevice].systemVersion,
      self.bootParameter.safeBoot ? @"YES" : @"No"];
  NSString* path = [NSHomeDirectory()
      stringByAppendingPathComponent:@"Documents/DolphiniOS-Launch-Diagnostics.txt"];
  [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Boot Diagnostics"
      message:report preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"Copy Report"
      style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* action) {
    [UIPasteboard generalPasteboard].string = report;
  }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"Close"
      style:UIAlertActionStyleCancel handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)updateNavigationBar:(bool)hidden {
  [self.navigationController setNavigationBarHidden:hidden animated:true];
  
  [self setNeedsStatusBarAppearanceUpdate];
  
  // Adjust the safe area insets.
  UIEdgeInsets insets = self.additionalSafeAreaInsets;
  if (hidden) {
    insets.top = 0;
  } else {
    // The safe area should extend behind the navigation bar.
    // This makes the bar "float" on top of the content.
    insets.top = -(self.navigationController.navigationBar.bounds.size.height);
  }
  
  self.additionalSafeAreaInsets = insets;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)stopPressed {
  if (Core::GetState(Core::System::GetInstance()) == Core::State::Starting) {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Emulation Starting" message:@"Emulation is still starting. Please wait for emulation to start before requesting for it to stop." preferredStyle:UIAlertControllerStyleAlert];
  
    [alert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"OK") style:UIAlertActionStyleDefault handler:nil]];
    
    [self presentViewController:alert animated:true completion:nil];
    
    return;
  }
  
  void (^stop)() = ^{
    Host_Message(HostMessageID::WMUserStop);
  };
  
  if (Config::Get(Config::MAIN_CONFIRM_ON_STOP)) {
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:DOLCoreLocalizedString(@"Confirm") message:DOLCoreLocalizedString(@"Do you want to stop the current emulation?") preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"No") style:UIAlertActionStyleDefault handler:nil]];
    
    [alert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"Yes") style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
      stop();
    }]];
    
    [self presentViewController:alert animated:true completion:nil];
  } else {
    stop();
  }
}

- (void)pausePressed {
  if (!Core::IsRunningOrStarting(Core::System::GetInstance())) {
    return;
  }
  
  [EmulationCoordinator shared].userRequestedPause = true;
  
  self.navigationItem.rightBarButtonItems = @[
    self.stopButton,
    self.playButton,
    self.hideBarButton
  ];
}

- (void)playPressed {
  if (!Core::IsRunningOrStarting(Core::System::GetInstance())) {
    return;
  }
  
  [EmulationCoordinator shared].userRequestedPause = false;
  
  self.navigationItem.rightBarButtonItems = @[
    self.stopButton,
    self.pauseButton,
    self.hideBarButton
  ];
}

- (void)hideBarPressed {
  [self updateNavigationBar:true];
}

- (void)receiveTitleChangedNotification {
  if (Config::Get(Config::MAIN_ANALYTICS_ENABLED)) {
    NSMutableArray<NSString*>* controllerList = [[NSMutableArray alloc] init];
    
    for (GCController* controller in [GCController controllers]) {
      NSString* controllerType = @"Unknown";
      
      if (controller.extendedGamepad != nil) {
        controllerType = @"Extended";
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      } else if (controller.gamepad != nil) {
#pragma clang diagnostic pop
        controllerType = @"Normal";
      } else if (controller.microGamepad != nil) {
        controllerType = @"Micro";
      } else {
        controllerType = @"Unknown";
      }
      
      [controllerList addObject:[NSString stringWithFormat:@"%@ (%@)", [controller vendorName], controllerType]];
    }
    
    NSString* title = CppToFoundationString(SConfig::GetInstance().GetTitleDescription());
    
    if ([title isEqualToString:@""]) {
      title = @"Unknown";
    }
    
    [FIRAnalytics logEventWithName:@"game_start" parameters:@{
      @"game_uid" : title,
      @"is_returning" : @"false", // TODO
      @"connected_controllers" : [controllerList count] != 0 ? [controllerList componentsJoinedByString:@", "] : @"none"
    }];
  }
}

- (void)receiveEmulationEndNotification {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self restoreSafeBootSettings];
    [UIView animateWithDuration:0.25f animations:^{
      self.rendererView.alpha = 0.0f;
    } completion:^(bool) {
      if (![EmulationCoordinator shared].isExternalDisplayConnected) {
        [[EmulationCoordinator shared] clearMetalLayer];
      }
      
      [self.navigationController dismissViewControllerAnimated:true completion:nil];
    }];
  });
}

@end
