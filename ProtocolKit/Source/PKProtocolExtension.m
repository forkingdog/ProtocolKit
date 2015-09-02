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

__attribute__((constructor)) static void _pk_extension_inject_entry(void) {
    
    pthread_mutex_lock(&protocolsLoadingLock);

    unsigned classCount = 0;
    Class *allClasses = objc_copyClassList(&classCount);
    
    @autoreleasepool {
        for (unsigned protocolIndex = 0; protocolIndex < extendedProtcolCount; ++protocolIndex) {
            PKExtendedProtocol extendedProtcol = allExtendedProtocols[protocolIndex];
            for (unsigned classIndex = 0; classIndex < classCount; ++classIndex) {
                Class class = allClasses[classIndex];
                if (!class_conformsToProtocol(class, extendedProtcol.protocol)) {
                    continue;
                }
                _pk_extension_inject_class(class, extendedProtcol);
            }
        }
    }
    pthread_mutex_unlock(&protocolsLoadingLock);
    
    free(allClasses);
    free(allExtendedProtocols);
    extendedProtcolCount = 0, extendedProtcolCapacity = 0;
}
