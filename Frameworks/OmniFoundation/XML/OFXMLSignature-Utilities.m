// Copyright 2009-2011 Omni Development, Inc. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.

#import "OFXMLSignature.h"

#import <Foundation/Foundation.h>
#import <OmniBase/OmniBase.h>
#import <OmniFoundation/OFCDSAUtilities.h>
#import <OmniFoundation/NSData-OFExtensions.h>
#import <OmniFoundation/OFErrors.h>
#import <OmniFoundation/NSDictionary-OFExtensions.h>
#import <OmniFoundation/NSMutableDictionary-OFExtensions.h>

#include <libxml/tree.h>

#include <libxml/c14n.h>
#include <libxml/xmlIO.h>
#include <libxml/xmlerror.h>
#include <libxml/xmlmemory.h>
#include <libxml/xmlversion.h>
#include <libxml/xpath.h>
#include <libxml/xpathInternals.h>
#include <libxml/xpointer.h>

RCS_ID("$Id$");

#pragma mark ASN.1 utility routines

/* ASN.1 DER construction utility routines */

#define CLASS_CONSTRUCTED 0x20

/*" Returns an ASN.1 DER INTEGER corresponding to an (unsigned) arbitrary-precision integer. "*/
NSData *OFASN1IntegerFromBignum(NSData *base256Number)
{
    NSUInteger firstDigit = [base256Number indexOfFirstNonZeroByte];
    if (firstDigit == NSNotFound) {
        /* Hardcoded zero representation, since it's a special case */
        static const uint8_t derZero[3] = {
            0x02,  /* Tag: INTEGER */
            0x01,  /* Length: 1 byte */
            0x00   /* Value: Zero */
        };
        return [NSData dataWithBytesNoCopy:(void *)derZero length:3 freeWhenDone:NO];
    }
    NSUInteger bytecount = [base256Number length] - firstDigit;
    NSMutableData *buf;
    if (((unsigned char *)[base256Number bytes])[firstDigit] & 0x80) {
        /* Insert a zero byte, since ASN.1 integers are signed */
        buf = OFASN1CreateForTag(BER_TAG_INTEGER, bytecount + 1);
        [buf appendBytes:"" length:1];
    } else {
        buf = OFASN1CreateForTag(BER_TAG_INTEGER, bytecount);
    }
    [buf autorelease];
    
    if (firstDigit == 0)
        [buf appendData:base256Number];
    else
        [buf appendData:[base256Number subdataWithRange:(NSRange){ firstDigit, bytecount }]];
    
    return buf;
}

/*" Formats the tag byte and length field of an ASN.1 item. "*/
NSMutableData *OFASN1CreateForTag(uint8_t tag, NSUInteger byteCount)
{
    uint8_t buf[ 2 + sizeof(NSUInteger) ];
    unsigned int bufUsed;
    
    buf[0] = tag;
    bufUsed = 1;
    
    if (byteCount < 128) {
        /* Short lengths have a 1-byte direct representation */
        buf[1] = (uint8_t)byteCount;
        bufUsed = 2;
    } else {
        /* Longer lengths have a count-and-value representation */
        unsigned int n;
        uint8_t bytebuf[ sizeof(NSUInteger) ];
        for(n = 0; n < sizeof(NSUInteger); n++) {
            bytebuf[n] = ( byteCount & 0xFF );
            byteCount >>= 8;
        }
        while(bytebuf[n-1] == 0)
            n--;
        buf[bufUsed++] = 0x80 | n;
        while (n--) {
            buf[bufUsed++] = bytebuf[n];
        };
    }
    
    return [[NSMutableData alloc] initWithBytes:buf length:bufUsed];
}

/*" Wraps a set of ASN.1 items in a SEQUENCE. "*/
NSMutableData *OFASN1CreateForSequence(NSData *item, ...)
{
    NSUInteger totalLength = 0;
    
    if (item != nil) {
        va_list items;
        va_start(items, item);
        
        totalLength = [item length];
        NSData *nextItem;
        while( (nextItem = va_arg(items, NSData *)) != nil ) {
            totalLength += [nextItem length];
        }
        
        va_end(items);
    }
    
    NSMutableData *header = OFASN1CreateForTag(BER_TAG_SEQUENCE | CLASS_CONSTRUCTED, totalLength);
    
    if (item != nil) {
        va_list items;
        va_start(items, item);
        
        [header appendData:item];
        NSData *nextItem;
        while( (nextItem = va_arg(items, NSData *)) != nil ) {
            [header appendData:nextItem];
        }
        
        va_end(items);
    }
    
    return header;
}

static BOOL asnParseFailure(NSError **err, NSString *fmt, ...)
{
    if (!err)
        return NO;
    
    va_list varg;
    va_start(varg, fmt);
    NSString *descr = [[NSString alloc] initWithFormat:fmt arguments:varg];
    va_end(varg);
    
    NSString *keys[3];
    id values[3];
    NSUInteger keyCount;
    
    keys[0] = NSLocalizedDescriptionKey;
    values[0] = @"ASN.1 Parse Failure";
    
    keys[1] = NSLocalizedFailureReasonErrorKey;
    values[1] = descr;
    
    keyCount = 2;
    
    NSDictionary *uinfo = [NSDictionary dictionaryWithObjects:values forKeys:keys count:keyCount];
    [descr release];
    
    *err = [NSError errorWithDomain:OFXMLSignatureErrorDomain code:OFASN1Error userInfo:uinfo];
    
    /* This return value is pointless, since this function is only called in error situations, but clang-analyze requires us to return something */
    return NO;
}

