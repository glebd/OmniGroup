// Copyright 1997-2012 Omni Development, Inc. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.

#import <OmniAppKit/OAApplication.h>
#import <OmniAppKit/OAVersion.h>

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <OmniBase/OmniBase.h>
#import <OmniFoundation/OmniFoundation.h>
#import <OmniAppKit/NSResponder-OAExtensions.h>

#import <Carbon/Carbon.h>
#import <ExceptionHandling/NSExceptionHandler.h>

#import "NSView-OAExtensions.h"
#import "NSWindow-OAExtensions.h"
#import "NSImage-OAExtensions.h"
#import "OAAppKitQueueProcessor.h"
#import "OAPreferenceController.h"
#import "OASheetRequest.h"
#import "NSEvent-OAExtensions.h"

RCS_ID("$Id$")

NSString * const OAFlagsChangedNotification = @"OAFlagsChangedNotification";
NSString * const OAFlagsChangedQueuedNotification = @"OAFlagsChangedNotification (Queued)";

@interface OAApplication (/*Private*/)
+ (void)_setupOmniApplication;
- (void)processMouseButtonsChangedEvent:(NSEvent *)event;
- (void)_scheduleModalPanelWithInvocation:(NSInvocation *)modalInvocation;
- (void)_rescheduleModalPanel:(NSTimer *)timer;
@end

static NSUInteger launchModifierFlags;
static BOOL OATargetSelection;

BOOL OATargetSelectionEnabled(void)
{
    [OAApplication sharedApplication]; // Make sure global is set up.
    return OATargetSelection;
}

@implementation OAApplication

+ (void)initialize;
{
    OBINITIALIZE;

    launchModifierFlags = [NSEvent modifierFlags];
}

static NSImage *HelpIcon = nil;
static NSImage *CautionIcon = nil;

#pragma mark -
#pragma mark NSApplication subclass

+ (NSApplication *)sharedApplication;
{
    static OAApplication *omniApplication = nil;

    if (omniApplication)
        return omniApplication;

    omniApplication = (id)[super sharedApplication];
    [self _setupOmniApplication];
    return omniApplication;
}

+ (void)workAroundCocoaScriptingLazyInitBug;
{
    // This is a workaround for <rdar://problem/7257705>.
    // Cocoa scripting initialization is too lazy, and things are not set up correctly for custom receivers of the 'open' command.
    // The symptom is that if your first interaction with the application is:
    // 
    //    tell application "OmniFocus"
    //        open quick entry
    //    end tell
    //        
    // that it just fails (without error on 10.6, with an error on 10.5)
    // 
    // Any other event not in the required suite (even one implemented by a scripting addition) kicks things into the working state.
    // Forcing the shared instance of the script suite registry to come into existance also works around the problem. (This costs us a few hundreths of a second at startup.)

    [NSScriptSuiteRegistry sharedScriptSuiteRegistry];
}

- (void)dealloc;
{
    [exceptionCheckpointDate release];
    [windowsForSheets release];
    [sheetQueue release];
    [super dealloc];
}

- (void)finishLaunching;
{
    windowsForSheets = NSCreateMapTable(NSObjectMapKeyCallBacks, NSObjectMapValueCallBacks, 0);
    sheetQueue = [[NSMutableArray alloc] init];

    [super finishLaunching];

    [[self class] workAroundCocoaScriptingLazyInitBug];
}

- (void)run;
{
    exceptionCount = 0;
    exceptionCheckpointDate = [[NSDate alloc] init];
    do {
        NS_DURING {
            [super run];
            NS_VOIDRETURN;
        } NS_HANDLER {
            if (++exceptionCount >= 300) {
                if ([exceptionCheckpointDate timeIntervalSinceNow] >= -3.0) {
                    // 300 unhandled exceptions in 3 seconds: abort
                    fprintf(stderr, "Caught 300 unhandled exceptions in 3 seconds, aborting\n");
                    return;
                }
                [exceptionCheckpointDate release];
                exceptionCheckpointDate = [[NSDate alloc] init];
                exceptionCount = 0;
            }
            if (localException) {
                if ([self isRunning])
                    [self handleRunException:localException];
                else
                    [self handleInitException:localException];
            }
        } NS_ENDHANDLER;
    } while ([self isRunning]);
}

// This is for the benefit of -miniaturizeWindows: below.
static NSArray *overrideWindows = nil;
- (NSArray *)windows;
{
    if (overrideWindows)
        return overrideWindows;
    return [super windows];
}

- (void)beginSheet:(NSWindow *)sheet modalForWindow:(NSWindow *)docWindow modalDelegate:(id)modalDelegate didEndSelector:(SEL)didEndSelector contextInfo:(void *)contextInfo;
{
    if ([NSAllMapTableValues(windowsForSheets) indexOfObjectIdenticalTo:docWindow] != NSNotFound) {
        // This window already has a sheet, we need to wait for it to finish
        [sheetQueue addObject:[OASheetRequest sheetRequestWithSheet:sheet modalForWindow:docWindow modalDelegate:modalDelegate didEndSelector:didEndSelector contextInfo:contextInfo]];
    } else {
        if (docWindow != nil)
            NSMapInsertKnownAbsent(windowsForSheets, sheet, docWindow);
        [super beginSheet:sheet modalForWindow:docWindow modalDelegate:modalDelegate didEndSelector:didEndSelector contextInfo:contextInfo];
    }
}

- (void)endSheet:(NSWindow *)sheet returnCode:(NSInteger)returnCode;
{
    // Find the document window associated with the sheet we just ended
    NSWindow *docWindow = [[(NSWindow *)NSMapGet(windowsForSheets, sheet) retain] autorelease];
    NSMapRemove(windowsForSheets, sheet);
    
    // End this sheet
    [super endSheet:sheet returnCode:returnCode]; // Note: This runs the event queue itself until the sheet finishes retracting

    // See if we have another sheet queued for this document window
    OASheetRequest *queuedSheet = nil;
    NSUInteger requestIndex, requestCount = [sheetQueue count];
    for (requestIndex = 0; requestIndex < requestCount; requestIndex++) {
        OASheetRequest *request;

        request = [sheetQueue objectAtIndex:requestIndex];
        if ([request docWindow] == docWindow) {
            queuedSheet = [request retain];
            [sheetQueue removeObjectAtIndex:requestIndex];
            break;
        }
    }

    // Start the queued sheet
    [queuedSheet beginSheet];
    [queuedSheet release];
}

