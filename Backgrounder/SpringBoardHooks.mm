/**
 * Name: Backgrounder
 * Type: iPhone OS 2.x SpringBoard extension (MobileSubstrate-based)
 * Description: allow applications to run in the background
 * Author: Lance Fetters (aka. ashikase)
 * Last-modified: 2008-12-25 19:28:58
 */

/**
 * Copyright (C) 2008  Lance Fetters (aka. ashikase)
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in
 *    the documentation and/or other materials provided with the
 *    distribution.
 *
 * 3. The name of the author may not be used to endorse or promote
 *    products derived from this software without specific prior
 *    written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS
 * OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
 * IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

#import "SpringBoardHooks.h"

#include <signal.h>
#include <substrate.h>

#import <CoreFoundation/CFPreferences.h>

#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSRunLoop.h>
#import <Foundation/NSString.h>
#import <Foundation/NSTimer.h>

#import <SpringBoard/SBApplication.h>
#import <SpringBoard/SBApplicationController.h>
#import <SpringBoard/SBAlertItemsController.h>
#import <SpringBoard/SBDisplayStack.h>
#import <SpringBoard/SBStatusBarController.h>
#import <SpringBoard/SBUIController.h>
#import <SpringBoard/SpringBoard.h>

#import "SimplePopup.h"
#import "TaskMenuPopup.h"

struct GSEvent;


#define APP_ID "jp.ashikase.backgrounder"

#define HOOK(class, name, type, args...) \
    static type (*_ ## class ## $ ## name)(class *self, SEL sel, ## args); \
    static type $ ## class ## $ ## name(class *self, SEL sel, ## args)

#define CALL_ORIG(class, name, args...) \
    _ ## class ## $ ## name(self, sel, ## args)

#define SIMPLE_POPUP 0
#define TASK_MENU_POPUP 1
static int feedbackType = SIMPLE_POPUP;

#define HOME_SHORT_PRESS 0
#define HOME_SINGLE_TAP 1
#define HOME_DOUBLE_TAP 2
static int invocationMethod = HOME_SHORT_PRESS;

static NSMutableDictionary *activeApplications = nil;
static NSMutableDictionary *statusBarStates = nil;
static NSString *deactivatingApplication = nil;

//______________________________________________________________________________
//______________________________________________________________________________

NSMutableArray *displayStacks = nil;

HOOK(SBDisplayStack, alloc, id)
{
    id stack = CALL_ORIG(SBDisplayStack, alloc);
    [displayStacks addObject:stack];
    return stack;
}

HOOK(SBDisplayStack, dealloc, void)
{
    [displayStacks removeObject:self];
    CALL_ORIG(SBDisplayStack, dealloc);
}

//______________________________________________________________________________
//______________________________________________________________________________

HOOK(SBUIController, animateLaunchApplication$, void, id app)
{
    if ([app pid] != -1) {
        // Application is backgrounded; don't animate
        NSArray *state = [statusBarStates objectForKey:[app displayIdentifier]];
        [app setActivationSetting:0x40 value:[state objectAtIndex:0]]; // statusbarmode
        [app setActivationSetting:0x80 value:[state objectAtIndex:1]]; // statusBarOrienation
        [[displayStacks objectAtIndex:2] pushDisplay:app];
    } else {
        // Normal launch
        CALL_ORIG(SBUIController, animateLaunchApplication$, app);
    }
}

//______________________________________________________________________________
//______________________________________________________________________________

// The alert window displays instructions when the home button is held down
static NSTimer *invocationTimer = nil;
static BOOL invocationTimerDidFire = NO;
static id alert = nil;

static void cancelInvocationTimer()
{
    // Disable and release timer (may be nil)
    [invocationTimer invalidate];
    [invocationTimer release];
    invocationTimer = nil;
}

HOOK(SpringBoard, menuButtonDown$, void, GSEvent *event)
{
    NSLog(@"Backgrounder: %s", __FUNCTION__);

    // FIXME: If already invoked, should not set timer... right? (needs thought)
    if (invocationMethod == HOME_SHORT_PRESS) {
        if ([[displayStacks objectAtIndex:0] topApplication] != nil) {
            // Setup toggle-delay timer
            invocationTimer = [[NSTimer scheduledTimerWithTimeInterval:0.7f
                target:self selector:@selector(invokeBackgrounder)
                userInfo:nil repeats:NO] retain];
            invocationTimerDidFire = NO;
        }
    }

    CALL_ORIG(SpringBoard, menuButtonDown$, event);
}

HOOK(SpringBoard, menuButtonUp$, void, GSEvent *event)
{
    NSLog(@"Backgrounder: %s", __FUNCTION__);

    if (invocationMethod == HOME_SHORT_PRESS && !invocationTimerDidFire)
        // Stop activation timer
        cancelInvocationTimer();

    CALL_ORIG(SpringBoard, menuButtonUp$, event);
}

HOOK(SpringBoard, _handleMenuButtonEvent, void)
{
    // Handle single tap
    NSLog(@"Backgrounder: %s", __FUNCTION__);

    if ([[displayStacks objectAtIndex:0] topApplication] != nil) {
        // Is an application (not SpringBoard)
        Ivar ivar = class_getInstanceVariable([self class], "_menuButtonClickCount");
        unsigned int *_menuButtonClickCount = (unsigned int *)((char *)self + ivar_getOffset(ivar));
        NSLog(@"Backgrounder: current value of buttonclick is %08x", *_menuButtonClickCount);

        // FIXME: This should be rearranged/cleaned-up, if possible
        if (feedbackType == TASK_MENU_POPUP) {
            if (alert != nil) {
                // Task menu is visible
                // FIXME: with short press, the task menu may have just been
                // invoked...
                if (invocationTimerDidFire == NO)
                    // Hide and destroy the task menu
                    [self dismissBackgrounderFeedback];
                *_menuButtonClickCount = 0x8000;
                return;
            } else if (invocationMethod == HOME_SINGLE_TAP) {
                // Invoke Backgrounder
                [self invokeBackgrounder];
                *_menuButtonClickCount = 0x8000;
                return;
            }
            // Fall-through
        } else { // SIMPLE_POPUP
            // Stop hold timer
        }
        // Fall-through
    }

    CALL_ORIG(SpringBoard, _handleMenuButtonEvent);
}

HOOK(SpringBoard, handleMenuDoubleTap, void)
{
    NSLog(@"Backgrounder: %s", __FUNCTION__);

    if ([[displayStacks objectAtIndex:0] topApplication] != nil && alert == nil)
        // Is an application and popup is not visible; toggle backgrounding
        [self invokeBackgrounder];
    else {
        // Is SpringBoard or alert is visible; perform normal behaviour
        [self dismissBackgrounderFeedback];
        CALL_ORIG(SpringBoard, handleMenuDoubleTap);
    }
}

HOOK(SpringBoard, applicationDidFinishLaunching$, void, id application)
{
    // NOTE: SpringBoard creates five stacks at startup:
    //       - first: visible displays
    //       - third: displays being activated
    //       - xxxxx: displays being deactivated
    displayStacks = [[NSMutableArray alloc] initWithCapacity:5];

    // NOTE: The initial capacity value was chosen to hold the default active
    //       apps (SpringBoard, MobilePhone, and MobileMail) plus two others
    activeApplications = [[NSMutableDictionary alloc] initWithCapacity:5];
    // SpringBoard is always active
    [activeApplications setObject:[NSNumber numberWithBool:YES] forKey:@"com.apple.springboard"];

    // Create a dictionary to store the statusbar state for active apps
    // FIXME: Determine a way to do this without requiring extra storage
    statusBarStates = [[NSMutableDictionary alloc] initWithCapacity:5];

    // Load preferences
    CFPropertyListRef prefMethod = CFPreferencesCopyAppValue(CFSTR("invocationMethod"), CFSTR(APP_ID));
    if (prefMethod) {
        // NOTE: Defaults to HOME_SHORT_PRESS
        if ([(NSString *)prefMethod isEqualToString:@"homeDoubleTap"]) {
            invocationMethod = HOME_DOUBLE_TAP;
            _SpringBoard$handleMenuDoubleTap =
                MSHookMessage([self class], @selector(handleMenuDoubleTap), &$SpringBoard$handleMenuDoubleTap);
        } else if ([(NSString *)prefMethod isEqualToString:@"homeSingleTap"]) {
            invocationMethod = HOME_SINGLE_TAP;
        }
        CFRelease(prefMethod);
    }

    CFPropertyListRef prefFeedback = CFPreferencesCopyAppValue(CFSTR("feedbackType"), CFSTR(APP_ID));
    if (prefFeedback) {
        // NOTE: Defaults to SIMPLE_POPUP
        if ([(NSString *)prefFeedback isEqualToString:@"taskMenuPopup"])
            feedbackType = TASK_MENU_POPUP;
        CFRelease(prefFeedback);
    }

    if (feedbackType == TASK_MENU_POPUP)
        // Initialize task menu popup
        initTaskMenuPopup();
    else
        // Initialize simple notification popup
        initSimplePopup();

    CALL_ORIG(SpringBoard, applicationDidFinishLaunching$, application);
}

HOOK(SpringBoard, dealloc, void)
{
    [activeApplications release];
    [displayStacks release];
    CALL_ORIG(SpringBoard, dealloc);
}

static void $SpringBoard$invokeBackgrounder(SpringBoard *self, SEL sel)
{
    NSLog(@"Backgrounder: %s", __FUNCTION__);

    if (invocationMethod == HOME_SHORT_PRESS)
        invocationTimerDidFire = YES;

    id app = [[displayStacks objectAtIndex:0] topApplication];
    if (app) {
        NSString *identifier = [app displayIdentifier];
        if (feedbackType == SIMPLE_POPUP) {
            BOOL isEnabled = [[activeApplications objectForKey:identifier] boolValue];
            [self setBackgroundingEnabled:(!isEnabled) forDisplayIdentifier:identifier];

            // Display simple popup
            NSString *status = [NSString stringWithFormat:@"Backgrounding %s",
                     (isEnabled ? "Disabled" : "Enabled")];

            Class $BGAlertItem = objc_getClass("BackgrounderAlertItem");
            NSString *message = (invocationMethod == HOME_SHORT_PRESS) ? @"(Continue holding to force-quit)" : nil;
            alert = [[$BGAlertItem alloc] initWithTitle:status message:message];

            Class $SBAlertItemsController(objc_getClass("SBAlertItemsController"));
            SBAlertItemsController *controller = [$SBAlertItemsController sharedInstance];
            [controller activateAlertItem:alert];
            if (invocationMethod == HOME_DOUBLE_TAP)
                [self performSelector:@selector(dismissBackgrounderFeedback) withObject:nil afterDelay:1.0];
        } else if (feedbackType == TASK_MENU_POPUP) {
            // Display task menu popup
            NSMutableArray *array = [NSMutableArray arrayWithArray:[activeApplications allKeys]];
            // This array will be used for "other apps", so remove the active app
            [array removeObject:identifier];
            // SpringBoard should always be first in the list
            int index = [array indexOfObject:@"com.apple.springboard"];
            [array exchangeObjectAtIndex:index withObjectAtIndex:0];

            Class $SBAlert = objc_getClass("BackgrounderAlert");
            alert = [[$SBAlert alloc] initWithCurrentApp:identifier otherApps:array];
            [alert activate];
        }
    }
}

static void $SpringBoard$dismissBackgrounderFeedback(SpringBoard *self, SEL sel)
{
    // FIXME: If feedback types other than simple and task-menu are added,
    //        this method will need to be updated

    // Hide and release alert window (may be nil)
    if (feedbackType == TASK_MENU_POPUP)
        [[alert display] dismiss];
    else
        [alert dismiss];
    [alert release];
    alert = nil;
}

static void $SpringBoard$setBackgroundingEnabled$forDisplayIdentifier$(SpringBoard *self, SEL sel, BOOL enable, NSString *identifier)
{
    NSNumber *object = [activeApplications objectForKey:identifier];
    if (object != nil) {
        BOOL isEnabled = [object boolValue];
        if (isEnabled != enable) {
            // Tell the application to change its backgrounding status
            Class $SBApplicationController(objc_getClass("SBApplicationController"));
            SBApplicationController *appCont = [$SBApplicationController sharedInstance];
            SBApplication *app = [appCont applicationWithDisplayIdentifier:identifier];
            // FIXME: If the target application does not have the Backgrounder
            //        hooks enabled, this will cause it to exit abnormally
            kill([app pid], SIGUSR1);

            // Store the new backgrounding status of the application
            [activeApplications setObject:[NSNumber numberWithBool:(!isEnabled)]
                forKey:identifier];
        }
    }
}

static void $SpringBoard$switchToAppWithDisplayIdentifier$(SpringBoard *self, SEL sel, NSString *identifier)
{
    SBApplication *currApp = [[displayStacks objectAtIndex:0] topApplication];
    NSString *currIdent = [currApp displayIdentifier];
    NSLog(@"Backgrounder: current id: %@, new id: %@", currIdent, identifier);
    if (![currIdent isEqualToString:identifier]) {
        // Save the identifier for later use
        deactivatingApplication = [currIdent copy];

        // If the current app will be backgrounded, store the status bar state
        if ([activeApplications objectForKey:currIdent]) {
            Class $SBStatusBarController(objc_getClass("SBStatusBarController"));
            SBStatusBarController *sbCont = [$SBStatusBarController sharedStatusBarController];
            NSNumber *mode = [NSNumber numberWithInt:[sbCont statusBarMode]];
            NSNumber *orientation = [NSNumber numberWithInt:[sbCont statusBarOrientation]];
            [statusBarStates setObject:[NSArray arrayWithObjects:mode, orientation, nil] forKey:currIdent];
        }

        if ([identifier isEqualToString:@"com.apple.springboard"]) {
            Class $SBUIController(objc_getClass("SBUIController"));
            SBUIController *uiCont = [$SBUIController sharedInstance];
            [uiCont quitTopApplication];
        } else {
            // NOTE: Must set animation flag for deactivation, otherwise
            //       application window does not disappear (reason yet unknown)
            [currApp setDeactivationSetting:0x2 flag:YES]; // animate
            //[currApp setDeactivationSetting:0x400 flag:YES]; // returnToLastApp
            //[currApp setDeactivationSetting:0x10000 flag:YES]; // appToApp
            //[currApp setDeactivationSetting:0x0100 value:[NSNumber numberWithDouble:0.1]]; // animation scale
            //[currApp setDeactivationSetting:0x4000 value:[NSNumber numberWithDouble:0.4]]; // animation duration
            //[currApp setDeactivationSetting:0x0100 value:[NSNumber numberWithDouble:1.0]]; // animation scale
            //[currApp setDeactivationSetting:0x4000 value:[NSNumber numberWithDouble:0]]; // animation duration

            if (![identifier isEqualToString:@"com.apple.springboard"]) {
                // Switching to an application other than SpringBoard
                Class $SBApplicationController(objc_getClass("SBApplicationController"));
                SBApplicationController *appCont = [$SBApplicationController sharedInstance];
                SBApplication *otherApp = [appCont applicationWithDisplayIdentifier:identifier];

                if (otherApp) {
                    //[otherApp setActivationSetting:0x4 flag:YES]; // animated
                    // NOTE: setting lastApp and appToApp (and the related
                    //       deactivation flags above) gives an interesting
                    //       switching effect; however, it does not seem to work
                    //       with animatedNoPNG, and thus makes it appear that the
                    //       application being switched to has been restarted.
                    //[otherApp setActivationSetting:0x20000 flag:YES]; // animatedNoPNG
                    //[otherApp setActivationSetting:0x10000 flag:YES]; // lastApp
                    //[otherApp setActivationSetting:0x20000000 flag:YES]; // appToApp
                    NSArray *state = [statusBarStates objectForKey:identifier];
                    [otherApp setActivationSetting:0x40 value:[state objectAtIndex:0]]; // statusbarmode
                    [otherApp setActivationSetting:0x80 value:[state objectAtIndex:1]]; // statusBarOrienation

                    // Activate the new app
                    [[displayStacks objectAtIndex:2] pushDisplay:otherApp];
                }
            }

            // Deactivate the current app
            [[displayStacks objectAtIndex:3] pushDisplay:currApp];
        }
    } else {
        // Application to switch to is same as current
        [self dismissBackgrounderFeedback];
    }
}

static void $SpringBoard$quitAppWithDisplayIdentifier$(SpringBoard *self, SEL sel,NSString *identifier)
{
    Class $SBApplicationController(objc_getClass("SBApplicationController"));
    SBApplicationController *appCont = [$SBApplicationController sharedInstance];
    SBApplication *app = [appCont applicationWithDisplayIdentifier:identifier];

    if (app) {
        // Disable backgrounding for the application
        [self setBackgroundingEnabled:NO forDisplayIdentifier:identifier];

        // NOTE: Must set animation flag for deactivation, otherwise
        //       application window does not disappear (reason yet unknown)
        [app setDeactivationSetting:0x2 flag:YES]; // animate
        [app setDeactivationSetting:0x4000 value:[NSNumber numberWithDouble:0]]; // animation duration

        // Deactivate the application
        [[displayStacks objectAtIndex:3] pushDisplay:app];
    }
}

//______________________________________________________________________________
//______________________________________________________________________________

HOOK(SBApplication, shouldLaunchPNGless, BOOL)
{
    // Only show splash-screen on initial launch
    return ([self pid] != -1) ? YES : CALL_ORIG(SBApplication, shouldLaunchPNGless);
}

HOOK(SBApplication, launchSucceeded, void)
{
    NSString *identifier = [self displayIdentifier];
    if ([activeApplications objectForKey:identifier] == nil) {
        // Initial launch; check if this application defaults to backgrounding
        CFPropertyListRef array = CFPreferencesCopyAppValue(CFSTR("enabledApplications"), CFSTR(APP_ID));
        if (array) {
            if ([(NSArray *)array containsObject:identifier]) {
                // Tell the application to enable backgrounding
                kill([self pid], SIGUSR1);

                // Store the backgrounding status of the application
                [activeApplications setObject:[NSNumber numberWithBool:YES] forKey:identifier];
            } else {
                [activeApplications setObject:[NSNumber numberWithBool:NO] forKey:identifier];
            }
            CFRelease(array);
        } else {
            [activeApplications setObject:[NSNumber numberWithBool:NO] forKey:identifier];
        }
    }

    CALL_ORIG(SBApplication, launchSucceeded);
}

HOOK(SBApplication, exitedCommon, void)
{
    // Application has exited (either normally or abnormally);
    // remove from active applications list
    NSString *identifier = [self displayIdentifier];
    [activeApplications removeObjectForKey:identifier];

    // ... also remove status bar state data from states list
    [statusBarStates removeObjectForKey:identifier];

    CALL_ORIG(SBApplication, exitedCommon);
}

HOOK(SBApplication, deactivate, BOOL)
{
    if ([[self displayIdentifier] isEqualToString:deactivatingApplication]) {
        Class $SpringBoard(objc_getClass("SpringBoard"));
        [[$SpringBoard sharedApplication] dismissBackgrounderFeedback];
        [deactivatingApplication release];
        deactivatingApplication = nil;
    }

    // If the app will be backgrounded, store the status bar state
    NSString *identifier = [self displayIdentifier];
    if ([activeApplications objectForKey:identifier]) {
        Class $SBStatusBarController(objc_getClass("SBStatusBarController"));
        SBStatusBarController *sbCont = [$SBStatusBarController sharedStatusBarController];
        NSNumber *mode = [NSNumber numberWithInt:[sbCont statusBarMode]];
        NSNumber *orientation = [NSNumber numberWithInt:[sbCont statusBarOrientation]];
        [statusBarStates setObject:[NSArray arrayWithObjects:mode, orientation, nil] forKey:identifier];
    }

    return CALL_ORIG(SBApplication, deactivate);
}

HOOK(SBApplication, _startTerminationWatchdogTimer, void)
{
    BOOL isBackgroundingEnabled = [[activeApplications objectForKey:[self displayIdentifier]] boolValue];
    if (!isBackgroundingEnabled)
        CALL_ORIG(SBApplication, _startTerminationWatchdogTimer);
}

//______________________________________________________________________________
//______________________________________________________________________________

void initSpringBoardHooks()
{
    Class $SBDisplayStackMeta(objc_getMetaClass("SBDisplayStack"));
    _SBDisplayStack$alloc =
        MSHookMessage($SBDisplayStackMeta, @selector(alloc), &$SBDisplayStack$alloc);

    Class $SBDisplayStack(objc_getClass("SBDisplayStack"));
    _SBDisplayStack$dealloc =
        MSHookMessage($SBDisplayStack, @selector(dealloc), &$SBDisplayStack$dealloc);

    Class $SBUIController(objc_getClass("SBUIController"));
    _SBUIController$animateLaunchApplication$ =
        MSHookMessage($SBUIController, @selector(animateLaunchApplication:), &$SBUIController$animateLaunchApplication$);

    Class $SpringBoard(objc_getClass("SpringBoard"));
    _SpringBoard$applicationDidFinishLaunching$ =
        MSHookMessage($SpringBoard, @selector(applicationDidFinishLaunching:), &$SpringBoard$applicationDidFinishLaunching$);
    _SpringBoard$dealloc =
        MSHookMessage($SpringBoard, @selector(dealloc), &$SpringBoard$dealloc);
    _SpringBoard$menuButtonDown$ =
        MSHookMessage($SpringBoard, @selector(menuButtonDown:), &$SpringBoard$menuButtonDown$);
    _SpringBoard$menuButtonUp$ =
        MSHookMessage($SpringBoard, @selector(menuButtonUp:), &$SpringBoard$menuButtonUp$);
    _SpringBoard$_handleMenuButtonEvent =
        MSHookMessage($SpringBoard, @selector(_handleMenuButtonEvent), &$SpringBoard$_handleMenuButtonEvent);

    class_addMethod($SpringBoard, @selector(setBackgroundingEnabled:forDisplayIdentifier:),
        (IMP)&$SpringBoard$setBackgroundingEnabled$forDisplayIdentifier$, "v@:c@");
    class_addMethod($SpringBoard, @selector(invokeBackgrounder), (IMP)&$SpringBoard$invokeBackgrounder, "v@:");
    class_addMethod($SpringBoard, @selector(dismissBackgrounderFeedback), (IMP)&$SpringBoard$dismissBackgrounderFeedback, "v@:");
    class_addMethod($SpringBoard, @selector(switchToAppWithDisplayIdentifier:), (IMP)&$SpringBoard$switchToAppWithDisplayIdentifier$, "v@:@");
    class_addMethod($SpringBoard, @selector(quitAppWithDisplayIdentifier:), (IMP)&$SpringBoard$quitAppWithDisplayIdentifier$, "v@:@");

    Class $SBApplication(objc_getClass("SBApplication"));
    _SBApplication$shouldLaunchPNGless =
        MSHookMessage($SBApplication, @selector(shouldLaunchPNGless), &$SBApplication$shouldLaunchPNGless);
    _SBApplication$launchSucceeded =
        MSHookMessage($SBApplication, @selector(launchSucceeded), &$SBApplication$launchSucceeded);
    _SBApplication$deactivate =
        MSHookMessage($SBApplication, @selector(deactivate), &$SBApplication$deactivate);
    _SBApplication$exitedCommon =
        MSHookMessage($SBApplication, @selector(exitedCommon), &$SBApplication$exitedCommon);
    _SBApplication$_startTerminationWatchdogTimer =
        MSHookMessage($SBApplication, @selector(_startTerminationWatchdogTimer), &$SBApplication$_startTerminationWatchdogTimer);
}

/* vim: set syntax=objcpp sw=4 ts=4 sts=4 expandtab textwidth=80 ff=unix: */
