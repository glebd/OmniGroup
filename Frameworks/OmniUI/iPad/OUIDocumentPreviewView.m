// Copyright 2010-2011 The Omni Group. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.

#import <OmniUI/OUIDocumentPreviewView.h>

#import <OmniUI/OUIDocumentPreview.h>
#import <OmniUI/UIView-OUIExtensions.h>
#import <OmniQuartz/CALayer-OQExtensions.h>
#import <OmniQuartz/OQDrawing.h>

#import "OUIParameters.h"

RCS_ID("$Id$");

@implementation OUIDocumentPreviewView
{
    NSMutableArray *_previews;
    
    BOOL _landscape;
    BOOL _group;
    BOOL _needsAntialiasingBorder;
    BOOL _selected;
    BOOL _draggingSource;
    BOOL _highlighted;
    BOOL _downloading;
    
    NSTimeInterval _animationDuration;
    UIViewAnimationCurve _animationCurve;

    CALayer *_selectionLayer;
    CALayer *_imageLayer;
    UIImageView *_statusImageView;
    UIProgressView *_transferProgressView;
}

static id _commonInit(OUIDocumentPreviewView *self)
{    
    self->_imageLayer = [[CALayer alloc] init];
    self->_imageLayer.opaque = YES;
    
    [self.layer addSublayer:self->_imageLayer];
    
    return self;
}

/*
 
 The edgeAntialiasingMask property on CALayer is pretty useless for our needs -- we aren't butting two objects together and it doesn't do edge coverage right (it seems).
 
 Instead, if we have the wiggle-edit animation going, we set shouldRasterize=YES on *our* layer. CALayer attempts to find the smallest rectangle that will enclose the drawing when it flattens the bitmap. Because we have a shadow, this rect extends 1px-ish outside the preview image layer (which has the most visible edge) and we get interior-style linear texture lookup.
 
 When we are selected, though, we don't have a shadow, but we *do* have a sublayer for the border that extends outside the bounds of the image, and the preview image has some exterior alpha. Again, this makes the flattened rasterized image have transparent pixels on the border and do linear texture lookup on the interior.
 
 Another (terrible) hack that we don't use here is to set a mostly transparent background color on this superview. If it is too transparent, CALayer will ignore us for the purposes of computing the size of the area to rasterisze. Another possible trick, that I haven't tried, would be to set a 1x1 transparent image as our content (or nil if we don't want to be rasterized). This seems like it would be less prone to implementation changes in computing how transparent is "too transparent" to include in the rasterization.
 */

static void _updateShouldRasterize(OUIDocumentPreviewView *self)
{
    BOOL shouldRasterize = self->_needsAntialiasingBorder;
    self.layer.shouldRasterize = shouldRasterize;
}

- initWithFrame:(CGRect)frame;
{
    if (!(self = [super initWithFrame:frame]))
        return nil;
    return _commonInit(self);
}

- initWithCoder:(NSCoder *)coder;
{
    if (!(self = [super initWithCoder:coder]))
        return nil;
    return _commonInit(self);
}

- (void)dealloc;
{
    [_previews release];
    [_imageLayer release];
    [_statusImageView release];
    [_transferProgressView release];
    [_selectionLayer release];
    [super dealloc];
}

@synthesize landscape = _landscape;
- (void)setLandscape:(BOOL)landscape;
{
    if (_landscape == landscape)
        return;
    
    _landscape = landscape;
    
    [self.superview setNeedsLayout]; // -previewRectInFrame: changes based on the orientation
    [self setNeedsLayout];
}

@synthesize group = _group;
- (void)setGroup:(BOOL)group;
{
    if (_group == group)
        return;
    
    _group = group;
    [self setNeedsLayout];
}

// See commentary by _updateShouldRasterize() for how edge antialiasing works.
@synthesize needsAntialiasingBorder = _needsAntialiasingBorder;
- (void)setNeedsAntialiasingBorder:(BOOL)needsAntialiasingBorder;
{
    if (_needsAntialiasingBorder == needsAntialiasingBorder)
        return;
    
    _needsAntialiasingBorder = needsAntialiasingBorder;
    
    _updateShouldRasterize(self);
    [self setNeedsLayout];
}

