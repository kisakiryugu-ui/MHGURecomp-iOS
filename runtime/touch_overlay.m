// MHGURecomp iOS touchscreen controls: custom pass-through UIKit overlay.
// iOS 15+, Objective-C (manual retain/release, matching the project Makefile).
// Input goes directly into host_input_update; no virtual SDL controller required.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <GameController/GameController.h>
#import <SDL3/SDL.h>
#import <SDL3/SDL_video.h>
#include <math.h>
#include <stdatomic.h>
#include "touch_overlay.h"
#include "hle/input.h"
#include <dispatch/dispatch.h>

// Queued item/ammo steps are emitted over separate input frames.
static atomic_int s_itemSteps, s_ammoSteps;
static atomic_uint_fast64_t s_stepDueMs;
static uint64_t s_lastWeaponPollMs;
static void queue_steps(BOOL ammo, int steps) {
    atomic_int *dst = ammo ? &s_ammoSteps : &s_itemSteps;
    int old = atomic_load(dst), next = MAX(-6, MIN(6, old + steps));
    atomic_store(dst, next);
}


static atomic_uint_fast64_t s_buttons;
static atomic_int s_buttonRefs[16];
static atomic_uint_fast64_t s_pulseUntilMs[16];
static atomic_int s_lx, s_ly, s_rx, s_ry;
static atomic_int s_swipeRx, s_swipeRy;
static atomic_uint_fast64_t s_lastSwipeMs, s_centerCameraUntilMs;
static atomic_bool s_iosForeground = ATOMIC_VAR_INIT(1);
int mhgu_ios_is_foreground(void) {
    return atomic_load_explicit(&s_iosForeground, memory_order_acquire) ? 1 : 0;
}

static uint64_t mhgu_now_ms(void) {
    return (uint64_t)(CACurrentMediaTime() * 1000.0);
}
// Reference-counted masks keep L/Y/A held correctly if a user presses a combo
// and an ordinary button at the same time. All UIKit presses occur on main.
static void pulse_button_mask(uint64_t mask, uint64_t duration_ms) {
    uint64_t until = mhgu_now_ms() + duration_ms;
    for (unsigned bit = 0; bit < 16; bit++)
        if (mask & (UINT64_C(1) << bit))
            atomic_store_explicit(&s_pulseUntilMs[bit], until, memory_order_relaxed);
}
static void set_button_mask(uint64_t mask, BOOL pressed) {
    for (unsigned bit = 0; bit < 16; bit++) {
        uint64_t flag = UINT64_C(1) << bit;
        if (!(mask & flag)) continue;
        if (pressed) {
            int before = atomic_fetch_add_explicit(&s_buttonRefs[bit], 1, memory_order_relaxed);
            if (before == 0) atomic_fetch_or_explicit(&s_buttons, flag, memory_order_relaxed);
        } else {
            int before = atomic_fetch_sub_explicit(&s_buttonRefs[bit], 1, memory_order_relaxed);
            if (before <= 1) {
                atomic_store_explicit(&s_buttonRefs[bit], 0, memory_order_relaxed);
                atomic_fetch_and_explicit(&s_buttons, ~flag, memory_order_relaxed);
            }
        }
    }
}

@class MHGUTouchRoot;
static MHGUTouchRoot *s_overlay;
static void poll_overlay_weapon(void);

void mhgu_touch_snapshot(uint64_t *buttons, int *lx, int *ly, int *rx, int *ry) {
    uint64_t now = mhgu_now_ms();
    // SDL host_input_update is run by the app's main thread.
    // Avoid UIKit operations on a possible non-main caller.
    if ([NSThread isMainThread] && s_overlay) poll_overlay_weapon();
    *buttons = atomic_load_explicit(&s_buttons, memory_order_relaxed);
    // Step sequencer: no burst of simultaneous X/B/A/Y events on a long flick.
    if (now >= atomic_load(&s_stepDueMs)) {
        int item = atomic_load(&s_itemSteps), ammo = atomic_load(&s_ammoSteps);
        if (item || ammo) {
            int direction = item ? item : ammo;
            uint64_t mask = UINT64_C(1) << BTN_L;
            if (item) mask |= UINT64_C(1) << (direction > 0 ? BTN_A : BTN_Y);
            else mask |= UINT64_C(1) << (direction > 0 ? BTN_X : BTN_B);
            pulse_button_mask(mask, 75);
            if (item) atomic_fetch_add(&s_itemSteps, item > 0 ? -1 : 1);
            else atomic_fetch_add(&s_ammoSteps, ammo > 0 ? -1 : 1);
            atomic_store(&s_stepDueMs, now + 125);
        }
    }
    for (int i = 0; i < 16; i++)
        if (now < atomic_load_explicit(&s_pulseUntilMs[i], memory_order_relaxed))
            *buttons |= UINT64_C(1) << i;
    if (now < atomic_load_explicit(&s_centerCameraUntilMs, memory_order_relaxed))
        *buttons |= UINT64_C(1) << BTN_L;
    *lx = atomic_load_explicit(&s_lx, memory_order_relaxed);
    *ly = atomic_load_explicit(&s_ly, memory_order_relaxed);
    *rx = atomic_load_explicit(&s_rx, memory_order_relaxed);
    *ry = atomic_load_explicit(&s_ry, memory_order_relaxed);
    // Swipe turns the stick only while movement is being reported; avoid
    // a camera that keeps spinning after the last finger-motion event.
    if (now - atomic_load_explicit(&s_lastSwipeMs, memory_order_relaxed) < 65) {
        *rx += atomic_load_explicit(&s_swipeRx, memory_order_relaxed);
        *ry += atomic_load_explicit(&s_swipeRy, memory_order_relaxed);
    }
}

void mhgu_touch_clear(void) {
    atomic_store_explicit(&s_buttons, 0, memory_order_relaxed);
    atomic_store(&s_itemSteps, 0);
    atomic_store(&s_ammoSteps, 0);
    atomic_store(&s_stepDueMs, 0);
    for (int i = 0; i < 16; i++) {
        atomic_store_explicit(&s_buttonRefs[i], 0, memory_order_relaxed);
        atomic_store_explicit(&s_pulseUntilMs[i], 0, memory_order_relaxed);
    }
    atomic_store_explicit(&s_swipeRx, 0, memory_order_relaxed);
    atomic_store_explicit(&s_swipeRy, 0, memory_order_relaxed);
    atomic_store_explicit(&s_lastSwipeMs, 0, memory_order_relaxed);
    atomic_store_explicit(&s_centerCameraUntilMs, 0, memory_order_relaxed);
    atomic_store_explicit(&s_lx, 0, memory_order_relaxed);
    atomic_store_explicit(&s_ly, 0, memory_order_relaxed);
    atomic_store_explicit(&s_rx, 0, memory_order_relaxed);
    atomic_store_explicit(&s_ry, 0, memory_order_relaxed);
}

