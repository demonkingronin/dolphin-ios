// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "MappingGroupEditViewController.h"

#import "InputCommon/ControllerEmu/ControlGroup/ControlGroup.h"
#import "InputCommon/ControllerEmu/ControllerEmu.h"
#import "InputCommon/ControllerEmu/Setting/NumericSetting.h"
#import "InputCommon/ControllerInterface/ControllerInterface.h"
#import "InputCommon/ControllerInterface/MappingCommon.h"

#import "FoundationStringUtil.h"
#import "LocalizationUtil.h"
#import "MappingGroupEditBoolCell.h"
#import "MappingGroupEditControlCell.h"
#import "MappingGroupEditDoubleCell.h"
#import "MappingGroupEditEnabledCell.h"
#import "MappingGroupEditViewControllerDelegate.h"
#import "MappingUtil.h"

#include <chrono>
#include <memory>
#include <string>
#include <vector>

typedef NS_ENUM(NSInteger, DOLMappingGroupEditSection) {
  DOLMappingGroupEditSectionEnableSwitch,
  DOLMappingGroupEditSectionControls,
  DOLMappingGroupEditSectionNumericSettings,
  DOLMappingGroupEditSectionCount
};

@interface MappingGroupEditViewController () {
  NSTimer* _inputTimer;
  // The detector is owned and accessed exclusively on this serial queue.
  // No detector work or blocking lock acquisition takes place on the UI thread.
  dispatch_queue_t _inputDetectionQueue;
  std::unique_ptr<ciface::Core::InputDetector> _inputDetector;

  UIAlertController* _inputAlertController;
  NSIndexPath* _mappingIndexPath;
  std::string _mappingDefaultDevice;
  NSUInteger _mappingGeneration;
  BOOL _mappingActive;
  BOOL _inputTickPending;
}

- (void)cancelInputDetection;
- (void)finishInputDetectionWithExpression:(NSString*)expression
                                generation:(NSUInteger)generation;

@end

@implementation MappingGroupEditViewController

- (void)viewDidLoad {
  [super viewDidLoad];

  self.navigationItem.title = DOLCoreLocalizedString(CppToFoundationString(self.controlGroup->ui_name));
  _inputDetectionQueue = dispatch_queue_create("org.dolphinios.mapping.input-detection",
                                               DISPATCH_QUEUE_SERIAL);
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];

  if (_inputTimer == nil) {
    _inputTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                                  target:self
                                                selector:@selector(processMappingButtons)
                                                userInfo:nil
                                                 repeats:YES];
  }
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];

  [self cancelInputDetection];
  if (_inputTimer != nil) {
    [_inputTimer invalidate];
    _inputTimer = nil;
  }
}

- (void)enableSwitchValueDidChange:(MappingGroupEditEnabledCell*)cell {
  self.controlGroup->enabled.SetValue(cell.enabledSwitch.on);
  
  for (int i = 0; i < self.controlGroup->controls.size(); i++) {
    MappingGroupEditControlCell* controlCell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:i inSection:DOLMappingGroupEditSectionControls]];
    
    [self updateControlCellBasedOnEnabled:controlCell];
  }
  
  for (int i = 0; i < self.controlGroup->numeric_settings.size(); i++) {
    switch (self.controlGroup->numeric_settings[i]->GetType()) {
      case ControllerEmu::SettingType::Double: {
        MappingGroupEditDoubleCell* doubleCell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:i inSection:DOLMappingGroupEditSectionNumericSettings]];
        
        [self updateDoubleCellBasedOnEnabled:doubleCell];
        
        break;
      }
      case ControllerEmu::SettingType::Bool: {
        MappingGroupEditBoolCell* boolCell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:i inSection:DOLMappingGroupEditSectionNumericSettings]];
        
        [self updateBoolCellBasedOnEnabled:boolCell];
        
        break;
      }
      default:
        break;
    }
  }
  
  [self.delegate controlGroupDidChange:self];
}

