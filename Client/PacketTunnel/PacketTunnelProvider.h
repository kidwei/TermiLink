#import <NetworkExtension/NetworkExtension.h>
#import <Network/Network.h>

@interface PacketTunnelProvider : NEPacketTunnelProvider

- (NSString *)extractDestinationIPFromIPPacket:(NSData *)packet;
- (void)sendPacketToServer:(NSData *)packet;

@end
