#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (BOOL)tryBlock:(NS_NOESCAPE void (^)(void))block error:(NSError *_Nullable *_Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] = [NSString stringWithFormat:@"%@: %@",
                                               exception.name, exception.reason ?: @"no reason given"];
            info[@"ExceptionName"] = exception.name;
            if (exception.reason) info[@"ExceptionReason"] = exception.reason;
            *error = [NSError errorWithDomain:@"com.maccesshub.objc-exception" code:1 userInfo:info];
        }
        return NO;
    }
}

@end
