// Copyright 2010-2011 The Omni Group. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.
//
// $Id$

#import <OmniFileStore/OFSFeatures.h>

#if OFS_DOCUMENT_STORE_SUPPORTED

#import <OmniFileStore/OFSDocumentStoreItem.h>

@interface OFSDocumentStoreItem (/*Internal*/)

- (void)_invalidate;

@end

#endif // OFS_DOCUMENT_STORE_SUPPORTED
