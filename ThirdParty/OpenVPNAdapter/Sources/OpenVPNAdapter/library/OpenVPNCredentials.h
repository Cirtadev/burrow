//
//  OpenVPNCredentials.h
//  OpenVPN Adapter
//
//  Created by Sergey Abramchuk on 24.04.17.
//
//

#import <Foundation/Foundation.h>

/**
 Class used to pass credentials
 */
@interface OpenVPNCredentials : NSObject

/**
 Client username
 */
@property (nullable, nonatomic) NSString *username;

/**
 Client password
 */
@property (nullable, nonatomic) NSString *password;

/**
 Response to challenge
 */
@property (nullable, nonatomic) NSString *response;

/**
 Dynamic challenge/response cookie
 */
@property (nullable, nonatomic) NSString *dynamicChallengeCookie;

@end
