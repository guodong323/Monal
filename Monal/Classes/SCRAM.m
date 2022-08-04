//
//  SCRAM.m
//  monalxmpp
//
//  Created by Thilo Molitor on 05.08.22.
//  Copyright © 2022 monal-im.org. All rights reserved.
//

#include <arpa/inet.h>

#import <Foundation/Foundation.h>
#import "HelperTools.h"
#import "SCRAM.h"

@interface SCRAM ()
{
    NSString* _method;
    NSString* _username;
    NSString* _password;
    NSString* _nonce;
    
    NSString* _clientFirstMessageBare;
    NSString* _gssHeader;
    
    NSString* _serverFirstMessage;
    uint32_t _iterationCount;
    NSData* _salt;
    
    NSString* _expectedServerSignature;
}
@end

//see these for intermediate test values:
//https://stackoverflow.com/a/32470299/3528174
//https://stackoverflow.com/a/29299946/3528174
@implementation SCRAM

//list supported mechanisms (highest security first!)
+(NSArray*) supportedMechanisms
{
    return @[@"SCRAM-SHA-512", @"SCRAM-SHA-256", @"SCRAM-SHA-1"];
}

-(instancetype) initWithUsername:(NSString*) username password:(NSString*) password andMethod:(NSString*) method
{
    self = [super init];
    MLAssert([[[self class] supportedMechanisms] containsObject:method], @"Unsupported SCRAM hash method!", (@{@"method": nilWrapper(method)}));
    _method = method;
    _username = username;
    _password = password;
    _nonce = [NSUUID UUID].UUIDString;
    return self;
}

-(NSString*) clientFirstMessage
{
    _gssHeader = @"n,,";
    _clientFirstMessageBare = [NSString stringWithFormat:@"n=%@,r=%@", [self quote:_username], _nonce];
    return [NSString stringWithFormat:@"%@%@", _gssHeader, _clientFirstMessageBare];
}

-(BOOL) parseServerFirstMessage:(NSString*) str
{
    NSDictionary* msg = [self parseScramString:str];
    //server nonce MUST start with our client nonce
    if(![msg[@"r"] hasPrefix:_nonce])
        return NO;
    //check for attributes not allowed per RFC
    for(NSString* key in msg)
        if([@"m" isEqualToString:key])
            return NO;
    _serverFirstMessage = str;
    _nonce = msg[@"r"];     //from now on use the full nonce
    _salt = [HelperTools dataWithBase64EncodedString:msg[@"s"]];
    _iterationCount = (uint32_t)[msg[@"i"] integerValue];
    return YES;
}

//see https://stackoverflow.com/a/29299946/3528174
-(NSString*) clientFinalMessage
{
    //calculate saltedPassword (e.g. Hi(Normalize(password), salt, i))
    uint32_t i = htonl(1);
    NSMutableData* salti = [NSMutableData dataWithData:_salt];
    [salti appendData:[NSData dataWithBytes:&i length:sizeof(i)]];
    NSData* passwordData = [_password dataUsingEncoding:NSUTF8StringEncoding];
    NSData* saltedPasswordIntermediate = [self hmacForKey:passwordData andData:salti];
    NSData* saltedPassword = saltedPasswordIntermediate;
    for(long i = 1; i < _iterationCount; i++)
    {
        saltedPasswordIntermediate = [self hmacForKey:passwordData andData:saltedPasswordIntermediate];
        saltedPassword = [HelperTools XORData:saltedPassword withData:saltedPasswordIntermediate];
    }
    
    //calculate clientKey (e.g. HMAC(SaltedPassword, "Client Key"))
    NSData* clientKey = [self hmacForKey:saltedPassword andData:[@"Client Key" dataUsingEncoding:NSUTF8StringEncoding]];
    
    //calculate storedKey (e.g. H(ClientKey))
    NSData* storedKey = [self hash:clientKey];
    
    //calculate authMessage (e.g. client-first-message-bare + "," + server-first-message + "," + client-final-message-without-proof)
    NSString* clientFinalMessageWithoutProof = [NSString stringWithFormat:@"c=%@,r=%@", [HelperTools encodeBase64WithString:_gssHeader], _nonce];
    NSString* authMessage = [NSString stringWithFormat:@"%@,%@,%@", _clientFirstMessageBare, _serverFirstMessage, clientFinalMessageWithoutProof];
    
    //calculate clientSignature (e.g. HMAC(StoredKey, AuthMessage))
    NSData* clientSignature = [self hmacForKey:storedKey andData:[authMessage dataUsingEncoding:NSUTF8StringEncoding]];
    
    //calculate clientProof (e.g. ClientKey XOR ClientSignature)
    NSData* clientProof = [HelperTools XORData:clientKey withData:clientSignature];
    
    //calculate serverKey (e.g. HMAC(SaltedPassword, "Server Key"))
    NSData* serverKey = [self hmacForKey:saltedPassword andData:[@"Server Key" dataUsingEncoding:NSUTF8StringEncoding]];
    
    //calculate _expectedServerSignature (e.g. HMAC(ServerKey, AuthMessage))
    _expectedServerSignature = [HelperTools encodeBase64WithData:[self hmacForKey:serverKey andData:[authMessage dataUsingEncoding:NSUTF8StringEncoding]]];
    
    //return client final message
    return [NSString stringWithFormat:@"%@,p=%@", clientFinalMessageWithoutProof, [HelperTools encodeBase64WithData:clientProof]];
}

-(BOOL) parseServerFinalMessage:(NSString*) str
{
    NSDictionary* msg = [self parseScramString:str];
    if(![_expectedServerSignature isEqualToString:msg[@"v"]])
        return NO;
    return YES;
}


-(NSData*) hmacForKey:(NSData*) key andData:(NSData*) data
{
    if([_method isEqualToString:@"SCRAM-SHA-1"])
        return [HelperTools sha1HmacForKey:key andData:data];
    if([_method isEqualToString:@"SCRAM-SHA-256"])
        return [HelperTools sha256HmacForKey:key andData:data];
    if([_method isEqualToString:@"SCRAM-SHA-512"])
        return [HelperTools sha512HmacForKey:key andData:data];
    NSAssert(NO, @"Unexpected error: unsupported SCRAM hash method!", (@{@"method": nilWrapper(_method)}));
    return nil;
}

-(NSData*) hash:(NSData*) data
{
    if([_method isEqualToString:@"SCRAM-SHA-1"])
        return [HelperTools sha1:data];
    if([_method isEqualToString:@"SCRAM-SHA-256"])
        return [HelperTools sha256:data];
    if([_method isEqualToString:@"SCRAM-SHA-512"])
        return [HelperTools sha512:data];
    NSAssert(NO, @"Unexpected error: unsupported SCRAM hash method!", (@{@"method": nilWrapper(_method)}));
    return nil;
}

-(NSDictionary* _Nullable) parseScramString:(NSString*) str
{
    NSMutableDictionary* retval = [[NSMutableDictionary alloc] init];
    for(NSString* component in [str componentsSeparatedByString:@","])
    {
        NSString* attribute = [component substringToIndex:1];
        NSString* value = [component substringFromIndex:2];
        retval[attribute] = value;
    }
    return retval;
}

-(NSString*) quote:(NSString*) str
{
    //TODO: use proper saslprep to allow for non-ascii chars
    str = [str stringByReplacingOccurrencesOfString:@"," withString:@"=2C"];
    str = [str stringByReplacingOccurrencesOfString:@"=" withString:@"=3D"];
    return str;
}

@end