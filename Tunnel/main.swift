import Foundation
import NetworkExtension

// A system extension is a plain daemon that macOS runs as root from /Library/SystemExtensions. Hand it to
// NetworkExtension, which creates a PacketTunnelProvider (Info.plist › NetworkExtension) for every start.
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
// Run the main run loop, not just the main dispatch queue (dispatchMain): OpenVPNAdapter delivers the packets it
// decrypts through a CFSocket source on CFRunLoopGetMain(), so without a running run loop nothing ever reaches
// the tunnel interface (the server's replies arrive, but utun counts 0 packets in). The run loop also drains
// the main queue.
CFRunLoopRun()
