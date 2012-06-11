// Copyright 2010-2012 The Omni Group. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.
//
// $Id$

#import <UIKit/UIView.h>

extern NSString * const OUIDocumentPickerScrollViewItemsBinding;

@class OFPreference;
@class OFSDocumentStoreItem, OFSDocumentStoreFileItem;
@class OUIDragGestureRecognizer, OUIDocumentPickerItemView, OUIDocumentPickerFileItemView, OUIDocumentPickerScrollView;

typedef enum {
    OUIDocumentPickerItemSortByDate,
    OUIDocumentPickerItemSortByName,
} OUIDocumentPickerItemSort;

typedef enum {
    OUIDocumentPickerItemViewTapAreaPreview,
    OUIDocumentPickerItemViewTapAreaLabelAndDetails,
} OUIDocumentPickerItemViewTapArea;

@protocol OUIDocumentPickerScrollViewDelegate <UIScrollViewDelegate>
- (void)documentPickerScrollView:(OUIDocumentPickerScrollView *)scrollView itemViewTapped:(OUIDocumentPickerItemView *)itemView inArea:(OUIDocumentPickerItemViewTapArea)area;
- (void)documentPickerScrollView:(OUIDocumentPickerScrollView *)scrollView dragWithRecognizer:(OUIDragGestureRecognizer *)recognizer;
@end

@interface OUIDocumentPickerScrollView : UIScrollView <UIGestureRecognizerDelegate>

@property(nonatomic,assign) id <OUIDocumentPickerScrollViewDelegate> delegate;

- (void)willRotateWithDuration:(NSTimeInterval)duration;
- (void)didRotate;
@property(nonatomic,assign) BOOL landscape;
@property(nonatomic,assign) BOOL ubiquityEnabled;

@property(nonatomic,readonly) NSSet *items;
- (void)startAddingItems:(NSSet *)toAdd;
- (void)finishAddingItems:(NSSet *)toAdd;
- (void)startRemovingItems:(NSSet *)toRemove;
- (void)finishRemovingItems:(NSSet *)toRemove;

@property(nonatomic,readonly) NSArray *sortedItems;
@property(nonatomic,retain) id draggingDestinationItem;

- (void)scrollItemToVisible:(OFSDocumentStoreItem *)item animated:(BOOL)animated;
- (void)scrollItemsToVisible:(id <NSFastEnumeration>)items animated:(BOOL)animated;
- (void)sortItems;

- (CGRect)frameForItem:(OFSDocumentStoreItem *)item;

- (OUIDocumentPickerItemView *)itemViewForItem:(OFSDocumentStoreItem *)item;
- (OUIDocumentPickerFileItemView *)fileItemViewForFileItem:(OFSDocumentStoreFileItem *)fileItem;
- (OUIDocumentPickerItemView *)itemViewHitInPreviewAreaByRecognizer:(UIGestureRecognizer *)recognizer;
- (OUIDocumentPickerFileItemView *)fileItemViewHitInPreviewAreaByRecognizer:(UIGestureRecognizer *)recognizer;

- (OFSDocumentStoreFileItem *)preferredFileItemForNextPreviewUpdate:(NSSet *)fileItemsNeedingPreviewUpdate;
- (void)previewsUpdatedForFileItem:(OFSDocumentStoreFileItem *)fileItem;

- (void)setEditing:(BOOL)editing animated:(BOOL)animated;


@property(nonatomic) OUIDocumentPickerItemSort itemSort;

- (void)startIgnoringItemForLayout:(OFSDocumentStoreItem *)item;
- (void)stopIgnoringItemForLayout:(OFSDocumentStoreItem *)item;

@end