// gu-native-inspired: parchment/bronze/charcoal/gold palette, rendered with UIKit.
// This is original iOS UI code; the Android renderer is not linked into iOS.
static UIColor *hudGold(void) {
    return [UIColor colorWithRed:222.0/255 green:186.0/255 blue:96.0/255 alpha:1.0];
}
static UIColor *hudCream(void) {
    return [UIColor colorWithRed:244.0/255 green:232.0/255 blue:200.0/255 alpha:1.0];
}
static UIColor *hudBackground(void) {
    return [UIColor colorWithRed:28.0/255 green:20.0/255 blue:15.0/255 alpha:0.87];
}
static UIColor *hudPressed(void) {
    return [UIColor colorWithRed:92.0/255 green:62.0/255 blue:22.0/255 alpha:0.96];
}
static void mhgu_style_menu(UIButton *button) {
    button.backgroundColor = hudBackground();
    button.layer.cornerRadius = 9.0;
    button.layer.borderWidth = 1.1;
    button.layer.borderColor = [hudGold() colorWithAlphaComponent:0.8].CGColor;
    button.titleLabel.font = [UIFont fontWithName:@"Georgia-Bold" size:10] ?: [UIFont boldSystemFontOfSize:10];
    [button setTitleColor:hudCream() forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithRed:1 green:.86 blue:.42 alpha:1] forState:UIControlStateHighlighted];
}

@interface MHGUTouchButton : UIView {
    uint64_t _mask;
    uint64_t _pressStartMs;
    NSMutableSet *_active;
    UILabel *_caption;
    UILabel *_badge;
    CALayer *_innerRing;
}
- (id)initWithLabel:(NSString *)label mask:(uint64_t)mask;
- (void)setMask:(uint64_t)mask;
- (void)resetInput;
@end

@implementation MHGUTouchButton
- (id)initWithLabel:(NSString *)label mask:(uint64_t)mask {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _mask = mask;
    _active = [[NSMutableSet alloc] init];
    self.multipleTouchEnabled = YES;
    self.opaque = NO;
    self.backgroundColor = hudBackground();
    self.layer.borderColor = [hudGold() colorWithAlphaComponent:.95].CGColor;
    self.layer.borderWidth = 2.1;
    _innerRing = [[CALayer alloc] init];
    _innerRing.borderColor = [[UIColor colorWithRed:112.0/255 green:76.0/255 blue:34.0/255 alpha:.90] CGColor];
    _innerRing.borderWidth = 1.7;
    [self.layer addSublayer:_innerRing];
    _caption = [[UILabel alloc] initWithFrame:self.bounds];
    _caption.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _caption.backgroundColor = [UIColor clearColor];
    _caption.textAlignment = NSTextAlignmentCenter;
    // Symbol plus a tiny original Switch letter, like gu-native's ink-and-badge controls.
    NSDictionary *symbols = @{@"A":@"✦", @"X":@"✧", @"B":@"↶", @"Y":@"◇"};
    NSString *symbol = [symbols objectForKey:label];
    _caption.text = symbol ?: label;
    if (symbol) {
        _badge = [[UILabel alloc] initWithFrame:CGRectZero];
        _badge.text = label;
        _badge.textAlignment = NSTextAlignmentCenter;
        _badge.backgroundColor = [UIColor colorWithRed:.08 green:.05 blue:.035 alpha:.98];
        _badge.textColor = hudCream();
        _badge.layer.borderColor = hudGold().CGColor;
        _badge.layer.borderWidth = 1.0;
        _badge.userInteractionEnabled = NO;
        [self addSubview:_badge];
    }
    _caption.adjustsFontSizeToFitWidth = YES;
    _caption.minimumScaleFactor = 0.6;
    _caption.textColor = hudCream();
    _caption.font = [UIFont fontWithName:@"Georgia-Bold" size:18] ?: [UIFont boldSystemFontOfSize:18];
    _caption.userInteractionEnabled = NO;
    [self addSubview:_caption];
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat d = MIN(self.bounds.size.width, self.bounds.size.height);
    self.layer.cornerRadius = d * 0.5;
    _innerRing.frame = CGRectInset(self.bounds, d * .09, d * .09);
    _innerRing.cornerRadius = d * .41;
    _caption.font = [UIFont fontWithName:@"Georgia-Bold" size:MIN(22, d * .44)]
                    ?: [UIFont boldSystemFontOfSize:MIN(22, d * .44)];
    if (_badge) {
        CGFloat bd = MAX(14, MIN(22, d * .32));
        _badge.frame = CGRectMake(d * .61, d * .02, bd, bd);
        _badge.layer.cornerRadius = bd * .5;
        _badge.layer.masksToBounds = YES;
        _badge.font = [UIFont boldSystemFontOfSize:MAX(9, bd * .58)];
    }
}
- (void)setPressedStyle:(BOOL)pressed {
    self.backgroundColor = pressed ? hudPressed() : hudBackground();
    self.layer.borderColor = (pressed ? [UIColor colorWithRed:1 green:.84 blue:.36 alpha:1] : hudGold()).CGColor;
    self.layer.borderWidth = pressed ? 2.8 : 2.1;
    _innerRing.borderColor = (pressed ? hudGold() : [hudGold() colorWithAlphaComponent:.46]).CGColor;
}
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    (void)event;
    BOOL wasDown = _active.count > 0;
    [_active unionSet:touches];
    if (!wasDown) {
        _pressStartMs = mhgu_now_ms();
        set_button_mask(_mask, YES);
    }
    [self setPressedStyle:YES];
}
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    (void)touches; (void)event;
    // Button remains held even if the finger slides a little outside its visual area.
}
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    (void)event;
    BOOL wasDown = _active.count > 0;
    [_active minusSet:touches];
    if (wasDown && _active.count == 0) {
        uint64_t elapsed = mhgu_now_ms() - _pressStartMs;
        // gu-native uses a minimum short-tap duration so the game loop
        // cannot miss a very quick touch between input snapshots.
        if (elapsed < 75) pulse_button_mask(_mask, 75 - elapsed);
        set_button_mask(_mask, NO);
        [self setPressedStyle:NO];
    }
}
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}
- (void)setMask:(uint64_t)mask {
    [self resetInput];
    _mask = mask;
}
- (void)resetInput {
    if (_active.count > 0) set_button_mask(_mask, NO);
    [_active removeAllObjects];
    [self setPressedStyle:NO];
}
- (void)dealloc {
    [self resetInput];
    [_active release];
    [_caption release];
    [_badge release];
    [_innerRing release];
    [super dealloc];
}
@end

