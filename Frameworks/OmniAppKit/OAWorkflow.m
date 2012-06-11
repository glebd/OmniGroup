// Copyright 2005, 2010-2012 Omni Development, Inc.  All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.
//
// This code adapted from http://rogueamoeba.com/utm/posts/Article/automator-hosting-2005-06-03-03-00

#import "OAWorkflow.h"

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <OmniBase/OmniBase.h>
#import <OmniFoundation/OmniFoundation.h>
#import "OAVersion.h"

RCS_ID("$Id$");

@interface OAWorkflow ()
- (CFURLRef)_createLaunchApplicationURL CF_RETURNS_RETAINED;
- (NSAppleEventDescriptor*)_launchParamsDescriptorWithFiles:(NSArray *)filePaths;
@end


@implementation OAWorkflow

+ (OAWorkflow *)workflowWithContentsOfFile:(NSString *)path error:(NSError **)outError;
{
    return [[[self alloc] initWithContentsOfFile:path error:outError] autorelease];
}

+ (OAWorkflow *)workflowWithContentsOfURL:(NSURL *)url error:(NSError **)outError;
{
    // Cast necessary for <http://llvm.org/bugs/show_bug.cgi?id=11577> "[self alloc]" in a class method not inferred to return an instance of that class
    // NSAppleScript has this same selector, but with error being 'NSDictionary **'.
    return [[(OAWorkflow *)[self alloc] initWithContentsOfURL:url error:outError] autorelease];
}

- (id)initWithContentsOfFile:(NSString *)path error:(NSError **)outError;
{
    return [self initWithContentsOfURL:[NSURL fileURLWithPath:path] error:outError];
}

- (id)initWithContentsOfURL:(NSURL *)url error:(NSError **)outError;
{
    OBPRECONDITION([url isFileURL]);
    
    if (!(self = [super init]))
        return nil;

    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[url path] traverseLink:YES error:outError];
    if (!attributes) {
        [self release];
        return nil;
    }
        
    _url = [url retain];
    
    return self;
}

- (void)executeWithFiles:(NSArray*)filePaths;
{
    CFURLRef launchApplicationURL = [self _createLaunchApplicationURL];
    if (launchApplicationURL == NULL) {
        NSString *exceptionReason = NSLocalizedStringFromTableInBundle(@"Couldn't locate Automator Launcher.app.", @"OmniAppKit", [OAWorkflow bundle], "workflow execution exception format string");
        [NSException raise:NSInternalInconsistencyException reason:exceptionReason];
        return; // <http://llvm.org/bugs/show_bug.cgi?id=11959> (Add attribute for ObjC "raise" selector)
    }

    LSLaunchURLSpec spec;
    spec.appURL = launchApplicationURL;
    spec.itemURLs = nil;
    spec.passThruParams	= [[self _launchParamsDescriptorWithFiles:filePaths] aeDesc];
    spec.launchFlags = kLSLaunchNewInstance;
    spec.asyncRefCon = nil;
    
    OSStatus err = LSOpenFromURLSpec( &spec, nil );
    CFRelease(launchApplicationURL);
    
    if (err) {
        NSString *exceptionReason = NSLocalizedStringFromTableInBundle(@"Couldn't launch Automator Launcher.app.  LSOpenFromURLSpec returned %@", @"OmniAppKit", [OAWorkflow bundle], "workflow execution exception format string");
        [NSException raise:NSInternalInconsistencyException format:exceptionReason, OFOSStatusDescription(err)];
    }
    
}

#pragma mark - Private

- (CFURLRef)_createLaunchApplicationURL;
{
    CFURLRef appUrl = NULL;
    OSStatus rc = LSFindApplicationForInfo(kLSUnknownCreator, (CFStringRef)@"com.apple.Automator_Launcher", NULL, NULL, &appUrl);
    if (rc != noErr)
        return NULL;
    return appUrl;
}

- (NSAppleEventDescriptor*)_launchParamsDescriptorWithFiles:(NSArray*)filePaths;
{
    NSAppleEventDescriptor* part;
    NSAppleEventDescriptor *paramRecord = [NSAppleEventDescriptor recordDescriptor];
    
    //AMcn - I don't know what this setting is for, but if you set it to anything less then 1999 it doesnt work
    //       It seems to be related to the Finders Automator contextual menu (the first item is 1999, second is 2000, and so on).
    SInt32 cn = 1999;
    part = [NSAppleEventDescriptor descriptorWithDescriptorType:typeSInt32 bytes:&cn length:sizeof(cn)];
    [paramRecord setDescriptor: part forKeyword: 'AMcn'];
    
    // AMap - This seems to be the calling application, but it also appears to be optional
    CFURLRef mainBundleURL = CFBundleCopyBundleURL(CFBundleGetMainBundle());
    FSRef mainBundleFSRef;
    CFURLGetFSRef(mainBundleURL, &mainBundleFSRef);
    part = [NSAppleEventDescriptor descriptorWithDescriptorType:typeFSRef bytes:&mainBundleFSRef length:sizeof(mainBundleFSRef)];
    [paramRecord setDescriptor: part forKeyword: 'AMap'];
    CFRelease(mainBundleURL);
    
    //AMsm - This is the actual workflow file
    FSRef workflowRef;
    CFURLGetFSRef((CFURLRef)_url, &workflowRef);
    part = [NSAppleEventDescriptor descriptorWithDescriptorType:typeFSRef bytes:&workflowRef length:sizeof(workflowRef)];
    [paramRecord setDescriptor: part forKeyword: 'AMsm'];
    
    // AMfs - This is a list of files to send to the workflow
    NSAppleEventDescriptor *fileList = [NSAppleEventDescriptor listDescriptor];
    NSUInteger fileIndex, fileCount = [filePaths count];
    for (fileIndex = 0; fileIndex < fileCount; fileIndex++) {
        NSString *path = [filePaths objectAtIndex:fileIndex];
        FSRef fileRef;
        CFURLGetFSRef((CFURLRef)[NSURL fileURLWithPath:path], &fileRef);
        part = [NSAppleEventDescriptor descriptorWithDescriptorType:typeFSRef bytes:&fileRef length:sizeof(fileRef)];
        if (part)
            [fileList insertDescriptor:part atIndex:fileIndex];
    }
    [paramRecord setDescriptor:fileList forKeyword: 'AMfs'];
    
    return paramRecord;
}

@end