#ifdef CustomScrollWheelHandling

#define MAXIMUM_LINE_FACTOR 12.0
#define PAGE_FACTOR MAXIMUM_LINE_FACTOR * 2.0 * 2.0 * 2.0
#define ACCELERATION 2.0
#define MAX_SCALE_SETTINGS 12

static struct {
    float targetScrollFactor;
    float timeSinceLastScroll;
} mouseScaling[MAX_SCALE_SETTINGS] = {
    {1.0, 0.0}
};

static void OATargetScrollFactorReadFromDefaults(void)
{
    NSArray *values;
    unsigned int settingIndex, valueCount;
    NSString *defaultsKey;

    defaultsKey = @"OAScrollWheelTargetScrollFactor";
    values = [[NSUserDefaults standardUserDefaults] arrayForKey:defaultsKey];
    if (values == nil)
        return;
    valueCount = [values count];
    for (settingIndex = 0; settingIndex < MAX_SCALE_SETTINGS; settingIndex++) {
        unsigned int factorValueIndex;
        float factor, cutoff;

        factorValueIndex = settingIndex * 2;
        factor = factorValueIndex < valueCount ? [[values objectAtIndex:factorValueIndex] floatValue] : 0.0;
        cutoff = factorValueIndex + 1 < valueCount ? (1.0 / [[values objectAtIndex:factorValueIndex + 1] floatValue]) : 0.0;
        mouseScaling[settingIndex].targetScrollFactor = factor;
        mouseScaling[settingIndex].timeSinceLastScroll = cutoff;
    }
}

static float OATargetScrollFactorForTimeInterval(NSTimeInterval timeSinceLastScroll)
{
    static BOOL alreadyInitialized = NO;
    unsigned int mouseScalingIndex;

    if (!alreadyInitialized) {
        OATargetScrollFactorReadFromDefaults();
        alreadyInitialized = YES;
    }
    for (mouseScalingIndex = 0;
         mouseScalingIndex < MAX_SCALE_SETTINGS && MAX(0.0, timeSinceLastScroll) < mouseScaling[mouseScalingIndex].timeSinceLastScroll;
         mouseScalingIndex++) {
    }

    return mouseScaling[mouseScalingIndex].targetScrollFactor;
}

static float OAScrollFactorForWheelEvent(NSEvent *event)
{
    static NSTimeInterval lastScrollWheelTimeInterval = 0.0;
    static float scrollFactor = 100.0;
    NSTimeInterval timestamp;
    NSTimeInterval timeSinceLastScroll;
    float targetScrollFactor;
    
    timestamp = [event timestamp];
    timeSinceLastScroll = timestamp - lastScrollWheelTimeInterval;
    targetScrollFactor = OATargetScrollFactorForTimeInterval(timeSinceLastScroll);
    lastScrollWheelTimeInterval = timestamp;
    if (scrollFactor == targetScrollFactor) {
        // Do nothing
    } else if (timeSinceLastScroll > 0.5) {
        // If it's been more than half a second, just start over at the target factor
        scrollFactor = targetScrollFactor;
    } else if (scrollFactor * (1.0 / ACCELERATION) > targetScrollFactor) {
        // Reduce our scroll factor
        scrollFactor *= (1.0 / ACCELERATION);
    } else if (scrollFactor * ACCELERATION < targetScrollFactor) {
        // Increase our scroll factor
        scrollFactor *= ACCELERATION;
    } else {
        // The target is near, just jump to it
        scrollFactor = targetScrollFactor;
    }
    return scrollFactor;
}
#endif

#define OASystemDefinedEvent_MouseButtonsChangedSubType 7

static NSArray *flagsChangedRunLoopModes;

- (void)sendEvent:(NSEvent *)event;
{
    // The -timestamp method on NSEvent doesn't seem to return an NSTimeInterval based off the same reference date as NSDate (which is what we want).
    lastEventTimeInterval = [NSDate timeIntervalSinceReferenceDate];

    NS_DURING {
        switch ([event type]) {
            case NSSystemDefined:
                if ([event subtype] == OASystemDefinedEvent_MouseButtonsChangedSubType)
                    [self processMouseButtonsChangedEvent:event];
                [super sendEvent:event];
                break;
            case NSFlagsChanged:
                [super sendEvent:event];
                [[NSNotificationCenter defaultCenter] postNotificationName:OAFlagsChangedNotification object:event];
                if (!flagsChangedRunLoopModes)
                    flagsChangedRunLoopModes = [[NSArray alloc] initWithObjects:
                                                NSDefaultRunLoopMode,
                                                NSRunLoopCommonModes,
                                                NSEventTrackingRunLoopMode, nil];
                [[NSNotificationQueue defaultQueue] enqueueNotification:[NSNotification notificationWithName:OAFlagsChangedQueuedNotification object:event]
                                                           postingStyle:NSPostWhenIdle
                                                           coalesceMask:NSNotificationCoalescingOnName
                                                               forModes:flagsChangedRunLoopModes];
                break;
            case NSLeftMouseDown:
            {
                NSUInteger modifierFlags = [event modifierFlags];
                BOOL justControlDown = (modifierFlags & NSControlKeyMask) && !(modifierFlags & NSShiftKeyMask) && !(modifierFlags & NSCommandKeyMask) && !(modifierFlags & NSAlternateKeyMask);
                
                if (justControlDown) {
                    NSView *contentView = [[event window] contentView];
                    NSView *viewUnderMouse = [contentView hitTest:[event locationInWindow]];
                    
                    if (viewUnderMouse != nil && [viewUnderMouse respondsToSelector:@selector(controlMouseDown:)]) {
                        [viewUnderMouse controlMouseDown:event];
                        NS_VOIDRETURN;
                    }
                }
                [super sendEvent:event];
                    
                break;
            }
                        
            default:
                [super sendEvent:event];
                break;
        }
    } NS_HANDLER {
        if ([[localException name] isEqualToString:NSAbortModalException] || [[localException name] isEqualToString:NSAbortPrintingException])
            [localException raise];
        [self handleRunException:localException];
    } NS_ENDHANDLER;

    [[OFScheduler mainScheduler] scheduleEvents]; // Ping the scheduler, in case the system clock changed
}

BOOL OADebugTargetSelection = NO;
#define DEBUG_TARGET_SELECTION(format, ...) do { \
    if (OADebugTargetSelection) \
        NSLog((format), ## __VA_ARGS__); \
} while (0)

