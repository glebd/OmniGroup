// Copyright 2003-2012 Omni Development, Inc. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.

#import <tgmath.h>
#import <OmniQuartz/OQDrawing.h>
#import <OmniBase/OmniBase.h>
#import <OmniFoundation/OFExtent.h>

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <AppKit/NSView.h>
#endif

RCS_ID("$Id$");

#if !defined(TARGET_OS_IPHONE) || !TARGET_OS_IPHONE
void OQSetPatternColorReferencePoint(CGPoint point, NSView *view)
{
    CGPoint refPoint = [view convertPoint:point toView:nil];
    CGSize phase = (CGSize){refPoint.x, refPoint.y};
    CGContextSetPatternPhase([[NSGraphicsContext currentContext] graphicsPort], phase);
}
#endif

//
// Rounded rect support.
//

// These assume a non-flipped coordinate system (top == CGRectGetMaxY, bottom == CGRectGetMinY)

void OQAppendRoundedRect(CGContextRef ctx, CGRect rect, CGFloat radius)
{
    CGPoint topMid      = CGPointMake(CGRectGetMidX(rect), CGRectGetMaxY(rect));
    CGPoint topLeft     = CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect));
    CGPoint topRight    = CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect));
    CGPoint bottomRight = CGPointMake(CGRectGetMaxX(rect), CGRectGetMinY(rect));
    
    CGContextMoveToPoint(ctx, topMid.x, topMid.y);
    CGContextAddArcToPoint(ctx, topLeft.x, topLeft.y, rect.origin.x, rect.origin.y, radius);
    CGContextAddArcToPoint(ctx, rect.origin.x, rect.origin.y, bottomRight.x, bottomRight.y, radius);
    CGContextAddArcToPoint(ctx, bottomRight.x, bottomRight.y, topRight.x, topRight.y, radius);
    CGContextAddArcToPoint(ctx, topRight.x, topRight.y, topLeft.x, topLeft.y, radius);
    CGContextClosePath(ctx);
}

void OQAddRoundedRect(CGMutablePathRef path, CGRect rect, CGFloat radius)
{
    CGPoint topMid      = CGPointMake(CGRectGetMidX(rect), CGRectGetMaxY(rect));
    CGPoint topLeft     = CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect));
    CGPoint topRight    = CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect));
    CGPoint bottomRight = CGPointMake(CGRectGetMaxX(rect), CGRectGetMinY(rect));
    
    CGPathMoveToPoint(path, NULL, topMid.x, topMid.y);
    CGPathAddArcToPoint(path, NULL, topLeft.x, topLeft.y, rect.origin.x, rect.origin.y, radius);
    CGPathAddArcToPoint(path, NULL, rect.origin.x, rect.origin.y, bottomRight.x, bottomRight.y, radius);
    CGPathAddArcToPoint(path, NULL, bottomRight.x, bottomRight.y, topRight.x, topRight.y, radius);
    CGPathAddArcToPoint(path, NULL, topRight.x, topRight.y, topLeft.x, topLeft.y, radius);
    CGPathCloseSubpath(path);
}

// These assume a flipped coordinate system (top == CGRectGetMinY, bottom == CGRectGetMaxY)

