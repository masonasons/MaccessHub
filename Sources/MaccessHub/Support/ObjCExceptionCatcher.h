#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs Objective-C code that can raise an NSException, which Swift cannot
/// catch. AVFoundation raises for conditions the caller cannot always check
/// beforehand, such as `-[AVAudioPlayerNode play]` while the output device is
/// still waking up ("player did not see an IO cycle").
@interface ObjCExceptionCatcher : NSObject

/// Runs `block`. Returns NO and fills `error` if it raised; the exception's
/// name and reason are in the error's `userInfo` and localized description.
+ (BOOL)tryBlock:(NS_NOESCAPE void (^)(void))block error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(run(_:));

@end

NS_ASSUME_NONNULL_END
