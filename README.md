
大家都知道 swift 语言层面就支持 protocol 默认实现，而 OC 是没有的，大概在3年前 `sunnyxx` 就开源了一款在 OC 支持 protocol 实现注入框架 `ProtocolKit`：[https://github.com/forkingdog/ProtocolKit](https://github.com/forkingdog/ProtocolKit)

这次主要会说下 ProtocolKit 的原理 和 我们改造的方案。


## ProtocolKit 实现原理解析

先来看头文件，作者很巧妙利用了 OC 保留关键字 `@defs`，来封装真正的实现宏，  defs 主要用来美化 IDE 的显示效果

```
#define defs _pk_extension

// Interface
#define _pk_extension($protocol) _pk_extension_imp($protocol, _pk_get_container_class($protocol))

// Implementation
#define _pk_extension_imp($protocol, $container_class)                    \
    protocol $protocol;                                                   \
    @interface $container_class : NSObject <$protocol>                    \
    @end                                                                  \
    @implementation $container_class                                      \
    +(void)load {                                                         \
        _pk_extension_load(@protocol($protocol), $container_class.class); \
    }

// Get container class name by counter
#define _pk_get_container_class($protocol) _pk_get_container_class_imp($protocol, __COUNTER__)
#define _pk_get_container_class_imp($protocol, $counter) _pk_get_container_class_imp_concat(__PKContainer_, $protocol, $counter)
#define _pk_get_container_class_imp_concat($a, $b, $c) $a##$b##_##$c

void _pk_extension_load(Protocol *protocol, Class containerClass);
```

`__COUNTER__ `  累加数字宏，有部分编译器不支持，反正 GCC、Clang 支持，其实也可以用 `__LINE__` 效果一样

主要是支持同个文件内的，拆分 `Protocol` 不同方法的实现， 可以看下图

# ![3.jpeg](https://upload-images.jianshu.io/upload_images/1332613-42fcb3c0bac103e2.jpeg?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

实现原理 简单来说， 生成一个 Class 代码， 然后 Class 里面的就是，`协议方法默认实现` 的代码， 然后 Class +load 方法中， 把对应 Protocol 和 自己 传给内部保存起来。 

可以利用 Xcode 来看 展开后的代码

![4.jpeg](https://upload-images.jianshu.io/upload_images/1332613-9a69f786a4a23702.jpeg?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

看下真正的核心方法是 `_pk_extension_load`

```
void _pk_extension_load(Protocol *protocol, Class containerClass) {
 	 // 主要考虑了 异步 外部主动调用 该方法，如果纯靠宏的话 是全在主线程执行的
    pthread_mutex_lock(&protocolsLoadingLock);
	// 数组够不够长，不够就申请内存
    if (extendedProtcolCount >= extendedProtcolCapacity) {
        ...
    }
    
    // 寻找是否已存在 protocol 的实现，否的话，创建一个新的对象，然后 merge 这次传进来的 Class 实现方法
    size_t resultIndex = SIZE_T_MAX;
    for (size_t index = 0; index < extendedProtcolCount; ++index) {
        if (allExtendedProtocols[index].protocol == protocol) {
            resultIndex = index;
            break;
        }
    }
    
    if (resultIndex == SIZE_T_MAX) {
        allExtendedProtocols[extendedProtcolCount] = (PKExtendedProtocol){
            .protocol = protocol,
            .instanceMethods = NULL,
            .instanceMethodCount = 0,
            .classMethods = NULL,
            .classMethodCount = 0,
        };
        resultIndex = extendedProtcolCount;
        extendedProtcolCount++;
    }
    
    _pk_extension_merge(&(allExtendedProtocols[resultIndex]), containerClass);

    pthread_mutex_unlock(&protocolsLoadingLock);
}
```

上部分只是保持 Protocol 和 对应实现方法的 IMP， 那真正给 Class 注入 默认 IMP 的地方是在哪呢？ 继续看源代码，可以发现一个 由 `__attribute__((constructor))` 标注的方法，可以理解为 +load 方法后， main 方法前执行

 [对应 sunnyxx 的解释](http://blog.sunnyxx.com/2016/05/14/clang-attributes#constructor-destructor)

PS：在试验的时候发现 `__attribute__((constructor(101)))` 优先级控制，在跨文件的时候不起作用

```

__attribute__((constructor)) static void _pk_extension_inject_entry(void) {
    // 防止跟 load 方法冲突
    pthread_mutex_lock(&protocolsLoadingLock);

    unsigned classCount = 0;
    
    //取出所有类
    Class *allClasses = objc_copyClassList(&classCount);
    
    @autoreleasepool {
        for (unsigned protocolIndex = 0; protocolIndex < extendedProtcolCount; ++protocolIndex) {
            PKExtendedProtocol extendedProtcol = allExtendedProtocols[protocolIndex];
            
            // 每个注册的 protocol 的实现，都去遍历下所有类，是否有继承该protocol
            for (unsigned classIndex = 0; classIndex < classCount; ++classIndex) {
                Class class = allClasses[classIndex];
                if (!class_conformsToProtocol(class, extendedProtcol.protocol)) {
                    continue;
                }
                
                // 如果 class 有继承该 protocol， 就把 所有该protocol下的默认实现 IMP ，添加到 该 Class 中， 完成默认方法实现
                // 内部还有判断，如果 class 已经有存在对应 Method IMP， 就不注入，毕竟默认实现优先级低
                _pk_extension_inject_class(class, extendedProtcol);
            }
        }
   } 
   ...
}
```

大致源码就是这样了，可以考虑下 上述实现中，有`哪些问题？`，然后 `如何优化？`

### 主要问题

1. 启动时间变长，在启动时就会把所有 class 的 initialized 执行完，这对启动时间是个损耗
2. Class 的生命周期乱了，因为我们很多的操作，基于 initialized 方法来触发，总体来说 还是对性能有影响
3. 由于生命周期乱了，所以有可能会导致，代码逻辑外的 野指针和死锁，之前 APM 注入 viewDidLoad 方法时，就发生过

硬是写了3点。。。

# 优化方案

那肯定就是懒加载了，等到该类需要的时候在加载。考虑过 hook `initialized`，这个是最完美的方案，但是由于，在 premain 阶段，可能部分 class 已经执行过 initialized 了，所以会造成 注入不了的 IMP 的情况。 于是需要继续寻找其他路径

于是想到了 `runtime` 中的方法调用逻辑，有很多框架在 `forwardInvocation：` 中完成了各种骚操作，那我们是不是也可以利用呢？ 

在试验的过程，发现一个问题：一般在调用协议的时候会先判断 `respondsToSelector：`  是否存在。。。 根本不走 `forwardInvocation:` 逻辑。。 

于是重新从 NSObject.h 头文件 寻找入口，后续看到  `resolveInstanceMethod：`  这个之前好像是用来动态添加方法的，这个时机可以吗？

进行试验吧！

![1.jpeg](https://upload-images.jianshu.io/upload_images/1332613-ca78583ebfdb5889.jpeg?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

![2.jpeg](https://upload-images.jianshu.io/upload_images/1332613-724df2228f02986b.jpeg?imageMogr2/auto-orient/strip%7CimageView2/2/w/1240)

发现  `resolveInstanceMethod:` 完美支持所有调用逻辑 :-D

```
Test:

- (void)testProtocol {
    NSLog(@"class response : %d", [C instancesRespondToSelector:@selector(logB)]);
    NSLog(@"instance response : %d", [[C new] respondsToSelector:@selector(logB)]);
    [[C new] logB];
}

C：

+ (BOOL)resolveInstanceMethod:(SEL)sel {
	 // 执行我们的protocol 注入
    [super resolveInstanceMethod:sel];
    return NO\YES;
}

+ (BOOL)resolveClassMethod:(SEL)sel {
	 // 执行我们的protocol 注入
    [super resolveClassMethod:sel];
    return NO\YES;
}

[2018-09-13 09:18:32.501 - NSObjectTests.m:51]: resolveInstanceMethod:
[2018-09-13 09:18:32.501 - NSObjectTests.m:112]: class response : 1
[2018-09-13 09:18:32.501 - NSObjectTests.m:113]: instance response : 1

不管 resolveInstanceMethod 方法，返回的是 YES、还是 NO， 其实 responseToSelector: 总能正确的返回

如果没有注入这个方法，其实每次调用的时候 都会重新走  resolveInstanceMethod:，有注入后，就不会再回调了

[2018-09-13 09:18:32.501 - NSObjectTests.m:51]: resolveInstanceMethod:
[2018-09-13 09:18:32.501 - NSObjectTests.m:112]: class response : 0
[2018-09-13 09:18:32.501 - NSObjectTests.m:51]: resolveInstanceMethod:
[2018-09-13 09:18:32.501 - NSObjectTests.m:113]: instance response : 0

```

我们的改造后的方案代码:

```

static void _pk_extension_inject_entry_class(Class class) {
    // 所有 Class，只要注入一次即可，但是 resolveInstanceMethod： 会多次调用
    static NSMutableDictionary *injectedClassMap;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        injectedClassMap = [NSMutableDictionary dictionary];
    });
    NSString *className = NSStringFromClass(class);
    if (injectedClassMap[className]) {
        return;
    }
    injectedClassMap[className] = @1;
    
    // 跟之前代码逻辑类似，循环所有注册的protocol
    for (unsigned protocolIndex = 0; protocolIndex < extendedProtcolCount; ++protocolIndex) {
        PKExtendedProtocol extendedProtcol = allExtendedProtocols[protocolIndex];
        if (![class conformsToProtocol:extendedProtcol.protocol]) {
            continue;
        }
        _pk_extension_inject_class(class, extendedProtcol);
    }
}

static void _pk_extension_try_inject_entry_class(Class class) {
    // 防止递归死锁，因为 class_getInstanceMethod(), 会触发 resolveInstanceMethod: 等方法的调用，就会导致递归调用，引起死锁
    // 这边没必要用 递归锁，内部 for 循环，才引起的递归。 代码不用重复执行
    NSMutableDictionary *threadDictionary = [NSThread currentThread].threadDictionary;
    if ([threadDictionary objectForKey:@"IMYProtocolExtension"]) {
        return;
    }
    pthread_mutex_lock(&protocolsLoadingLock);
    [threadDictionary setObject:@1 forKey:@"IMYProtocolExtension"];
    _pk_extension_inject_entry_class(class);
    [threadDictionary removeObjectForKey:@"IMYProtocolExtension"];
    pthread_mutex_unlock(&protocolsLoadingLock);
}

@implementation NSObject (IMYProtocolExtension)

+ (BOOL)_pk_resolveInstanceMethod:(SEL)sel {
    _pk_extension_try_inject_entry_class(self);
    return [self _pk_resolveInstanceMethod:sel];
}

+ (BOOL)_pk_resolveClassMethod:(SEL)sel {
    _pk_extension_try_inject_entry_class(self);
    return [self _pk_resolveClassMethod:sel];
}

@end

// 由 imy_load.m 中进行调用，之前也说 不同文件的 __attribute__((constructor))  优先级没底。
void _pk_extension_inject_entry(void) {
    [NSObject imy_swizzleClassMethod:@selector(resolveInstanceMethod:) withClassMethod:@selector(_pk_resolveInstanceMethod:) error:nil];
    [NSObject imy_swizzleClassMethod:@selector(resolveClassMethod:) withClassMethod:@selector(_pk_resolveClassMethod:) error:nil];
}

imy_load.m：

// protocol inject, after +load，因为要在 run premain 之前执行，所以不在自己文件中写了
extern void _pk_extension_inject_entry(void);
///after +load
__attribute__((constructor)) static void imy_load_premain_entry(void) {
    _pk_extension_inject_entry();
    imy_run_premain();
}

```

优化后的地址： [https://github.com/li6185377/ProtocolKit](https://github.com/li6185377/ProtocolKit)