#define badvalue (~(NSUInteger)0)
static NSUInteger parseLengthField(NSData *within, NSUInteger *inOutWhere, NSError **outError)
{
    NSUInteger where = *inOutWhere;
    NSUInteger byteCount = [within length];
    
    if (byteCount < 1 || byteCount-1 < where) {
        asnParseFailure(outError, @"Truncated");
        return badvalue;
    }
    
    const UInt8 *bytes = [within bytes];
    UInt8 first = bytes[where ++];
    NSUInteger result;
    if ((first & 0x80) == 0) {
        result = first;
    } else {
        unsigned lengthLength = ( bytes[1] & 0x7F );
        if (lengthLength < 1 || lengthLength > sizeof(NSUInteger)) {
            asnParseFailure(outError, @"Unexpected length-of-length field: 0x%02X", bytes[1]);
            return badvalue;
        }
        if (lengthLength > byteCount-where) {
            asnParseFailure(outError, @"Truncated value (in length-of-length)");
            return badvalue;
        }
        result = 0;
        for(;;) {
            result |= bytes[where++];
            lengthLength --;
            if (!lengthLength) break;
            result <<= 8;
        }
    }
    
    if (byteCount-where < result) {
        asnParseFailure(outError, @"Truncated value (length exceeds buffer)");
        return badvalue;
    }
    
    *inOutWhere = where;
    return result;
}

/*" Given a BER-encoded SEQUENCE, returns the index at which its content starts, or ~0 in the case of an error. "*/
NSUInteger OFASN1UnwrapSequence(NSData *seq, NSError **outError)
{
    NSUInteger byteCount = [seq length];
    if (byteCount < 2) {
        asnParseFailure(outError, @"Sequence is short");
        return badvalue;
    }
    
    const UInt8 *bytes = [seq bytes];
    if (bytes[0] != ( BER_TAG_SEQUENCE | CLASS_CONSTRUCTED )) {
        asnParseFailure(outError, @"Unexpected tag: expecting SEQUENCE (0x30), found 0x%02X", bytes[0]);
        return badvalue;
    }
    
    NSUInteger startsAt = 1;
    NSUInteger lengthField = parseLengthField(seq, &startsAt, outError);
    if (lengthField == badvalue)
        return badvalue;
    
    if (lengthField != ( byteCount - startsAt )) {
        asnParseFailure(outError, @"Incorrect length for SEQUENCE (found %lu, but have %lu bytes)", (unsigned long)lengthField, (unsigned long)(byteCount - startsAt));
        return badvalue;
    }
    
    return startsAt;
}

NSData *OFASN1UnwrapUnsignedInteger(NSData *buf, NSUInteger *inOutWhere, NSError **outError)
{
    NSUInteger byteCount = [buf length];
    NSUInteger where = *inOutWhere;
    if (byteCount < 2 || byteCount-2 < where) {
        asnParseFailure(outError, @"Sequence is short");
        return nil;
    }
    
    const UInt8 *bytes = [buf bytes];
    if (bytes[where] != BER_TAG_INTEGER) {
        asnParseFailure(outError, @"Unexpected tag: expecting INTEGER (0x02), found 0x%02X", bytes[0]);
        return nil;
    }
    where ++;
    
    NSUInteger integerLength = parseLengthField(buf, &where, outError);
    if (integerLength == badvalue)
        return nil;
    
    if (integerLength > 0 && (bytes[where] & 0x80)) {
        asnParseFailure(outError, @"Unexpected negative INTEGER", bytes[0]);
        return nil;
    }
    if (integerLength > 0 && bytes[where] == 0) {
        where ++;
        integerLength --;
    }
    NSData *result = [buf subdataWithRange:(NSRange){ where, integerLength }];
    *inOutWhere = where + integerLength;
    return result;
}

NSString *OFASN1DescribeOID(const unsigned char *bytes, size_t len)
{
    if (!bytes)
        return nil;
    if (len < 1)
        return @"{ }";
    
    
    // The first byte has a special encoding.
    unsigned int c0 = bytes[0] / 40;
    unsigned int c1 = bytes[0] % 40;
    
    NSMutableString *buf = [NSMutableString stringWithFormat:@"{ %u %u ", c0, c1];

    size_t p = 1;
    while(p < len) {
        size_t e = p;
        while(e < len && (bytes[e] & 0x80))
            e++;
        if (!(e < len)) {
            [buf appendString:@"*TRUNC "];
            break;
        } else {
            size_t nbytes = 1 + e - p;
            if (nbytes * 7 >= sizeof(unsigned long)*NBBY) {
                [buf appendString:@"*BIG "];
            } else {
                unsigned long value = 0;
                while(p <= e) {
                    value = ( value << 7 ) | ( bytes[p] & 0x7F );
                    p++;
                }
                [buf appendFormat:@"%lu ", value];
            }
        }
    }
    
    [buf appendString:@"}"];
    return buf;
}

#pragma mark SecItem debugging

/* The main reason for OFSecItemDescription() to exist is so that I can tell what the 10.7 crypto APIs are returning to me. Unfortunately, one of the more inscrutably buggy APIs is SecItemCopyMatching(), which is the only way to inspect a key ref in the new world. So using that call to debug itself is kind of counterproductive. */
#define AVOID_SecItemCopyMatching

static void describeSecKeyItem(SecKeychainItemRef item, SecItemClass itemClass, NSMutableString *buf);
static BOOL describeSecItem(SecKeychainItemRef item, NSMutableString *buf);
#if !defined(AVOID_SecItemCopyMatching) && defined(MAC_OS_X_VERSION_10_7) && MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_7
static BOOL describeSecItemLion(CFTypeRef item, CFTypeID what, NSMutableString *buf);
#endif       


NSString *OFSecItemDescription(CFTypeRef item)
{
    if (item == NULL)
        return @"(null)";
    
    CFTypeID what = CFGetTypeID(item);
    CFStringRef classname = CFCopyTypeIDDescription(what);
    NSMutableString *buf = [NSMutableString stringWithFormat:@"<%@ %p:", (id)classname, item];
    CFRelease(classname);
    
    if (
#if !defined(AVOID_SecItemCopyMatching) && defined(MAC_OS_X_VERSION_10_7) && MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_7
        describeSecItemLion(item, what, buf) ||
#endif
        describeSecItem((SecKeychainItemRef)item, buf)) {
        
        [buf appendString:@">"];
        return buf;
    }
    
    return [(id)item description]; // Fall back on crappy CoreFoundation description
}