- (BOOL)sendAction:(SEL)theAction to:(id)theTarget from:(id)sender;
{
    if (OATargetSelection) {
        // The normal NSApplication version, sadly, uses internal target lookup for the nil case. It should really call -targetForAction:to:from:.
        if (!theTarget)
            theTarget = [self targetForAction:theAction to:nil from:sender];
    }
    
    return [super sendAction:theAction to:theTarget from:sender];
}

// Just does our portion of the chain.
- (BOOL)applyToResponderChain:(OAResponderChainApplier)applier;
{
    if (![super applyToResponderChain:applier])
        return NO;
    
    id delegate = (id)self.delegate;
    if (delegate)
        DEBUG_TARGET_SELECTION(@"---> checking OAApplication delegate ");
    if (delegate && ![delegate applyToResponderChain:applier])
        return NO;
    
    return YES;
}

// Does the full search documented for -targetForAction:to:from:
static void _applyFullSearch(OAApplication *self, SEL theAction, id theTarget, id sender, OAResponderChainApplier applier)
{
    NSWindow *mainWindow = [self mainWindow];
    NSWindow *keyWindow = [self keyWindow];
    
    // a modal key window should go through its responder chain, self, and delegate, but not the mainWindow, application or document controller.
    if (keyWindow && keyWindow == [self modalWindow]) {
        [keyWindow.firstResponder applyToResponderChain:applier]; 
        return;
    }    

    // Try *just* the first responder on the key window, if it is different from the main window.
    if (keyWindow.firstResponder && keyWindow != mainWindow && !applier(keyWindow.firstResponder))
        return;

    // NSApp class reference: "If the delegate cannot handle the message and the main window is different from the key window, NSApp begins searching again with the first responder in the main window".  Experimentally, this is not true if the key window is a sheet.  That makes sense since if the sheet is key, the window it covers is the mainWindow and the sheet conceptually blocks actions to it.  However with super's implementation, mainWindow is the chosen target for toggleUsingSmallToolbarIcons:.  NSWindow responds to toggleUsingSmallToolbarIcons by sending its toolbar a setSizeMode:. The NSToolbarConfigSheet is a window but does not _have_ a toolbar. It is key but not main. Therefore the keywindow's responder chain must not be responsible if it's a sheet. However, if the keyWindow has a first responder that's, say, a text field, paste: must be valid.  So here we try the sheets' firstResponder, then the mainWindow itself (_not_ its responder chain), then the keyWindow's responder chain, and if nobody has eaten it by then, the main window's first responder chain (then the document controller and the app itself)..
    if (keyWindow != mainWindow && [keyWindow isSheet] && ![self modalWindow] && !applier(mainWindow)) {
        return;
    }
    
    // Follow the normal set of fallbacks as documented for this method on NSApplication.  Terminate if the applier stops (which might be due to finding a target or might be due to one of the candidates claiming the action but refusing to do it).
    if (keyWindow.firstResponder && ![keyWindow.firstResponder applyToResponderChain:applier])
        return;
    
    if (keyWindow != mainWindow) {
         if (![keyWindow isSheet] && ![self modalWindow] && mainWindow.firstResponder && ![mainWindow.firstResponder applyToResponderChain:applier])
            return;
    }

    // This isn't ideal since this forces an NSDocumentController to be created.  AppKit presumably has some magic to avoid this...  We could avoid this if there are no registered document types, if that becomes an issue.
    NSDocumentController *documentController = [NSDocumentController sharedDocumentController];
    if (documentController && ![documentController applyToResponderChain:applier])
        return;
    
    [self applyToResponderChain:applier];
}

- (id)targetForAction:(SEL)theAction to:(id)theTarget from:(id)sender;
{
    if (!theAction || !OATargetSelection)
        return [super targetForAction:theAction to:theTarget from:sender];
    
    __block id target = nil;
    
    DEBUG_TARGET_SELECTION(@"looking for target for action: %@ given\n   target:%@\n    sender:%@\n    keyWindow first responder:%@\n    mainWindow first responder:%@)", NSStringFromSelector(theAction), [theTarget shortDescription], [sender shortDescription], [[[self keyWindow] firstResponder] shortDescription], [[[self mainWindow] firstResponder] shortDescription]);
    
    OAResponderChainApplier applier = ^(id object){
        DEBUG_TARGET_SELECTION(@" ... trying %@", [object shortDescription]);
        id responsible = [object responsibleTargetForAction:theAction sender:sender];
        
#if defined(MAC_OS_X_VERSION_10_7) && MAC_OS_X_VERSION_10_7 <= MAC_OS_X_VERSION_MIN_REQUIRED
        // Use the supplementalTargetForAction mechanism that was introduced in 10.7 to look for delegates and other helper objects attached to responders, but still use our OATargetSelection approach of requiring objects to override responsibleTargetForAction if they wish to terminate the search.
        if (!responsible && [object isKindOfClass:[NSResponder class]]) {
            responsible = [(NSResponder *)object supplementalTargetForAction:theAction sender:sender];
            if (responsible)
                DEBUG_TARGET_SELECTION(@"      ... got supplementalTarget: %@", [responsible shortDescription]);
            responsible = [responsible responsibleTargetForAction:theAction sender:sender];
        }
#endif
        
        if (responsible) {
            // Someone claimed to be responsible for the action.  The sender will re-validate with any appropriate means and might still get refused, but we should stop iterating.
            DEBUG_TARGET_SELECTION(@"      ... got responsible target: %@", responsible);
            target = responsible;
            return NO; // stop the search
        }
        return YES; // continue searching
    };
    
    // The caller had a specific target in mind.  Start there and follow the responder chain.  The documentation states that if the target is non-nil, it is returned (which is silly since why would you call this method then?)
    if (theTarget)
        [theTarget applyToResponderChain:applier];
    else
        _applyFullSearch(self, theAction, theTarget, sender, applier);
    
    DEBUG_TARGET_SELECTION(@" ... using %@", [target shortDescription]);
    return target;
}

