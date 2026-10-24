// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <UIKit/UIKit.h>

namespace DiscIO {
enum class Region;
}

@class EmulationBootParameter;
@class GameFilePtrWrapper;

NS_ASSUME_NONNULL_BEGIN

@interface SoftwareListViewController : UICollectionViewController<UICollectionViewDelegateFlowLayout> {
  NSArray<GameFilePtrWrapper*>* _gameFiles;
  GameFilePtrWrapper* _selectedFile;
  EmulationBootParameter* _bootParameter;
}

- (void)reloadGameFiles;
// Reorder existing game covers without changing any game files.
- (void)sortGameFiles;
// Paired mod JSONs are launch profiles, not duplicate disc covers.
- (BOOL)isModDescriptorAtPath:(NSString*)path pairedWithGame:(GameFilePtrWrapper*)game;
- (void)loadGameFile:(GameFilePtrWrapper*)gameFileWrapper;
- (void)loadGameFile:(GameFilePtrWrapper*)gameFileWrapper withLaunchProfile:(nullable NSString*)profilePath;
- (void)loadGameFile:(GameFilePtrWrapper*)gameFileWrapper withLaunchProfile:(nullable NSString*)profilePath safeBoot:(BOOL)safeBoot;
- (void)loadGameCubeIPLForRegion:(DiscIO::Region)region;

- (void)performSegueForWiiUpdateWithSource:(NSString*)source isOnline:(bool)online;

@end

NS_ASSUME_NONNULL_END