@synthesize selected = _selected;
- (void)setSelected:(BOOL)selected;
{
    if (_selected == selected)
        return;
    
    _selected = selected;
    
    if (_selected && !_selectionLayer) {
        OUIWithoutAnimating(^{
            _selectionLayer = [[CALayer alloc] init];
            _selectionLayer.name = @"selection";
            
            UIImage *image = [UIImage imageNamed:@"OUIDocumentPreviewViewSelectedBorder.png"];
            CGSize imageSize = image.size;
            
            _selectionLayer.contents = (id)[image CGImage];
            _selectionLayer.contentsCenter = CGRectMake(kOUIDocumentPreviewViewBorderEdgeInsets.left/imageSize.width,
                                                        kOUIDocumentPreviewViewBorderEdgeInsets.top/imageSize.height,
                                                        (imageSize.width-kOUIDocumentPreviewViewBorderEdgeInsets.left-kOUIDocumentPreviewViewBorderEdgeInsets.right)/imageSize.width,
                                                        (imageSize.height-kOUIDocumentPreviewViewBorderEdgeInsets.top-kOUIDocumentPreviewViewBorderEdgeInsets.bottom)/imageSize.height);
        });
        
        [self.layer insertSublayer:_selectionLayer below:_imageLayer];
    } else if (!_selected && _selectionLayer) {
        [_selectionLayer removeFromSuperlayer];
        [_selectionLayer release];
        _selectionLayer = nil;
    }
    
    [self.superview setNeedsLayout]; // -previewRectInFrame: changes based on the selection state
    [self setNeedsLayout];
}

@synthesize draggingSource = _draggingSource;
- (void)setDraggingSource:(BOOL)draggingSource;
{
    if (_draggingSource == draggingSource)
        return;
    
    _draggingSource = draggingSource;
    
    [self setNeedsLayout];
}

@synthesize highlighted = _highlighted;
- (void)setHighlighted:(BOOL)highlighted;
{
    if (_highlighted == highlighted)
        return;
    
    _highlighted = highlighted;
    
    [self setNeedsLayout];
}

@synthesize previews = _previews;

- (void)addPreview:(OUIDocumentPreview *)preview;
{
    OBPRECONDITION([NSThread isMainThread]);
    OBPRECONDITION(preview);
    OBPRECONDITION(!_previews || [_previews indexOfObjectIdenticalTo:preview] == NSNotFound);
    
    OBFinishPortingLater("Maintain the previews the sorted order that our enclosing picker is using.");
    
    if (!_previews)
        _previews = [[NSMutableArray alloc] init];
    
    // Files should only have one preview. We might hold onto one while refreshing, though.
    if (!_group)
        [_previews removeAllObjects];
    [_previews addObject:preview];
    
    PREVIEW_DEBUG(@"%p addPreview: %@", self, [(id)preview shortDescription]);

    // Our frame gets set by our superview based on our preview size
    [self.superview setNeedsLayout];
    [self setNeedsLayout];
}

- (void)discardPreviews;
{
    OBPRECONDITION([NSThread isMainThread]);

    if ([_previews count] == 0)
        return;
    
    PREVIEW_DEBUG(@"%p discardPreviews", self);

    [_previews removeAllObjects];
}

#define kOUIDocumentPreviewViewNormalShadowInsets UIEdgeInsetsMake(ceil(kOUIDocumentPreviewViewNormalShadowBlur)/*top*/, ceil(kOUIDocumentPreviewViewNormalShadowBlur)/*left*/, ceil(kOUIDocumentPreviewViewNormalShadowBlur + 1)/*bottom*/, ceil(kOUIDocumentPreviewViewNormalShadowBlur)/*right*/)

static CGRect _outsetRect(CGRect rect, UIEdgeInsets insets)
{
    UIEdgeInsets outsets = {
        .top = -insets.top,
        .bottom = -insets.bottom,
        .left = -insets.left,
        .right = -insets.right,
    };
    return UIEdgeInsetsInsetRect(rect, outsets);
}

- (UIEdgeInsets)_edgeInsets;
{
    UIEdgeInsets insets;
    
    if (_selected) {
        // Room for the selection border image
        insets = kOUIDocumentPreviewViewBorderEdgeInsets;
    } else if (_draggingSource) {
        // No shadow
        insets = UIEdgeInsetsZero;
    } else {
        // Normal shadow
        insets = kOUIDocumentPreviewViewNormalShadowInsets;
    }
    
    return insets;
}

