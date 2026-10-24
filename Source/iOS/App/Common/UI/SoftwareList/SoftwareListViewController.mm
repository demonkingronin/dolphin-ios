// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "SoftwareListViewController.h"

#import "EmulationBootParameter.h"
#import "EmulationViewController.h"
#import "FoundationStringUtil.h"
#import "GameFileCacheManager.h"
#import "GameFilePtrWrapper.h"
#import "SoftwarePropertiesViewController.h"
#import "Swift.h"
#import "WiiSystemUpdateViewController.h"

#import "UICommon/GameFile.h"
#import "Common/FileUtil.h"
#import "DiscIO/Blob.h"
#import "DiscIO/GameModDescriptor.h"

@interface SoftwareListViewController ()

@end

@implementation SoftwareListViewController {
  NSString* _wiiUpdateSource;
  bool _wiiUpdateIsOnline;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  
  self->_gameFiles = [self hidePairedJSONDescriptors:
      [[GameFileCacheManager sharedManager] getGames]];
  [self sortGameFiles];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  
  [self reloadGameFiles];
}

- (void)reloadGameFiles {
  [[GameFileCacheManager sharedManager] rescanAndFetchMetadataWithCompletionHandler:^{
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_gameFiles = [self hidePairedJSONDescriptors:
          [[GameFileCacheManager sharedManager] getGames]];
      [self sortGameFiles];
      [self.collectionView reloadData];
    });
  }];
}

// Sort the visible games using persisted preferences and the on-device play history.
- (void)sortGameFiles {
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  NSString* sort = [defaults stringForKey:@"DOLSoftwareSortKey"] ?: @"recent";
  BOOL ascending = [defaults objectForKey:@"DOLSoftwareSortAscending"] ?
      [defaults boolForKey:@"DOLSoftwareSortAscending"] : NO;
  NSDictionary* usage = [defaults dictionaryForKey:@"DOLGameUsageStatisticsV1"] ?: @{};
  self->_gameFiles = [self->_gameFiles sortedArrayUsingComparator:^NSComparisonResult(GameFilePtrWrapper* a, GameFilePtrWrapper* b) {
    NSString* aName = CppToFoundationString(a.gameFile->GetName(UICommon::GameFile::Variant::LongAndPossiblyCustom));
    NSString* bName = CppToFoundationString(b.gameFile->GetName(UICommon::GameFile::Variant::LongAndPossiblyCustom));
    NSComparisonResult result = NSOrderedSame;
    if ([sort isEqualToString:@"name"]) {
      result = [aName localizedStandardCompare:bName];
    } else {
      NSString* aPath = CppToFoundationString(a.gameFile->GetFilePath());
      NSString* bPath = CppToFoundationString(b.gameFile->GetFilePath());
      NSDictionary* aUsage = usage[aPath];
      NSDictionary* bUsage = usage[bPath];
      NSString* metric = [sort isEqualToString:@"time"] ? @"timePlayed" : @"lastPlayed";
      double av = [aUsage[metric] doubleValue];
      double bv = [bUsage[metric] doubleValue];
      if (av < bv) result = NSOrderedAscending;
      else if (av > bv) result = NSOrderedDescending;
    }
    if (!ascending) {
      if (result == NSOrderedAscending) result = NSOrderedDescending;
      else if (result == NSOrderedDescending) result = NSOrderedAscending;
    }
    return result == NSOrderedSame ? [aName localizedStandardCompare:bName] : result;
  }];
}

