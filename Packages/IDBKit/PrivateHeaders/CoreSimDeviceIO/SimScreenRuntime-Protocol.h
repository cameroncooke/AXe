/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * This source code is licensed under the MIT license found in the LICENSE file.
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurfaceObjC.h>

NS_ASSUME_NONNULL_BEGIN

// Read-only subset verified against CoreSimDeviceIO runtime protocol encodings
// on 17 October 2026. Numeric state values are deliberately not named here.
@protocol SimScreenBacklight <NSObject>
@property (nonatomic, readonly) int state;
@property (nonatomic, readonly) double brightnessFactor;
@end

@protocol SimScreenMode <NSObject>
@property (nonatomic, readonly) double preferredUIScale;
@end

@protocol SimScreenProperties <NSObject>
@property (nonatomic, readonly) unsigned int seed;
@property (nonatomic, readonly) unsigned int screenID;
@property (nonatomic, readonly, nullable) NSString *name;
@property (nonatomic, readonly, nullable) NSString *uniqueId;
@property (nonatomic, readonly, nullable) NSString *deviceName;
@property (nonatomic, readonly) int powerState;
@property (nonatomic, readonly) unsigned long long screenType;
@property (nonatomic, readonly) unsigned int uiOrientation;
@property (nonatomic, readonly) CGSize pixelSize;
@property (nonatomic, readonly, nullable) id<SimScreenMode> currentMode;
@property (nonatomic, readonly, nullable) id<SimScreenBacklight> backlight;
@end

@protocol SimScreen <NSObject>
@property (nonatomic, readonly, nullable) id<SimScreenProperties> screenProperties;
// Block signatures verified from CoreSimDeviceIO extended protocol encodings.
- (void)registerScreenCallbacksWithUUID:(NSUUID *)uuid
                         callbackQueue:(dispatch_queue_t)queue
                         frameCallback:(void (^ _Nullable)(void))frame
               surfacesChangedCallback:(void (^ _Nullable)(IOSurface * _Nullable first, IOSurface * _Nullable second))surfaces
             propertiesChangedCallback:(void (^)(id<SimScreenProperties> properties))properties NS_SWIFT_NAME(registerScreenCallbacks(with:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:));
- (void)unregisterScreenCallbacksWithUUID:(NSUUID *)uuid;
@end

@protocol SimScreenAdapter <NSObject>
// Callback shape independently confirmed by the installed RocketSim IDB
// Swift symbol: @Sendable ([SimScreen]?, Error?) -> Void.
- (void)enumerateScreensWithCompletionQueue:(dispatch_queue_t)queue
                        completionHandler:(void (^)(NSArray<id<SimScreen>> * _Nullable screens, NSError * _Nullable error))completionHandler;
@end

NS_ASSUME_NONNULL_END