// Could use -sizeThatFits:, but that would require the caller to center the size... just as easy to define our own API
- (CGRect)previewRectInFrame:(CGRect)frame;
{
    OBPRECONDITION([NSThread isMainThread]);
    
    if (_group) {
        return CGRectInset(frame, 16, 16); // ... or something
    } else {
        OUIDocumentPreview *preview = [_previews lastObject];

        CGSize previewSize;
        if (preview && preview.type == OUIDocumentPreviewTypeRegular) {
            previewSize = preview.size;
            
            CGFloat scale = [OUIDocumentPreview previewImageScale];
            previewSize.width = floor(previewSize.width / scale);
            previewSize.height = floor(previewSize.height / scale);
        } else
            previewSize = [OUIDocumentPreview maximumPreviewSizeForLandscape:_landscape];
        
        CGRect previewFrame;
        previewFrame.origin.x = floor(CGRectGetMidX(frame) - previewSize.width / 2);
        previewFrame.origin.y = floor(CGRectGetMidY(frame) - previewSize.height / 2);
        previewFrame.size = previewSize;
        
        return _outsetRect(previewFrame, [self _edgeInsets]);
    }
}

- (CGRect)imageBounds;
{
    return UIEdgeInsetsInsetRect(self.bounds, [self _edgeInsets]);
}

@synthesize animationDuration = _animationDuration;
@synthesize animationCurve = _animationCurve;

- (UIImage *)statusImage;
{
    return _statusImageView.image;
}
- (void)setStatusImage:(UIImage *)image;
{
    if (self.statusImage == image)
        return;

    if (image) {
        if (!_statusImageView) {
            _statusImageView = [[UIImageView alloc] initWithImage:nil];
            [self addSubview:_statusImageView];
        }
        _statusImageView.image = image;
    } else {
        if (_statusImageView) {
            [_statusImageView removeFromSuperview];
            [_statusImageView release];
            _statusImageView = nil;
        }
    }
    
    _updateShouldRasterize(self);
    [self setNeedsLayout];
}

@synthesize downloading = _downloading;
- (void)setDownloading:(BOOL)downloading;
{
    if (_downloading == downloading)
        return;
    
    _downloading = downloading;
    
    [self setNeedsLayout];
}

- (BOOL)showsProgress;
{
    return _transferProgressView != nil;
}
- (void)setShowsProgress:(BOOL)showsProgress;
{
    if (showsProgress) {
        if (_transferProgressView)
            return;
        _transferProgressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        [self addSubview:self->_transferProgressView];
    } else {
        if (_transferProgressView) {
            [_transferProgressView removeFromSuperview];
            [_transferProgressView release];
            _transferProgressView = nil;
        }
    }
    
    _updateShouldRasterize(self);
    [self setNeedsLayout];
}

- (double)progress;
{
    if (_transferProgressView)
        return _transferProgressView.progress;
    return 0.0;
}
- (void)setProgress:(double)progress;
{
    OBPRECONDITION(_transferProgressView || progress == 0.0);
    
    _transferProgressView.progress = progress;
}

#pragma mark -
#pragma mark UIView (OUIExtensions)

- (UIImage *)snapshotImage;
{
    if (_group) {
        OBFinishPortingLater("Want a special case for this?");
    } else if (!_draggingSource) {
        // If we have one, return the image we already have for the document picker open/close animation.
        // Note: this may have a tiny glitch due to the 1px inset to avoid edge aliasing issues.
        OBASSERT([_previews count] <= 1);
        OUIDocumentPreview *preview = [_previews lastObject];
        
        if (preview.type == OUIDocumentPreviewTypeRegular) {
            OBFinishPortingLater("The CGImageRef will be 2x scale from what we want, possibly");
            OBASSERT(preview.image);
            return [UIImage imageWithCGImage:preview.image];
        }
    }
    
    return [super snapshotImage];
}

#pragma mark -
#pragma mark UIView subclass

#ifdef OMNI_ASSERTIONS_ON
- (void)setFrame:(CGRect)frame;
{
    OBPRECONDITION(CGRectEqualToRect(frame, CGRectIntegral(frame)));
    [super setFrame:frame];
}
#endif