void OQAppendRectWithRoundedCornerMask(CGContextRef ctx, CGRect rect, CGFloat radius, NSUInteger cornerMask)
{
    CGPoint topMid      = CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect));
    CGPoint topLeft     = CGPointMake(CGRectGetMinX(rect), CGRectGetMinY(rect));
    CGPoint topRight    = CGPointMake(CGRectGetMaxX(rect), CGRectGetMinY(rect));
    CGPoint bottomRight = CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect));
    CGPoint bottomLeft  = CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect));

    CGContextMoveToPoint(ctx, topMid.x, topMid.y);
    
    if (cornerMask & OQRoundedRectCornerTopRight) {
        CGContextAddLineToPoint(ctx, topRight.x - radius, topRight.y);
        CGContextAddArcToPoint(ctx, topRight.x, topRight.y, topRight.x, topRight.y + radius, radius);
    } else {
        CGContextAddLineToPoint(ctx, topRight.x, topRight.y);
        CGContextAddLineToPoint(ctx, topRight.x, topRight.y + radius);
    }
    
    if (cornerMask & OQRoundedRectCornerBottomRight) {
        CGContextAddLineToPoint(ctx, bottomRight.x, bottomRight.y - radius);
        CGContextAddArcToPoint(ctx, bottomRight.x, bottomRight.y, bottomRight.x - radius, bottomRight.y, radius);
    } else {
        CGContextAddLineToPoint(ctx, bottomRight.x, bottomRight.y);
        CGContextAddLineToPoint(ctx, bottomRight.x - radius, bottomRight.y);
    }
    
    if (cornerMask & OQRoundedRectCornerBottomLeft) {
        CGContextAddLineToPoint(ctx, bottomLeft.x + radius, bottomLeft.y);
        CGContextAddArcToPoint(ctx, bottomLeft.x, bottomLeft.y, bottomLeft.x, bottomLeft.y - radius, radius);
    } else {
        CGContextAddLineToPoint(ctx, bottomLeft.x, bottomLeft.y);
        CGContextAddLineToPoint(ctx, bottomLeft.x, bottomLeft.y - radius);
    }
    
    if (cornerMask & OQRoundedRectCornerTopLeft) {
        CGContextAddLineToPoint(ctx, topLeft.x, topLeft.y + radius);
        CGContextAddArcToPoint(ctx, topLeft.x, topLeft.y, topLeft.x + radius, topLeft.y, radius);
    } else {
        CGContextAddLineToPoint(ctx, topLeft.x, topLeft.y);
        CGContextAddLineToPoint(ctx, topLeft.x + radius, topLeft.y);
    }
    
    CGContextClosePath(ctx);
}

void OQAppendRectWithRoundedTop(CGContextRef ctx, CGRect rect, CGFloat radius, BOOL closeBottom)
{
    if (closeBottom) {
        OQAppendRectWithRoundedCornerMask(ctx, rect, radius, (OQRoundedRectCornerTopLeft | OQRoundedRectCornerTopRight));
    } else {
        CGPoint topLeft     = CGPointMake(CGRectGetMinX(rect), CGRectGetMinY(rect));
        CGPoint topRight    = CGPointMake(CGRectGetMaxX(rect), CGRectGetMinY(rect));
        CGPoint bottomRight = CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect));
        CGPoint bottomLeft  = CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect));
        
        CGContextMoveToPoint(ctx, bottomLeft.x, bottomLeft.y);
        CGContextAddLineToPoint(ctx, topLeft.x, topLeft.y + radius);
        CGContextAddArcToPoint(ctx, topLeft.x, topLeft.y, topLeft.x + radius, topLeft.y, radius);
        CGContextAddLineToPoint(ctx, topRight.x - radius, topRight.y);
        CGContextAddArcToPoint(ctx, topRight.x, topRight.y, topRight.x, topRight.y + radius, radius);
        CGContextAddLineToPoint(ctx, bottomRight.x, bottomRight.y);
    }
}

void OQAppendRectWithRoundedTopLeft(CGContextRef ctx, CGRect rect, CGFloat radius, BOOL closeBottom)
{
    if (closeBottom) {
        OQAppendRectWithRoundedCornerMask(ctx, rect, radius, OQRoundedRectCornerTopLeft);
    } else {
        CGPoint bottomLeft  = CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect));
        CGPoint bottomRight = CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect));
        CGPoint topRight    = CGPointMake(CGRectGetMaxX(rect), CGRectGetMinY(rect));
        CGPoint topLeft     = CGPointMake(CGRectGetMinX(rect), CGRectGetMinY(rect));
        
        CGContextMoveToPoint(ctx, bottomRight.x, bottomRight.y);
        CGContextAddLineToPoint(ctx, topRight.x, topRight.y);
        CGContextAddLineToPoint(ctx, topLeft.x + radius, topLeft.y);
        CGContextAddArcToPoint(ctx, topLeft.x, topLeft.y, topLeft.x, topLeft.y + radius, radius);
        CGContextAddLineToPoint(ctx, bottomLeft.x, bottomLeft.y);
    }
}

void OQAppendRectWithRoundedTopRight(CGContextRef ctx, CGRect rect, CGFloat radius, BOOL closeBottom)
{
    if (closeBottom) {
        OQAppendRectWithRoundedCornerMask(ctx, rect, radius, OQRoundedRectCornerTopRight);
    } else {
        CGPoint topLeft     = CGPointMake(CGRectGetMinX(rect), CGRectGetMinY(rect));
        CGPoint topRight    = CGPointMake(CGRectGetMaxX(rect), CGRectGetMinY(rect));
        CGPoint bottomRight = CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect));
        CGPoint bottomLeft  = CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect));
        
        CGContextMoveToPoint(ctx, bottomLeft.x, bottomLeft.y);
        CGContextAddLineToPoint(ctx, topLeft.x, topLeft.y);
        CGContextAddLineToPoint(ctx, topRight.x - radius, topRight.y);
        CGContextAddArcToPoint(ctx, topRight.x, topRight.y, topRight.x, topRight.y + radius, radius);
        CGContextAddLineToPoint(ctx, bottomRight.x, bottomRight.y);
    }
}