static BOOL describeSecItem(SecKeychainItemRef item, NSMutableString *buf)
{
    OSStatus oserr;
    SecItemClass returnedClass;
    
    /* First, discover the item's class. CFGetTypeID() doesn't distinguish between (eg) public, private, and symmetric keys. */
    
    returnedClass = 0;
    oserr = SecKeychainItemCopyAttributesAndData(item, NULL, &returnedClass, NULL, NULL, NULL);
    if (oserr != noErr) {
        // NSLog(@"SecKeychainItemCopyAttributesAndData(%@) -> %@", (id)item, OFOSStatusDescription(oserr));
        return NO;
    }
    
    if (returnedClass == kSecInternetPasswordItemClass || returnedClass == CSSM_DL_DB_RECORD_INTERNET_PASSWORD ||
        returnedClass == kSecGenericPasswordItemClass || returnedClass == CSSM_DL_DB_RECORD_GENERIC_PASSWORD ||
        returnedClass == kSecAppleSharePasswordItemClass || returnedClass == CSSM_DL_DB_RECORD_APPLESHARE_PASSWORD) {
        [buf appendString:@" Password"];
    } else if (returnedClass == kSecCertificateItemClass || returnedClass == CSSM_DL_DB_RECORD_CERT) {
        [buf appendString:@" Certificate"];
    } else if (returnedClass == kSecPublicKeyItemClass) {
        [buf appendString:@" Public"];
        describeSecKeyItem(item, returnedClass, buf);
    } else if (returnedClass == kSecPrivateKeyItemClass) {
        [buf appendString:@" Private"];
        describeSecKeyItem(item, returnedClass, buf);
    } else if (returnedClass == kSecSymmetricKeyItemClass) {
        [buf appendString:@" Symmetric"];
        describeSecKeyItem(item, returnedClass, buf);
    } else {
        // Unknown class. Not sure we can do any better than -description here.
        return NO;
    }
    
    return YES;
}

static const struct { CSSM_ALGORITHMS algid; const char *name; } algnames[] = {
    { CSSM_ALGID_DH, "DH" },  // Diffie-Hellman
    { CSSM_ALGID_PH, "PH" },  // Pohlig-Hellman
    { CSSM_ALGID_DES, "DES" },
    { CSSM_ALGID_RSA, "RSA" },
    { CSSM_ALGID_DSA, "DSA" },
    { CSSM_ALGID_MQV, "MQV" },
    { CSSM_ALGID_ElGamal, "ElGamal" },
    
    { CSSM_ALGID_ECDSA, "ECDSA" },
    { CSSM_ALGID_ECDH, "ECDH" },
    { CSSM_ALGID_ECMQV, "ECMQV" },
    { CSSM_ALGID_ECC, "ECC" },
    { 0, NULL }
};

static BOOL uint32attr(const SecKeychainAttributeList *attrs, SecKeychainAttrType tag, UInt32 *val)
{
    UInt32 ix;
    
    if (!attrs)
        return NO;
    
    for(ix = 0; ix < attrs->count; ix ++) {
        const SecKeychainAttribute *attr = &( attrs->attr[ix] );
        if(attr->tag == tag) {
            if (attr->data != NULL && attr->length == 4) {
                memcpy(val, attr->data, 4);
                return YES;
            }
        }
    }
    
    return NO;
}

static void boolattr(const SecKeychainAttributeList *attrs, SecKeychainAttrType tag, int ch, NSMutableString *buf)
{
    UInt32 v;
    if (uint32attr(attrs, tag, &v)) {
        if (!v) {
            ch = tolower(ch);
        }
        unichar utf16[1] = { (unichar)ch };
        CFStringAppendCharacters((CFMutableStringRef)buf, utf16, 1);
    }
}

static void describeSecKeyItem(SecKeychainItemRef item, SecItemClass itemClass, NSMutableString *buf)
{
    OSStatus oserr;
    SecKeychainAttributeList *returnedAttributes;
    static const UInt32 keyAttributeCount = 2;
    static const UInt32 keyAttributeTags[2]     = { kSecKeyKeyType, kSecKeyKeySizeInBits };
    static const UInt32 keyAttributeFormats[2]  = { CSSM_DB_ATTRIBUTE_FORMAT_UINT32, CSSM_DB_ATTRIBUTE_FORMAT_UINT32 };
    
    static const UInt32 moreKeyAttributeCount = 8;
    static const UInt32 moreKeyAttributeTags[8]     = { kSecKeyPermanent, kSecKeyEncrypt, kSecKeyDecrypt, kSecKeyDerive, kSecKeySign, kSecKeyVerify, kSecKeyWrap, kSecKeyUnwrap };
    static const UInt32 moreKeyAttributeFormats[8]  = { CSSM_DB_ATTRIBUTE_FORMAT_UINT32, CSSM_DB_ATTRIBUTE_FORMAT_UINT32, CSSM_DB_ATTRIBUTE_FORMAT_UINT32, CSSM_DB_ATTRIBUTE_FORMAT_UINT32, CSSM_DB_ATTRIBUTE_FORMAT_UINT32, CSSM_DB_ATTRIBUTE_FORMAT_UINT32, CSSM_DB_ATTRIBUTE_FORMAT_UINT32, CSSM_DB_ATTRIBUTE_FORMAT_UINT32 };
    
    SecKeychainAttributeInfo queryAttributes = { keyAttributeCount, (UInt32 *)keyAttributeTags, (UInt32 *)keyAttributeFormats };
    
    returnedAttributes = NULL;
    oserr = SecKeychainItemCopyAttributesAndData(item, &queryAttributes, NULL, &returnedAttributes, NULL, NULL);
    if (oserr == noErr) {
        UInt32 v;
        BOOL alg = NO;
        if (uint32attr(returnedAttributes, kSecKeyKeyType, &v)) {
            for(int i = 0; algnames[i].name; i++) {
                if(algnames[i].algid == v) {
                    [buf appendFormat:@" %s", algnames[i].name];
                    alg = YES;
                    break;
                }
            }
            if (!alg) {
                [buf appendFormat:@" alg#%u", (unsigned int)v];
                alg = YES;
            }
        }
        
        if (uint32attr(returnedAttributes, kSecKeyKeySizeInBits, &v)) {
            if (alg)
                [buf appendFormat:@"-%u", (unsigned int)v];
            else
                [buf appendFormat:@"%u-bit", (unsigned int)v];
        }
        
        SecKeychainItemFreeAttributesAndData(returnedAttributes, NULL);
    }
    
    queryAttributes = (SecKeychainAttributeInfo){ moreKeyAttributeCount, (UInt32 *)moreKeyAttributeTags, (UInt32 *)moreKeyAttributeFormats };
    returnedAttributes = NULL;
    oserr = SecKeychainItemCopyAttributesAndData(item, &queryAttributes, NULL, &returnedAttributes, NULL, NULL);
    if (oserr == noErr) {
        [buf appendString:@" ["];
        boolattr(returnedAttributes, kSecKeyEncrypt,  'E', buf);
        boolattr(returnedAttributes, kSecKeyDecrypt,  'D', buf);
        boolattr(returnedAttributes, kSecKeyDerive,   'R', buf);
        boolattr(returnedAttributes, kSecKeySign,     'S', buf);
        boolattr(returnedAttributes, kSecKeyVerify,   'V', buf);
        boolattr(returnedAttributes, kSecKeyWrap,     'W', buf);
        boolattr(returnedAttributes, kSecKeyUnwrap,   'U', buf);
        [buf appendString:@"]"];
        
        UInt32 v;
        if (uint32attr(returnedAttributes, kSecKeyPermanent, &v)) {
            if (v)
                [buf appendString:@" perm"];
            else
                [buf appendString:@" temp"];
        }
        
        SecKeychainItemFreeAttributesAndData(returnedAttributes, NULL);
    }
}


