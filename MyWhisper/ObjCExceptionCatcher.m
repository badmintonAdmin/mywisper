//
//  ObjCExceptionCatcher.m
//  MyWhisper
//

#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (BOOL)catchException:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
            info[@"ExceptionName"] = exception.name;
            *error = [NSError errorWithDomain:@"com.barssoft.mywhisper.objc-exception" code:1 userInfo:info];
        }
        return NO;
    }
}

@end