@interface MHGUTouchStick : UIView {
    BOOL _left;
    UITouch *_tracked;
    UIView *_knob;
    UILabel *_name;
}
- (id)initLeft:(BOOL)left;
- (void)resetInput;
@end

@implementation MHGUTouchStick
- (id)initLeft:(BOOL)left {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _left = left;
    self.opaque = NO;
    self.backgroundColor = hudBackground();
    self.layer.borderWidth = 2.5;
    self.layer.borderColor = [hudGold() colorWithAlphaComponent:.93].CGColor;
    _knob = [[UIView alloc] initWithFrame:CGRectZero];
    _knob.userInteractionEnabled = NO;
    _knob.backgroundColor = [UIColor colorWithRed:.24 green:.17 blue:.10 alpha:.98];
    _knob.layer.borderColor = hudGold().CGColor;
    _knob.layer.borderWidth = 2.0;
    [self addSubview:_knob];
    _name = [[UILabel alloc] initWithFrame:CGRectZero];
    _name.text = left ? @"MOVE" : @"CAM";
    _name.textColor = [hudCream() colorWithAlphaComponent:.85];
    _name.textAlignment = NSTextAlignmentCenter;
    _name.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
    _name.userInteractionEnabled = NO;
    [self addSubview:_name];
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat d = MIN(self.bounds.size.width, self.bounds.size.height);
    self.layer.cornerRadius = d * 0.5;
    CGFloat kd = d * 0.43;
    _knob.bounds = CGRectMake(0, 0, kd, kd);
    _knob.layer.cornerRadius = kd * 0.5;
    if (!_tracked) _knob.center = CGPointMake(self.bounds.size.width / 2, self.bounds.size.height / 2);
    _name.frame = CGRectMake(0, d * 0.08, d, 13);
}
- (void)setPosition:(CGPoint)p {
    CGFloat cx = self.bounds.size.width / 2, cy = self.bounds.size.height / 2;
    CGFloat travel = MIN(self.bounds.size.width, self.bounds.size.height) * 0.29;
    if (travel <= 0) return;
    CGFloat x = (p.x - cx) / travel, y = (p.y - cy) / travel;
    CGFloat length = hypot(x, y);
    if (length > 1) { x /= length; y /= length; }
    if (length < 0.10) x = y = 0;
    _knob.center = CGPointMake(cx + x * travel, cy + y * travel);
    int ax = (int)lrint(x * 32767.0);
    int ay = (int)lrint(-y * 32767.0); // Switch stick Y is positive upward
    if (_left) {
        atomic_store_explicit(&s_lx, ax, memory_order_relaxed);
        atomic_store_explicit(&s_ly, ay, memory_order_relaxed);
    } else {
        if (length >= 0.10) mhgu_touch_camera_drag();
        atomic_store_explicit(&s_rx, ax, memory_order_relaxed);
        atomic_store_explicit(&s_ry, ay, memory_order_relaxed);
    }
}
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (_tracked) return;
    UITouch *touch = [touches anyObject];
    if (!touch) return;
    _tracked = [touch retain];
    [self setPosition:[touch locationInView:self]];
}
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (_tracked && [touches containsObject:_tracked])
        [self setPosition:[_tracked locationInView:self]];
}
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (_tracked && [touches containsObject:_tracked]) [self resetInput];
}
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}
- (void)resetInput {
    [_tracked release];
    _tracked = nil;
    [self setPosition:CGPointMake(self.bounds.size.width / 2, self.bounds.size.height / 2)];
}
- (void)dealloc {
    [self resetInput];
    [_knob release];
    [_name release];
    [super dealloc];
}
@end

// The original Android port directly hooks the rendered item HUD. Here the
// gesture surface is a separate UIKit item strip; it sends native L+Y/A (items)
// and L+B/X (ammo) combinations rather than modifying the guest's HUD.
@interface MHGUTouchItemStrip : UIView {
    UITouch *_finger;
    CGPoint _first;
    CGPoint _last;
    BOOL _moved;
    UILabel *_label;
}
- (void)resetInput;
@end
@implementation MHGUTouchItemStrip
- (id)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.opaque = NO;
    self.multipleTouchEnabled = NO;
    self.backgroundColor = hudBackground();
    self.layer.borderColor = [hudGold() colorWithAlphaComponent:.9].CGColor;
    self.layer.borderWidth = 2.0;
    self.layer.cornerRadius = 15;
    _label = [[UILabel alloc] initWithFrame:self.bounds];
    _label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _label.text = @"◀  ITEM  •  USE  ▶";
    _label.textColor = hudCream();
    _label.textAlignment = NSTextAlignmentCenter;
    _label.font = [UIFont fontWithName:@"Georgia-Bold" size:14] ?: [UIFont boldSystemFontOfSize:14];
    _label.userInteractionEnabled = NO;
    [self addSubview:_label];
    return self;
}
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (_finger) return;
    UITouch *t = [touches anyObject];
    if (!t) return;
    _finger = [t retain];
    _first = _last = [t locationInView:self];
    _moved = NO;
}
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (!_finger || ![touches containsObject:_finger]) return;
    _last = [_finger locationInView:self];
    if (hypot(_last.x - _first.x, _last.y - _first.y) > 15) _moved = YES;
}
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (!_finger || ![touches containsObject:_finger]) return;
    CGPoint p = [_finger locationInView:self];
    CGFloat dx = p.x - _first.x, dy = p.y - _first.y;
    [_finger release]; _finger = nil;
    if (hypot(dx, dy) > 19 || _moved) {
        // Vertical swipe switches ammo/coatings; horizontal swipe switches items.
        BOOL ammo = fabs(dy) > fabs(dx) * 1.25;
        CGFloat dist = ammo ? -dy : dx;
        int count = MIN(5, MAX(1, (int)lrint(fabs(dist) / 55.0)));
        if (fabs(dist) >= 19) queue_steps(ammo, (dist > 0 ? 1 : -1) * count);
    } else {
        // Simple tap uses the item when sheathed, or sheaths the weapon.
        pulse_button_mask(UINT64_C(1) << BTN_Y, 95);
    }
}
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (_finger && [touches containsObject:_finger]) [self resetInput];
}
- (void)resetInput { [_finger release]; _finger = nil; _moved = NO; }
- (void)dealloc { [self resetInput]; [_label release]; [super dealloc]; }
@end