- (void)reportException:(NSException *)anException;
{
    if (currentRunExceptionPanel) {
        // Already handling an exception!
        NSLog(@"Ignoring exception raised while displaying previous exception: %@", anException);
        return;
    }

    @try {
        // Let OFController have a crack at this.  It may decide it wants to up and crash to report uncaught exceptions back to home base.  Strange, but we'll cover our bases here.  Do our alert regardless of the result, which is intended to control whether AppKit logs the message (but we are displaying UI, not just spewing to Console).
        // Pass NSLogUncaughtExceptionMask to simulate a totally uncaught exception, even though AppKit has a top-level handler.  This will cause OFController to get the exception two times; once with NSLogOtherExceptionMask (ignored, since it might be caught) and here with NSLogUncaughtExceptionMask (it turned out to not get caught).  One bonus is that since it is the same exception, the NSStackTraceKey is in place and has the location of the original exception raise point.
        [[OFController sharedController] exceptionHandler:[NSExceptionHandler defaultExceptionHandler] shouldLogException:anException mask:NSLogUncaughtExceptionMask];

        id delegate = [self delegate];
        if ([delegate respondsToSelector:@selector(handleRunException:)]) {
            [delegate handleRunException:anException];
        } else {
            NSLog(@"%@", [anException reason]);

            // Do NOT use NSRunAlertPanel.  If another exception happens while NSRunAlertPanel is going, the alert will be removed from the screen and the user will not be able to report the original exception!
            // NSGetAlertPanel will not have a default button if we pass nil.
            NSString *okString = NSLocalizedStringFromTableInBundle(@"OK", @"OmniAppKit", [OAApplication bundle], "unhandled exception panel button");
            currentRunExceptionPanel = NSGetAlertPanel(nil, @"%@", okString, nil, nil, [anException reason]);
            [currentRunExceptionPanel center];
            [currentRunExceptionPanel makeKeyAndOrderFront:self];

            // The documentation for this method says that -endModalSession: must be before the NS_ENDHANDLER.
            NSModalSession modalSession = [self beginModalSessionForWindow:currentRunExceptionPanel];

            NSInteger ret = NSAlertErrorReturn;
            while (ret != NSAlertDefaultReturn) {
                NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
                @try {
                    // Might be NSAlertErrorReturn or NSRunContinuesResponse experimental evidence shows that it returns NSRunContinuesResponse if an exception was raised inside calling it (and it doesn't re-raise the exception since it returns).  We'll not assume this, though and we'll put this in a handler.
                    ret = [self runModalSession:modalSession];
                } @catch (NSException *localException) {
                    // Exception might get caught and passed to us by some other code (since this method is public).  So, our nesting avoidance is at the top of the method instead of in this handler block.
                    [self reportException:localException];
                    ret = NSAlertErrorReturn;
                }

                // Since we keep looping until the user clicks the button (rather than hiding the error panel at the first sign of trouble), we don't want to eat all the CPU needlessly.
                [NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
                [pool release];
            }
            
            [self endModalSession:modalSession];
            [currentRunExceptionPanel orderOut:nil];
            NSReleaseAlertPanel(currentRunExceptionPanel);
            currentRunExceptionPanel = nil;
        }
    } @catch (NSException *exc) {
        // Exception might get caught and passed to us by some other code (since this method is public).  So, our nesting avoidance is at the top of the method instead of in this handler block.
        [self reportException:exc];
    }
}

#pragma mark NSResponder subclass

- (void)presentError:(NSError *)error modalForWindow:(NSWindow *)window delegate:(id)delegate didPresentSelector:(SEL)didPresentSelector contextInfo:(void *)contextInfo;
{
    OBPRECONDITION(error); // The superclass will call CFRetain and we'll crash if this is nil.
    
    // If you want to pass nil/NULL, could call the simpler method above.
    OBPRECONDITION(delegate);
    OBPRECONDITION(didPresentSelector);
    
    if (!error) {
        NSLog(@"%s called with a nil error", __PRETTY_FUNCTION__);
        NSBeep();
        return;
    }
    
    // nil/NULL here can crash in the superclass crash trying to build an NSInvocation from this goop.  Let's not.
    if (!delegate) {
        delegate = self;
        didPresentSelector = @selector(noop_didPresentErrorWithRecovery:contextInfo:); // From NSResponder(OAExtensions)
    }
    
    // Log all errors so users can report them.
    if (![error causedByUserCancelling])
        NSLog(@"Presenting application modal error for window %@: %@", [window title], [error toPropertyList]);
    [super presentError:error modalForWindow:window delegate:delegate didPresentSelector:didPresentSelector contextInfo:contextInfo];
}

- (BOOL)presentError:(NSError *)error;
{
    // Log all errors so users can report them.
    if (![error causedByUserCancelling])
        NSLog(@"Presenting modal error: %@", [error toPropertyList]);
    return [super presentError:error];
}

#pragma mark -
#pragma mark API

- (void)handleInitException:(NSException *)anException;
{
    id delegate;
    
    delegate = [self delegate];
    if ([delegate respondsToSelector:@selector(handleInitException:)]) {
        [delegate handleInitException:anException];
    } else {
        NSLog(@"%@", [anException reason]);
    }
}

- (void)handleRunException:(NSException *)anException;
{
    // Redirect exceptions that get raised all the way out to -run back to -reportException:.  AppKit doesn't do this normally.  For example, if cmd-z (to undo) hits an exception, it will get re-raised all the way up to the top level w/o -reportException: getting called.  
    [self reportException:anException];
}

- (NSPanel *)currentRunExceptionPanel;
{
    return currentRunExceptionPanel;
}

- (NSWindow *)frontWindowForMouseLocation;
{
    for (NSWindow *window in [NSWindow windowsInZOrder]) {
	if ([window ignoresMouseEvents])
	    continue;
	    
        NSPoint mouse = [window mouseLocationOutsideOfEventStream];
        NSView *contentView = [window contentView];
        if ([contentView mouse:mouse inRect:[contentView frame]])
            return window;
    }
    
    return nil;
}

- (NSTimeInterval)lastEventTimeInterval;
{
    return lastEventTimeInterval;
}

- (BOOL)mouseButtonIsDownAtIndex:(unsigned int)mouseButtonIndex;
{
    return (mouseButtonState & (1 << mouseButtonIndex)) != 0;
}

- (BOOL)scrollWheelButtonIsDown;
{
    return [self mouseButtonIsDownAtIndex:2];
}

- (NSUInteger)launchModifierFlags;
{
    return launchModifierFlags;
}

- (void)scheduleModalPanelForTarget:(id)modalController selector:(SEL)modalSelector userInfo:(id)userInfo;
{
    OBPRECONDITION(modalController != nil);
    OBPRECONDITION([modalController respondsToSelector:modalSelector]);
    
    // Create an invocation out of this request
    NSMethodSignature *modalSignature = [modalController methodSignatureForSelector:modalSelector];
    if (modalSignature == nil)
        return;
    NSInvocation *modalInvocation = [NSInvocation invocationWithMethodSignature:modalSignature];
    [modalInvocation setTarget:modalController];
    [modalInvocation setSelector:modalSelector];
    
    // Pass userInfo if modalSelector takes it
    if ([modalSignature numberOfArguments] > 2) // self, _cmd
        [modalInvocation setArgument:&userInfo atIndex:2];

    [self _scheduleModalPanelWithInvocation:modalInvocation];
}

// Prefix the URL string with "anchor:" if the string is the name of an anchor in the help files. Prefix it with "search:" to search for the string in the help book.
- (void)showHelpURL:(NSString *)helpURL;
{
    id applicationDelegate = [NSApp delegate];
    if ([applicationDelegate respondsToSelector:@selector(openAddressWithString:)]) {
        // We're presumably in OmniWeb, in which case we display our help internally
        NSString *omniwebHelpBaseURL = @"omniweb:/Help/";
        if([helpURL isEqualToString:@"anchor:SoftwareUpdatePreferences_Help"])
            helpURL = @"reference/preferences/Update.html";
        [applicationDelegate performSelector:@selector(openAddressWithString:) withObject:[omniwebHelpBaseURL stringByAppendingString:helpURL]];
    } else {
	NSBundle *mainBundle = [NSBundle mainBundle];
        NSString *bookName = [mainBundle localizedStringForKey:@"CFBundleHelpBookName" value:@"" table:@"InfoPlist"];
        if (![bookName isEqualToString:@"CFBundleHelpBookName"]) {
            // We've got Apple Help.  First, make sure the help book is registered.  NSHelpManager would do this for us, but we use AHGotoPage, which it doesn't cover.
	    static BOOL helpBookRegistered = NO;
	    if (!helpBookRegistered) {
		helpBookRegistered = YES;
		NSURL *appBundleURL = [NSURL fileURLWithPath:[mainBundle bundlePath]];
		FSRef appBundleRef;
		if (!CFURLGetFSRef((CFURLRef)appBundleURL, &appBundleRef))
		    NSLog(@"Unable to get FSRef for app bundle URL of '%@' for bundle '%@'", appBundleURL, mainBundle);
		else
		    AHRegisterHelpBook(&appBundleRef);
	    }
	    
	    
            OSStatus err;
            NSRange range = [helpURL rangeOfString:@"search:"];
            if ((range.length != 0) || (range.location == 0))
                err = AHSearch((CFStringRef)bookName, (CFStringRef)[helpURL substringFromIndex:NSMaxRange(range)]);
            else {
                range = [helpURL rangeOfString:@"anchor:"];
                if ((range.length != 0) || (range.location == 0))
                    err = AHLookupAnchor((CFStringRef)bookName, (CFStringRef)[helpURL substringFromIndex:NSMaxRange(range)]);
                else
                    err = AHGotoPage((CFStringRef)bookName, (CFStringRef)helpURL, NULL);
            }
            
            if (err != noErr)
                NSLog(@"Apple Help error: %@", OFOSStatusDescription(err));
        } else {
            // We can let the system decide who to open the URL with
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:helpURL]];
        }
    }
}

