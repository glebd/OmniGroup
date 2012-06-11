// Copyright 2004-2008, 2010-2012 Omni Development, Inc. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.

#import <OmniFoundation/OFBindingPoint.h>

RCS_ID("$Id$");

@implementation OFBindingPoint

- initWithObject:(id)object keyPath:(NSString *)keyPath;
{
    if (!(self = [super init]))
        return nil;
    
    _object = [object retain];
    _keyPath = [keyPath copy];
    
    return self;
}

- (void)dealloc;
{
    [_object release];
    [_keyPath release];
    [super dealloc];
}

@synthesize object = _object;
@synthesize keyPath = _keyPath;

- (BOOL)isEqual:(id)object;
{
    if (![object isKindOfClass:[OFBindingPoint class]])
        return NO;
    return OFBindingPointsEqual(self, object);
}

- (NSUInteger)hash;
{
    return [_object hash] ^ [_keyPath hash];
}

BOOL OFBindingPointsEqual(OFBindingPoint *a, OFBindingPoint *b)
{
    // Requires identical objects, not -isEqual:!
    return a->_object == b->_object && [a->_keyPath isEqualToString:b->_keyPath];
}


@end
