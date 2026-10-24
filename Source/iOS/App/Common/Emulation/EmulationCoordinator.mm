// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "EmulationCoordinator.h"

#import <MetalKit/MetalKit.h>

#import "Common/MemoryUtil.h"
#import "Common/WindowSystemInfo.h"

#import "Core/Boot/Boot.h"
#import "Core/BootManager.h"
#import "Core/Config/GraphicsSettings.h"
#import "Core/Config/MainSettings.h"
#import "Core/Core.h"
#import "Core/PowerPC/PowerPC.h"
#import "Core/System.h"

#import "VideoCommon/Present.h"
#import "VideoCommon/VideoConfig.h"

#import "EmulationBootParameter.h"
#import "HostNotifications.h"
#import "HostQueue.h"
#import "JitManager.h"

@interface EmulationCoordinator ()
@property (atomic, copy, readwrite) NSString* lastBootOutcome;
@end

@implementation EmulationCoordinator {
  MTKView* _mtkView;
  CAMetalLayer* _metalLayer;
  UIView* _mainDisplayView;
}

@synthesize userRequestedPause = _userRequestedPause;

+ (EmulationCoordinator*)shared {
  static EmulationCoordinator* sharedInstance = nil;
  static dispatch_once_t onceToken;

  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });

  return sharedInstance;
}

- (id)init {
  if (self = [super init]) {
    _mtkView = [[MTKView alloc] init];
    _mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mtkView.preferredFramesPerSecond = 120;
    
    _metalLayer = (CAMetalLayer*)_mtkView.layer;
    
    self.isExternalDisplayConnected = false;
    self.lastBootOutcome = @"Not started";
  }
  
  return self;
}

- (void)setIsExternalDisplayConnected:(bool)connected {
  self->_isExternalDisplayConnected = connected;
  
  if (!_isExternalDisplayConnected) {
    [self requestDisplayOnSuperview:_mainDisplayView];
  }
}

- (void)registerMainDisplayView:(UIView*)mainView {
  _mainDisplayView = mainView;
  
  if (!self.isExternalDisplayConnected) {
    [self requestDisplayOnSuperview:mainView];
  }
}

- (void)registerExternalDisplayView:(UIView*)externalView {
  [self requestDisplayOnSuperview:externalView];
}

- (void)requestDisplayOnSuperview:(UIView*)superview {
  [_mtkView removeFromSuperview];
  
  [superview addSubview:_mtkView];
  [_mtkView setFrame:superview.bounds];
  
  if (g_presenter) {
    g_presenter->ResizeSurface();
  }
}

// Store only the latest diagnostic stage in a new file inside the existing guest.
// Never touch games, saves, controller profiles or Dolphin's existing INI files.
- (void)recordBootStage:(NSString*)stage {
  self.lastBootOutcome = stage;
  NSString* path = [NSHomeDirectory()
      stringByAppendingPathComponent:@"Documents/DolphiniOS-Launch-Diagnostics.txt"];
  NSString* report = [NSString stringWithFormat:
      @"DolphiniOS launch check\nStage: %@\nRecorded: %@\n", stage, [NSDate date]];
  [report writeToFile:path atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
}

- (void)runEmulationWithBootParameter:(EmulationBootParameter*)bootParameter {
  [self recordBootStage:@"Emulation view ready; starting worker"];
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    [self emulationLoopWithBootParameter:bootParameter];
  });
}

- (void)emulationLoopWithBootParameter:(EmulationBootParameter*)bootParameter {
  dispatch_sync(dispatch_get_main_queue(), ^{
    Core::UndeclareAsHostThread();
  });

  [self recordBootStage:@"Boot worker entered"];
  DOLHostQueueRunSync(^{
    [self recordBootStage:@"Host queue entered; initializing JIT and graphics"];
    __block WindowSystemInfo wsi;
    wsi.type = WindowSystemType::iOS;
    wsi.render_surface = (__bridge void*)self->_metalLayer;
    wsi.render_surface_scale = UIScreen.mainScreen.scale;
    
    auto& system = Core::System::GetInstance();
    
    if ([JitManager shared].acquiredJit)
    {
      if (@available(iOS 26, *))
      {
        Common::SetJitType([JitManager shared].deviceHasTxm ? Common::JitType::LuckTXM : Common::JitType::LuckNoTXM);
      }
      else
      {
        Common::SetJitType(Common::JitType::Legacy);
      }
      
      Config::SetBase(Config::GFX_VERTEX_LOADER_TYPE, VertexLoaderType::Native);
      
      Common::AllocateExecutableMemoryRegion();
    }
    else
    {
      Config::SetBase(Config::GFX_VERTEX_LOADER_TYPE, VertexLoaderType::Software);
    }
    
    [self recordBootStage:@"Resolving game boot parameters"];
    std::unique_ptr<BootParameters> boot = [bootParameter generateDolphinBootParameter];

    if (!boot) {
      [self recordBootStage:@"FAILED: selected game could not be opened"];
      PanicAlertFmt("Unable to open the selected game!");
    } else {
      [self recordBootStage:@"Boot parameters resolved; starting core"];
      if (!BootManager::BootCore(system, std::move(boot), wsi)) {
        [self recordBootStage:@"FAILED: emulator core initialization"];
        PanicAlertFmt("Failed to init core!");
      } else {
        [self recordBootStage:@"BootCore succeeded; waiting for video"];
      }
    }
  });
  
  while (Core::GetState(Core::System::GetInstance()) == Core::State::Starting) {
    [NSThread sleepForTimeInterval:0.025];
  }
  
  [[NSNotificationCenter defaultCenter] postNotificationName:DOLEmulationDidStartNotification object:self userInfo:nil];
  
  while (Core::IsRunning(Core::System::GetInstance())) {
    [NSThread sleepForTimeInterval:0.025];
  }
  
  dispatch_sync(dispatch_get_main_queue(), ^{
    Core::DeclareAsHostThread();
  });
  
  [[NSNotificationCenter defaultCenter] postNotificationName:DOLEmulationDidEndNotification object:self userInfo:nil];
  
  _mainDisplayView = nil;
}

- (bool)userRequestedPause {
  return _userRequestedPause;
}

- (void)setUserRequestedPause:(bool)userRequestedPause {
  if (userRequestedPause == _userRequestedPause) {
    return;
  }
  
  DOLHostQueueRunSync(^{
    Core::SetState(Core::System::GetInstance(), userRequestedPause ? Core::State::Paused : Core::State::Running);
  });
  
  _userRequestedPause = userRequestedPause;
}

- (void)clearMetalLayer {
  id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
  
  if (drawable == nil) {
    return;
  }
  
  MTLRenderPassDescriptor* renderPass = [MTLRenderPassDescriptor renderPassDescriptor];
  renderPass.colorAttachments[0].texture = drawable.texture;
  renderPass.colorAttachments[0].loadAction = MTLLoadActionClear;
  renderPass.colorAttachments[0].storeAction = MTLStoreActionStore;
  renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
  
  id<MTLCommandQueue> commandQueue = [_mtkView.preferredDevice newCommandQueue];
  id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
  
  id<MTLRenderCommandEncoder> commandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPass];
  commandEncoder.label = @"Clear";
  [commandEncoder endEncoding];
 
  [commandBuffer presentDrawable:drawable];
  [commandBuffer commit];
}

@end