void OQAppendRectWithRoundedBottom(CGContextRef ctx, CGRect rect, CGFloat radius, BOOL closeTop)
{
    if (closeTop) {
        OQAppendRectWithRoundedCornerMask(ctx, rect, radius, (OQRoundedRectCornerBottomLeft | OQRoundedRectCornerBottomRight));
    } else {
        CGPoint bottomLeft  = CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect));
        CGPoint bottomRight = CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect));
        CGPoint topRight    = CGPointMake(CGRectGetMaxX(rect), CGRectGetMinY(rect));
        CGPoint topLeft     = CGPointMake(CGRectGetMinX(rect), CGRectGetMinY(rect));
        
        CGContextMoveToPoint(ctx, topLeft.x, topLeft.y);
        CGContextAddLineToPoint(ctx, bottomLeft.x, bottomLeft.y - radius);
        CGContextAddArcToPoint(ctx, bottomLeft.x, bottomLeft.y, bottomLeft.x + radius, bottomLeft.y, radius);
        CGContextAddLineToPoint(ctx, bottomRight.x - radius, bottomRight.y);
        CGContextAddArcToPoint(ctx, bottomRight.x, bottomRight.y, bottomRight.x, bottomRight.y - radius, radius);
        CGContextAddLineToPoint(ctx, topRight.x, topRight.y);
    }
}

void OQAppendRectWithRoundedBottomLeft(CGContextRef ctx, CGRect rect, CGFloat radius, BOOL closeTop)
{
    if (closeTop) {
        OQAppendRectWithRoundedCornerMask(ctx, rect, radius, OQRoundedRectCornerBottomLeft);
    } else {
        CGPoint bottomLeft  = CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect));
        CGPoint bottomRight = CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect));
        CGPoint topRight    = CGPointMake(CGRectGetMaxX(rect), CGRectGetMinY(rect));
        CGPoint topLeft     = CGPointMake(CGRectGetMinX(rect), CGRectGetMinY(rect));
        
        CGContextMoveToPoint(ctx, topLeft.x, topLeft.y);
        CGContextAddLineToPoint(ctx, bottomLeft.x, bottomLeft.y - radius);
        CGContextAddArcToPoint(ctx, bottomLeft.x, bottomLeft.y, bottomLeft.x + radius, bottomLeft.y, radius);
        CGContextAddLineToPoint(ctx, bottomRight.x, bottomRight.y);
        CGContextAddLineToPoint(ctx, topRight.x, topRight.y);
    }
    
    
    if (closeTop)
        CGContextClosePath(ctx);
}

void OQAppendRectWithRoundedBottomRight(CGContextRef ctx, CGRect rect, CGFloat radius, BOOL closeTop)
{
    if (closeTop) {
        OQAppendRectWithRoundedCornerMask(ctx, rect, radius, OQRoundedRectCornerBottomRight);
    } else {
        CGPoint bottomLeft  = CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect));
        CGPoint bottomRight = CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect));
        CGPoint topRight    = CGPointMake(CGRectGetMaxX(rect), CGRectGetMinY(rect));
        CGPoint topLeft     = CGPointMake(CGRectGetMinX(rect), CGRectGetMinY(rect));
        
        CGContextMoveToPoint(ctx, topLeft.x, topLeft.y);
        CGContextAddLineToPoint(ctx, bottomLeft.x, bottomLeft.y);
        CGContextAddLineToPoint(ctx, bottomRight.x - radius, bottomRight.y);
        CGContextAddArcToPoint(ctx, bottomRight.x, bottomRight.y, bottomRight.x, bottomRight.y - radius, radius);
        CGContextAddLineToPoint(ctx, topRight.x, topRight.y);
    }
}