- (void)updateControlCellBasedOnEnabled:(MappingGroupEditControlCell*)cell {
  bool enabled = !self.controlGroup->HasEnabledSetting() || self.controlGroup->enabled_setting->GetValue();
  
  cell.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
  cell.nameLabel.textColor = enabled ? [UIColor labelColor] : [UIColor systemGrayColor];
}

- (void)updateDoubleCellBasedOnEnabled:(MappingGroupEditDoubleCell*)cell {
  bool enabled = !self.controlGroup->HasEnabledSetting() || self.controlGroup->enabled_setting->GetValue();
  
  cell.nameLabel.textColor = enabled ? [UIColor labelColor] : [UIColor systemGrayColor];
  cell.textField.enabled = enabled;
}

- (void)updateBoolCellBasedOnEnabled:(MappingGroupEditBoolCell*)cell {
  bool enabled = !self.controlGroup->HasEnabledSetting() || self.controlGroup->enabled_setting->GetValue();
  
  cell.nameLabel.textColor = enabled ? [UIColor labelColor] : [UIColor systemGrayColor];
  cell.enabledSwitch.enabled = enabled;
}

- (void)updateControlCell:(MappingGroupEditControlCell*)cell withExpression:(std::string)expression {
  NSString* foundationExpression;
  if (!expression.empty()) {
    foundationExpression = CppToFoundationString(expression);
  } else {
    foundationExpression = @"—";
  }
  
  cell.expressionLabel.text = foundationExpression;
}

- (void)updateDoubleCell:(MappingGroupEditDoubleCell*)cell withSetting:(ControllerEmu::NumericSetting<double>*)setting {
  NSString* textString = [NSString stringWithFormat:@"%g", setting->GetValue()];
  
  const char* suffix = setting->GetUISuffix();
  if (suffix) {
    NSString* localizedSuffix = DOLCoreLocalizedString(CToFoundationString(suffix));
    textString = [textString stringByAppendingFormat:@"%@", localizedSuffix];
  }
  
  cell.textField.text = textString;
}

- (void)textFieldDidChange:(MappingGroupEditDoubleCell*)cell {
  NSIndexPath* indexPath = [self.tableView indexPathForCell:cell];
  
  // TODO: Handling of non-simple values?
  
  auto& setting = self.controlGroup->numeric_settings[indexPath.row];
  auto doubleSetting = static_cast<ControllerEmu::NumericSetting<double>*>(setting.get());
  
  double value;
  
  NSScanner* scanner = [NSScanner localizedScannerWithString:cell.textField.text];
  if (![scanner scanDouble:&value]) {
    [self updateDoubleCell:cell withSetting:doubleSetting];
    
    return;
  }
  
  double minValue = doubleSetting->GetMinValue();
  double maxValue = doubleSetting->GetMaxValue();
  
  if (value < minValue) {
    value = minValue;
  } else if (value > maxValue) {
    value = maxValue;
  }
  
  doubleSetting->SetValue(value);
  
  [self.delegate controlGroupDidChange:self];
  
  [self updateDoubleCell:cell withSetting:doubleSetting];
}

- (void)switchDidChange:(MappingGroupEditBoolCell*)cell {
  NSIndexPath* indexPath = [self.tableView indexPathForCell:cell];
  
  // TODO: Handling of non-simple values?
  
  auto& setting = self.controlGroup->numeric_settings[indexPath.row];
  auto boolSetting = static_cast<ControllerEmu::NumericSetting<bool>*>(setting.get());
  
  boolSetting->SetValue(cell.enabledSwitch.on);
  
  [self.delegate controlGroupDidChange:self];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
  return DOLMappingGroupEditSectionCount;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  switch (section) {
    case DOLMappingGroupEditSectionEnableSwitch:
      return self.controlGroup->default_value != ControllerEmu::ControlGroup::DefaultValue::AlwaysEnabled ? 1 : 0;
    case DOLMappingGroupEditSectionControls:
      return self.controlGroup->controls.size();
    case DOLMappingGroupEditSectionNumericSettings:
      return self.controlGroup->numeric_settings.size();
    default:
      return 0;
  }
}