#if !defined(AVOID_SecItemCopyMatching) && defined(MAC_OS_X_VERSION_10_7) && MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_7

static void addflag(CFDictionaryRef d, CFTypeRef k, CFMutableStringRef buf, int asciiChar)
{
    CFTypeRef v = NULL;
    if (CFDictionaryGetValueIfPresent(d, k, &v)) {
        if (!CFBooleanGetValue(v))
            asciiChar = tolower(asciiChar);
        UniChar chbuf[1];
        chbuf[0] = asciiChar;
        CFStringAppendCharacters(buf, chbuf, 1);
    }
}

static BOOL describeSecItemLion(CFTypeRef item, CFTypeID what, NSMutableString *buf)
{
    /* We need to look up the class of the item and tell SecItemCopyMatching() that that's the class we're interested in. You'd think it would be able to do that itself... */
    
    CFTypeRef secClass;
    if (what == SecKeyGetTypeID())
        secClass = kSecClassKey;
    else if (what == SecCertificateGetTypeID())
        secClass = kSecClassCertificate;
    else if (what == SecIdentityGetTypeID())
        secClass = kSecClassIdentity;
    else
        secClass = NULL; // Will probably cause SecItemCopyMatching() to fail, but might as well try    
    
    /* We use kSecUseItemList because it works, although the documentation suggests we should use kSecMatchItemList (kSecUseItemList is in "Other Constants", which isn't listed as one of the sets of constants SecItemCopyMatching() looks at). */
    NSDictionary *query = [NSDictionary dictionaryWithObjectsAndKeys:
                           [NSArray arrayWithObject:(id)item], (id)kSecUseItemList,
                           //[NSArray arrayWithObject:(id)item], (id)kSecMatchItemList,
                           (id)kCFBooleanTrue, (id)kSecReturnAttributes,
                           (id)kCFBooleanTrue, (id)kSecReturnRef,
                           (id)kSecMatchLimitAll, (id)kSecMatchLimit,
                           (id)secClass, (id)kSecClass,  // Note secClass is last since it may be nil
                           nil];
    CFTypeRef result = NULL;
    OSStatus err = SecItemCopyMatching((CFDictionaryRef)query, &result);
    if (err != noErr) {
        NSLog(@"SecItemCopyMatching(%@) -> %@", query, OFOSStatusDescription(err));
    }
    
    NSLog(@"kSecReturnAttributes(%@) -> %@", query, [(id)result description]);
    
    if (CFGetTypeID(result) != CFArrayGetTypeID() ||
        CFArrayGetCount(result) != 1) {
        // SecItemCopyMatching() usually doesn't actually work correctly.
        CFRelease(result);
        return NO;
    }
    
    CFDictionaryRef attrDict = CFArrayGetValueAtIndex(result, 0);
    if (CFGetTypeID(attrDict) != CFDictionaryGetTypeID()) {
        // I haven't seen this happen, but I don't really trust SecItemCopyMatching
        CFRelease(result);
        return NO;
    }
    
    /* There are two different class keys for keys: kSecClass->key, and kSecAttrKeyClass->whatkindofkey */
    secClass = CFDictionaryGetValue(attrDict, kSecClass);
    if (CFEqual(secClass, kSecClassKey)) {
        CFTypeRef secKeyClass = CFDictionaryGetValue(attrDict, kSecAttrKeyClass);
        if (CFEqual(secKeyClass, kSecAttrKeyClassPublic)) {
            [buf appendString:@" Public"];
        } else if (CFEqual(secKeyClass, kSecAttrKeyClassPrivate)) {
            [buf appendString:@" Private"];
        } else if (CFEqual(secKeyClass, kSecAttrKeyClassSymmetric)) {
            [buf appendString:@" Symmetric"];
        } else {
            [buf appendFormat:@" kcls=%@", (id)secKeyClass];
        }
    }
    
    CFTypeRef secAlgorithm = NULL;
    if (CFDictionaryGetValueIfPresent(attrDict, kSecAttrKeyType, &secAlgorithm)) {
        NSString *algname;
        if (CFEqual(secAlgorithm, kSecAttrKeyTypeRSA)) { algname = @"RSA"; }
        else if (CFEqual(secAlgorithm, kSecAttrKeyTypeDSA)) { algname = @"DSA"; }
        else if (CFEqual(secAlgorithm, kSecAttrKeyTypeAES)) { algname = @"AES"; }
        else if (CFEqual(secAlgorithm, kSecAttrKeyType3DES)) { algname = @"3DES"; } 
        else if (CFEqual(secAlgorithm, kSecAttrKeyTypeCAST)) { algname = @"CAST"; } 
        else if (CFEqual(secAlgorithm, kSecAttrKeyTypeECDSA)) { algname = @"ECDSA"; } 
        else { algname = [NSString stringWithFormat:@"alg#%@", secAlgorithm]; }
        
        CFTypeRef bitSize = NULL;
        if (CFDictionaryGetValueIfPresent(attrDict, kSecAttrEffectiveKeySize, &bitSize) ||
            CFDictionaryGetValueIfPresent(attrDict, kSecAttrKeySizeInBits, &bitSize)) {
            [buf appendFormat:@" %@-%@", algname, bitSize];
        } else {
            [buf appendFormat:@" %@", algname];
        }
    }
    
    CFMutableStringRef fbuf = CFStringCreateMutable(kCFAllocatorDefault, 8);
    addflag(attrDict, kSecAttrCanEncrypt,  fbuf, 'E');
    addflag(attrDict, kSecAttrCanDecrypt,  fbuf, 'D');
    addflag(attrDict, kSecAttrCanDerive,   fbuf, 'R');
    addflag(attrDict, kSecAttrCanSign,     fbuf, 'S');
    addflag(attrDict, kSecAttrCanVerify,   fbuf, 'V');
    addflag(attrDict, kSecAttrCanWrap,     fbuf, 'W');
    addflag(attrDict, kSecAttrCanUnwrap,   fbuf, 'U');
    if (CFStringGetLength(fbuf) > 0) {
        [buf appendFormat:@" [%@]", fbuf];
    }
    CFRelease(fbuf);
    
    CFTypeRef isPermanent = NULL;
    if (CFDictionaryGetValueIfPresent(attrDict, kSecAttrIsPermanent, &isPermanent)) {
        if (CFBooleanGetValue(isPermanent))
            [buf appendString:@" perm"];
        else
            [buf appendString:@" temp"];
    }
    
    CFRelease(result);
    
    return YES;
}