void OQAppendRectWithRoundedLeft(CGContextRef ctx, CGRect rect, CGFloat radius, BOOL closeRight)
{
    if (closeRight) {
        OQAppendRectWithRoundedCornerMask(ctx, rect, radius, (OQRoundedRectCornerBottomLeft | OQRoundedRectCornerTopLeft));
    } else {
        CGPoint bottomLeft  = CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect));
        CGPoint bottomRight = CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect));
        CGPoint topRight    = CGPointMake(CGRectGetMaxX(rect), CGRectGetMinY(rect));
        CGPoint topLeft     = CGPointMake(CGRectGetMinX(rect), CGRectGetMinY(rect));
        
        CGContextMoveToPoint(ctx, topRight.x, topRight.y);
        CGContextAddLineToPoint(ctx, topLeft.x + radius, topLeft.y);
        CGContextAddArcToPoint(ctx, topLeft.x, topLeft.y, topLeft.x, topLeft.y + radius, radius);
        CGContextAddLineToPoint(ctx, bottomLeft.x, bottomLeft.y - radius );
        CGContextAddArcToPoint(ctx, bottomLeft.x, bottomLeft.y, bottomLeft.x + radius, bottomLeft.y, radius);
        CGContextAddLineToPoint(ctx, bottomRight.x, bottomRight.y);
    }
}

void OQAppendRectWithRoundedRight(CGContextRef ctx, CGRect rect, CGFloat radius, BOOL closeLeft)
{
    if (closeLeft) {
        OQAppendRectWithRoundedCornerMask(ctx, rect, radius, (OQRoundedRectCornerBottomRight | OQRoundedRectCornerTopRight));
    } else {
        CGPoint bottomLeft  = CGPointMake(CGRectGetMinX(rect), CGRectGetMaxY(rect));
        CGPoint bottomRight = CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect));
        CGPoint topRight    = CGPointMake(CGRectGetMaxX(rect), CGRectGetMinY(rect));
        CGPoint topLeft     = CGPointMake(CGRectGetMinX(rect), CGRectGetMinY(rect));
        
        CGContextMoveToPoint(ctx, topLeft.x, topLeft.y);
        CGContextAddLineToPoint(ctx, topRight.x - radius, topRight.y);
        CGContextAddArcToPoint(ctx, topRight.x, topRight.y, topRight.x, topRight.y + radius, radius);
        CGContextAddLineToPoint(ctx, bottomRight.x, bottomRight.y - radius );
        CGContextAddArcToPoint(ctx, bottomRight.x, bottomRight.y, bottomRight.x - radius, bottomRight.y, radius);
        CGContextAddLineToPoint(ctx, bottomLeft.x, bottomLeft.y);
    }
}

// No size change -- might even overflow
CGRect OQCenteredIntegralRectInRect(CGRect enclosingRect, CGSize toCenter)
{
    CGPoint pt;
    
    pt.x = CGRectGetMinX(enclosingRect) + (enclosingRect.size.width - toCenter.width)/2;
    pt.y = CGRectGetMinY(enclosingRect) + (enclosingRect.size.height - toCenter.height)/2;
    
    // TODO: Assuming 1-1 mapping between user and device space
    pt.x = ceil(pt.x);
    pt.y = ceil(pt.y);
    
    return CGRectMake(pt.x, pt.y, toCenter.width, toCenter.height);
}

CGRect OQLargestCenteredIntegralRectInRectWithAspectRatioAsSize(CGRect enclosingRect, CGSize toCenter)
{
    CGFloat xRatio = enclosingRect.size.width / toCenter.width;
    CGFloat yRatio = enclosingRect.size.height / toCenter.height;
    
    // Make sure we have an exact match on the min/max edge on the fitting axis
    if (xRatio == yRatio)
        return enclosingRect; // same size already
    
    CGRect result;
    if (xRatio < yRatio) {
        CGFloat x = enclosingRect.origin.x;
        CGFloat width = enclosingRect.size.width;
        
        CGFloat height = floor(toCenter.height * xRatio);
        CGFloat y = round(enclosingRect.origin.y + 0.5f * (enclosingRect.size.height - height));
        
        result = CGRectMake(x, y, width, height);
    } else {
        CGFloat y = enclosingRect.origin.y;
        CGFloat height = enclosingRect.size.height;

        CGFloat width = floor(toCenter.width * yRatio);
        CGFloat x = round(enclosingRect.origin.x + 0.5f * (enclosingRect.size.width - width));
        
        result = CGRectMake(x, y, width, height);
    }
    
    // Make sure we really did snap exactly to one pair of sides
    OBASSERT(OFExtentsEqual(OFExtentFromRectXRange(enclosingRect), OFExtentFromRectXRange(result)) ||
             OFExtentsEqual(OFExtentFromRectYRange(enclosingRect), OFExtentFromRectYRange(result)));
    
    // Make sure we don't overflow on nearly identical rects or whatever
    OBASSERT(CGRectContainsRect(enclosingRect, result));
    
    // If we use this in a hi dpi context, we'll want to perform this operation in device space, or pass in a context and do the conversion here
    OBASSERT(CGRectEqualToRect(result, CGRectIntegral(result)));
    
    return result;
}

