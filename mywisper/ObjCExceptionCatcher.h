//
//  ObjCExceptionCatcher.h
//  mywisper
//
//  AVAudioEngine reports misuse (e.g. installTap with a format that no longer matches the
//  hardware after headphones connect) by raising an Objective-C NSException. Swift cannot
//  catch those — the app just dies. This shim converts them into a Swift-throwable NSError.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCExceptionCatcher : NSObject

/// Runs `block`; if it raises an NSException, returns NO and fills `error` instead of crashing.
+ (BOOL)catchException:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
