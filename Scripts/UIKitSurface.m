#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL relevant(NSString *name) {
    NSString *n = name.lowercaseString;
    for (NSString *s in @[@"background", @"backdrop", @"tint", @"host", @"remote", @"chrome", @"clip", @"appearance", @"dictation", @"globe", @"compatib", @"inputmode", @"extension", @"content", @"bounds", @"geometry"]) {
        if ([n containsString:s]) return YES;
    }
    return NO;
}

static NSArray *methods(Class cls, BOOL all) {
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    NSMutableArray *result = [NSMutableArray new];
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(list[i]));
        if (all || relevant(name)) [result addObject:@{@"name":name, @"type":@(method_getTypeEncoding(list[i]))}];
    }
    free(list);
    return result;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSMutableDictionary *classes = [NSMutableDictionary new];
        unsigned int count = 0;
        Class *list = objc_copyClassList(&count);
        for (unsigned int i = 0; i < count; i++) {
            Class cls = list[i];
            NSString *name = NSStringFromClass(cls);
            NSString *n = name.lowercaseString;
            BOOL focus = [n containsString:@"inputviewcontroller"] || [n containsString:@"keyboardextension"] ||
                [name isEqualToString:@"UIInputView"] || [n containsString:@"remotekeyboard"] ||
                [n containsString:@"keyboardplaceholder"] || [n containsString:@"viewcontrolleroperator"];
            BOOL broad = [n hasPrefix:@"ui"] || [n hasPrefix:@"_ui"] || [n hasPrefix:@"tui"];
            if (!focus && !(broad && ([n containsString:@"keyboard"] || [n containsString:@"inputview"]))) continue;
            NSArray *instance = methods(cls, focus), *statics = methods(object_getClass(cls), focus);
            if (instance.count || statics.count) classes[name] = @{@"superclass":NSStringFromClass(class_getSuperclass(cls)) ?: @"", @"instance":instance, @"class":statics};
        }
        free(list);
        NSMutableDictionary *protocols = [NSMutableDictionary new];
        Protocol *__unsafe_unretained *plist = objc_copyProtocolList(&count);
        for (unsigned int i = 0; i < count; i++) {
            Protocol *p = plist[i];
            NSString *name = @(protocol_getName(p)), *n = name.lowercaseString;
            if (![n containsString:@"inputview"] && ![n containsString:@"remoteview"] && ![n containsString:@"ivc"] && ![n containsString:@"keyboardextension"]) continue;
            NSMutableArray *entries = [NSMutableArray new];
            for (int required = 0; required < 2; required++) {
                unsigned int mc = 0;
                struct objc_method_description *ml = protocol_copyMethodDescriptionList(p, required, YES, &mc);
                for (unsigned int j = 0; j < mc; j++) [entries addObject:@{@"name":NSStringFromSelector(ml[j].name), @"type":ml[j].types ? @(ml[j].types) : @"", @"required":@(required)}];
                free(ml);
            }
            protocols[name] = entries;
        }
        free(plist);
        NSDictionary *report = @{@"os":NSProcessInfo.processInfo.operatingSystemVersionString, @"classes":classes, @"protocols":protocols, @"metadataOnly":@YES};
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
        if (!data) { fprintf(stderr, "%s\n", error.description.UTF8String); return 1; }
        fwrite(data.bytes, 1, data.length, stdout);
        putchar('\n');
    }
    return 0;
}
