//
//  PWDataManager.m
//  PushNotificationManager
//
//  Copyright © 2016 Pushwoosh. All rights reserved.
//

#import "PWDataManager.common.h"
#import "PWCache.h"
#import "PWRequestManager.h"
#import "PWNetworkModule.h"
#import "PWGetTagsRequest.h"
#import "PWSetTagsRequest.h"
#import "PWPushStatRequest.h"
#import "PWAppOpenRequest.h"
#import "PWVersionTracking.h"
#import "PWPlatformModule.h"
#import "PWPreferences.h"
#import "PWSetEmailTagsRequest.h"
#import "PWServerCommunicationManager.h"

#if TARGET_OS_IOS || TARGET_OS_OSX
#import "PWBusinessCaseManager.h"
#import "PWGetConfigRequest.h"
#endif

#if TARGET_OS_IOS
#import "PWAppLifecycleTrackingManager.h"
#import "PWScreenTrackingManager.h"
#endif

@interface PWDataManagerCommon()

// @Inject
@property (nonatomic, strong) PWRequestManager *requestManager;
@property (nonatomic) BOOL appOpenDidSent;

@end

@implementation PWDataManagerCommon {
    id _communicationStartedHandler;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		[[PWNetworkModule module] inject:self];
        [[NSOperationQueue currentQueue] addOperationWithBlock:^{
            [self loadConfig];
        }];
	}
	return self;
}

- (void)loadConfig {
    // wait until server communication is allowed
    if (![[PWServerCommunicationManager sharedInstance] isServerCommunicationAllowed]) {
        [self addServerCommunicationStartedObserver];
        return;
    }
#if TARGET_OS_IOS || TARGET_OS_OSX
    PWGetConfigRequest *request = [PWGetConfigRequest new];
    [_requestManager sendRequest:request completion:^(NSError *error) {
        _channels = request.channels;

        [[PWPreferences preferences] setIsLoggerActive:request.isLoggerActive];

        #if TARGET_OS_IOS
        
        _events = request.events;
        
        [PWAppLifecycleTrackingManager sharedManager].defaultAppClosedAllowed = [_events containsObject:defaultApplicationClosedEvent];
        [PWAppLifecycleTrackingManager sharedManager].defaultAppOpenAllowed = [_events containsObject:defaultApplicationOpenedEvent];
        [PWScreenTrackingManager sharedManager].defaultScreenOpenAllowed = [_events containsObject:defaultScreenOpenEvent];
        
        #endif
    }];
#endif
}

- (void)addServerCommunicationStartedObserver {
    if (!_communicationStartedHandler) {
        _communicationStartedHandler = [[NSNotificationCenter defaultCenter] addObserverForName:kPWServerCommunicationStarted object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {

            [[NSNotificationCenter defaultCenter] removeObserver:_communicationStartedHandler];
            _communicationStartedHandler = nil;
            [self loadConfig];
        }];
    }
}

- (void)setTags:(NSDictionary *)tags {
	[self setTags:tags withCompletion:nil];
}

- (void)setTags:(NSDictionary *)tags withCompletion:(PushwooshErrorHandler)completion {
	if (![tags isKindOfClass:[NSDictionary class]]) {
		PWLogError(@"tags must be NSDictionary");
		return;
	}

	[[PWCache cache] addTags:tags];

	PWSetTagsRequest *request = [[PWSetTagsRequest alloc] init];
	request.tags = tags;

	[_requestManager sendRequest:request completion:^(NSError *error) {
		if (error == nil) {
			PWLogDebug(@"setTags completed");
		} else {
			PWLogError(@"setTags failed");
		}

		if (completion)
			completion(error);
	}];
}

- (void)loadTags {
	[self loadTags:nil error:nil];
}

- (void)loadTags:(PushwooshGetTagsHandler)successHandler error:(PushwooshErrorHandler)errorHandler {
	PWGetTagsRequest *request = [[PWGetTagsRequest alloc] init];
	[_requestManager sendRequest:request completion:^(NSError *error) {
		PWLogDebug(@"loadTags completed");
		if (error == nil && [request.tags isKindOfClass:[NSDictionary class]]) {
			[[PWCache cache] setTags:request.tags];

			if ([[PushNotificationManager pushManager].delegate respondsToSelector:@selector(onTagsReceived:)]) {
				[[PushNotificationManager pushManager].delegate onTagsReceived:request.tags];
			}

			if (successHandler) {
				successHandler(request.tags);
			}

		} else {
			NSDictionary *tags = [[PWCache cache] getTags];
			if (tags) {
				PWLogWarn(@"loadTags failed, return cached tags");

				if ([[PushNotificationManager pushManager].delegate respondsToSelector:@selector(onTagsReceived:)]) {
					[[PushNotificationManager pushManager].delegate onTagsReceived:tags];
				}

				if (successHandler) {
					successHandler(tags);
				}
			} else {
				PWLogError(@"loadTags failed");

				if ([[PushNotificationManager pushManager].delegate respondsToSelector:@selector(onTagsFailedToReceive:)]) {
				   [[PushNotificationManager pushManager].delegate onTagsFailedToReceive:error];
				}

				if (errorHandler) {
				   errorHandler(error);
				}
			}
		}
	}];
}