// Resolve path aliases and compare genuine game identity to recognize a
// paired Dolphin JSON descriptor. Never combine two actual ISO/WBFS game files.
- (BOOL)isModDescriptorAtPath:(NSString*)path pairedWithGame:(GameFilePtrWrapper*)game {
  if (path.length == 0 || !game.gameFile)
    return NO;
  auto descriptor = DiscIO::ParseGameModDescriptorFile(FoundationToCppString(path));
  if (!descriptor)
    return NO;
  NSString* base = CppToFoundationString(descriptor->base_file);
  NSString* disc = CppToFoundationString(game.gameFile->GetFilePath());
  if ([[base stringByStandardizingPath] isEqualToString:[disc stringByStandardizingPath]] ||
      [[base stringByResolvingSymlinksInPath] isEqualToString:[disc stringByResolvingSymlinksInPath]])
    return YES;
  // A valid descriptor has an openable base disc. Match its game identity
  // even if the JSON stored an alternate pathname for the same game.
  UICommon::GameFile baseGame(descriptor->base_file);
  return baseGame.IsValid() &&
      baseGame.GetGameID() == game.gameFile->GetGameID() &&
      baseGame.GetPlatform() == game.gameFile->GetPlatform() &&
      baseGame.GetRevision() == game.gameFile->GetRevision() &&
      baseGame.GetDiscNumber() == game.gameFile->GetDiscNumber();
}

// A JSON descriptor with a matching base game is a launch profile, not a
// separate game. Other formats (including independently patched ISOs) remain.
- (NSArray<GameFilePtrWrapper*>*)hidePairedJSONDescriptors:
    (NSArray<GameFilePtrWrapper*>*)games {
  NSMutableArray<GameFilePtrWrapper*>* visible = [NSMutableArray array];
  for (GameFilePtrWrapper* item in games) {
    if (item.gameFile->GetBlobType() == DiscIO::BlobType::MOD_DESCRIPTOR) {
      NSString* path = CppToFoundationString(item.gameFile->GetFilePath());
      BOOL paired = NO;
      for (GameFilePtrWrapper* other in games) {
        if (other.gameFile->GetBlobType() != DiscIO::BlobType::MOD_DESCRIPTOR &&
            [self isModDescriptorAtPath:path pairedWithGame:other]) {
          paired = YES;
          break;
        }
      }
      if (paired)
        continue;
    }
    [visible addObject:item];
  }
  return visible;
}

- (void)loadGameFile:(GameFilePtrWrapper*)gameFileWrapper {
  // The default profile is only applied when the cover is tapped.
  NSString* key = [NSString stringWithFormat:@"DolphiniOSDefaultLaunchProfile:%@r%u",
      CppToFoundationString(gameFileWrapper.gameFile->GetGameID()),
      (unsigned)gameFileWrapper.gameFile->GetRevision()];
  NSString* defaultProfile = [[NSUserDefaults standardUserDefaults] stringForKey:key];
  // Selecting "Original Game" is a persistent opt-out of automatic patch
  // selection. Otherwise a single existing, working mod descriptor beside
  // its original disc acts as that disc's default launch profile.
  if ([defaultProfile isEqualToString:@"__dolphinios_original__"]) {
    defaultProfile = nil;
  } else if (defaultProfile == nil &&
             gameFileWrapper.gameFile->GetBlobType() != DiscIO::BlobType::MOD_DESCRIPTOR) {
    NSString* discoveredProfile = nil;
    NSUInteger discoveredCount = 0;
    for (GameFilePtrWrapper* candidate in [[GameFileCacheManager sharedManager] getGames]) {
      if (candidate.gameFile->GetBlobType() != DiscIO::BlobType::MOD_DESCRIPTOR)
        continue;
      auto descriptor =
          DiscIO::ParseGameModDescriptorFile(candidate.gameFile->GetFilePath());
      if (!descriptor ||
          ![self isModDescriptorAtPath:CppToFoundationString(candidate.gameFile->GetFilePath())
                       pairedWithGame:gameFileWrapper] ||
          !descriptor->riivolution || descriptor->riivolution->patches.empty())
        continue;

      BOOL isReady = YES;
      for (const auto& patch : descriptor->riivolution->patches) {
        if (!File::Exists(patch.xml) || !File::Exists(patch.root)) {
          isReady = NO;
          break;
        }
      }
      if (isReady) {
        discoveredProfile = CppToFoundationString(candidate.gameFile->GetFilePath());
        ++discoveredCount;
      }
    }
    // When more than one patched variant exists, let the user choose a
    // default instead of silently picking one.
    if (discoveredCount == 1)
      defaultProfile = discoveredProfile;
  }
  [self loadGameFile:gameFileWrapper withLaunchProfile:defaultProfile];
}