#endif /* 10.7 and above */

#pragma mark X.509 Certificate Utilities

#if OF_ENABLE_CDSA
static NSData *getSKI(CSSM_CL_HANDLE cl, const CSSM_DATA *cert)
{
    uint32 fieldCount;
    CSSM_DATA *buf;
    CSSM_RETURN err;
    CSSM_HANDLE queryHandle;
    
    fieldCount = 0;
    buf = NULL;
    queryHandle = CSSM_INVALID_HANDLE;
    
    err = CSSM_CL_CertGetFirstFieldValue(cl, cert, &CSSMOID_SubjectKeyIdentifier,
                                         &queryHandle, &fieldCount, &buf);
    
    if (err != CSSM_OK)
        return nil;
    
    NSData *result = nil;
    
    if (fieldCount > 0 && buf && buf->Length == sizeof(CSSM_X509_EXTENSION)) {
        const CSSM_X509_EXTENSION *ext = (CSSM_X509_EXTENSION *)(buf->Data);
        const CSSM_DATA *skiBuf;
        if (ext->format == CSSM_X509_DATAFORMAT_ENCODED) {
            skiBuf = &( ext->value.tagAndValue->value );
        } else if (ext->format == CSSM_X509_DATAFORMAT_PARSED) {
            skiBuf = (CE_SubjectKeyID *)ext->value.parsedValue;
        } else
            skiBuf = NULL;
        
        if (skiBuf)
            result = [NSData dataWithBytes:skiBuf->Data length:skiBuf->Length];
    }
    
    if(buf)
        CSSM_CL_FreeFieldValue(cl, &CSSMOID_SubjectKeyIdentifier, buf);
    CSSM_CL_CertAbortQuery(cl, queryHandle);
    
    return result;
}
#endif

static void osError(NSMutableDictionary *into, OSStatus code, NSString *function)
{
    NSDictionary *userInfo;
    
    if (function)
        userInfo = [NSDictionary dictionaryWithObject:function forKey:@"function"];
    else
        userInfo = nil;
    
    [into setObject:[NSError errorWithDomain:NSOSStatusErrorDomain code:code userInfo:userInfo] forKey:NSUnderlyingErrorKey];
}

