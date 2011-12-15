// Copyright 2010-2011 The Omni Group. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.
//
// $Id$

#import <UIKit/UIViewController.h>
#import <OmniUI/OUISyncTypes.h>


@interface OUISyncMenuController : UIViewController

+ (void)displayInSheet;

- (void)showMenuFromBarItem:(UIBarButtonItem *)barItem;

@property (nonatomic, assign) BOOL isExporting;

@end