#pragma mark -
#pragma mark Application Support directory

- (NSString *)applicationSupportDirectoryName;
{
    NSString *appSupportDirectory = nil;
    
    id appDelegate = [self delegate];
    if (appDelegate != nil && [appDelegate respondsToSelector:@selector(applicationSupportDirectoryName)])
        appSupportDirectory = [appDelegate applicationSupportDirectoryName];
    
    // TODO: Would it be better to use [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleName"] here ?
    if (appSupportDirectory == nil)
        appSupportDirectory = [[NSProcessInfo processInfo] processName];
    
    OBASSERT(appSupportDirectory != nil);

    return appSupportDirectory;
}

- (NSArray *)supportDirectoriesInDomain:(NSSearchPathDomainMask)domains;
{
    NSArray *appSupp = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, domains, YES);
    if (appSupp == nil) {
        NSArray *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, domains, YES);
        if (library == nil)
            return nil;
        appSupp = [library arrayByPerformingSelector:@selector(stringByAppendingPathComponent:) withObject:@"Application Support"];
    }
        
    return [appSupp arrayByPerformingSelector:@selector(stringByAppendingPathComponent:) withObject:[self applicationSupportDirectoryName]];
}

- (NSArray *)readableSupportDirectoriesInDomain:(NSSearchPathDomainMask)domains withComponents:(NSString *)subdir, ...;
{
    NSFileManager *filemgr = [NSFileManager defaultManager];
    NSMutableArray *result = [NSMutableArray array];
    
    for (NSString *path in [self supportDirectoriesInDomain:domains]) {
        va_list varg;
        va_start(varg, subdir);
        NSString *component = subdir;
        while (component != nil) {
            path = [path stringByAppendingPathComponent:component];
            component = va_arg(varg, NSString *);
        }
        va_end(varg);
        
        BOOL isDir;
        if ([filemgr fileExistsAtPath:path isDirectory:&isDir] && isDir)
            [result addObject:path];
    }
    return result;
}

- (NSString *)writableSupportDirectoryInDomain:(NSSearchPathDomainMask)domains withComponents:(NSString *)subdir, ...;
{
    NSFileManager *filemgr = [NSFileManager defaultManager];
    
    for (NSString *path in [self supportDirectoriesInDomain:domains]) {
        va_list varg;
        va_start(varg, subdir);
        NSString *component = subdir;
        while (component != nil) {
            path = [path stringByAppendingPathComponent:component];
            component = va_arg(varg, NSString *);
        }
        va_end(varg);
        
        BOOL isDir;
        if ([filemgr fileExistsAtPath:path isDirectory:&isDir]) {
            if(isDir && [filemgr isWritableFileAtPath:path])
                return path;
        } else {
            NSError *error = nil;
            if ([filemgr createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error]) // only return if there is no error creating the directory
                return path;
        }
    }
    return nil;
}

#pragma mark -
#pragma mark Actions

- (IBAction)closeAllMainWindows:(id)sender;
{
    for (NSWindow *window in [NSArray arrayWithArray:[self orderedWindows]]) {
        if ([window canBecomeMainWindow])
            [window performClose:nil];
    }
}