static BOOL certificateMatchesSKI(SecCertificateRef aCert, NSData *subjectKeyIdentifier)
{
#if defined(MAC_OS_X_VERSION_10_7) && MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_7
    if (SecCertificateCopyValues != NULL && kSecOIDSubjectKeyIdentifier != NULL) {
        const void *desiredAttributeOIDs_[1] = { kSecOIDSubjectKeyIdentifier };
        CFArrayRef desiredAttributeOIDs = CFArrayCreate(kCFAllocatorDefault, desiredAttributeOIDs_, 1, &kCFTypeArrayCallBacks);
        CFDictionaryRef parsedCertificate = SecCertificateCopyValues(aCert, desiredAttributeOIDs, NULL);
        CFRelease(desiredAttributeOIDs);
        
        if (parsedCertificate != NULL) {
            BOOL result;
            CFDictionaryRef skiValueInfo = NULL;
            CFTypeRef skiValueType = NULL;
            CFTypeRef skiContainedValue;
            
            //NSLog(@"CertInfo(%@) -> %@", (id)aCert, [(id)parsedCertificate description]);
            
            if (!CFDictionaryGetValueIfPresent(parsedCertificate, kSecOIDSubjectKeyIdentifier, (const void **)&skiValueInfo) ||
                !CFDictionaryGetValueIfPresent(skiValueInfo, kSecPropertyKeyType, (const void **)&skiValueType)) {
                CFRelease(parsedCertificate);
                return NO;
            }
            
            /* There's no documentation on what format SecCertificateCopyValues() returns individual values in (RADAR 10430553). SKIs appear to be returned either as a kSecPropertyTypeData, or as a "section" containing 2 elements: the critical flag (returned as a string--- WTF, Apple!?!) and the SKI. */
            
            if (CFEqual(skiValueType, kSecPropertyTypeSection) &&
                CFDictionaryGetValueIfPresent(skiValueInfo, kSecPropertyKeyValue, (const void **)&skiContainedValue) &&
                CFArrayGetCount(skiContainedValue) == 2) {
                // 2-element "section" containing critical flag & actual value.
                skiValueInfo = CFArrayGetValueAtIndex(skiContainedValue, 1);
                skiValueType = CFDictionaryGetValue(skiValueInfo, kSecPropertyKeyType);
            }
            
            if (CFEqual(skiValueType, kSecPropertyTypeData)) {
                //NSLog(@"SKIv = %@", [(id)skiValueInfo description]);
                result = [subjectKeyIdentifier isEqualToData:(NSData *)CFDictionaryGetValue(skiValueInfo, kSecPropertyKeyValue)];
            } else {
                result = NO;
            }

            CFRelease(parsedCertificate);

            return result;
        }
    }
#endif
    
#if !defined(MAC_OS_X_VERSION_10_7) || MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_7
    /* On 10.6 and earlier, we use SecKeychainItemCopyAttributesAndData() */
    OSStatus err;
    static const UInt32 desiredAttributeTags[1] = { kSecSubjectKeyIdentifierItemAttr };
    static const UInt32 desiredAttributeFormats[1] = { CSSM_DB_ATTRIBUTE_FORMAT_BLOB };
    static const SecKeychainAttributeInfo desiredAtts = {
        .count = 1,
        .tag = (UInt32 *)desiredAttributeTags,
        .format = (UInt32 *)desiredAttributeFormats
    };
    
    SecKeychainAttributeList *retrievedAtts = NULL;
    
    SecKeychainItemRef asKCItem = (SecKeychainItemRef)aCert; // Superclass, but the compiler doesn't know that for CFTypes
    err = SecKeychainItemCopyAttributesAndData(asKCItem, (SecKeychainAttributeInfo *)&desiredAtts, NULL, &retrievedAtts, NULL, NULL);
    
    if (err == noErr) {
        BOOL result;
        
        if (retrievedAtts->count == 1 &&
            retrievedAtts->attr[0].tag == kSecSubjectKeyIdentifierItemAttr &&
            retrievedAtts->attr[0].length == [subjectKeyIdentifier length] &&
            !memcmp(retrievedAtts->attr[0].data, [subjectKeyIdentifier bytes], [subjectKeyIdentifier length])) {
            result = YES;
        } else {
            result = NO;
        }
        
        SecKeychainItemFreeAttributesAndData(retrievedAtts, NULL);
        
        return result;
    }
#else
#if OF_ENABLE_CDSA
    OSStatus err = errKCNotAvailable;
#endif
#endif    
    
#if OF_ENABLE_CDSA
    if (err == errKCNotAvailable) {
        // Huh. I guess we have to use CSSM directly here.
        
        CSSM_DATA buf = { 0, 0 };
        err = SecCertificateGetData(aCert, &buf);
        if (err != noErr) {
            // ?? !!
            return NO;
        }
        
        CSSM_CL_HANDLE cl = CSSM_INVALID_HANDLE;
        err = SecCertificateGetCLHandle(aCert, &cl);
        if (err != noErr || cl == CSSM_INVALID_HANDLE) {
            NSLog(@"No cert lib for %@ - %ld %ld", aCert, (long)err, (long)cl);
            return NO;
        }
        
        NSData *foundSKI = getSKI(cl, &buf);
        // NSLog(@"extracted SKI %@", foundSKI);
        return [subjectKeyIdentifier isEqualToData:foundSKI];
    }
#endif
    
    // Not a fatal error, or even unexpected; this might just be an intermediate cert
    return NO;
}

