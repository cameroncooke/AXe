#import <UIKit/UIKit.h>
#import <unistd.h>

static const NSUInteger SliderCallbackLimit = 1024;
static const NSUInteger SliderTouchLimit = 4096;

@interface SliderObservingWindow : UIWindow
@property (copy) void (^observeTouch)(UITouch *, UIWindow *);
@end

@implementation SliderObservingWindow
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

@interface SliderProbeController : UIViewController
@property (nonatomic, strong) UILabel *summary;
@property (nonatomic, strong) UILabel *unitState;
@property (nonatomic, strong) UILabel *shiftedState;
@property (nonatomic, strong) UILabel *duplicateState;
@property (nonatomic, strong) UISlider *unitSlider;
@property (nonatomic, strong) UISlider *shiftedSlider;
@property (nonatomic, strong) UISlider *duplicateSlider;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *counts;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIView *> *controls;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *callbackTrace;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *touchTrace;
@property (nonatomic, strong) NSMapTable<UITouch *, NSNumber *> *contacts;
@property (nonatomic, strong) NSTimer *samplingTimer;
@property NSUInteger sequence;
@property NSUInteger callbackSequence;
@property NSUInteger callbacksDropped;
@property NSUInteger touchesDropped;
@property NSUInteger nextContactID;
@property NSUInteger unmatchedTouchEvents;
@property BOOL publishPending;
@property CGSize lastSize;
@property UIInterfaceOrientation lastOrientation;
@end

@implementation SliderProbeController
- (UILabel *)label:(NSString *)identifier {
    UILabel *label = [UILabel new];
    label.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    label.accessibilityIdentifier = identifier;
    NSLayoutConstraint *height = [label.heightAnchor constraintEqualToConstant:18];
    height.priority = 999;
    height.active = YES;
    self.controls[identifier] = label;
    return label;
}

- (UIButton *)button:(NSString *)title identifier:(NSString *)identifier action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.accessibilityIdentifier = identifier;
    button.backgroundColor = UIColor.secondarySystemBackgroundColor;
    button.layer.cornerRadius = 6;
    button.titleLabel.font = [UIFont systemFontOfSize:13];
    [button.heightAnchor constraintEqualToConstant:34].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    self.controls[identifier] = button;
    return button;
}

- (UISlider *)slider:(NSString *)identifier label:(NSString *)label minimum:(float)minimum
            maximum:(float)maximum initial:(float)initial key:(NSString *)key {
    UISlider *slider = [UISlider new];
    slider.minimumValue = minimum;
    slider.maximumValue = maximum;
    slider.value = initial;
    slider.accessibilityIdentifier = identifier;
    slider.accessibilityLabel = label;
    NSLayoutConstraint *height = [slider.heightAnchor constraintEqualToConstant:28];
    height.priority = 999;
    height.active = YES;
    [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    self.controls[key] = slider;
    return slider;
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
    self.callbackTrace = [NSMutableArray new];
    self.touchTrace = [NSMutableArray new];
    self.contacts = [NSMapTable weakToStrongObjectsMapTable];

    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 4;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8]
    ]];
    self.summary = [self label:@"slider.state"];
    self.summary.numberOfLines = 1;
    [stack addArrangedSubview:self.summary];

    self.unitState = [self label:@"slider.unitState"];
    [stack addArrangedSubview:self.unitState];
    self.unitSlider = [self slider:@"slider.unit" label:@"Unit range slider" minimum:0
                          maximum:1 initial:0.25 key:@"unit"];
    [stack addArrangedSubview:self.unitSlider];

    self.shiftedState = [self label:@"slider.shiftedState"];
    [stack addArrangedSubview:self.shiftedState];
    self.shiftedSlider = [self slider:@"slider.shifted" label:@"Shifted range slider" minimum:-20
                             maximum:80 initial:5 key:@"shifted"];
    [stack addArrangedSubview:self.shiftedSlider];

    [self addRow:@[[self button:@"Toggle duplicate" identifier:@"slider.duplicateControl" action:@selector(toggleDuplicate)],
                  [self button:@"Wrong role target" identifier:@"slider.wrongRole" action:@selector(wrongRole)]] to:stack];
    [self addRow:@[[self button:@"Fresh button" identifier:@"slider.fresh" action:@selector(fresh)],
                  [self button:@"Sentinel button" identifier:@"slider.sentinel" action:@selector(sentinel)]] to:stack];

    self.duplicateState = [self label:@"slider.duplicateState"];
    self.duplicateState.hidden = YES;
    [stack addArrangedSubview:self.duplicateState];
    self.duplicateSlider = [self slider:@"slider.unit" label:@"Unit range slider" minimum:0
                               maximum:1 initial:0.25 key:@"duplicate"];
    self.duplicateSlider.hidden = YES;
    [stack addArrangedSubview:self.duplicateSlider];
    [self publishLater];
}

- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.samplingTimer) {
        __weak SliderProbeController *weakSelf = self;
        self.samplingTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
            [weakSelf publishLater];
        }];
    }
    [self publishLater];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.samplingTimer invalidate];
    self.samplingTimer = nil;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = self.view.bounds.size;
    UIInterfaceOrientation orientation = self.view.window.windowScene.interfaceOrientation;
    if (CGSizeEqualToSize(size, self.lastSize) && orientation == self.lastOrientation) return;
    self.lastSize = size;
    self.lastOrientation = orientation;
    [self publishLater];
}

- (void)increment:(NSString *)name {
    self.counts[name] = @([self.counts[name] unsignedIntegerValue] + 1);
}

- (NSString *)keyForControl:(UIView *)view {
    for (NSString *key in self.controls) {
        if (self.controls[key] == view) return key;
    }
    return @"(none)";
}

- (void)sliderChanged:(UISlider *)slider {
    NSString *key = [self keyForControl:slider];
    [self increment:[key stringByAppendingString:@"Changed"]];
    [self.callbackTrace addObject:@{
        @"sequence":@(++self.callbackSequence), @"control":key,
        @"identifier":slider.accessibilityIdentifier ?: @"",
        @"minimum":@(slider.minimumValue), @"maximum":@(slider.maximumValue), @"value":@(slider.value),
        @"guestUptime":@(NSProcessInfo.processInfo.systemUptime)
    }];
    if (self.callbackTrace.count > SliderCallbackLimit) {
        [self.callbackTrace removeObjectAtIndex:0];
        self.callbacksDropped++;
    }
    [self publishLater];
}

- (void)toggleDuplicate {
    [self increment:@"duplicateControl"];
    BOOL hidden = !self.duplicateSlider.hidden;
    self.duplicateSlider.hidden = hidden;
    self.duplicateState.hidden = hidden;
    [self publishLater];
}
- (void)wrongRole { [self increment:@"wrongRole"]; [self publishLater]; }
- (void)fresh { [self increment:@"fresh"]; [self publishLater]; }
- (void)sentinel { [self increment:@"sentinel"]; [self publishLater]; }

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
        if ([self.contacts objectForKey:touch]) self.unmatchedTouchEvents++;
        [self.contacts setObject:@(++self.nextContactID) forKey:touch];
    }
    NSNumber *contactID = [self.contacts objectForKey:touch];
    if (!contactID) self.unmatchedTouchEvents++;
    if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
        [self.contacts removeObjectForKey:touch];
    }
    UIView *hit = touch.view;
    while (hit && !hit.accessibilityIdentifier) hit = hit.superview;
    CGPoint point = [touch locationInView:window];
    [self.touchTrace addObject:@{
        @"contactID":contactID ?: @0, @"phase":phase, @"x":@(point.x), @"y":@(point.y),
        @"guestUptime":@(touch.timestamp), @"activeTouches":@(self.contacts.count),
        @"hitView":hit.accessibilityIdentifier ?: @"(none)", @"control":[self keyForControl:hit]
    }];
    if (self.touchTrace.count > SliderTouchLimit) {
        [self.touchTrace removeObjectAtIndex:0];
        self.touchesDropped++;
    }
    [self increment:phase];
    [self publishLater];
}

- (NSDictionary *)stateForSlider:(UISlider *)slider {
    return @{
        @"identifier":slider.accessibilityIdentifier ?: @"", @"label":slider.accessibilityLabel ?: @"",
        @"minimum":@(slider.minimumValue), @"maximum":@(slider.maximumValue), @"value":@(slider.value),
        @"enabled":@(slider.enabled), @"hidden":@(slider.hidden), @"tracking":@(slider.tracking)
    };
}