- (IBAction)cycleToNextMainWindow:(id)sender;
{
    NSWindow *mainWindow = [NSApp mainWindow];
    
    for (NSWindow *window in [NSApp orderedWindows]) {
        if (window != mainWindow && [window canBecomeMainWindow] && ![NSStringFromClass([window class]) isEqualToString:@"NSDrawerWindow"]) {
            [window makeKeyAndOrderFront:nil];
            [mainWindow orderBack:nil];
            return;
        }
    }
    // There's one (or less) window which can potentially be main, make it key and bring it forward.
    [mainWindow makeKeyAndOrderFront:nil];
}

- (IBAction)cycleToPreviousMainWindow:(id)sender;
{
    NSWindow *mainWindow = [NSApp mainWindow];
    
    for (NSWindow *window in [[NSApp orderedWindows] reverseObjectEnumerator]) {
        if (window != mainWindow && [window canBecomeMainWindow] && ![NSStringFromClass([window class]) isEqualToString:@"NSDrawerWindow"]) {
            [window makeKeyAndOrderFront:nil];
            return;
        }
    }
    // There's one (or less) window which can potentially be main, make it key and bring it forward.
    [mainWindow makeKeyAndOrderFront:nil];
}

- (IBAction)showPreferencesPanel:(id)sender;
{
    [[OAPreferenceController sharedPreferenceController] showPreferencesPanel:nil];
}

- (void)miniaturizeWindows:(NSArray *)windows;
{
    overrideWindows = windows;
    @try {
        [super miniaturizeAll:nil];
    } @finally {
        overrideWindows = nil;
    }
}

#pragma mark - AppleScript

static void _addPreferenceForKey(const void *value, void *context)
{
    NSString *key = (NSString *)value;
    NSMutableArray *prefs = (NSMutableArray *)context;
    
    OFPreference *pref = [OFPreference preferenceForKey:key];
    OBASSERT(pref);
    if (pref)
        [prefs addObject:pref];
}

static NSComparisonResult _compareByKey(id obj1, id obj2, void *context)
{
    return [[obj1 key] compare:[obj2 key]];
}

- (NSArray *)scriptPreferences;
{
    NSMutableArray *prefs = [NSMutableArray array];
    [[OFPreference registeredKeys] applyFunction:_addPreferenceForKey context:prefs];
    [prefs sortUsingFunction:_compareByKey context:NULL];
    return prefs;
}

- (OFPreference *)valueInScriptPreferencesWithUniqueID:(NSString *)identifier;
{
    return [OFPreference preferenceForKey:identifier];
}

- (BOOL)_shouldFilterWindowFromOrderedWindows:(NSWindow *)window;
{
    static BOOL hasComputedSignatures = NO;
    static NSData *fullScreenToolbarWindowSignature = nil;
    static NSData *fullScreenBackdropWindowSignature = nil;

    // We have to filter these windows by private classname. Since the private classname cannot appear in our App Store binary, we do it by sha1 hash.

    if (!hasComputedSignatures) {
        hasComputedSignatures = YES;
    
        unsigned char toolbarSignatureBytes[] = {0x69, 0x20, 0xef, 0xa7, 0x58, 0xa2, 0x8c, 0xc3, 0x20, 0xa1, 0xb8, 0xcd, 0x75, 0x46, 0x40, 0xfc, 0x05, 0xae, 0x61, 0x0a};
        fullScreenToolbarWindowSignature = [[NSData alloc] initWithBytes:toolbarSignatureBytes length:sizeof(toolbarSignatureBytes) / sizeof(unsigned char)];

        unsigned char backdropSignatureBytes[] = {0x35, 0xc2, 0x5e, 0x22, 0xd0, 0x4b, 0x59, 0x4a, 0xfe, 0xc7, 0xb2, 0x0c, 0xb5, 0x8d, 0x07, 0x4b, 0xee, 0x4a, 0x35, 0x52};
        fullScreenBackdropWindowSignature = [[NSData alloc] initWithBytes:backdropSignatureBytes length:sizeof(backdropSignatureBytes) / sizeof(unsigned char)];

#ifdef DEBUG
        // Make sure we didn't botch the static sha1 signatures above
        NSData *signature = nil;
        
        signature = [[@"NSToolbarFullScreenWindow" dataUsingEncoding:NSUTF8StringEncoding] sha1Signature];
        OBASSERT([signature isEqualToData:fullScreenToolbarWindowSignature]);

        signature = [[@"_NSFullScreenUnbufferedWindow" dataUsingEncoding:NSUTF8StringEncoding] sha1Signature];
        OBASSERT([signature isEqualToData:fullScreenBackdropWindowSignature]);
#endif
    }

    NSData *signature = [[NSStringFromClass([window class]) dataUsingEncoding:NSUTF8StringEncoding] sha1Signature];
    
    if ([signature isEqualToData:fullScreenToolbarWindowSignature])
        return YES;

    if ([signature isEqualToData:fullScreenBackdropWindowSignature])
        return YES;
        
    return NO;
}

- (NSArray *)orderedWindows;
{
    NSArray *orderedWindows = [super orderedWindows];

    if (NSAppKitVersionNumber >= OAAppKitVersionNumber10_7) {
        // Workaround for rdar://problem/10262921
        //
        // In full-screen mode, the window's toolbar gets hosted in it's own window, and there is a full-screen backdrop window.
        // These are returned as window 1 and window N.
        // Both are unexpected, and uninteresting to scripters. 
        // Worse, it breaks the idiom that the first window is the interesting one to target.
        // Fixes <bug:///74072> (10.7 / Lion :  Full screened apps don't return the full screened window as window 1, breaking scripts [applescript])

        NSMutableArray *filteredOrderedWindows = [NSMutableArray array];
        NSEnumerator *enumerator = [orderedWindows objectEnumerator];
        NSWindow *window = nil;
        
        while (nil != (window = [enumerator nextObject])) {
            // Exclude NSToolbarFullScreenWindow and _NSFullScreenUnbufferedWindow
            // We must test by hash of the classname so that we don't trigger SPI detection on the Mac App Store
            if ([self _shouldFilterWindowFromOrderedWindows:window])
                continue;
                       
            [filteredOrderedWindows addObject:window];
        }
        
        orderedWindows = filteredOrderedWindows;
    }

    return orderedWindows;
}

#pragma mark -
#pragma mark Private