// Shinks if necessary
CGRect OQCenterAndFitIntegralRectInRectWithSameAspectRatioAsSize(CGRect enclosingRect, CGSize toCenter)
{
    if (toCenter.width <= enclosingRect.size.width && toCenter.height <= enclosingRect.size.height)
        return OQCenteredIntegralRectInRect(enclosingRect, toCenter);
    return OQLargestCenteredIntegralRectInRectWithAspectRatioAsSize(enclosingRect, toCenter);
}

#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED

#if __MAC_OS_X_VERSION_MIN_REQUIRED < 40000 /* Apple recommends using literal numbers here instead of version constants */
/* It's important that the compiler select the CGFloat declaration of -scale instead of the one that returns 'short' ! */
@interface UIImage (OQForwardCompatibility)
@property(nonatomic,readonly) CGFloat scale;
@end
#endif

void OQDrawImageCenteredInRect(CGContextRef ctx, UIImage *image, CGRect rect)
{
#if __MAC_OS_X_VERSION_MIN_REQUIRED < 40000 /* Apple recommends using literal numbers here instead of version constants */
    /* -[UIImage scale] appeared in iOS 4.0 */
    CGFloat scale = [image respondsToSelector:@selector(scale)] ? [image scale] : 1.0;
#else
    CGFloat scale = [image scale];
#endif
    OQDrawCGImageWithScaleCenteredInRect(ctx, [image CGImage], scale, rect);
}
#endif

void OQDrawCGImageWithScaleCenteredInRect(CGContextRef ctx, CGImageRef image, CGFloat scale, CGRect rect)
{
    CGSize imageSize = CGSizeMake(CGImageGetWidth(image) / scale, CGImageGetHeight(image) / scale);
    CGRect imageRect = OQCenteredIntegralRectInRect(rect, imageSize);
    
    CGContextDrawImage(ctx, imageRect, image);
}

void OQPreflightImage(CGImageRef image)
{
    // Force decoding of the image data up front. This can be useful when we want to ensure that UI interaction isn't slowed down the first time a image comes on screen.
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, 1, 1, 8/*bitsPerComponent*/, 4/*bytesPerRow*/, colorSpace, kCGImageAlphaNoneSkipFirst);
    CGColorSpaceRelease(colorSpace);
    
    OBASSERT(ctx);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, 1, 1), image);
        CGContextRelease(ctx);
    }
}

CGImageRef OQCopyFlattenedImage(CGImageRef image)
{
    return OQCreateImageWithSize(image, CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image)), kCGInterpolationNone);
}

CGImageRef OQCreateImageWithSize(CGImageRef image, CGSize size, CGInterpolationQuality interpolationQuality)
{
    OBPRECONDITION(image);
    OBPRECONDITION(size.width == floor(size.width));
    OBPRECONDITION(size.height == floor(size.height));
    OBPRECONDITION(size.width >= 1);
    OBPRECONDITION(size.height >= 1);
    
    // Try building a bitmap context with the same settings as the input image.
    CGColorSpaceRef colorSpace = CGImageGetColorSpace(image);
    size_t bytesPerPixel = CGImageGetBitsPerPixel(image) / 8; OBASSERT((CGImageGetBitsPerPixel(image) % 8) == 0);
    CGContextRef ctx = CGBitmapContextCreate(NULL, size.width, size.height, CGImageGetBitsPerComponent(image), bytesPerPixel*size.width, colorSpace, CGImageGetAlphaInfo(image));
    if (!ctx) {
        // Fall back to something that CGBitmapContext actually understands
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        ctx = CGBitmapContextCreate(NULL, size.width, size.height, 8/*bitsPerComponent*/, 4*size.width, colorSpace, kCGImageAlphaPremultipliedFirst);
        CGColorSpaceRelease(colorSpace);
    }

    CGContextSetInterpolationQuality(ctx, interpolationQuality);
    CGContextDrawImage(ctx, CGRectMake(0, 0, size.width, size.height), image);
    CGImageRef newImage = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    
    return newImage;
}