@interface MHGUTouchRoot : UIView {
    NSMutableArray *_controls;
    MHGUTouchStick *_left;
    MHGUTouchStick *_right;
    MHGUTouchButton *_button[16];
    MHGUTouchItemStrip *_itemStrip;
    MHGUTouchButton *_fire, *_reload, *_aim, *_special, *_ammoUp, *_ammoDown;
    UIButton *_weaponModeButton, *_lockButton;
    int _weaponSetting, _weaponKind, _drawn, _bowType;
    BOOL _lockOn;
    NSMutableDictionary *_namedControls;
    NSMutableDictionary *_customLayout;
    UIView *_selectedControl;
    UITouch *_editFinger;
    CGPoint _editPoint;
    UIButton *_editButton, *_sizeMinus, *_sizePlus, *_resetLayout;
    BOOL _editing;
    MHGUTouchButton *_arts[3];
    UIButton *_cameraButton, *_artsButton;
    UITouch *_cameraFinger;
    CGPoint _cameraPoint;
    BOOL _cameraSwipe;
    BOOL _artsType3;
    UIButton *_showButton;
    UIButton *_alphaButton;
    UIButton *_settingsButton;  // compact gu-native-style settings tab
    BOOL _settingsOpen;
    BOOL _controlsHidden;
    NSUInteger _opacityStep;
}
- (void)resetAll;
- (void)syncWeapon;
- (void)updateMenuVisibility;
@end

