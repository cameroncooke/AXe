#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <unistd.h>

// These declarations match the selectors measured by the original cadisplays probe.
@interface NSObject (AXeCADisplayRead)
+ (NSArray *)displays;
- (unsigned int)displayId;
- (NSString *)uniqueId;
- (NSString *)currentOrientation;
- (CGRect)bounds;
@end

int main(int argc, char **argv) {
  // One-shot helper. Even if a framework read stalls, the child cannot run indefinitely.
  alarm(3);
  @autoreleasepool {
    if (argc != 2 || ![[NSUUID alloc] initWithUUIDString:@(argv[1])]) return 64;
    dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
    Class displayClass = NSClassFromString(@"CADisplay");
    if (!displayClass || ![displayClass respondsToSelector:@selector(displays)]) return 65;
    NSMutableArray *rows = [NSMutableArray array];
    for (id display in [displayClass displays]) {
      if (![display respondsToSelector:@selector(displayId)] ||
          ![display respondsToSelector:@selector(uniqueId)] ||
          ![display respondsToSelector:@selector(currentOrientation)] ||
          ![display respondsToSelector:@selector(bounds)]) return 66;
      NSString *uniqueID = [display uniqueId];
      NSString *rotation = [display currentOrientation];
      CGRect bounds = [display bounds];
      if (!uniqueID || !rotation) return 67;
      [rows addObject:@{@"displayId": @([display displayId]), @"uniqueId": uniqueID,
        @"currentOrientation": rotation, @"bounds": @{@"x": @(bounds.origin.x),
        @"y": @(bounds.origin.y), @"width": @(bounds.size.width), @"height": @(bounds.size.height)}}];
    }
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"schemaVersion": @1,
      @"requestID": @(argv[1]), @"processIdentifier": @(getpid()), @"displays": rows}
      options: NSJSONWritingSortedKeys error:&error];
    if (!data || data.length > 65536) return 68;
    if (fwrite(data.bytes, 1, data.length, stdout) != data.length || fflush(stdout) != 0) return 69;
    return 0;
  }
}