- (void)loadGameFile:(GameFilePtrWrapper*)gameFileWrapper
   withLaunchProfile:(NSString*)profilePath {
  [self loadGameFile:gameFileWrapper withLaunchProfile:profilePath safeBoot:NO];
}

- (void)loadGameFile:(GameFilePtrWrapper*)gameFileWrapper
   withLaunchProfile:(NSString*)profilePath
            safeBoot:(BOOL)safeBoot {
  std::shared_ptr<const UICommon::GameFile> game = gameFileWrapper.gameFile;
  if (profilePath.length > 0) {
    auto descriptor = DiscIO::ParseGameModDescriptorFile(FoundationToCppString(profilePath));
    BOOL isValid = descriptor &&
        [self isModDescriptorAtPath:profilePath pairedWithGame:gameFileWrapper] &&
        descriptor->riivolution && !descriptor->riivolution->patches.empty();
    if (isValid) {
      for (const auto& patch : descriptor->riivolution->patches) {
        if (!File::Exists(patch.xml) ||
            !File::Exists(patch.root)) {
          isValid = NO;
          break;
        }
      }
    }
    if (!isValid) {
      UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Launch Profile Unavailable"
         message:@"The JSON profile is missing, targets a different game, or its Riivolution files are not accessible. Use Launch Profiles to select a working profile or play the original game."
         preferredStyle:UIAlertControllerStyleAlert];
      [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault
          handler:nil]];
      [self presentViewController:alert animated:YES completion:nil];
      return;
    }
  }
  
  std::shared_ptr<const UICommon::GameFile> second_game = nullptr;
  std::shared_ptr<const UICommon::GameFile> match_without_revision = nullptr;
  
  if (DiscIO::IsDisc(game->GetPlatform())) {
    for (GameFilePtrWrapper* otherWrapper in self->_gameFiles) {
      std::shared_ptr<const UICommon::GameFile> other_game = otherWrapper.gameFile;
      
      if (game->GetGameID() == other_game->GetGameID() &&
          game->GetDiscNumber() != other_game->GetDiscNumber()) {
        if (game->GetRevision() == other_game->GetRevision()) {
          second_game = other_game;
          break;
        } else {
          match_without_revision = other_game;
        }
      }
    }
  }
  
  if (second_game == nullptr) {
    second_game = match_without_revision;
  }
  
  NSString* resolvedPath = profilePath.length > 0 ?
      profilePath : CppToFoundationString(game->GetFilePath());
  BOOL pathIsDirectory = NO;
  if (![[NSFileManager defaultManager] fileExistsAtPath:resolvedPath
                                           isDirectory:&pathIsDirectory] || pathIsDirectory) {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Game File Unavailable"
        message:@"The selected game or launch profile cannot be found in this Dolphin installation's storage. Existing files have not been changed."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    return;
  }

  _bootParameter = [[EmulationBootParameter alloc] init];
  _bootParameter.bootType = EmulationBootTypeFile;
  _bootParameter.path = profilePath.length > 0 ? profilePath :
      CppToFoundationString(game->GetFilePath());
  // Attribute profile launches to their displayed base game in the library.
  _bootParameter.usageGamePath = CppToFoundationString(game->GetFilePath());
  _bootParameter.secondPath = profilePath.length > 0 ? nil :
      (second_game != nullptr ? CppToFoundationString(second_game->GetFilePath()) : nil);
  _bootParameter.isNKit = gameFileWrapper.gameFile->IsNKit();
  _bootParameter.safeBoot = safeBoot;
  
  [self performSegueWithIdentifier:@"emulation" sender:nil];
}

