#import <UIKit/UIKit.h>
#import <unistd.h>

@interface WaitObservingWindow : UIWindow
@property (copy) void (^observeTouch)(UITouch *, UIWindow *);
@end

@implementation WaitObservingWindow
- (void)sendEvent:(UIEvent *)event {
    [super sendEvent:event];
    if (event.type != UIEventTypeTouches) return;
    for (UITouch *touch in event.allTouches) {
        if (touch.window == self && touch.phase != UITouchPhaseStationary && self.observeTouch) {
            self.observeTouch(touch, self);
        }
    }
}
@end

@interface WaitProbeController : UIViewController
@property (nonatomic, strong) UILabel *summary;
@property (nonatomic, strong) UIButton *target;
@property (nonatomic, strong) UIButton *duplicate;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *counts;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIView *> *controls;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *trace;
@property (nonatomic, strong) NSMapTable<UITouch *, NSNumber *> *contacts;
@property (nonatomic, strong) NSTimer *timer;
@property NSUInteger nextContactID;
@property NSUInteger traceDropped;
@property NSUInteger activeTouches;
@property NSUInteger sequence;
@property NSUInteger generation;
@property NSTimeInterval scheduledDelay;
@property NSTimeInterval appearedUptime;
@property BOOL publishPending;
@property CGSize lastSize;
@property UIInterfaceOrientation lastOrientation;
@end

@implementation WaitProbeController
- (UIButton *)button:(NSString *)title identifier:(NSString *)identifier action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.accessibilityIdentifier = identifier;
    button.backgroundColor = UIColor.secondarySystemBackgroundColor;
    button.layer.cornerRadius = 6;
    [button.heightAnchor constraintEqualToConstant:38].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    self.controls[identifier] = button;
    return button;
}

- (void)addRow:(NSArray<UIView *> *)views to:(UIStackView *)stack {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:views];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8;
    row.distribution = UIStackViewDistributionFillEqually;
    [stack addArrangedSubview:row];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.counts = [NSMutableDictionary new];
    self.controls = [NSMutableDictionary new];
    self.trace = [NSMutableArray new];
    self.contacts = [NSMapTable weakToStrongObjectsMapTable];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8]
    ]];
    self.summary = [UILabel new];
    self.summary.numberOfLines = 3;
    self.summary.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.summary.accessibilityIdentifier = @"wait.state";
    [self.summary.heightAnchor constraintEqualToConstant:52].active = YES;
    [stack addArrangedSubview:self.summary];
    [self addRow:@[[self button:@"Start 3 seconds" identifier:@"wait.start3" action:@selector(startThree)],
                  [self button:@"Start 8 seconds" identifier:@"wait.start8" action:@selector(startEight)]] to:stack];
    [self addRow:@[[self button:@"Hide target" identifier:@"wait.hide" action:@selector(hide)],
                  [self button:@"Show target" identifier:@"wait.show" action:@selector(show)]] to:stack];
    [self addRow:@[[self button:@"Toggle duplicate" identifier:@"wait.duplicateControl" action:@selector(toggleDuplicate)],
                  [self button:@"Fresh button" identifier:@"wait.fresh" action:@selector(fresh)]] to:stack];
    self.target = [self button:@"Delayed target" identifier:@"wait.target" action:@selector(targetTapped)];
    self.target.accessibilityLabel = @"Delayed target";
    self.target.accessibilityValue = @"ready";
    self.target.hidden = YES;
    [self addRow:@[self.target, [self button:@"Sentinel button" identifier:@"wait.sentinel" action:@selector(sentinel)]] to:stack];
    self.duplicate = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.duplicate setTitle:@"Delayed target" forState:UIControlStateNormal];
    self.duplicate.accessibilityIdentifier = @"wait.target";
    self.duplicate.accessibilityLabel = @"Delayed target";
    self.duplicate.accessibilityValue = @"ready";
    self.duplicate.backgroundColor = UIColor.secondarySystemBackgroundColor;
    [self.duplicate.heightAnchor constraintEqualToConstant:38].active = YES;
    [self.duplicate addTarget:self action:@selector(duplicateTapped) forControlEvents:UIControlEventTouchUpInside];
    self.duplicate.hidden = YES;
    [stack addArrangedSubview:self.duplicate];
    [self publishLater];
}

- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = self.view.bounds.size;
    UIInterfaceOrientation orientation = self.view.window.windowScene.interfaceOrientation;
    if (!CGSizeEqualToSize(size, self.lastSize) || orientation != self.lastOrientation) {
        self.lastSize = size;
        self.lastOrientation = orientation;
        [self publishLater];
    }
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [self publishLater]; }
- (void)increment:(NSString *)name { self.counts[name] = @([self.counts[name] unsignedIntegerValue] + 1); }

- (void)cancelSchedule {
    [self.timer invalidate];
    self.timer = nil;
    self.generation++;
}

- (void)start:(NSTimeInterval)seconds counter:(NSString *)counter {
    [self cancelSchedule];
    [self increment:counter];
    self.target.hidden = YES;
    self.duplicate.hidden = YES;
    self.scheduledDelay = seconds;
    self.appearedUptime = 0;
    NSUInteger generation = self.generation;
    __weak WaitProbeController *weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:seconds repeats:NO block:^(NSTimer *timer) {
        WaitProbeController *owner = weakSelf;
        if (!owner || owner.generation != generation) return;
        owner.timer = nil;
        owner.target.hidden = NO;
        owner.appearedUptime = NSProcessInfo.processInfo.systemUptime;
        [owner increment:@"appeared"];
        [owner publishLater];
    }];
    [self publishLater];
}

