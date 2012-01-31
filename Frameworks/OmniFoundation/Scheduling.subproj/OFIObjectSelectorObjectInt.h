// Copyright 2003-2005, 2008 Omni Development, Inc.  All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.
//
// $Id$

#import <OFIObjectSelector.h>

@interface OFIObjectSelectorObjectInt : OFIObjectSelector
{
    id withObject;
    int theInt;
}

- initForObject:(id)anObject selector:(SEL)aSelector withObject:(id)aWithObject withInt:(int)anInt;

@end