- (void)setEmailTags:(NSDictionary *)tags forEmail:(NSString *)email {
    [self setEmailTags:tags forEmail:email withCompletion:nil];
}

- (void)setEmailTags:(NSDictionary *)tags forEmail:(NSString *)email withCompletion:(PushwooshErrorHandler)completion {
    if (![tags isKindOfClass:[NSDictionary class]]) {
        PWLogError(@"tags must be NSDictionary");
        return;
    }
    
    if (email == nil) {
        PWLogError(@"email cannot be nil");
        return;
    }
    
    [[PWCache cache] addEmailTags:tags];
    
    PWSetEmailTagsRequest *request = [[PWSetEmailTagsRequest alloc] init];
    request.tags = tags;
    request.email = email;
    
    [_requestManager sendRequest:request completion:^(NSError *error) {
        if (error == nil) {
            PWLogDebug(@"setEmailTags completed");
        } else {
            PWLogError(@"setEmailTags failed");
        }
        
        if (completion)
            completion(error);
    }];
    [[PWCache cache] getEmailTags];
}

- (void)sendAppOpenWithCompletion:(void (^)(NSError *error))completion {
    if (![[PWServerCommunicationManager sharedInstance] isServerCommunicationAllowed]) {
        return;
    }
    if (_appOpenDidSent) {
        return;
    }
    
    _appOpenDidSent = YES;
    
    [PWVersionTracking track];
    
    #if TARGET_OS_IOS || TARGET_OS_OSX
    
    [[PWBusinessCaseManager sharedManager] startBusinessCase:kPWWelcomeBusinessCase completion:^(PWBusinessCaseResult result) {
        if (result == PWBusinessCaseResultConditionFail) {
            [[PWBusinessCaseManager sharedManager] startBusinessCase:kPWUpdateBusinessCase completion:nil];
        }
    }];
    
    #endif
    
    //it's ok to call this method without push token
    PWAppOpenRequest *request = [[PWAppOpenRequest alloc] init];
    
    [_requestManager sendRequest:request completion:^(NSError *error) {
        if (error == nil) {
            PWLogDebug(@"sending appOpen completed");
            
            #if TARGET_OS_IOS || TARGET_OS_OSX
            [[PWBusinessCaseManager sharedManager] handleBusinessCaseResources:request.businessCasesDict];
            #endif
            
            if (!error) {
                if ([PWPreferences preferences].previosHWID) {
                    [self performDeviceMigrationWithCompletion:^(NSError *error) {
                        if (!error) {
                            [[PWPreferences preferences] saveCurrentHWIDtoUserDefaults]; //forget previous HWID
                            
                            if ([PushNotificationManager pushManager].getPushToken) {
                                [PWPreferences preferences].lastRegTime = nil;
                                [[PushNotificationManager pushManager] registerForPushNotifications];
                            }
                        }
                    }];
                }
            }
        } else {
            PWLogInfo(@"sending appOpen failed");
        }
        
        if (completion) {
            completion(error);
        }
    }];
    
    [self loadTags]; //we need to initially load and cache tags for personalized in-apps
}

- (void)performDeviceMigrationWithCompletion:(void (^)(NSError *error))completion {
    PWGetTagsRequest *request = [PWGetTagsRequest new];
    request.usePreviousHWID = YES;
    [_requestManager sendRequest:request completion:^(NSError *error) {
        if (error) {
            if (completion) {
                completion(error);
            }
        } else if (request.tags) {
            [self setTags:request.tags withCompletion:completion];
        }
    }];
}

- (void)sendStatsForPush:(NSDictionary *)pushDict {
    NSDictionary *apsDict = [pushDict pw_dictionaryForKey:@"aps"];
    BOOL isContentAvailable = [[apsDict objectForKey:@"content-available"] boolValue];
    
    NSString *alert = pushDict[@"alert"];
    
    if (isContentAvailable && !alert) { //is silent push
        return;
    }
    
    if (pushDict[@"pw_msg"] == nil) { // not Pushwoosh push
        return;
    }
    
    if ([_lastHash isEqualToString:pushDict[@"p"]]){
        return;
    }
    
    _lastHash = pushDict[@"p"];
    
    dispatch_block_t sendPushStatBlock = ^{
        PWPushStatRequest *request = [[PWPushStatRequest alloc] init];
        request.pushDict = pushDict;
        
        [_requestManager sendRequest:request completion:^(NSError *error) {
            if (error == nil) {
                PWLogDebug(@"sendStats completed");
            } else {
                PWLogError(@"sendStats failed");
            }
        }];
    };
    
#if TARGET_OS_IOS
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), sendPushStatBlock);
    }
    else
#endif
    {
        sendPushStatBlock();
    }
}

@end