- (void)startThree { [self start:3 counter:@"start3"]; }
- (void)startEight { [self start:8 counter:@"start8"]; }
- (void)hide {
    [self cancelSchedule];
    [self increment:@"hide"];
    self.target.hidden = YES;
    self.duplicate.hidden = YES;
    self.scheduledDelay = 0;
    self.appearedUptime = 0;
    [self publishLater];
}
- (void)show {
    [self cancelSchedule];
    [self increment:@"show"];
    self.target.hidden = NO;
    self.appearedUptime = NSProcessInfo.processInfo.systemUptime;
    [self publishLater];
}
- (void)toggleDuplicate {
    [self increment:@"duplicateControl"];
    self.duplicate.hidden = !self.duplicate.hidden;
    [self publishLater];
}
- (void)targetTapped { [self increment:@"target"]; [self publishLater]; }
- (void)duplicateTapped { [self increment:@"duplicateTarget"]; [self publishLater]; }
- (void)sentinel { [self increment:@"sentinel"]; [self publishLater]; }
- (void)fresh { [self increment:@"fresh"]; [self publishLater]; }

- (void)observeTouch:(UITouch *)touch window:(UIWindow *)window {
    NSString *phase;
    switch (touch.phase) {
        case UITouchPhaseBegan: phase = @"began"; break;
        case UITouchPhaseMoved: phase = @"moved"; break;
        case UITouchPhaseEnded: phase = @"ended"; break;
        case UITouchPhaseCancelled: phase = @"cancelled"; break;
        default: return;
    }
    if (touch.phase == UITouchPhaseBegan) {
        [self.contacts setObject:@(++self.nextContactID) forKey:touch];
        self.activeTouches++;
    }
    NSNumber *contactID = [self.contacts objectForKey:touch] ?: @0;
    if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
        self.activeTouches = self.activeTouches > 0 ? self.activeTouches - 1 : 0;
    }
    UIView *hit = touch.view;
    while (hit && !hit.accessibilityIdentifier) hit = hit.superview;
    CGPoint point = [touch locationInView:window];
    [self.trace addObject:@{@"contactID":contactID, @"phase":phase, @"x":@(point.x), @"y":@(point.y),
                           @"guestUptime":@(touch.timestamp), @"activeTouches":@(self.activeTouches),
                           @"hitView":hit.accessibilityIdentifier ?: @"(none)"}];
    if (self.trace.count > 4096) { [self.trace removeObjectAtIndex:0]; self.traceDropped++; }
    [self increment:phase];
    if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) [self.contacts removeObjectForKey:touch];
    [self publishLater];
}

- (void)publishLater {
    if (self.publishPending) return;
    self.publishPending = YES;
    // The queued publisher runs after normal UIKit dispatch and layout callbacks.
    dispatch_async(dispatch_get_main_queue(), ^{
        self.publishPending = NO;
        [self publish];
    });
}

- (void)publish {
    if (!self.isViewLoaded || !self.view.window) return;
    [self.view layoutIfNeeded];
    self.sequence++;
    NSString *phase = self.timer ? @"waiting" : (self.target.hidden ? @"hidden" : @"visible");
    self.summary.text = [NSString stringWithFormat:@"Tap wait probe 1: %@\ntarget %@  sentinel %@  fresh %@\ncontacts %lu  records %lu",
        phase, self.counts[@"target"] ?: @0, self.counts[@"sentinel"] ?: @0, self.counts[@"fresh"] ?: @0,
        (unsigned long)self.activeTouches, (unsigned long)self.trace.count];
    self.summary.accessibilityLabel = self.summary.text;
    NSMutableDictionary *geometry = [NSMutableDictionary new];
    for (NSString *name in self.controls) {
        UIView *view = self.controls[name];
        CGRect frame = [view convertRect:view.bounds toView:self.view.window];
        geometry[name] = @{@"x":@(frame.origin.x), @"y":@(frame.origin.y), @"width":@(frame.size.width),
                           @"height":@(frame.size.height), @"hidden":@(view.hidden), @"inWindow":@(view.window != nil)};
    }
    CGSize size = self.view.window.bounds.size;
    NSDictionary *state = @{@"fixtureVersion":@1, @"bundleIdentifier":NSBundle.mainBundle.bundleIdentifier ?: @"",
        @"pid":@(getpid()), @"sequence":@(self.sequence), @"phase":phase, @"targetVisible":@(!self.target.hidden),
        @"duplicateVisible":@(!self.duplicate.hidden), @"scheduledDelaySeconds":@(self.scheduledDelay),
        @"scheduleGeneration":@(self.generation), @"targetAppearedGuestUptime":@(self.appearedUptime),
        @"publishedGuestUptime":@(NSProcessInfo.processInfo.systemUptime), @"counts":[self.counts copy],
        @"geometry":geometry, @"width":@(size.width), @"height":@(size.height),
        @"interfaceOrientation":@(self.view.window.windowScene.interfaceOrientation),
        @"activeWindowTouches":@(self.activeTouches), @"windowTouchTrace":[self.trace copy],
        @"windowTraceLimit":@4096, @"windowTraceDropped":@(self.traceDropped)};
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    if (!data || ![data writeToURL:[documents URLByAppendingPathComponent:@"state.json"] options:NSDataWritingAtomic error:&error]) {
        NSLog(@"Tap wait state publication failed: %@", error);
    }
}
@end

@interface WaitSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation WaitSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    WaitProbeController *controller = [WaitProbeController new];
    WaitObservingWindow *window = [[WaitObservingWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    __weak WaitProbeController *weakController = controller;
    window.observeTouch = ^(UITouch *touch, UIWindow *owner) { [weakController observeTouch:touch window:owner]; };
    self.window = window;
    window.rootViewController = controller;
    [window makeKeyAndVisible];
}
@end
@interface WaitAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation WaitAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options { return YES; }
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(WaitAppDelegate.class)); }
}