- (CGFloat)tableView:(UITableView*)tableView heightForHeaderInSection:(NSInteger)section {
  // If there are no rows, don't reserve space for a section header.
  if ([self tableView:tableView numberOfRowsInSection:section] == 0) {
    return CGFLOAT_MIN;
  }
  
  return UITableViewAutomaticDimension;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  switch (indexPath.section) {
    case DOLMappingGroupEditSectionEnableSwitch: {
      MappingGroupEditEnabledCell* enabledCell = [tableView dequeueReusableCellWithIdentifier:@"EnabledCell" forIndexPath:indexPath];
      
      enabledCell.delegate = self;
      enabledCell.enabledSwitch.on = self.controlGroup->enabled.GetValue();
      
      return enabledCell;
    }
    case DOLMappingGroupEditSectionControls: {
      const auto lock = ControllerEmu::EmulatedController::GetStateLock();
      
      const auto& control = self.controlGroup->controls[indexPath.row];
      
      MappingGroupEditControlCell* controlCell = [tableView dequeueReusableCellWithIdentifier:@"ControlCell" forIndexPath:indexPath];
      
      NSString* name = CppToFoundationString(control->ui_name);
      if (control->translate == ControllerEmu::Translatability::Translate) {
        name = DOLCoreLocalizedString(name);
      }
      
      controlCell.nameLabel.text = name;
      
      [self updateControlCellBasedOnEnabled:controlCell];
      
      [self updateControlCell:controlCell withExpression:control->control_ref->GetExpression()];
      
      return controlCell;
    }
    case DOLMappingGroupEditSectionNumericSettings: {
      const auto& setting = self.controlGroup->numeric_settings[indexPath.row];
      UITableViewCell* numericCell;
      
      switch (setting->GetType()) {
        case ControllerEmu::SettingType::Double: {
          const auto& doubleSetting = static_cast<ControllerEmu::NumericSetting<double>*>(setting.get());
          
          MappingGroupEditDoubleCell* doubleCell = [tableView dequeueReusableCellWithIdentifier:@"DoubleCell" forIndexPath:indexPath];
          
          doubleCell.delegate = self;
          doubleCell.nameLabel.text = DOLCoreLocalizedString(CToFoundationString(doubleSetting->GetUIName()));
          
          [self updateDoubleCellBasedOnEnabled:doubleCell];
          
          [self updateDoubleCell:doubleCell withSetting:doubleSetting];
          
          numericCell = doubleCell;
         
          break;
        }
        case ControllerEmu::SettingType::Bool: {
          const auto& boolSetting = static_cast<ControllerEmu::NumericSetting<bool>*>(setting.get());
          
          MappingGroupEditBoolCell* boolCell = [tableView dequeueReusableCellWithIdentifier:@"BoolCell" forIndexPath:indexPath];
          
          boolCell.delegate = self;
          boolCell.nameLabel.text = DOLCoreLocalizedString(CToFoundationString(boolSetting->GetUIName()));
          boolCell.enabledSwitch.on = boolSetting->GetValue();
          
          [self updateBoolCellBasedOnEnabled:boolCell];
          
          numericCell = boolCell;
          
          break;
        }
        default:
          return nil;
      }
      
      if (setting->GetUIDescription()) {
        numericCell.accessoryType = UITableViewCellAccessoryDetailButton;
      } else {
        numericCell.accessoryType = UITableViewCellAccessoryNone;
      }
      
      return numericCell;
    }
    default:
      return nil;
  }
  
  return nil;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  if (indexPath.section == DOLMappingGroupEditSectionControls) {
    // TODO: All devices
    [self startInputDetectionWithAllDevices:false];
  } else {
    [tableView deselectRowAtIndexPath:indexPath animated:true];
  }
}