- (void)layoutSubviews;
{
    CGRect bounds = self.bounds;
    if (CGRectEqualToRect(bounds, CGRectZero))
        return; // Not configured yet.
    
    CGRect previewFrame = UIEdgeInsetsInsetRect(bounds, [self _edgeInsets]);
    
    // TODO: Placeholder images -- make the preview generation build pre-composited images
    OUIWithoutLayersAnimating(^{
        _imageLayer.frame = previewFrame;
    });

    // Image
    if (_group) {
        // Want to add multiple image layers? Want to force the caller to pre-composite a 3x3 grid of preview images?        
        OBASSERT(self.superview.hidden);
    } else {
        _imageLayer.contents = (id)[[_previews lastObject] image];
    }
    
    // Highlighting (image alpha)
    {
        CGFloat alpha = 1;
        
        if (_highlighted)
            alpha = 0.5;
        
        _imageLayer.opacity = alpha;
    }
    
    // Shadow
    if (_selected || _draggingSource) {
        // No shadow
        OUIWithoutLayersAnimating(^{
            _imageLayer.shadowPath = NULL;
            _imageLayer.shadowColor = NULL;
            _imageLayer.shadowOpacity = 0;
        });
    } else {
        OUIWithoutLayersAnimating(^{
            CGPathRef path = CGPathCreateWithRect(CGRectMake(0, 0, previewFrame.size.width, previewFrame.size.height), NULL/*transform*/);
            _imageLayer.shadowPath = path;
            CFRelease(path);
            
            _imageLayer.shadowOpacity = 1;
            _imageLayer.shadowRadius = kOUIDocumentPreviewViewNormalShadowBlur;
            _imageLayer.shadowOffset = CGSizeMake(0, 1);
            
            //CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
            //CGFloat shadowComponents[] = {1, 0, 0, 1};
            CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
            CGFloat shadowComponents[] = {kOUIDocumentPreviewViewNormalShadowWhiteAlpha.w, kOUIDocumentPreviewViewNormalShadowWhiteAlpha.a};
            CGColorRef shadowColor = CGColorCreate(colorSpace, shadowComponents);
            CGColorSpaceRelease(colorSpace);
            _imageLayer.shadowColor = shadowColor;
            CGColorRelease(shadowColor);
        });
    }

    // Selection
    if (_selectionLayer) {
        OUIWithoutLayersAnimating(^{
            _selectionLayer.frame = _outsetRect(previewFrame, kOUIDocumentPreviewViewBorderEdgeInsets);
        });
    }
    
    if (_statusImageView) {
        UIImage *statusImage = _statusImageView.image;
        if (statusImage) {
            CGSize statusImageSize = statusImage.size;
            CGRect statusFrame = CGRectMake(CGRectGetMaxX(previewFrame) - statusImageSize.width, CGRectGetMinY(previewFrame), statusImageSize.width, statusImageSize.height);
            
            OUIWithoutAnimating(^{
                _statusImageView.frame = statusFrame;
            });
        }
    }

    if (_transferProgressView) {
        OUIWithoutAnimating(^{
            CGRect previewFrameInsetForProgress = CGRectInset(previewFrame, 16, 16);
            CGRect progressFrame = previewFrameInsetForProgress;
            
            progressFrame.size.height = [_transferProgressView sizeThatFits:progressFrame.size].height;
            progressFrame.origin.y = CGRectGetMaxY(previewFrameInsetForProgress) - progressFrame.size.height;
            
            _transferProgressView.frame = progressFrame;
        });
    }
}

