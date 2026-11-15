#import <NetworkExtension/NetworkExtension.h>
#import <Network/Network.h>

@interface PacketTunnelProvider : NEPacketTunnelProvider

- (NSString *)extractDestinationIPFromIPPacket:(NSData *)packet;
- (void)sendFramedDataToServer:(NSData *)framedData;

@end