- (void)tableView:(UITableView*)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath*)indexPath {
  if (indexPath.section != DOLMappingGroupEditSectionNumericSettings) {
    return;
  }
  
  const auto& setting = self.controlGroup->numeric_settings[indexPath.row];
  NSString* description = DOLCoreLocalizedString(CToFoundationString(setting->GetUIDescription()));
  
  UIAlertController* alertController = [UIAlertController alertControllerWithTitle:DOLCoreLocalizedString(@"Help") message:description preferredStyle:UIAlertControllerStyleAlert];
  [alertController addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"OK") style:UIAlertActionStyleDefault handler:nil]];
  
  [self presentViewController:alertController animated:true completion:nil];
}

- (UISwipeActionsConfiguration*)tableView:(UITableView*)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath*)indexPath
{
  if (indexPath.section != DOLMappingGroupEditSectionControls) {
    return nil;
  }
  
  UIContextualAction* clearAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:DOLCoreLocalizedString(@"Clear") handler:^(UIContextualAction* action, __kindof UIView* source_view, void (^completion_handler)(bool)) {
    auto& controlRef = self.controlGroup->controls[indexPath.row]->control_ref;
    
    controlRef->range = 1.0;
    
    controlRef->SetExpression("");
    self.controller->UpdateSingleControlReference(g_controller_interface, controlRef.get());
    
    MappingGroupEditControlCell* controlCell = [tableView cellForRowAtIndexPath:indexPath];
    
    [self updateControlCell:controlCell withExpression:""];
    
    [self.delegate controlGroupDidChange:self];
    
    completion_handler(true);
  }];

  UISwipeActionsConfiguration* actions = [UISwipeActionsConfiguration configurationWithActions:@[clearAction]];
  actions.performsFirstActionWithFullSwipe = false;
  
  return actions;
}

#pragma mark - Input detection

// All of the UI state below is owned by the main queue. Detector creation, polling,
// and destruction happen only on _inputDetectionQueue, preventing lock-related UI freezes.
- (void)startInputDetectionWithAllDevices:(bool)allDevices {
  if (_mappingActive)
    return;

  NSIndexPath* selectedRow = self.tableView.indexPathForSelectedRow;
  if (selectedRow == nil || selectedRow.section != DOLMappingGroupEditSectionControls)
    return;

  _mappingIndexPath = [selectedRow copy];
  _mappingDefaultDevice = self.controller->GetDefaultDevice().ToString();
  _mappingActive = YES;
  const NSUInteger generation = ++_mappingGeneration;
  const std::string defaultDevice = _mappingDefaultDevice;

  _inputAlertController = [UIAlertController
      alertControllerWithTitle:DOLCoreLocalizedString(@"[ Press Now ]")
                       message:nil
                preferredStyle:UIAlertControllerStyleAlert];
  __weak MappingGroupEditViewController* weakSelf = self;
  [_inputAlertController addAction:[UIAlertAction
      actionWithTitle:DOLCoreLocalizedString(@"Cancel")
                style:UIAlertActionStyleCancel
              handler:^(__unused UIAlertAction* action) {
                [weakSelf cancelInputDetection];
              }]];

  [self presentViewController:_inputAlertController animated:YES completion:^{
    // The user may navigate away or cancel while the alert is animating.
    if (!self->_mappingActive || generation != self->_mappingGeneration)
      return;

    dispatch_async(self->_inputDetectionQueue, ^{
      std::vector<std::string> devices;
      if (allDevices) {
        devices = g_controller_interface.GetAllDeviceStrings();
      } else {
        devices.push_back(defaultDevice);
      }

      self->_inputDetector = std::make_unique<ciface::Core::InputDetector>();
      self->_inputDetector->Start(g_controller_interface, devices);
    });
  }];
}

