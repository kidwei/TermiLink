#import <NetworkExtension/NetworkExtension.h>
#import <Network/Network.h>

@interface PacketTunnelProvider : NEPacketTunnelProvider

@property (nonatomic, strong) NWTCPConnection *serverConnection;
@property (nonatomic, copy) NSString *authToken;

- (NSString *)extractDestinationIPFromIPPacket:(NSData *)packet;
- (void)sendPacketToServer:(NSData *)packet;

@end
