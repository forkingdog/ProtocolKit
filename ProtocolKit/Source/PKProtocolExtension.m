// The MIT License (MIT)
//
// Copyright (c) 2015-2016 forkingdog ( https://github.com/forkingdog )
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#import <Foundation/Foundation.h>
#import "PKProtocolExtension.h"
#import <pthread.h>

typedef struct {
    Protocol *__unsafe_unretained protocol;
    Method *instanceMethods;
    unsigned instanceMethodCount;
    Method *classMethods;
    unsigned classMethodCount;
} PKExtendedProtocol;

static PKExtendedProtocol *allExtendedProtocols = NULL;
static pthread_mutex_t protocolsLoadingLock = PTHREAD_MUTEX_INITIALIZER;
static size_t extendedProtcolCount = 0, extendedProtcolCapacity = 0;

Method *_pk_extension_create_merged(Method *existMethods, unsigned existMethodCount, Method *appendingMethods, unsigned appendingMethodCount) {
    
    if (existMethodCount == 0) {
        return appendingMethods;
    }
    unsigned mergedMethodCount = existMethodCount + appendingMethodCount;
    Method *mergedMethods = malloc(mergedMethodCount * sizeof(Method));
    memcpy(mergedMethods, existMethods, existMethodCount * sizeof(Method));
    memcpy(mergedMethods + existMethodCount, appendingMethods, appendingMethodCount * sizeof(Method));
    return mergedMethods;
}

void _pk_extension_merge(PKExtendedProtocol *extendedProtocol, Class containerClass) {
    
    // Instance methods
    unsigned appendingInstanceMethodCount = 0;
    Method *appendingInstanceMethods = class_copyMethodList(containerClass, &appendingInstanceMethodCount);
    Method *mergedInstanceMethods = _pk_extension_create_merged(extendedProtocol->instanceMethods,
                                                                extendedProtocol->instanceMethodCount,
                                                                appendingInstanceMethods,
                                                                appendingInstanceMethodCount);
    free(extendedProtocol->instanceMethods);
    extendedProtocol->instanceMethods = mergedInstanceMethods;
    extendedProtocol->instanceMethodCount += appendingInstanceMethodCount;
    
    // Class methods
    unsigned appendingClassMethodCount = 0;
    Method *appendingClassMethods = class_copyMethodList(object_getClass(containerClass), &appendingClassMethodCount);
    Method *mergedClassMethods = _pk_extension_create_merged(extendedProtocol->classMethods,
                                                             extendedProtocol->classMethodCount,
                                                             appendingClassMethods,
                                                             appendingClassMethodCount);
    free(extendedProtocol->classMethods);
    extendedProtocol->classMethods = mergedClassMethods;
    extendedProtocol->classMethodCount += appendingClassMethodCount;
}

void _pk_extension_load(Protocol *protocol, Class containerClass) {
    
    pthread_mutex_lock(&protocolsLoadingLock);
    
    if (extendedProtcolCount >= extendedProtcolCapacity) {
        size_t newCapacity = 0;
        if (extendedProtcolCapacity == 0) {
            newCapacity = 1;
        } else {
            newCapacity = extendedProtcolCapacity << 1;
        }
        allExtendedProtocols = realloc(allExtendedProtocols, sizeof(*allExtendedProtocols) * newCapacity);
        extendedProtcolCapacity = newCapacity;
    }
    
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

static void _pk_extension_inject_class(Class targetClass, PKExtendedProtocol extendedProtocol) {
    
    for (unsigned methodIndex = 0; methodIndex < extendedProtocol.instanceMethodCount; ++methodIndex) {
        Method method = extendedProtocol.instanceMethods[methodIndex];
        SEL selector = method_getName(method);
        
        if (class_getInstanceMethod(targetClass, selector)) {
            continue;
        }
        
        IMP imp = method_getImplementation(method);
        const char *types = method_getTypeEncoding(method);
        class_addMethod(targetClass, selector, imp, types);
    }
    
    Class targetMetaClass = object_getClass(targetClass);
    for (unsigned methodIndex = 0; methodIndex < extendedProtocol.classMethodCount; ++methodIndex) {
        Method method = extendedProtocol.classMethods[methodIndex];
        SEL selector = method_getName(method);
        
        if (selector == @selector(load) || selector == @selector(initialize)) {
            continue;
        }
        if (class_getInstanceMethod(targetMetaClass, selector)) {
            continue;
        }
        
        IMP imp = method_getImplementation(method);
        const char *types = method_getTypeEncoding(method);
        class_addMethod(targetMetaClass, selector, imp, types);
    }
}

static void _pk_extension_inject_entry_class(Class class) {
    static NSMutableDictionary *injectedClassMap;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        injectedClassMap = [NSMutableDictionary dictionary];
    });
    NSString *className = NSStringFromClass(class);
    // 所有 Class，只要注入一次即可，但是 resolveInstanceMethod： 会多次调用
    if (injectedClassMap[className]) {
        return;
    }
    injectedClassMap[className] = @1;
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
    if ([threadDictionary objectForKey:@"_pk_injecting"]) {
        return;
    }
    pthread_mutex_lock(&protocolsLoadingLock);
    [threadDictionary setObject:@1 forKey:@"_pk_injecting"];
    _pk_extension_inject_entry_class(class);
    [threadDictionary removeObjectForKey:@"_pk_injecting"];
    pthread_mutex_unlock(&protocolsLoadingLock);
}

static BOOL _pk_swizzleMethod(Class class, SEL origSel_, SEL altSel_) {
    Method origMethod = class_getInstanceMethod(class, origSel_);
    if (!origMethod) {
        return NO;
    }
    Method altMethod = class_getInstanceMethod(class, altSel_);
    if (!altMethod) {
        return NO;
    }

    class_addMethod(class,
                    origSel_,
                    class_getMethodImplementation(class, origSel_),
                    method_getTypeEncoding(origMethod));
    class_addMethod(class,
                    altSel_,
                    class_getMethodImplementation(class, altSel_),
                    method_getTypeEncoding(altMethod));

    method_exchangeImplementations(class_getInstanceMethod(class, origSel_), class_getInstanceMethod(class, altSel_));

    return YES;
}

@implementation NSObject (PKExtendedProtocol)

+ (BOOL)_pk_resolveInstanceMethod:(SEL)sel {
    _pk_extension_try_inject_entry_class(self);
    return [self _pk_resolveInstanceMethod:sel];
}

+ (BOOL)_pk_resolveClassMethod:(SEL)sel {
    _pk_extension_try_inject_entry_class(self);
    return [self _pk_resolveClassMethod:sel];
}

@end

__attribute__((constructor)) static void _pk_extension_inject_entry(void) {
    _pk_swizzleMethod(object_getClass([NSObject class]), @selector(resolveInstanceMethod:), @selector(_pk_resolveInstanceMethod:));
    _pk_swizzleMethod(object_getClass([NSObject class]), @selector(resolveClassMethod:), @selector(_pk_resolveClassMethod:));
}
