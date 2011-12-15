// Copyright 2010-2011 The Omni Group. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.
//
// $Id$

#import <OmniUI/OUIAppController.h>

#import <OmniFileStore/OFSDocumentStoreDelegate.h>
#import <OmniUI/OUIUndoBarButtonItem.h>
#import <OmniUI/OUIBarButtonItemBackgroundType.h>

@class OFSDocumentStoreFileItem, OUIDocument, OUIMainViewController, OUIBarButtonItem;

@interface OUISingleDocumentAppController : OUIAppController <UITextFieldDelegate, OUIUndoBarButtonItemTarget, OFSDocumentStoreDelegate>

@property(nonatomic,retain) IBOutlet UIWindow *window;
@property(nonatomic,retain) IBOutlet OUIMainViewController *mainViewController;
@property(nonatomic,retain) IBOutlet UITextField *documentTitleTextField;
@property(nonatomic,retain) IBOutlet UIBarButtonItem *documentTitleToolbarItem;

@property(readonly) UIBarButtonItem *closeDocumentBarButtonItem;
@property(readonly) OUIUndoBarButtonItem *undoBarButtonItem;
@property(readonly) UIBarButtonItem *infoBarButtonItem;

- (NSString *)documentTypeForURL:(NSURL *)url;
- (void)createNewDocumentAtURL:(NSURL *)url completionHandler:(void (^)(NSURL *url, NSError *error))completionHandler;
- (IBAction)makeNewDocument:(id)sender;
- (IBAction)closeDocument:(id)sender;

// Returns the width the _documentTitleTextField should be set to while editing. A different width can be returned depending on isLandscape.
// If overridden in sub-class, don't call super.
- (CGFloat)titleTextFieldWidthForOrientation:(UIInterfaceOrientation)orientation;

- (OUIBarButtonItemBackgroundType)defaultBarButtonBackgroundType;

@property(readonly) OUIDocument *document;

// Sample documents
- (NSString *)sampleDocumentsDirectoryTitle;
- (NSURL *)sampleDocumentsDirectoryURL;
- (void)copySampleDocumentsToUserDocuments;
- (NSString *)localizedNameForSampleDocumentNamed:(NSString *)documentName;
- (NSURL *)URLForSampleDocumentNamed:(NSString *)name ofType:(NSString *)fileType;

// UIApplicationDelegate methods we implement (see OUIAppController too)
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions;
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation;
- (void)applicationWillEnterForeground:(UIApplication *)application;
- (void)applicationDidEnterBackground:(UIApplication *)application;

// OUIDocumentPickerDelegate methods we implement
- (void)documentPicker:(OUIDocumentPicker *)picker openTappedFileItem:(OFSDocumentStoreFileItem *)fileItem;
- (void)documentPicker:(OUIDocumentPicker *)picker openCreatedFileItem:(OFSDocumentStoreFileItem *)fileItem;

// Subclass responsibility
- (Class)documentClassForURL:(NSURL *)url;
- (UIView *)pickerAnimationViewForTarget:(OUIDocument *)document;
- (NSArray *)toolbarItemsForDocument:(OUIDocument *)document;
- (void)showInspectorFromBarButtonItem:(UIBarButtonItem *)item;
- (void)mainThreadFinishedLoadingDocument:(OUIDocument *)document;  // For handling any loading that can't be done in a thread
@end
