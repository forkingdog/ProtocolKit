# ProtocolKit
Protocol extension for Objective-C

# Usage

Your protocol:  

``` objc

@protocol Forkable <NSObject>

@optional
- (void)fork;

@required
- (NSString *)github;

@end
```

Protocol extension, add default implementation, use `@defs` magic keyword    

``` objc

@defs(Forkable)

- (void)fork {
    NSLog(@"Forkable protocol extension: I'm forking (%@).", self.github);
}

- (NSString *)github {
    return @"This is a required method, concrete class must override me.";
}

@end
```

Your concrete class

``` objc
@interface Forkingdog : NSObject <Forkable>
@end

@implementation Forkingdog

- (NSString *)github {
    return @"https://github.com/forkingdog";
}

@end
```

Run test

``` objc
[[Forkingdog new] fork];
```

Result

```
[Console] Forkable protocol extension: I'm forking (https://github.com/forkingdog).
```
