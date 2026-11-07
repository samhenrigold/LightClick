#import <Foundation/Foundation.h>
// `control` is a VIMQMPConnection, which Swift knows under another name.
@interface VIMUSBClient : NSObject
@property BOOL useUSB2Storage;
+ (void)authorizeUsingTerminalWithCompletion:(void (^)(NSError *error))completion;
- (void)prepareWithCompletion:(void (^)(NSError *error))completion;
- (void)checkStorageInterface:(NSDictionary *)identity
                inUserSession:(BOOL)userSession
                   completion:(void (^)(NSDictionary *result, NSError *error))completion;
- (void)connectDevice:(NSDictionary *)device
            processID:(pid_t)pid
            directory:(NSString *)directory
              control:(id)control
           completion:(void (^)(NSError *error))completion;
- (void)disconnectDevice:(NSString *)identifier control:(id)control completion:(void (^)(NSError *error))completion;
- (void)deviceWasDeleted:(NSString *)identifier control:(id)control;
- (void)stop;
@end