// Cancelling never changes the existing mapping. The cleanup is enqueued behind
// any active detector operation, so the UI never waits for input/device locks.
- (void)cancelInputDetection {
  if (!_mappingActive)
    return;

  _mappingActive = NO;
  ++_mappingGeneration;
  NSIndexPath* selectedRow = _mappingIndexPath;
  _mappingIndexPath = nil;
  _mappingDefaultDevice.clear();

  UIAlertController* alert = _inputAlertController;
  _inputAlertController = nil;

  dispatch_async(_inputDetectionQueue, ^{
    self->_inputDetector.reset();
  });

  if (selectedRow != nil)
    [self.tableView deselectRowAtIndexPath:selectedRow animated:YES];
  [alert dismissViewControllerAnimated:YES completion:nil];
}

// Called on the main queue only after a background detection has finished.
// A session token prevents stale queued results from applying to another row.
- (void)finishInputDetectionWithExpression:(NSString*)expression
                                generation:(NSUInteger)generation {
  if (!_mappingActive || generation != _mappingGeneration)
    return;

  NSIndexPath* selectedRow = _mappingIndexPath;
  _mappingActive = NO;
  ++_mappingGeneration;
  _mappingIndexPath = nil;
  _mappingDefaultDevice.clear();

  UIAlertController* alert = _inputAlertController;
  _inputAlertController = nil;

  if (expression.length > 0 && selectedRow != nil &&
      selectedRow.section == DOLMappingGroupEditSectionControls &&
      selectedRow.row < (NSInteger)self.controlGroup->controls.size()) {
    const std::string mappedExpression = FoundationToCppString(expression);
    auto& controlRef = self.controlGroup->controls[selectedRow.row]->control_ref;
    controlRef->SetExpression(mappedExpression);
    self.controller->UpdateSingleControlReference(g_controller_interface, controlRef.get());

    [self.delegate controlGroupDidChange:self];
    MappingGroupEditControlCell* cell = [self.tableView cellForRowAtIndexPath:selectedRow];
    [self updateControlCell:cell withExpression:mappedExpression];
  }

  if (selectedRow != nil)
    [self.tableView deselectRowAtIndexPath:selectedRow animated:YES];
  // An empty result (no controller, timeout, or unreleased input) simply
  // closes the alert and preserves the previous binding.
  [alert dismissViewControllerAnimated:YES completion:nil];
}

- (void)processMappingButtons {
  if (!_mappingActive || _inputTickPending)
    return;

  _inputTickPending = YES;
  const NSUInteger generation = _mappingGeneration;
  const std::string defaultDeviceString = _mappingDefaultDevice;

  // Serial background polling keeps the main thread free even if the device
  // backend is slow. Only one poll may be outstanding at any time.
  dispatch_async(_inputDetectionQueue, ^{
    BOOL finished = NO;
    std::string expression;

    if (self->_inputDetector) {
      constexpr auto initialTime = std::chrono::seconds(3);
      constexpr auto confirmationTime = std::chrono::milliseconds(0);
      constexpr auto maximumTime = std::chrono::seconds(5);

      self->_inputDetector->Update(initialTime, confirmationTime, maximumTime);
      finished = self->_inputDetector->IsComplete();

      if (finished) {
        auto results = self->_inputDetector->TakeResults();
        if (ciface::MappingCommon::ContainsCompleteDetection(results)) {
          ciface::Core::DeviceQualifier qualifier;
          qualifier.FromString(defaultDeviceString);
          expression = ciface::MappingCommon::BuildExpression(
              results, qualifier, ciface::MappingCommon::Quote::On);
        }
        self->_inputDetector.reset();
      }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      self->_inputTickPending = NO;
      if (finished && self->_mappingActive && generation == self->_mappingGeneration) {
        [self finishInputDetectionWithExpression:CppToFoundationString(expression)
                                     generation:generation];
      }
    });
  });
}

@end
