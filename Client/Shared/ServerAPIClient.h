#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ServerAPIClient : NSObject

+ (instancetype)sharedClient;

- (void)getServerListWithCompletion:(void (^)(NSArray<NSDictionary *> * _Nullable servers, NSError * _Nullable error))completion;
- (void)startServerWithCompletion:(void (^)(NSError * _Nullable))completion;
- (void)stopServerWithCompletion:(void (^)(NSError * _Nullable))completion;

@end

NS_ASSUME_NONNULL_END
