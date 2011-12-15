// Copyright 2011 Omni Development, Inc. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.

#import "OATinyPopUpButton.h"

#import <Cocoa/Cocoa.h>
#import <OmniAppKit/OmniAppKit.h>
#import <OmniBase/rcsid.h>

RCS_ID("$Id$");

@implementation OATinyPopUpButton

- initWithFrame:(NSRect)frame;
{
    if ((self = [super initWithFrame:frame]) == nil)
        return nil;
    [self setPullsDown:YES]; // set to pull down, so the superclass doesn't munge with our menu items, trying to check one of them and uncheck the rest
    [[self cell] setArrowPosition:NSPopUpNoArrow];
    return self;
}

- initWithCoder:(NSCoder *)coder;
{
    if ((self = [super initWithCoder:coder]) == nil)
        return nil;
    [[self cell] setArrowPosition:NSPopUpNoArrow];
    return self;
}

- (void)setMenu:(NSMenu *)menu;
{
    // assume that we want a blank item at the top, which would be the pull down title, if we were showing it, which we aren't
    if([self menu] != menu)
        [menu insertItemWithTitle:@"" action:NULL keyEquivalent:@"" atIndex:0];
    [super setMenu:menu];
}


// NSView subclass

#define TINY_TRIANGLE_BOTTOM_PADDING 3  // pixels

- (void)drawRect:(NSRect)aRect;
{
    if ([[self window] firstResponder] == self) {
        NSSetFocusRingStyle(NSFocusRingAbove);
        [self setKeyboardFocusRingNeedsDisplayInRect:[self frame]];
    }
    if ([self isEnabled]) {
        // Draw image near top center of its view
        NSImage *dropDownImage = [NSImage imageNamed:@"OADropDownTriangle.png" inBundleForClass:[self class]];
        NSSize imageSize = [dropDownImage size];
        CGRect bounds = [self bounds];
        CGRect imageRect;
        imageRect.size = imageSize;
        imageRect.origin.x = (bounds.size.width - imageSize.width)/2;
        imageRect.origin.y = /*bounds.size.height - imageSize.height - */ TINY_TRIANGLE_BOTTOM_PADDING;
        
        [dropDownImage drawFlippedInRect:imageRect operation:NSCompositeSourceOver];
    }
}

@end