#if 0
- (void)drawRect:(CGRect)rect;
{
    if (_group) {
        // Disabled for now since we get added to the view hierarchy and drawn once while we are hidden (during closing a document, for example), as previews are loading.
        //OBASSERT([_previews count] >= 1); // can have a group with 1 item

        // 3x3 grid of previews
        const CGFloat kPreviewPadding = 8;
        const NSUInteger kPreviewsPerRow = 3;
        const NSUInteger kPreviewRows = 3;
        
        CGRect bounds = self.bounds;
        CGSize previewSize = CGSizeMake((bounds.size.width - (kPreviewsPerRow + 1)*kPreviewPadding) / kPreviewsPerRow,
                                        (bounds.size.height - (kPreviewRows + 1)*kPreviewPadding) / kPreviewRows);
        
        [[UIColor blackColor] set];
        UIRectFill(bounds);
        
        OBFinishPortingLater("Do a gray overlay for highlighting"); // iWork highlights folders as they are opening and on long press (though long press does nothing interesting).
        
        NSUInteger previewCount = [_previews count];
        for (NSUInteger row = 0; row < kPreviewRows; row++) {
            for (NSUInteger column = 0; column < kPreviewsPerRow; column++) {
                NSUInteger previewIndex = row * kPreviewsPerRow + column;
                if (previewIndex >= previewCount)
                    break;
                
                CGPoint pt = bounds.origin;
                pt.x += ceil(column * previewSize.width + kPreviewPadding);
                pt.y += ceil(row * previewSize.height + kPreviewPadding);
                
                OUIDocumentPreview *preview = [_previews objectAtIndex:previewIndex];

                [preview drawInRect:CGRectMake(pt.x, pt.y, previewSize.width, previewSize.height)];
            }
        }
    } else {
        OBASSERT([_previews count] <= 1);
        
        CGRect previewRect = CGRectInset(self.bounds, 1, 1); // space for edge antialiasing
              
        if (_draggingSource) {
            OBFinishPortingLater("Do empty box look");
            
            [[UIColor blueColor] set];
            UIRectFill(previewRect);
            
        } else {
            OUIDocumentPreview *preview = [_previews lastObject];
            CGContextRef ctx = UIGraphicsGetCurrentContext();
            
            BOOL drawingShadow = NO;
            
            if (_selected) {
                UIImage *image = [UIImage imageNamed:@"OUIDocumentPreviewViewSelectedBorder.png"];
                OBASSERT(image);
                
                image = [image resizableImageWithCapInsets:kOUIDocumentPreviewViewBorderEdgeInsets];
                [image drawInRect:previewRect];
                
                previewRect = UIEdgeInsetsInsetRect(previewRect, kOUIDocumentPreviewViewBorderEdgeInsets);
            } else if (_draggingSource) {
                // No shadow
            } else {
                // Normal preview
                drawingShadow = YES;
                CGContextSaveGState(ctx);
                
                CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
                CGFloat shadowComponents[] = {kOUIDocumentPreviewViewNormalShadowWhiteAlpha.w, kOUIDocumentPreviewViewNormalShadowWhiteAlpha.a};
                CGColorRef shadowColor = CGColorCreate(colorSpace, shadowComponents);
                CGColorSpaceRelease(colorSpace);
                
                CGContextSetShadowWithColor(ctx, CGSizeMake(0, 1), kOUIDocumentPreviewViewNormalShadowBlur, shadowColor);
                CGColorRelease(shadowColor);
                
                // Leave room for the shadow
                previewRect = UIEdgeInsetsInsetRect(previewRect, kOUIDocumentPreviewViewNormalShadowInsets);
            }
            
            BOOL isPlaceholder = (!preview || preview.type != OUIDocumentPreviewTypeRegular);
            if (isPlaceholder) {
                [[UIColor whiteColor] set];
                UIRectFill(previewRect);
                
                // In this case the white box has the shadow and we don't want the preview to be shadowed *too*
                if (drawingShadow) {
                    CGContextRestoreGState(ctx);
                    drawingShadow = NO;
                }
            }
            
            CGRect previewImageRect = previewRect;
            if (preview && isPlaceholder)
                previewImageRect = OQLargestCenteredIntegralRectInRectWithAspectRatioAsSize(previewRect, preview.size);
            [preview drawInRect:previewImageRect];

            if (drawingShadow) {
                CGContextRestoreGState(ctx);
            }
            
            if (_highlighted || _downloading) {
                CGContextSaveGState(ctx);
                                
                CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
                CGContextSetFillColorSpace(ctx, colorSpace);
                CGColorSpaceRelease(colorSpace);

                CGFloat highlight[] = {0, kOUIDocumentPreviewHighlightAlpha};
                CGContextSetFillColor(ctx, highlight);
                
                CGContextFillRect(ctx, previewRect);
                CGContextRestoreGState(ctx);
            }
        }
    }
}
#endif

@end