/*" Given a <KeyInfo> element, this function attempts to find the X.509 certificate(s) corresponding to the key specified by the element's <X509Foo> children. All certificates supplied by the element are appended to auxiliaryCertificates, which may also contain externally supplied certificates which are used to satisfy <X509SKI> patterns. (In the future this function may also support SubjectKeyidentifier lookups, as well as Apple Keychain searches.) "*/
NSArray *OFXMLSigFindX509Certificates(xmlNode *keyInfoNode, CFMutableArrayRef auxiliaryCertificates, NSMutableDictionary *errorInfo)
{
    unsigned int nodeCount, nodeIndex;
    xmlNode **x509Nodes = OFLibXMLChildrenNamed(keyInfoNode, "X509Data", XMLSignatureNamespace, &nodeCount);
    
    if (!nodeCount)
        return nil;
    
    NSMutableSet *certBlobs = [NSMutableSet set];  // <X509Certificate> blobs encountered in the document
    NSMutableArray *desiredKeys = [NSMutableArray array];  // Other <X509Data> entries, indicating applicable verification keys
    
    for(nodeIndex = 0; nodeIndex < nodeCount; nodeIndex ++ ) {
        NSDictionary *parsedNode = OFXMLSigParseX509DataNode(x509Nodes[nodeIndex]);
        
        if (!parsedNode)
            continue;
        
        NSArray *certs = [parsedNode objectForKey:@"Certificate"];
        if (certs)
            [certBlobs addObjectsFromArray:certs];
        
        /* The constraints in XML-DSIG [4.4.4] end up meaning that any X509Data node containing nodes other than Certificate or CRL nodes must indicate keys to use for validation. It doesn't restrict us from having more than one such --- I suppose it's allowing for the possibility of multiple distinct certificates all certifying the same key. */
        
        /* Right now we only do SubjectKeyIdentifier lookups, so that we don't have to get into all the minutia of parsing DNs. */
        if ([parsedNode objectForKey:@"SKI"])
            [desiredKeys addObject:[parsedNode dictionaryWithObject:nil forKey:@"Certificate"]];
    }
    
    free(x509Nodes);
    
    [errorInfo setObject:desiredKeys forKey:@"desiredKeys"];
    
    NSData *fallbackBlob = nil;
    if ([desiredKeys count] == 0) {
        // Huh. Well, maybe they just gave us a single cert.
        if ([certBlobs count] == 1)
            fallbackBlob = [certBlobs anyObject];
    }
    
    NSMutableArray *testCertificates = [NSMutableArray array];
    
    // Convert all of our certs (whether from the document or from our trust store) into SecCertificateRefs.
    
    // Re-use any CertificateRefs from auxiliaryCertificates --- don't create new ones.
    for(CFIndex inputCertIndex = 0; inputCertIndex < CFArrayGetCount(auxiliaryCertificates); inputCertIndex ++) {
        SecCertificateRef aCert = (SecCertificateRef)CFArrayGetValueAtIndex(auxiliaryCertificates, inputCertIndex);
#if !defined(MAC_OS_X_VERSION_10_6) || MAC_OS_X_VERSION_10_6 > MAC_OS_X_VERSION_MIN_REQUIRED
        CSSM_DATA bufReference = { 0, 0 };
        if (SecCertificateGetData(aCert, &bufReference) == noErr) {
            NSData *knownBlob = [[NSData alloc] initWithBytesNoCopy:bufReference.Data length:bufReference.Length freeWhenDone:NO];
#else
        NSData *knownBlob = NSMakeCollectable(SecCertificateCopyData(aCert));
        if (knownBlob != NULL) {
#endif
            [certBlobs removeObject:knownBlob];
            if (fallbackBlob && [fallbackBlob isEqualToData:knownBlob])
                [testCertificates addObject:(id)aCert];
            [knownBlob release];
        }
    }
    
    // Create SecCertificateRefs from any remaining (non-duplicate) data blobs.
    OFForEachObject([certBlobs objectEnumerator], NSData *, aBlob) {
#if !defined(MAC_OS_X_VERSION_10_6) || MAC_OS_X_VERSION_10_6 > MAC_OS_X_VERSION_MIN_REQUIRED
        CSSM_DATA blob = { .Data = (void *)[aBlob bytes], .Length = [aBlob length] };
        SecCertificateRef certReference = NULL;
        OSStatus err = SecCertificateCreateFromData(&blob, CSSM_CERT_X_509v3, CSSM_CERT_ENCODING_BER, &certReference);
        if (err != noErr) {
            osError(errorInfo, err, @"SecCertificateCreateFromData");
            continue;
        }
#else
        SecCertificateRef certReference = SecCertificateCreateWithData(kCFAllocatorDefault, (CFDataRef)aBlob);
        if (!certReference) {
            // RADAR 10057193: There's no way to know why SecCertificateCreateWithData() failed.
            // (However, see RADAR 7514859: SecCertificateCreateFromData will accept inputs that it's documented to return NULL for, and return an unusable SecCertificateRef; I guess we're no worse off with no error-reporting API than with an error-reporting API that doesn't work.)
            osError(errorInfo, paramErr, @"SecCertificateCreateWithData");
            continue;
        }
#endif
        
        CFArrayAppendValue(auxiliaryCertificates, certReference);
        if (fallbackBlob && [fallbackBlob isEqualToData:aBlob])
            [testCertificates addObject:(id)certReference];
        CFRelease(certReference);
    }
    
    // Run through all entries we've stashed in desiredKeys and try to find a corresponding certificate in auxiliaryCertificates.
    // (This is written with the assumption that there'll usually only be one entry in desiredKeys, so it's not worth caching anything in that inner loop.)
    CFIndex auxCertCount = CFArrayGetCount(auxiliaryCertificates);
    OFForEachObject([desiredKeys objectEnumerator], NSDictionary *, spec) {
        NSData *subjectKeyIdentifier = [spec objectForKey:@"SKI"];
        if (!subjectKeyIdentifier)
            continue; // huh?
        for(CFIndex certIndex = 0; certIndex < auxCertCount; certIndex ++) {
            SecCertificateRef aCert = (SecCertificateRef)CFArrayGetValueAtIndex(auxiliaryCertificates, certIndex);
            if (certificateMatchesSKI(aCert, subjectKeyIdentifier)) {
                /* The SubjectKeyIdentifier extension matches; this cert contains a key we could use to validate */
                [testCertificates addObject:(id)aCert];
            }
        }
    }
    
    [errorInfo setUnsignedIntValue:(unsigned)auxCertCount forKey:@"auxCertCount"];
    
    return testCertificates;
}

static const struct { SecTrustResultType code; NSString *display; } results[] = {
    { kSecTrustResultInvalid, @"Invalid" },
    { kSecTrustResultProceed, @"Proceed" },
    { kSecTrustResultConfirm, @"Confirm" },
    { kSecTrustResultDeny, @"Deny" },
    { kSecTrustResultUnspecified, @"Unspecified" },
    { kSecTrustResultRecoverableTrustFailure, @"RecoverableTrustFailure" },
    { kSecTrustResultFatalTrustFailure, @"FatalTrustFailure" },
    { kSecTrustResultOtherError, @"OtherError" },
    { 0, nil }
};

#if OF_ENABLE_CDSA
    
static const struct { CSSM_TP_APPLE_CERT_STATUS bit; NSString *display; } statusBits[] = {
    { CSSM_CERT_STATUS_EXPIRED, @"EXPIRED" },
    { CSSM_CERT_STATUS_NOT_VALID_YET, @"NOT_VALID_YET" },
    { CSSM_CERT_STATUS_IS_IN_INPUT_CERTS, @"IS_IN_INPUT_CERTS" },
    { CSSM_CERT_STATUS_IS_IN_ANCHORS, @"IS_IN_ANCHORS" },
    { CSSM_CERT_STATUS_IS_ROOT, @"IS_ROOT" },
    { CSSM_CERT_STATUS_IS_FROM_NET, @"IS_FROM_NET" },
    { CSSM_CERT_STATUS_TRUST_SETTINGS_FOUND_USER, @"SETTINGS_FOUND_USER" },
    { CSSM_CERT_STATUS_TRUST_SETTINGS_FOUND_ADMIN, @"SETTINGS_FOUND_ADMIN" },
    { CSSM_CERT_STATUS_TRUST_SETTINGS_FOUND_SYSTEM, @"SETTINGS_FOUND_SYSTEM" },
    { CSSM_CERT_STATUS_TRUST_SETTINGS_TRUST, @"SETTINGS_TRUST" },
    { CSSM_CERT_STATUS_TRUST_SETTINGS_DENY, @"SETTINGS_DENY" },
    { CSSM_CERT_STATUS_TRUST_SETTINGS_IGNORED_ERROR, @"SETTINGS_IGNORED_ERROR" },
    { 0, nil }
};

NSString *OFSummarizeTrustResult(SecTrustRef evaluationContext)
{
    SecTrustResultType trustResult;
    CFArrayRef chain = NULL;
    CSSM_TP_APPLE_EVIDENCE_INFO *stats = NULL;
    if (SecTrustGetResult(evaluationContext, &trustResult, &chain, &stats) != noErr) {
        return @"[SecTrustGetResult failure]";
    }
    
    NSMutableString *buf = [NSMutableString stringWithFormat:@"Trust result = %d", (int)trustResult];
    for(int i = 0; results[i].display; i++) {
        if(results[i].code == trustResult) {
            [buf appendFormat:@" (%@)", results[i].display];
        }
    }

    for(CFIndex i = 0; i < CFArrayGetCount(chain); i++) {
        SecCertificateRef c = (SecCertificateRef)CFArrayGetValueAtIndex(chain, i);
        CFStringRef cert = CFCopyDescription(c);
        [buf appendFormat:@"\n   %@: status=%08x ", cert, stats[i].StatusBits];
        CFRelease(cert);
        NSMutableArray *codez = [NSMutableArray array];
        
        for(int b = 0; statusBits[b].display; b ++) {
            if ((statusBits[b].bit & stats[i].StatusBits) == statusBits[b].bit)
                [codez addObject:statusBits[b].display];
        }
        if ([codez count]) {
            [buf appendFormat:@"(%@) ", [codez componentsJoinedByComma]];
            [codez removeAllObjects];
        }
        
        for(unsigned int ret = 0; ret < stats[i].NumStatusCodes; ret++)
            [codez addObject:OFStringFromCSSMReturn(stats[i].StatusCodes[ret])];
    }
    
    CFRelease(chain);
    
    return buf;
}
    
#else

NSString *OFSummarizeTrustResult(SecTrustRef evaluationContext)
{
    OSStatus err;
    SecTrustResultType trustResult;
    
    err = SecTrustGetTrustResult(evaluationContext, &trustResult);
    if (err != noErr) {
        return [NSString stringWithFormat:@"[SecTrustGetTrustResult failure: %@]", OFOSStatusDescription(err)];
    }
    
    NSMutableString *buf = [NSMutableString stringWithFormat:@"Trust result = %d", (int)trustResult];
    for(int i = 0; results[i].display; i++) {
        if(results[i].code == trustResult) {
            [buf appendFormat:@" (%@)", results[i].display];
        }
    }
 
    CFArrayRef certProperties = SecTrustCopyProperties(evaluationContext);
    for(CFIndex i = 0; i < CFArrayGetCount(certProperties); i++) {
        NSDictionary *c = (NSDictionary *)CFArrayGetValueAtIndex(certProperties, i);
        [buf appendFormat:@"\n  "];
        for (NSString *k in c) {
            [buf appendFormat:@" %s=%s", k, [[c objectForKey:k] description]];
        }
    }
    CFRelease(certProperties);
    
    return buf;
}

#endif
    
NSArray *OFReadCertificatesFromFile(NSString *path, SecExternalFormat inputFormat_, NSError **outError)
{
    NSData *pemFile = [[NSData alloc] initWithContentsOfFile:path options:0 error:outError];
    if (!pemFile)
        return nil;
    
    SecExternalFormat inputFormat;
    SecExternalItemType itemType;
    
    /* Oh Apple, why do you hate us so? */
#if defined(MAC_OS_X_VERSION_10_7) && MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_7
    SecItemImportExportKeyParameters keyParams = (SecItemImportExportKeyParameters){
#else
    SecKeyImportExportParameters keyParams = (SecKeyImportExportParameters){
#endif
        .version = SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION,  /* Yes, both versions have the same version number */
        .flags = 0,
        .passphrase = NULL,
        .alertTitle = NULL,  /* undocumentedly does nothing: see RADAR #7530393 */
        .alertPrompt = NULL,
        .accessRef = NULL,
#if defined(MAC_OS_X_VERSION_10_7) && MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_7
        .keyUsage = (CFArrayRef)[NSArray arrayWithObject:(id)kSecAttrCanVerify],
        /* The docs say to use CSSM_KEYATTR_EXTRACTABLE here, but that's clearly wrong--- apparently nobody updated the docs after updating the API to purge all references to CSSM. kSecKeyExtractable exists, but it's the wrong type and is deprecated. Anyway, certificates are generally extractable, so I guess we can rely on the default behavior being what we want here, but it would be nice if Lion's crypto were a little less half-baked.
         Update: According to the libsecurity sources, the only thing accepted in keyAttributes is kSecAttrIsPermanent. SecItemImport() just converts the strings to CSSM_FOO flags and calls SecKeychainItemImport(). (RADAR 10428209, 10274369)
         */
        .keyAttributes = NULL
#else
        .keyUsage = CSSM_KEYUSE_VERIFY,
        .keyAttributes = CSSM_KEYATTR_EXTRACTABLE | CSSM_KEYATTR_RETURN_DATA
#endif
    };
    CFArrayRef outItems;
    
    inputFormat = inputFormat_;
    itemType = kSecItemTypeCertificate;
    
    OSStatus err = 
#if defined(MAC_OS_X_VERSION_10_7) && MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_7
                   SecItemImport(
#else
                   SecKeychainItemImport(
#endif    
                                         (CFDataRef)pemFile, (CFStringRef)path,
                                         &inputFormat, &itemType, 0, &keyParams, NULL, &outItems);
    
    [pemFile release];
    
    if (err != noErr) {
        if (outError)
            *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:err userInfo:[NSDictionary dictionaryWithObjectsAndKeys:path, NSFilePathErrorKey, @"SecKeychainItemImport", @"function", nil]];
        return nil;
    }
    
    if (!outItems)
        return [NSArray array];
    return [NSMakeCollectable(outItems) autorelease];
}
                                 
