//
//  OpenVPNConfiguration+Internal.h
//  OpenVPN Adapter
//
//  Created by Sergey Abramchuk on 21.04.17.
//
//

#import "OpenVPNConfiguration.h"

#include <ovpnapi.hpp>

using namespace openvpn;

NS_ASSUME_NONNULL_BEGIN

@interface OpenVPNConfiguration (Internal)

@property (readonly) ClientAPI::Config config;

+ (OpenVPNTransportProtocol)getTransportProtocolFromValue:(nullable NSString *)value;
+ (NSString *)getValueFromTransportProtocol:(OpenVPNTransportProtocol)protocol;


+ (OpenVPNCompressionMode)getCompressionModeFromValue:(nullable NSString *)value;
+ (NSString *)getValueFromCompressionMode:(OpenVPNCompressionMode)compressionMode;

+ (OpenVPNMinTLSVersion)getMinTLSFromValue:(nullable NSString *)value;
+ (NSString *)getValueFromMinTLS:(OpenVPNMinTLSVersion)minTLS;

+ (OpenVPNTLSCertProfile)getTLSCertProfileFromValue:(nullable NSString *)value;
+ (NSString *)getValueFromTLSCertProfile:(OpenVPNTLSCertProfile)tlsCertProfile;

@end

NS_ASSUME_NONNULL_END
