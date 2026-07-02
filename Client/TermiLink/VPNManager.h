#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface VPNManager : NSObject

@property (nonatomic, assign, readonly) BOOL isConnected;
@property (nonatomic, copy, readonly) NSString *statusText;

+ (instancetype)sharedManager;

- (void)startVPNWithServerIP:(NSString *)serverIP port:(NSInteger)port completion:(void (^)(NSError * _Nullable))completion;
- (void)stopVPN;

@end

NS_ASSUME_NONNULL_END