- (void)publishLater {
    if (self.publishPending) return;
    self.publishPending = YES;
    // Publish after normal UIKit event dispatch and layout callbacks return.
    dispatch_async(dispatch_get_main_queue(), ^{
        self.publishPending = NO;
        [self publish];
    });
}

- (void)publish {
    if (!self.isViewLoaded || !self.view.window) return;
    self.sequence++;
    self.summary.text = [NSString stringWithFormat:@"Slider probe 1  callbacks %lu  contacts %lu",
        (unsigned long)self.callbackSequence, (unsigned long)self.contacts.count];
    self.unitState.text = [NSString stringWithFormat:@"Unit value: %.9g  range: 0...1", self.unitSlider.value];
    self.shiftedState.text = [NSString stringWithFormat:@"Shifted value: %.9g  range: -20...80", self.shiftedSlider.value];
    self.duplicateState.text = [NSString stringWithFormat:@"Duplicate value: %.9g  range: 0...1", self.duplicateSlider.value];
    for (UILabel *label in @[self.summary, self.unitState, self.shiftedState, self.duplicateState]) {
        label.accessibilityLabel = label.text;
    }
    [self.view layoutIfNeeded];
    NSMutableDictionary *geometry = [NSMutableDictionary new];
    for (NSString *key in self.controls) {
        UIView *view = self.controls[key];
        CGRect frame = [view convertRect:view.bounds toView:self.view.window];
        geometry[key] = @{
            @"identifier":view.accessibilityIdentifier ?: @"", @"class":NSStringFromClass(view.class),
            @"x":@(frame.origin.x), @"y":@(frame.origin.y), @"width":@(frame.size.width), @"height":@(frame.size.height),
            @"hidden":@(view.hidden), @"inWindow":@(view.window != nil), @"ambiguousLayout":@(view.hasAmbiguousLayout)
        };
    }
    CGSize size = self.view.window.bounds.size;
    NSDictionary *state = @{
        @"fixtureVersion":@1, @"bundleIdentifier":NSBundle.mainBundle.bundleIdentifier ?: @"",
        @"pid":@(getpid()), @"sequence":@(self.sequence), @"publishedGuestUptime":@(NSProcessInfo.processInfo.systemUptime),
        @"counts":[self.counts copy], @"sliders":@{
            @"unit":[self stateForSlider:self.unitSlider], @"shifted":[self stateForSlider:self.shiftedSlider],
            @"duplicate":[self stateForSlider:self.duplicateSlider]
        }, @"duplicateVisible":@(!self.duplicateSlider.hidden),
        @"callbackSequence":@(self.callbackSequence), @"sliderCallbackTrace":[self.callbackTrace copy],
        @"sliderCallbackLimit":@(SliderCallbackLimit), @"sliderCallbacksDropped":@(self.callbacksDropped),
        @"geometry":geometry, @"width":@(size.width), @"height":@(size.height),
        @"interfaceOrientation":@(self.view.window.windowScene.interfaceOrientation),
        @"activeWindowTouches":@(self.contacts.count), @"windowTouchTrace":[self.touchTrace copy],
        @"windowTraceLimit":@(SliderTouchLimit), @"windowTraceDropped":@(self.touchesDropped),
        @"unmatchedTouchEvents":@(self.unmatchedTouchEvents)
    };
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    if (!data || ![data writeToURL:[documents URLByAppendingPathComponent:@"state.json"] options:NSDataWritingAtomic error:&error]) {
        NSLog(@"Slider state publication failed: %@", error);
    }
}
@end

@interface SliderSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SliderSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    SliderProbeController *controller = [SliderProbeController new];
    SliderObservingWindow *window = [[SliderObservingWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    __weak SliderProbeController *weakController = controller;
    window.observeTouch = ^(UITouch *touch, UIWindow *owner) { [weakController observeTouch:touch window:owner]; };
    self.window = window;
    window.rootViewController = controller;
    [window makeKeyAndVisible];
}
@end

@interface SliderAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation SliderAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options { return YES; }
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(SliderAppDelegate.class)); }
}