+ (void)_setupOmniApplication;
{
    [OBObject self]; // Trigger +[OBPostLoader processClasses]
    
    // Wait until defaults are registered with OBPostLoader to look this up.
    OATargetSelection = [[NSUserDefaults standardUserDefaults] boolForKey:@"OATargetSelection"];

    // make these images available to client nibs and whatnot (retaining them so they stick around in cache).
    // Store them in ivars to avoid clang scan-build warnings.
    HelpIcon = [[NSImage imageNamed:@"OAHelpIcon" inBundleForClass:[OAApplication class]] retain];
    CautionIcon = [[NSImage imageNamed:@"OACautionIcon" inBundleForClass:[OAApplication class]] retain];
}

- (void)processMouseButtonsChangedEvent:(NSEvent *)event;
{
    mouseButtonState = [event data2];
}

- (void)_scheduleModalPanelWithInvocation:(NSInvocation *)modalInvocation;
{
    OBPRECONDITION(modalInvocation != nil);
    
    NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
    if ([[runLoop currentMode] isEqualToString:NSModalPanelRunLoopMode]) {
        NSTimer *timer = [NSTimer timerWithTimeInterval:0.0 target:self selector:@selector(_rescheduleModalPanel:) userInfo:modalInvocation repeats:NO];
        [runLoop addTimer:timer forMode:NSDefaultRunLoopMode];
    } else {
        [modalInvocation invoke];
    }
}

- (void)_rescheduleModalPanel:(NSTimer *)timer;
{
    OBPRECONDITION(timer != nil);
    
    NSInvocation *invocation = [timer userInfo];
    OBASSERT(invocation != nil);
    
    [self _scheduleModalPanelWithInvocation:invocation];
}

@end

#pragma mark -
#pragma mark OATargetSelection

@implementation NSObject (OATargetSelection)

- (BOOL)applyToResponderChain:(OAResponderChainApplier)applier;
{
    return applier(self);
}

- (BOOL)_stubValidatorMethodJustForItsTypeSignature:(id)sender;
{
    return YES;
}

static BOOL _validates(id self, SEL validateSelector, id sender)
{
#ifdef DEBUG
    static const char *expectedValidatorMethodType = NULL;
    if (!expectedValidatorMethodType) {
        expectedValidatorMethodType = method_getTypeEncoding(class_getInstanceMethod([NSObject class], @selector(_stubValidatorMethodJustForItsTypeSignature:)));
    }
#endif

    Method validatorMethod = class_getInstanceMethod([self class], validateSelector);
    if (!validatorMethod) {
        OBASSERT_NOT_REACHED("validator method not implemented");
        return NO;
    }
        
#ifdef DEBUG
    const char *validatorMethodType = method_getTypeEncoding(validatorMethod);
    if(strcmp(validatorMethodType, expectedValidatorMethodType)) {
        OBASSERT_NOT_REACHED("implemented validator method is of the wrong type");
        return NO;
    }
#endif

    IMP validatorImplementation = method_getImplementation(validatorMethod);
    BOOL (*validator)(id self, SEL selector, id sender) = (typeof(validator))validatorImplementation;
    return validator(self, validateSelector, sender);
}

static id _selfIfValidElseNil(id self, SEL validateSelector, id sender)
{
    if (_validates(self, validateSelector, sender))
        return self;
    else
        return nil;
}

- (id)responsibleTargetForAction:(SEL)action sender:(id)sender;
{
    if (![self respondsToSelector:action])
        return nil;
    
    SEL validateSpecificItemSelector = NULL;
    if ([sender isKindOfClass:[NSMenuItem class]])
        validateSpecificItemSelector = @selector(validateMenuItem:);
    else if ([sender isKindOfClass:[NSToolbarItem class]])
        validateSpecificItemSelector = @selector(validateToolbarItem:);
    
    if (validateSpecificItemSelector != NULL)
        return _selfIfValidElseNil(self, validateSpecificItemSelector, sender);
    else if ([sender conformsToProtocol:@protocol(NSValidatedUserInterfaceItem)])
        return _selfIfValidElseNil(self, @selector(validateUserInterfaceItem:), sender);

    return self;
}

@end

@interface NSResponder (OATargetSelection)
@end
@implementation NSResponder (OATargetSelection)

- (BOOL)applyToResponderChain:(OAResponderChainApplier)applier;
{
    if (![super applyToResponderChain:applier])
        return NO;
    
    NSResponder *next = self.nextResponder;
    if (next)
        DEBUG_TARGET_SELECTION(@"---> checking nextResponder ");
    if (next && ![next applyToResponderChain:applier])
        return NO;

    return YES;
}

@end

@interface NSWindow (OATargetSelection)
@end
@implementation NSWindow (OATargetSelection)

- (BOOL)applyToResponderChain:(OAResponderChainApplier)applier;
{
    if (![super applyToResponderChain:applier])
        return NO;
    
    // Beginning in 10.7, as a first approximation, the delegate is returned via supplementalTargetForAction:sender:. However, if the delegate is an NSResponder, then NSWindow seems to chase the responder chain and return the first object that implements the action. We apply our mechanism here. It's redundant in some cases, but let's us run the applier against the full chain.
    id delegate = (id)self.delegate;
    if (delegate)
        DEBUG_TARGET_SELECTION(@"---> checking NSWindow delegate ");
    if (delegate && ![delegate applyToResponderChain:applier])
        return NO;
    
    id windowController = self.windowController;
    if (windowController)
        DEBUG_TARGET_SELECTION(@"---> checking NSWindow windowController ");
    if (windowController && windowController != delegate && ![windowController applyToResponderChain:applier])
        return NO;
    
    return YES;
}

@end

@interface NSWindowController (OATargetSelection)
@end
@implementation NSWindowController (OATargetSelection)

- (BOOL)applyToResponderChain:(OAResponderChainApplier)applier;
{
    if (![super applyToResponderChain:applier])
        return NO;

    NSDocument *document = self.document;
    if (document)
        DEBUG_TARGET_SELECTION(@"---> checking NSWindowController document ");
    if (document && ![document applyToResponderChain:applier])
        return NO;
    
    return YES;
}

@end


#pragma mark -
#pragma mark OATargetSelectionValidation

