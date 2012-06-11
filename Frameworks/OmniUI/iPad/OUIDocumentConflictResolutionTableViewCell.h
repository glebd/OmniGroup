// Copyright 2010-2012 The Omni Group. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.
//
// $Id$

#import <UIKit/UITableViewCell.h>

@class OUIDocumentPreview;
@class NSFileVersion;

@interface OUIDocumentConflictResolutionTableViewCell : UITableViewCell

@property(nonatomic,retain) OUIDocumentPreview *preview;
@property(nonatomic,retain) NSFileVersion *fileVersion;
@property(nonatomic,assign) BOOL landscape;

@end
