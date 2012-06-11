// Copyright 2010-2012 The Omni Group. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.

#import "OUIDocumentPickerItemNameAndDateView.h"

#import "OUIParameters.h"

RCS_ID("$Id$");

@implementation OUIDocumentPickerItemNameAndDateView
{
    NSString *_name;
    NSString *_dateString;
    UIImage *_nameBadgeImage;
    
    CGSize _nameSize;
    CGSize _dateStringSize;
}

static UIColor *ShadowColor = nil;
static UIFont *NameFont = nil;
static UIFont *DateFont = nil;

+ (void)initialize;
{
    OBINITIALIZE;
    
    ShadowColor = [[UIColor colorWithWhite:kOUIDocumentPickerItemViewLabelShadowWhiteAlpha.w alpha:kOUIDocumentPickerItemViewLabelShadowWhiteAlpha.a] retain];
    NameFont = [[UIFont boldSystemFontOfSize:kOUIDocumentPickerItemViewNameLabelFontSize] retain];
    DateFont = [[UIFont boldSystemFontOfSize:kOUIDocumentPickerItemViewDetailLabelFontSize] retain];
}

- initWithFrame:(CGRect)frame;
{
    if (!(self = [super initWithFrame:frame]))
        return nil;
    
    self.opaque = NO;

#if 0 && defined(DEBUG_bungi)
    _nameBadgeImage = [[UIImage imageNamed:@"OUINotInCloud.png"] retain];
#endif
    
    return self;
}

- (void)dealloc;
{
    [_name release];
    [_dateString release];
    [_nameBadgeImage release];
    [super dealloc];
}

@synthesize name = _name;
- (void)setName:(NSString *)name;
{
    if (OFISEQUAL(_name, name))
        return;
    [_name release];
    _name = [name copy];
    
    _nameSize = [_name sizeWithFont:NameFont];
    
    [self setNeedsDisplay];
}

@synthesize nameBadgeImage = _nameBadgeImage;
- (void)setNameBadgeImage:(UIImage *)nameBadgeImage;
{
    if (OFISEQUAL(_nameBadgeImage, nameBadgeImage))
        return;
    
    [_nameBadgeImage release];
    _nameBadgeImage = [nameBadgeImage retain];

    [self setNeedsDisplay];
}

@synthesize dateString = _dateString;
- (void)setDateString:(NSString *)dateString;
{
    if (OFISEQUAL(_dateString, dateString))
        return;
    [_dateString release];
    _dateString = [dateString copy];
    
    _dateStringSize = [_dateString sizeWithFont:DateFont];
    
    [self setNeedsDisplay];
}

#pragma mark - UIView subclass

- (CGSize)sizeThatFits:(CGSize)size;
{
    return CGSizeMake(ceil(MAX(_nameSize.width, _dateStringSize.width)),
                      ceil(_nameSize.height) + kOUIDocumentPickerItemViewNameToDatePadding + ceil(_dateStringSize.height));
}

- (void)drawRect:(CGRect)rect;
{
    CGRect bounds = self.bounds;
        
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, 1), 0.5, [ShadowColor CGColor]);
    {
        CGRect nameRect;
        CGRectDivide(bounds, &nameRect, &bounds, ceil(_nameSize.height), CGRectMinYEdge);
        
        CGRect dateRect;
        CGRectDivide(bounds, &dateRect, &bounds, ceil(_dateStringSize.height), CGRectMaxYEdge);
        
        [[UIColor colorWithWhite:kOUIDocumentPickerItemViewNameLabelWhiteAlpha.w alpha:kOUIDocumentPickerItemViewNameLabelWhiteAlpha.a] set];
        
        if (_nameBadgeImage) {            
            // Center the name and image together.
            static const CGFloat kNameToBadgePadding = 4;
            CGSize imageSize = [_nameBadgeImage size];
            CGFloat totalWidth = _nameSize.width + kNameToBadgePadding + imageSize.width;
            
            CGFloat nameLeftXEdge = MAX(CGRectGetMinX(bounds), floor(CGRectGetMidX(bounds) - totalWidth/2));
            CGFloat nameRightXEdge = MIN(CGRectGetMaxX(bounds) - (kNameToBadgePadding + imageSize.width), ceil(nameLeftXEdge + _nameSize.width));
            
            nameRect.origin.x = nameLeftXEdge;
            nameRect.size.width = nameRightXEdge - nameLeftXEdge;
            
            CGRect imageRect = CGRectMake(nameRightXEdge + kNameToBadgePadding, floor(CGRectGetMidY(nameRect) - imageSize.height/2), imageSize.width, imageSize.height);
            [_nameBadgeImage drawInRect:imageRect blendMode:kCGBlendModeNormal alpha:1.0];
        }

        [_name drawInRect:nameRect withFont:NameFont lineBreakMode:UILineBreakModeTailTruncation alignment:UITextAlignmentCenter];
        
        [[UIColor colorWithWhite:kOUIDocumentPickerItemViewDetailLabelWhiteAlpha.w alpha:kOUIDocumentPickerItemViewDetailLabelWhiteAlpha.a] set];
        [_dateString drawInRect:dateRect withFont:DateFont lineBreakMode:UILineBreakModeTailTruncation alignment:UITextAlignmentCenter];
    }
    CGContextRestoreGState(ctx);
}

@end


