// Copyright 2010-2011 The Omni Group. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.
//
// $Id$

enum {
    OUIMobileMeSync,
    OUIWebDAVSync,
    OUIiTunesSync,
    OUINumberSyncChoices,
    
    OUIOmniSync, /* still in beta */
    OUISyncTypeNone, /* not used for syncing. used for getting a rough idea of how many export types are available */
}; 
typedef NSUInteger OUISyncType;

enum {
    OUIExportOptionsNone, /* not used for exporting. used for getting a rough idea of how many export types are available */
    OUIExportOptionsExport,
    OUIExportOptionsEmail,
    OUIExportOptionsSendToApp,
}; 
typedef NSUInteger OUIExportOptionsType;