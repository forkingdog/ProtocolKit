//
//  main.m
//  ProtocolKit
//
//  Created by sunnyxx on 15/7/24.
//  Copyright (c) 2015年 forkingdog. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "ProtocolKit.h"

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

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        [[Forkingdog new] fork];
    }
    return 0;
}
