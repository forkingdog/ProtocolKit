//
//  ProtocolKit.h
//  ProtocolKit
//
//  Created by sunnyxx on 15/8/22.
//  Copyright (c) 2015年 forkingdog. All rights reserved.
//

#import "PKProtocolExtension.h"

/**
 * Protocol Extension Usage
 *
 * @code

// Protocol

@protocol Forkable <NSObject>

@optional
- (void)fork;

@required
- (NSString *)github;

@end

// Protocol Extentsion

@defs(Forkable)

- (void)fork {
    NSLog(@"Forkable protocol extension: I'm forking (%@).", self.github);
}

- (NSString *)github {
    return @"This is a required method, concrete class must override me.";
}

@end

// Concrete Class

@interface Forkingdog : NSObject <Forkable>
@end

@implementation Forkingdog

- (NSString *)github {
    return @"https://github.com/forkingdog";
}

@end
 
 * @endcode
 *
 * @note You can either implement within a single @defs or multiple ones.
 *
 */