- (void)loadGameCubeIPLForRegion:(DiscIO::Region)region {
  _bootParameter = [[EmulationBootParameter alloc] init];
  _bootParameter.bootType = EmulationBootTypeGCIPL;
  _bootParameter.iplRegion = region;
  
  [self performSegueWithIdentifier:@"emulation" sender:nil];
}

#pragma mark <UICollectionViewDataSource>

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView*)collectionView {
  return 1;
}

- (NSInteger)collectionView:(UICollectionView*)collectionView numberOfItemsInSection:(NSInteger)section {
  return self->_gameFiles.count;
}

- (UICollectionViewCell*)collectionView:(UICollectionView*)collectionView cellForItemAtIndexPath:(NSIndexPath*)indexPath {
  SoftwareListCell* cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"softwareCell" forIndexPath:indexPath];
  GameFilePtrWrapper* gameFileWrapper = [self->_gameFiles objectAtIndex:indexPath.item];
  
  NSString* gameName = CppToFoundationString(gameFileWrapper.gameFile->GetName(UICommon::GameFile::Variant::LongAndPossiblyCustom));
  
  const UICommon::GameCover& cover = gameFileWrapper.gameFile->GetCoverImage();
  
  UIImage* image;
  if (cover.buffer.empty()) {
    image = [UIImage imageNamed:@"NoCover"];
  } else {
    NSData* data = [NSData dataWithBytes:cover.buffer.data() length:cover.buffer.size()];
    image = [UIImage imageWithData:data];
  }
  
  cell.imageView.image = image;
  cell.nameLabel.text = gameName;
  
  return cell;
}

- (void)collectionView:(UICollectionView*)collectionView didSelectItemAtIndexPath:(NSIndexPath*)indexPath {
  GameFilePtrWrapper* gameFileWrapper = [self->_gameFiles objectAtIndex:indexPath.item];
  
  [self loadGameFile:gameFileWrapper];
}

#pragma mark <UICollectionViewDelegateFlowLayout>

- (CGSize)collectionView:(UICollectionView*)collectionView layout:(UICollectionViewLayout*)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath*)indexPath {
  const CGFloat cellsPerRow = 3.f;
  const CGFloat cellSpacing = 4.f;
  const CGFloat cellHeight = 218.f;
  
  CGFloat totalSpacing = ((cellsPerRow - 1) * cellSpacing);
  return CGSizeMake((collectionView.bounds.size.width - totalSpacing) / cellsPerRow, cellHeight);
}

#pragma mark Segue

- (void)performSegueForWiiUpdateWithSource:(NSString*)source isOnline:(bool)online {
  _wiiUpdateSource = source;
  _wiiUpdateIsOnline = online;
  
  [self performSegueWithIdentifier:@"wiiUpdate" sender:nil];
}

- (void)prepareForSegue:(UIStoryboardSegue*)segue sender:(id)sender
{
  if ([segue.identifier isEqualToString:@"emulation"]) {
    UINavigationController* navigationController = segue.destinationViewController;
    EmulationViewController* viewController = navigationController.viewControllers[0];
    
    viewController.bootParameter = _bootParameter;
  } else if ([segue.identifier isEqualToString:@"wiiUpdate"]) {
    WiiSystemUpdateViewController* updateController = segue.destinationViewController;
    
    updateController.updateSource = _wiiUpdateSource;
    updateController.isOnlineUpdate = _wiiUpdateIsOnline;
  } else if ([segue.identifier isEqualToString:@"properties"]) {
    UINavigationController* navigationController = segue.destinationViewController;
    SoftwarePropertiesViewController* propertiesController = navigationController.viewControllers[0];
    
    propertiesController.gameFileWrapper = _selectedFile;
  }
}

@end