@interface NSObject (OATargetSelectionValidation)
/* 
 Allows replacing monolithic validateMenuItem:, validateToolbarItem:, and validateUserInterfaceItem: methods with action-specific methods. For example, a toggleRulerView: action can be validated using:
 
        - (BOOL)validateToggleRulerViewMenuItem:(NSMenuItem *)item;
        - (BOOL)validateToggleRulerViewToolbarItem:(NSToolbarItem *)item;

 depending on the type of the sender. If the sender-type-specific method is missing, then we validate the action using:
 
        - (BOOL)validateToggleRulerView:(id <NSValidatedUserInterfaceItem>)item;
 
 which is useful when the toolbar item and menu item for an action have the same validation logic.
 
 Note well: if the monolithic validateMenuItem:, validateToolbarItem:, and validateUserInterfaceItem: methods exist, they will be used rather than using the action-specific methods. This approach allows us to migrate on a class-by-class basis to using action-specific valiation, since it retains the previous validation behavior for a class until we eliminate the monolithic methods.
*/

- (BOOL)validateMenuItem:(NSMenuItem *)item;
- (BOOL)validateToolbarItem:(NSToolbarItem *)item;
- (BOOL)validateUserInterfaceItem:(id <NSValidatedUserInterfaceItem>)item;
@end

@implementation NSObject (OATargetSelectionValidation)

typedef enum {
    OAMenuItemValidatorType,
    OAToolbarItemValidatorType,
    OAUserInterfaceItemValidatorType,
    OAValidatorTypeCount
} OAValidationType;

static NSMapTable *OAValidatorMaps[OAValidatorTypeCount]; // One SEL --> SEL map for each validator type.

- (SEL)_validatorSelectorFromAction:(SEL)action type:(OAValidationType)type;
{
    OBPRECONDITION(action);
    OBPRECONDITION(type < OAValidatorTypeCount);
    OBPRECONDITION([NSThread isMainThread]); // Our validator map mutation is not thread safe.
    
    static NSString * const OAMenuItemValidatorSuffix = @"MenuItem";
    static NSString * const OAToolbarItemValidatorSuffix = @"ToolbarItem";
    static NSString * const OAUserInterfaceItemValidatorSuffix = nil;
    static BOOL initialized = NO;
    
    if (!initialized) {
        NSPointerFunctionsOptions options = NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality;
        int defaultCapacity = 0; // Pointer collections will pick an appropriate small capacity on their own
        for (int i=0; i < OAValidatorTypeCount; i++) {
            NSMapTable *map = [[NSMapTable alloc] initWithKeyOptions:options valueOptions:options capacity:defaultCapacity];
            OAValidatorMaps[i] = map;
        }
        initialized = YES;
    }

    NSMapTable *validators = OAValidatorMaps[type];
    SEL validator = NSMapGet(validators, action);
    if (validator != NULL)
        return validator;

    NSString *suffix;
    switch (type) {
        case OAMenuItemValidatorType:
            suffix = OAMenuItemValidatorSuffix;
            break;
        case OAToolbarItemValidatorType:
            suffix = OAToolbarItemValidatorSuffix;
            break;
        default:
            suffix = OAUserInterfaceItemValidatorSuffix;
            break;
    }
    
    // e.g., @selector(toggleStatusCheckbox:) --> @"ToggleStatusCheckbox"
    NSString *selectorString = NSStringFromSelector(action);
#ifdef OMNI_ASSERTIONS_ON
    NSRange firstColon = [selectorString rangeOfString:@":"];
    OBASSERT(firstColon.length == 1 && firstColon.location == [selectorString length] - 1); // sanity check for unary selector
#endif
    unichar *buffer = alloca(selectorString.length * sizeof(unichar));
    [selectorString getCharacters:buffer];
    if (*buffer >= 'a' && *buffer <= 'z')
        *buffer += 'A' - 'a';

    NSString *actionName = [[NSString alloc] initWithCharacters:buffer length:selectorString.length - 1];
    NSString *validatorString = [[NSString alloc] initWithFormat:@"validate%@%@:", actionName, suffix ? suffix : @""];
    validator = NSSelectorFromString(validatorString);
    [validatorString release];
    [actionName release];

    NSMapInsert(validators, action, validator);
    
    return validator;
}

- (BOOL)_invokeValidatorForType:(OAValidationType)type item:(NSObject <NSValidatedUserInterfaceItem> *)item;
{
    SEL validator = [self _validatorSelectorFromAction:[item action] type:type];
    
    if ([self respondsToSelector:validator])
        return _validates(self, validator, item);
    
    if (type == OAMenuItemValidatorType || type == OAToolbarItemValidatorType) {
        // We checked for a menu item or toolbar item above and didn't find it, so check for generic user interface item
        validator = [self _validatorSelectorFromAction:[item action] type:OAUserInterfaceItemValidatorType];
        if ([self respondsToSelector:validator])
            return _validates(self, validator, item);
    }
    
    // Validator invocation happens twice. Once during the search for the target object and again for the actual validation decision. We reach this point in the code only when self implements the desired action but does not implement any validation. In that case, self should be the target and should validate the action.
    return YES;
}

static BOOL _overridesNSObjectCategoryMethod(id self, SEL validateSelector)
{
    Method categoryMethod = class_getInstanceMethod([NSObject class], validateSelector);
    OBASSERT_NOTNULL(categoryMethod);
    Method possiblyOverridingMethod = class_getInstanceMethod([self class], validateSelector);
    OBASSERT_NOTNULL(possiblyOverridingMethod);
    
    return possiblyOverridingMethod != categoryMethod;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item;
{
    // Give priority to subclass overrides of validateUserInterfaceItem. (Already gave priorty to subclass overrides of validateMenuItem, since we wouldn't have gotten here in that case.)
    if ([item conformsToProtocol:@protocol(NSValidatedUserInterfaceItem)] && _overridesNSObjectCategoryMethod(self, @selector(validateUserInterfaceItem:)))
        return [self validateUserInterfaceItem:item];
    return [self _invokeValidatorForType:OAMenuItemValidatorType item:item];
}

- (BOOL)validateToolbarItem:(NSToolbarItem *)item;
{
    // Give priority to subclass overrides of validateUserInterfaceItem. (Already gave priorty to subclass overrides of validateToolbarItem, since we wouldn't have gotten here in that case.)
    if ([item conformsToProtocol:@protocol(NSValidatedUserInterfaceItem)] && _overridesNSObjectCategoryMethod(self, @selector(validateUserInterfaceItem:)))
        return [self validateUserInterfaceItem:item];
    return [self _invokeValidatorForType:OAToolbarItemValidatorType item:item];
}

- (BOOL)validateUserInterfaceItem:(id <NSValidatedUserInterfaceItem>)item;
{
    return [self _invokeValidatorForType:OAUserInterfaceItemValidatorType item:(NSObject <NSValidatedUserInterfaceItem> *)item];
}

@end