@implementation MHGUTouchRoot
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (_editing) {
        if (hit == _editButton || hit == _sizePlus || hit == _sizeMinus ||
            hit == _resetLayout || hit == _settingsButton)
            return hit;
        return self;
    }
    // Empty screen is a relative camera surface; buttons/sticks retain
    // ownership of any fingers which begin on them.
    if (hit == self)
        return (!_controlsHidden && _cameraSwipe && point.x > self.bounds.size.width * 0.25) ? self : nil;
    return hit;
}
- (void)addControl:(UIView *)view {
    [self addSubview:view];
    [_controls addObject:view];
}
- (void)named:(NSString *)name view:(UIView *)view {
    if (name && view) [_namedControls setObject:view forKey:name];
}
- (void)addButton:(int)bit text:(NSString *)text {
    MHGUTouchButton *b = [[MHGUTouchButton alloc] initWithLabel:text mask:(UINT64_C(1) << bit)];
    _button[bit] = b;
    [self addControl:b];
    [self named:text view:b];
    [b release];
}
- (MHGUTouchButton *)addMaskButton:(uint64_t)mask text:(NSString *)text {
    MHGUTouchButton *b = [[MHGUTouchButton alloc] initWithLabel:text mask:mask];
    [self addControl:b];
    [b release];
    return b;
}
- (id)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.opaque = NO;
    self.multipleTouchEnabled = YES;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _controls = [[NSMutableArray alloc] init];
    _namedControls = [[NSMutableDictionary alloc] init];
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"mhgu_touch_layout_v3"];
    _customLayout = [[NSMutableDictionary alloc] initWithDictionary:saved ? saved : @{}];
    _left = [[MHGUTouchStick alloc] initLeft:YES];
    [self addControl:_left];
    [self named:@"MOVE" view:_left];
    [_left release];
    _right = [[MHGUTouchStick alloc] initLeft:NO];
    [self addControl:_right];
    [self named:@"CAMERA_STICK" view:_right];
    [_right release];

    [self addButton:BTN_A text:@"A"];
    [self addButton:BTN_B text:@"B"];
    [self addButton:BTN_X text:@"X"];
    [self addButton:BTN_Y text:@"Y"];
    [self addButton:BTN_L text:@"L"];
    [self addButton:BTN_R text:@"R"];
    [self addButton:BTN_ZL text:@"ZL"];
    [self addButton:BTN_ZR text:@"ZR"];
    [self addButton:BTN_PLUS text:@"+"];
    [self addButton:BTN_MINUS text:@"−"];
    [self addButton:BTN_UP text:@"▲"];
    [self addButton:BTN_DOWN text:@"▼"];
    [self addButton:BTN_LEFT text:@"◀"];
    [self addButton:BTN_RIGHT text:@"▶"];
    [self addButton:BTN_LSTICK text:@"L3"];
    [self addButton:BTN_RSTICK text:@"R3"];

    // Following gu-native's hunting-first layout: item wheel shortcuts and
    // Hunter Arts have thumb-sized buttons, without game-memory hooks.
    _itemStrip = [[MHGUTouchItemStrip alloc] initWithFrame:CGRectZero];
    [self addControl:_itemStrip];
    [self named:@"ITEM_BAR" view:_itemStrip];
    [_itemStrip release];
    _fire = [self addMaskButton:(UINT64_C(1) << BTN_A) text:@"FIRE"];
    _reload = [self addMaskButton:(UINT64_C(1) << BTN_X) text:@"RELOAD"];
    _aim = [self addMaskButton:(UINT64_C(1) << BTN_R) text:@"AIM"];
    _special = [self addMaskButton:(UINT64_C(1) << BTN_X) | (UINT64_C(1) << BTN_A) text:@"SPECIAL"];
    _ammoUp = [self addMaskButton:(UINT64_C(1) << BTN_L) | (UINT64_C(1) << BTN_X) text:@"AMMO+"];
    _ammoDown = [self addMaskButton:(UINT64_C(1) << BTN_L) | (UINT64_C(1) << BTN_B) text:@"AMMO−"];
    [self named:@"FIRE" view:_fire];
    [self named:@"RELOAD" view:_reload];
    [self named:@"AIM" view:_aim];
    [self named:@"SPECIAL" view:_special];
    [self named:@"AMMO_UP" view:_ammoUp];
    [self named:@"AMMO_DOWN" view:_ammoDown];
    _arts[0] = [self addMaskButton:(UINT64_C(1) << BTN_UP) text:@"ART1"];
    _arts[1] = [self addMaskButton:(UINT64_C(1) << BTN_RIGHT) text:@"ART2"];
    _arts[2] = [self addMaskButton:(UINT64_C(1) << BTN_DOWN) text:@"ART3"];
    for (int i=0; i<3; i++) [self named:[NSString stringWithFormat:@"ART%d",i+1] view:_arts[i]];

    _cameraButton = [UIButton buttonWithType:UIButtonTypeCustom];
    mhgu_style_menu(_cameraButton);
    [_cameraButton addTarget:self action:@selector(toggleCamera:) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_cameraButton];

    _artsButton = [UIButton buttonWithType:UIButtonTypeCustom];
    mhgu_style_menu(_artsButton);
    [_artsButton addTarget:self action:@selector(toggleArts:) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_artsButton];

    _weaponModeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _lockButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _editButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _sizeMinus = [UIButton buttonWithType:UIButtonTypeCustom];
    _sizePlus = [UIButton buttonWithType:UIButtonTypeCustom];
    _resetLayout = [UIButton buttonWithType:UIButtonTypeCustom];
    NSArray *menuButtons = @[_weaponModeButton, _lockButton, _editButton, _sizeMinus, _sizePlus, _resetLayout];
    NSArray *actions = @[@"toggleWeapon:", @"toggleLock:", @"toggleEdit:",
                         @"shrinkSelected:", @"growSelected:", @"resetLayout:"];
    NSArray *titles = @[@"WEAPON:AUTO", @"LOCK:OFF", @"EDIT", @"SIZE −", @"SIZE +", @"RESET"];
    for (NSUInteger i=0; i<menuButtons.count; i++) {
        UIButton *b = [menuButtons objectAtIndex:i];
        [b setTitle:[titles objectAtIndex:i] forState:UIControlStateNormal];
        mhgu_style_menu(b);
        [b addTarget:self action:NSSelectorFromString([actions objectAtIndex:i])
                         forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:b];
    }
    _sizeMinus.hidden = YES; _sizePlus.hidden = YES; _resetLayout.hidden = YES;

    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    _cameraSwipe = [prefs objectForKey:@"mhgu_touch_camera_swipe"] ? [prefs boolForKey:@"mhgu_touch_camera_swipe"] : YES;
    _artsType3 = [prefs boolForKey:@"mhgu_touch_arts_type3"];
    _weaponSetting = (int)[prefs integerForKey:@"mhgu_touch_weapon_setting"] % 4;
    if (_weaponSetting < 0) _weaponSetting = 0;
    _drawn = -1;
    _lockOn = NO;
    [self syncWeapon];
    [self updateArtsMapping];
    [self updateCameraMode];
    NSArray *weaponNames = @[@"WEAPON:AUTO", @"WEAPON:GUN", @"WEAPON:BOW", @"WEAPON:NORM"];
    [_weaponModeButton setTitle:[weaponNames objectAtIndex:_weaponSetting] forState:UIControlStateNormal];
    s_lastWeaponPollMs = 0;
    [self syncWeapon];

    _showButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_showButton setTitle:@"HIDE" forState:UIControlStateNormal];
    mhgu_style_menu(_showButton);
    [_showButton addTarget:self action:@selector(toggleControls:) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_showButton];

    _alphaButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_alphaButton setTitle:@"OPACITY" forState:UIControlStateNormal];
    mhgu_style_menu(_alphaButton);
    [_alphaButton addTarget:self action:@selector(cycleOpacity:) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_alphaButton];
    // The gear stays accessible even when a controller hides the touch pad.
    // Other settings appear only when tapped, preserving iPhone play space.
    _settingsButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_settingsButton setTitle:@"⚙" forState:UIControlStateNormal];
    mhgu_style_menu(_settingsButton);
    _settingsButton.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
    [_settingsButton addTarget:self action:@selector(toggleSettings:)
              forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_settingsButton];
    _settingsOpen = NO;

    _opacityStep = [[NSUserDefaults standardUserDefaults] objectForKey:@"mhgu_touch_opacity_step"] ?
                   (NSUInteger)[[NSUserDefaults standardUserDefaults] integerForKey:@"mhgu_touch_opacity_step"] % 3 : 1;
    [self updateOpacity];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(controllerChanged:)
                                                 name:GCControllerDidConnectNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(controllerChanged:)
                                                 name:GCControllerDidDisconnectNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appLostFocus:)
                                                 name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appBecameActive:)
                                                 name:UIApplicationDidBecomeActiveNotification object:nil];
    [self controllerChanged:nil];
    return self;
}
- (void)resetAll {
    for (UIView *v in _controls) {
        if ([v isKindOfClass:[MHGUTouchButton class]]) [(MHGUTouchButton *)v resetInput];
        else if ([v isKindOfClass:[MHGUTouchStick class]]) [(MHGUTouchStick *)v resetInput];
        else if ([v isKindOfClass:[MHGUTouchItemStrip class]]) [(MHGUTouchItemStrip *)v resetInput];
    }
    [_cameraFinger release];
    _cameraFinger = nil;
    mhgu_touch_clear();
}
- (void)appLostFocus:(NSNotification *)notification {
    (void)notification;
    atomic_store_explicit(&s_iosForeground, 0, memory_order_release);
    [self resetAll];
}
- (void)appBecameActive:(NSNotification *)notification {
    (void)notification;
    atomic_store_explicit(&s_iosForeground, 1, memory_order_release);
}
- (void)setControlsVisible:(BOOL)visible {
    _controlsHidden = !visible;
    if (!visible) {
        [self resetAll];
        mhgu_touch_lock_enable(0);
        _lockOn = NO;
        [_lockButton setTitle:@"LOCK:OFF" forState:UIControlStateNormal];
    }
    for (UIView *v in _controls) v.hidden = !visible;
    [_showButton setTitle:visible ? @"HIDE" : @"SHOW" forState:UIControlStateNormal];
    [self updateMenuVisibility];
    [self updateRangedVisibility];
    [self updateCameraMode];
}
- (void)updateMenuVisibility {
    BOOL open = _settingsOpen;
    _showButton.hidden = !open;
    _alphaButton.hidden = !open || _controlsHidden;
    _cameraButton.hidden = !open || _controlsHidden;
    _artsButton.hidden = !open || _controlsHidden;
    _weaponModeButton.hidden = !open || _controlsHidden;
    _lockButton.hidden = !open || _controlsHidden;
    _editButton.hidden = !open || _controlsHidden;
    _sizeMinus.hidden = !open || _controlsHidden || !_editing;
    _sizePlus.hidden = !open || _controlsHidden || !_editing;
    _resetLayout.hidden = !open || _controlsHidden || !_editing;
    [_settingsButton setTitle:(open ? @"✕" : @"⚙") forState:UIControlStateNormal];
}
- (void)toggleSettings:(id)sender {
    (void)sender;
    _settingsOpen = !_settingsOpen;
    [self updateMenuVisibility];
}
- (void)toggleControls:(id)sender {
    (void)sender;
    [self setControlsVisible:_controlsHidden];
}
- (void)updateOpacity {
    static const CGFloat levels[] = {0.38, 0.64, 0.88};
    for (UIView *v in _controls) v.alpha = levels[_opacityStep];
}
- (void)cycleOpacity:(id)sender {
    (void)sender;
    _opacityStep = (_opacityStep + 1) % 3;
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)_opacityStep forKey:@"mhgu_touch_opacity_step"];
    [self updateOpacity];
}
- (void)updateCameraMode {
    [_cameraButton setTitle:(_cameraSwipe ? @"CAM:SWIPE" : @"CAM:STICK") forState:UIControlStateNormal];
    _right.hidden = _controlsHidden || _cameraSwipe;
    if (_editing && !_controlsHidden) _right.hidden = NO;
}
- (void)toggleCamera:(id)sender {
    (void)sender;
    _cameraSwipe = !_cameraSwipe;
    [_right resetInput];
    [_cameraFinger release]; _cameraFinger = nil;
    atomic_store_explicit(&s_lastSwipeMs, 0, memory_order_relaxed);
    [[NSUserDefaults standardUserDefaults] setBool:_cameraSwipe forKey:@"mhgu_touch_camera_swipe"];
    [self updateCameraMode];
}
- (void)updateArtsMapping {
    uint64_t masks[3];
    if (_artsType3) {
        masks[0] = (UINT64_C(1) << BTN_ZL) | (UINT64_C(1) << BTN_X);
        masks[1] = (UINT64_C(1) << BTN_ZL) | (UINT64_C(1) << BTN_A);
        masks[2] = (UINT64_C(1) << BTN_ZL) | (UINT64_C(1) << BTN_B);
    } else {
        masks[0] = UINT64_C(1) << BTN_UP;
        masks[1] = UINT64_C(1) << BTN_RIGHT;
        masks[2] = UINT64_C(1) << BTN_DOWN;
    }
    for (int i = 0; i < 3; i++) [_arts[i] setMask:masks[i]];
    [_artsButton setTitle:(_artsType3 ? @"ART:TYPE3" : @"ART:TYPE1") forState:UIControlStateNormal];
}
- (void)toggleArts:(id)sender {
    (void)sender;
    _artsType3 = !_artsType3;
    [[NSUserDefaults standardUserDefaults] setBool:_artsType3 forKey:@"mhgu_touch_arts_type3"];
    [self updateArtsMapping];
}
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (_editing) {
        if (_editFinger) return;
        UITouch *t = [touches anyObject];
        if (!t) return;
        CGPoint p = [t locationInView:self];
        _selectedControl = nil;
        for (UIView *v in [_controls reverseObjectEnumerator]) {
            if (v.hidden) continue;
            if (CGRectContainsPoint(CGRectInset(v.frame, -13, -13), p)) {
                _selectedControl = v;
                break;
            }
        }
        if (_selectedControl) {
            _editFinger = [t retain];
            _editPoint = p;
            _selectedControl.layer.borderColor = [UIColor cyanColor].CGColor;
            _selectedControl.layer.borderWidth = 3.0;
        }
        return;
    }
    if (_controlsHidden || !_cameraSwipe || _cameraFinger) return;
    UITouch *finger = [touches anyObject];
    if (!finger) return;
    if (finger.tapCount >= 2) {
        // A double tap in the open camera area taps L to recenter/target.
        atomic_store_explicit(&s_centerCameraUntilMs, mhgu_now_ms() + 100, memory_order_relaxed);
        return;
    }
    _cameraFinger = [finger retain];
    _cameraPoint = [finger locationInView:self];
}
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (_editing) {
        if (_editFinger && [touches containsObject:_editFinger] && _selectedControl) {
            CGPoint p = [_editFinger locationInView:self];
            CGFloat halfW = _selectedControl.bounds.size.width / 2.0;
            CGFloat halfH = _selectedControl.bounds.size.height / 2.0;
            CGPoint c = _selectedControl.center;
            CGRect safeRect = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
            if (CGRectIsEmpty(safeRect)) safeRect = self.bounds;
            c.x = MAX(CGRectGetMinX(safeRect) + halfW,
                      MIN(CGRectGetMaxX(safeRect) - halfW, c.x + p.x - _editPoint.x));
            c.y = MAX(CGRectGetMinY(safeRect) + halfH,
                      MIN(CGRectGetMaxY(safeRect) - halfH, c.y + p.y - _editPoint.y));
            _selectedControl.center = c;
            _editPoint = p;
        }
        return;
    }
    if (!_cameraFinger || ![touches containsObject:_cameraFinger]) return;
    CGPoint p = [_cameraFinger locationInView:self];
    mhgu_touch_camera_drag();
    CGFloat dx = p.x - _cameraPoint.x, dy = p.y - _cameraPoint.y;
    _cameraPoint = p;
    // Game's right-stick camera has a ~40% dead zone. Lift small swipes
    // above that dead zone while still scaling from slow to quick drags.
    CGFloat vx = fmin(1.0, fabs(dx) / 12.0);
    CGFloat vy = fmin(1.0, fabs(dy) / 12.0);
    int ax = fabs(dx) < 0.4 ? 0 : (int)lrint(copysign(32767.0 * (0.43 + 0.57 * vx), dx));
    int ay = fabs(dy) < 0.4 ? 0 : (int)lrint(copysign(32767.0 * (0.43 + 0.57 * vy), -dy));
    atomic_store_explicit(&s_swipeRx, ax, memory_order_relaxed);
    atomic_store_explicit(&s_swipeRy, ay, memory_order_relaxed);
    atomic_store_explicit(&s_lastSwipeMs, mhgu_now_ms(), memory_order_relaxed);
}
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (_editing && _editFinger && [touches containsObject:_editFinger]) {
        [self saveLayout];
        if (_selectedControl) {
            _selectedControl.layer.borderColor = [hudGold() colorWithAlphaComponent:.85].CGColor;
            _selectedControl.layer.borderWidth = 1.5;
        }
        [_editFinger release]; _editFinger = nil;
        return;
    }
    if (_cameraFinger && [touches containsObject:_cameraFinger]) {
        [_cameraFinger release]; _cameraFinger = nil;
        atomic_store_explicit(&s_lastSwipeMs, 0, memory_order_relaxed);
        atomic_store_explicit(&s_swipeRx, 0, memory_order_relaxed);
        atomic_store_explicit(&s_swipeRy, 0, memory_order_relaxed);
    }
}
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}
- (void)controllerChanged:(NSNotification *)notification {
    (void)notification;
    // Native gamepads keep working through SDL3. The UI automatically hides for them.
    [self setControlsVisible:([GCController controllers].count == 0)];
}
- (void)place:(UIView *)view center:(CGPoint)center diameter:(CGFloat)diameter {
    // Keep control hit targets in the actual safe viewport (notch / Dynamic Island / home bar).
    UIEdgeInsets insets = self.safeAreaInsets;
    CGRect r = UIEdgeInsetsInsetRect(self.bounds, insets);
    if (CGRectIsEmpty(r)) r = self.bounds;
    CGFloat radius = diameter * .5;
    center.x = MAX(CGRectGetMinX(r) + radius, MIN(CGRectGetMaxX(r) - radius, center.x));
    center.y = MAX(CGRectGetMinY(r) + radius, MIN(CGRectGetMaxY(r) - radius, center.y));
    view.bounds = CGRectMake(0, 0, diameter, diameter);
    view.center = center;
}
- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    if (w < 100 || h < 100) return;
    UIEdgeInsets safe = self.safeAreaInsets;
    CGFloat availW = MAX(100, w - safe.left - safe.right);
    CGFloat availH = MAX(100, h - safe.top - safe.bottom);
    // Points, not pixels: modern phones have 3x Retina scale. Responsive to small iPhones.
    CGFloat scale = fmin(1.15, fmax(.78, availH / 355.0));
    if (availW < 620) scale *= fmax(.78, availW / 620.0);
    CGFloat button = 53 * scale, mini = 40 * scale, stick = 120 * scale;
    CGFloat y = h - safe.bottom - 17 * scale - stick * .5;
    CGFloat leftX = safe.left + 16 * scale + stick * .5;
    CGFloat dX = leftX + 149 * scale;
    CGFloat faceX = w - safe.right - 76 * scale;
    CGFloat rightX = faceX - 147 * scale;
    // iPhone SE / unusual rotation: distribute d-pad and camera stick symmetrically.
    if (rightX - dX < stick * 1.12) {
        CGFloat correction = (stick * 1.12 - (rightX - dX)) / 2;
        dX -= correction;
        rightX += correction;
    }
    [self place:_left center:CGPointMake(leftX, y) diameter:stick];
    [self place:_right center:CGPointMake(rightX, y) diameter:stick];
    CGFloat spread = 50 * scale;
    [self place:_button[BTN_UP] center:CGPointMake(dX, y - spread) diameter:mini];
    [self place:_button[BTN_DOWN] center:CGPointMake(dX, y + spread) diameter:mini];
    [self place:_button[BTN_LEFT] center:CGPointMake(dX - spread, y) diameter:mini];
    [self place:_button[BTN_RIGHT] center:CGPointMake(dX + spread, y) diameter:mini];
    // Android-inspired combat cluster: heavy A, light X, evade B, sheathe Y.
    [self place:_button[BTN_X] center:CGPointMake(faceX - 12 * scale, y - 61 * scale) diameter:button];
    [self place:_button[BTN_A] center:CGPointMake(faceX + 19 * scale, y - 6 * scale) diameter:button];
    [self place:_button[BTN_B] center:CGPointMake(faceX - 2 * scale, y + 57 * scale) diameter:button];
    [self place:_button[BTN_Y] center:CGPointMake(faceX - 75 * scale, y - 10 * scale) diameter:mini];

    CGFloat topY = safe.top + 14 * scale + mini / 2;
    CGFloat l = safe.left + 12 * scale + mini / 2;
    CGFloat r = w - safe.right - 12 * scale - mini / 2;
    [self place:_button[BTN_L] center:CGPointMake(l, topY) diameter:mini];
    [self place:_button[BTN_ZL] center:CGPointMake(l + 43 * scale, topY) diameter:mini];
    [self place:_button[BTN_R] center:CGPointMake(r - 43 * scale, topY) diameter:mini];
    [self place:_button[BTN_ZR] center:CGPointMake(r, topY) diameter:mini];
    CGFloat mid = w * .5;
    [self place:_button[BTN_MINUS] center:CGPointMake(mid - 41 * scale, topY) diameter:mini];
    [self place:_button[BTN_PLUS] center:CGPointMake(mid + 41 * scale, topY) diameter:mini];
    [self place:_button[BTN_LSTICK] center:CGPointMake(mid - 111 * scale, topY) diameter:mini];
    [self place:_button[BTN_RSTICK] center:CGPointMake(mid + 111 * scale, topY) diameter:mini];

    // Small permanent gear; the settings grid is hidden unless opened.
    CGFloat gearX = safe.left + 10 * scale;
    CGFloat gearY = safe.top + 66 * scale;
    _settingsButton.frame = CGRectMake(gearX, gearY, 43 * scale, 37 * scale);
    CGFloat panelX = gearX + 49 * scale;
    CGFloat panelY = gearY;
    CGFloat gutter = 5 * scale;
    CGFloat panelW = fmin(112 * scale, (w - safe.right - panelX - 12 * scale) * .47);
    CGFloat panelH = 27 * scale;
    NSArray *panel = @[_showButton, _alphaButton, _cameraButton, _artsButton,
                       _weaponModeButton, _lockButton, _editButton];
    for (NSUInteger i = 0; i < panel.count; i++) {
        UIButton *b = [panel objectAtIndex:i];
        b.frame = CGRectMake(panelX + (i % 2) * (panelW + gutter),
                             panelY + (i / 2) * (panelH + gutter), panelW, panelH);
    }
    _sizeMinus.frame = CGRectMake(panelX, panelY + 4 * (panelH + gutter), panelW * .73, panelH);
    _sizePlus.frame = CGRectMake(panelX + panelW * .77, panelY + 4 * (panelH + gutter), panelW * .73, panelH);
    _resetLayout.frame = CGRectMake(panelX + (panelW + gutter) * 1.55,
                                    panelY + 4 * (panelH + gutter), panelW * .65, panelH);

    CGFloat itemY = h - safe.bottom - 27 * scale;
    _itemStrip.frame = CGRectMake(mid - 91 * scale, itemY - 19 * scale, 182 * scale, 38 * scale);
    [self place:_fire center:CGPointMake(faceX, y - 15 * scale) diameter:72 * scale];
    [self place:_reload center:CGPointMake(faceX - 85 * scale, y + 38 * scale) diameter:48 * scale];
    [self place:_aim center:CGPointMake(faceX - 95 * scale, y - 45 * scale) diameter:49 * scale];
    [self place:_special center:CGPointMake(faceX - 55 * scale, y - 102 * scale) diameter:44 * scale];
    [self place:_ammoUp center:CGPointMake(mid + 115 * scale, itemY - 34 * scale) diameter:38 * scale];
    [self place:_ammoDown center:CGPointMake(mid + 115 * scale, itemY + 19 * scale) diameter:38 * scale];
    CGFloat artY = safe.top + 93 * scale;
    CGFloat artX = w - safe.right - 152 * scale;
    for (int i = 0; i < 3; i++)
        [self place:_arts[i] center:CGPointMake(artX + i * 48 * scale, artY) diameter:41 * scale];
    [self applyCustomLayout];
    [self updateRangedVisibility];
    [self updateMenuVisibility];
}
- (void)updateRangedVisibility {
    BOOL ranged = _weaponKind != 0;
    for (UIView *v in @[_fire, _reload, _aim, _special, _ammoUp, _ammoDown])
        v.hidden = _controlsHidden || (!ranged && !_editing);
    for (int bit=BTN_A; bit<=BTN_Y; bit++)
        _button[bit].hidden = _controlsHidden || (ranged && !_editing);
    if (_editing) {
        for (UIView *v in _controls) v.hidden = _controlsHidden ? YES : NO;
        [self updateCameraMode];
    }
}
- (void)syncWeapon {
    uint64_t now = mhgu_now_ms();
    if (now - s_lastWeaponPollMs < 160 && _weaponSetting == 0) return;
    s_lastWeaponPollMs = now;
    int detectedDrawn = -1, detectedBowType = 0;
    int detected = mhgu_touch_detect_weapon(&detectedDrawn, &detectedBowType);
    int kind = _weaponSetting == 0 ? detected : (_weaponSetting == 1 ? 2 : _weaponSetting == 2 ? 1 : 0);
    if (kind == _weaponKind && detectedDrawn == _drawn && detectedBowType == _bowType) return;
    _weaponKind = kind; _drawn = detectedDrawn; _bowType = detectedBowType;
    // MHGU 1.4.0: bowgun A fires, X reloads, R aims; bow X charges
    // (Bow Controls Type 2 reverses R and X); sheathed X draws the weapon.
    uint64_t fire = UINT64_C(1) << ((_drawn == 0) ? BTN_X :
                     _weaponKind == 1 ? (_bowType ? BTN_R : BTN_X) : BTN_A);
    uint64_t aim = UINT64_C(1) << ((_weaponKind == 1 && _bowType) ? BTN_X : BTN_R);
    [_fire setMask:fire];
    [_reload setMask:UINT64_C(1) << ((_weaponKind == 1 || _drawn == 0) ? BTN_A : BTN_X)];
    [_aim setMask:aim];
    [self updateRangedVisibility];
}
- (void)toggleWeapon:(id)sender {
    (void)sender;
    _weaponSetting = (_weaponSetting + 1) % 4;
    [[NSUserDefaults standardUserDefaults] setInteger:_weaponSetting forKey:@"mhgu_touch_weapon_setting"];
    NSArray *names = @[@"WEAPON:AUTO", @"WEAPON:GUN", @"WEAPON:BOW", @"WEAPON:NORM"];
    [_weaponModeButton setTitle:[names objectAtIndex:_weaponSetting] forState:UIControlStateNormal];
    s_lastWeaponPollMs = 0;
    [self syncWeapon];
}
- (void)toggleLock:(id)sender {
    (void)sender;
    if (!mhgu_touch_lock_available()) {
        [_lockButton setTitle:@"LOCK:N/A" forState:UIControlStateNormal];
        return;
    }
    _lockOn = !_lockOn;
    mhgu_touch_lock_enable(_lockOn);
    [_lockButton setTitle:(_lockOn ? @"LOCK:ON" : @"LOCK:OFF") forState:UIControlStateNormal];
}
- (void)applyCustomLayout {
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    if (w <= 0 || h <= 0) return;
    for (NSString *key in _customLayout) {
        UIView *v = [_namedControls objectForKey:key];
        NSArray *a = [_customLayout objectForKey:key];
        if (!v || ![a isKindOfClass:[NSArray class]] || a.count != 4) continue;
        BOOL landscape = w >= h;
        if ([[a objectAtIndex:3] boolValue] != landscape) continue;
        CGFloat diameter = MAX(26, MIN(h * .42, [[a objectAtIndex:2] doubleValue] * h));
        if (v == _itemStrip) {
            v.bounds = CGRectMake(0, 0, diameter * 4.43, diameter);
        } else {
            v.bounds = CGRectMake(0, 0, diameter, diameter);
        }
        CGFloat cx = [[a objectAtIndex:0] doubleValue] * w;
        CGFloat cy = [[a objectAtIndex:1] doubleValue] * h;
        CGRect safeRect = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
        if (CGRectIsEmpty(safeRect)) safeRect = self.bounds;
        CGFloat hw = v.bounds.size.width * .5, hh = v.bounds.size.height * .5;
        v.center = CGPointMake(MAX(CGRectGetMinX(safeRect)+hw, MIN(CGRectGetMaxX(safeRect)-hw,cx)),
                               MAX(CGRectGetMinY(safeRect)+hh,MIN(CGRectGetMaxY(safeRect)-hh,cy)));
    }
}
- (void)saveLayout {
    if (!_selectedControl) return;
    NSString *name = [[_namedControls allKeysForObject:_selectedControl] firstObject];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    if (!name || w <= 0 || h <= 0) return;
    NSArray *a = @[@(_selectedControl.center.x/w), @(_selectedControl.center.y/h),
                   @(_selectedControl.bounds.size.height/h), @(w >= h)];
    [_customLayout setObject:a forKey:name];
    [[NSUserDefaults standardUserDefaults] setObject:_customLayout forKey:@"mhgu_touch_layout_v3"];
}
- (void)toggleEdit:(id)sender {
    (void)sender;
    _editing = !_editing;
    if (_editing) [self resetAll];
    [self saveLayout];
    [_editFinger release]; _editFinger = nil;
    _selectedControl = nil;
    [_editButton setTitle:(_editing ? @"SAVE / DONE" : @"EDIT") forState:UIControlStateNormal];
    [self updateMenuVisibility];
    for (UIView *v in _controls) v.userInteractionEnabled = !_editing;
    [self updateRangedVisibility];
    [self updateCameraMode];
    [self setNeedsLayout];
}
- (void)resizeSelectedBy:(CGFloat)factor {
    if (!_editing || !_selectedControl) return;
    CGSize sz = _selectedControl.bounds.size;
    CGFloat size = MAX(26, MIN(self.bounds.size.height * .42, sz.height * factor));
    CGFloat aspect = sz.width / MAX(1, sz.height);
    _selectedControl.bounds = CGRectMake(0,0,size*aspect,size);
    [self saveLayout];
}
- (void)shrinkSelected:(id)sender { (void)sender; [self resizeSelectedBy:.90]; }
- (void)growSelected:(id)sender { (void)sender; [self resizeSelectedBy:1.10]; }
- (void)resetLayout:(id)sender {
    (void)sender;
    [_customLayout removeAllObjects];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"mhgu_touch_layout_v3"];
    [self setNeedsLayout];
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self resetAll];
    [_editFinger release];
    [_namedControls release];
    [_customLayout release];
    [_controls release];
    [super dealloc];
}
@end

static void poll_overlay_weapon(void) { [s_overlay syncWeapon]; }

void mhgu_touch_install(SDL_Window *window) {
    if (!window) return;
    // UIKit work must run on the UI thread. ui_init() is called there in this port.
    if (![NSThread isMainThread]) {
        // Never block the host thread: dispatch asynchronously to avoid a deadlock.
        dispatch_async(dispatch_get_main_queue(), ^{ mhgu_touch_install(window); });
        return;
    }
    if (s_overlay) return;
    SDL_PropertiesID props = SDL_GetWindowProperties(window);
    UIWindow *uiWindow = (__bridge UIWindow *)SDL_GetPointerProperty(
        props, SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
    if (!uiWindow) {
        NSLog(@"[MHGU Touch] SDL UIKit window unavailable; overlay not installed");
        return;
    }
    s_overlay = [[MHGUTouchRoot alloc] initWithFrame:uiWindow.bounds];
    [uiWindow addSubview:s_overlay];
    [s_overlay setNeedsLayout];
    [s_overlay layoutIfNeeded];
    NSLog(@"[MHGU Touch] Native touchscreen controller installed");
}
