#import "SSELibrary.h"

#import <OmniBase/OmniBase.h>
#import <OmniFoundation/OmniFoundation.h>

#import "SSELibraryEntry.h"
#import "BDAlias.h"


@interface SSELibrary (Private)

- (NSArray *)_fileTypesFromDocumentTypeDictionary:(NSDictionary *)documentTypeDict;

- (void)_loadEntries;

@end


@implementation SSELibrary

DEFINE_NSSTRING(SSELibraryDidChangeNotification);

const FourCharCode SSEApplicationCreatorCode = 'SnSX';
const FourCharCode SSELibraryFileTypeCode = 'sXLb';
const FourCharCode SSESysExFileTypeCode = 'sysX';
NSString *SSESysExFileExtension = @"syx";


+ (NSString *)defaultPath;
{
    return [[[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"SysEx Librarian"] stringByAppendingPathComponent:@"SysEx Library.sXLb"];
}

+ (NSString *)path;
{
    NSData *aliasData;
    NSString *path = nil;

    aliasData = [[NSUserDefaults standardUserDefaults] objectForKey:@"LibraryAlias"];
    if (aliasData) {
        BDAlias *alias;

        alias = [BDAlias aliasWithData:aliasData];
        path = [alias fullPath];        
    }
    // TODO We don't save this alias in the user defaults yet, but we need to.
    
    if (!path)
        path = [self defaultPath];

    return path;
}

+ (NSString *)defaultFileDirectoryPath;
{
    return [[[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"SysEx Librarian"] stringByAppendingPathComponent:@"SysEx Files"];
}

+ (NSString *)fileDirectoryPath;
{
    NSData *aliasData;
    NSString *path = nil;

    aliasData = [[NSUserDefaults standardUserDefaults] objectForKey:@"LibraryFileDirectoryAlias"];
    if (aliasData) {
        BDAlias *alias;

        alias = [BDAlias aliasWithData:aliasData];
        path = [alias fullPath];
    }
    // TODO We don't save this alias in the user defaults yet, but we need to.

    if (!path)
        path = [self defaultFileDirectoryPath];

    return path;
}


- (id)init;
{
    NSArray *documentTypes;

    if (![super init])
        return nil;

    libraryFilePath = [[[self class] path] retain];
    entries = [[NSMutableArray alloc] init];
    flags.isDirty = NO;

    [self _loadEntries];

    // Ignore any changes that came from reading entries
    flags.isDirty = NO;

    documentTypes = [[[self bundle] infoDictionary] objectForKey:@"CFBundleDocumentTypes"];
    if ([documentTypes count] > 0) {
        NSDictionary *documentTypeDict;

        documentTypeDict = [documentTypes objectAtIndex:0];
        rawSysExFileTypes = [[self _fileTypesFromDocumentTypeDictionary:documentTypeDict] retain];

        if ([documentTypes count] > 1) {
            documentTypeDict = [documentTypes objectAtIndex:1];
            standardMIDIFileTypes = [[self _fileTypesFromDocumentTypeDictionary:documentTypeDict] retain];
        }
    }
    allowedFileTypes = [[rawSysExFileTypes arrayByAddingObjectsFromArray:standardMIDIFileTypes] retain];
    
    return self;
}

- (void)dealloc;
{
    [libraryFilePath release];
    libraryFilePath = nil;
    [entries release];
    entries = nil;
    [rawSysExFileTypes release];
    rawSysExFileTypes = nil;
    [standardMIDIFileTypes release];
    standardMIDIFileTypes = nil;
    [allowedFileTypes release];
    allowedFileTypes = nil;
    
    [super dealloc];
}

- (NSArray *)entries;
{
    return entries;
}

- (SSELibraryEntry *)addEntryForFile:(NSString *)filePath;
{
    SSELibraryEntry *entry;
    BOOL wasDirty;

    // Setting the entry path and name will cause us to be notified of a change, and we'll autosave.
    // However, the add might not succeed--if it doesn't, make sure our dirty flag isn't set if it shouldn't be.

    wasDirty = flags.isDirty;

    entry = [[SSELibraryEntry alloc] initWithLibrary:self];
    [entry setPath:filePath];

    if ([[entry messages] count] > 0) {
        [entry setNameFromFile];
        [entries addObject:entry];
        [entry release];
    } else {
        [entry release];
        entry = nil;
        if (!wasDirty)
            flags.isDirty = NO;
    }
    
    return entry;
}

- (SSELibraryEntry *)addNewEntryWithData:(NSData *)sysexData;
{
    NSFileManager *fileManager;
    NSString *newFileName;
    NSString *newFilePath;
    NSDictionary *newFileAttributes;
    SSELibraryEntry *entry = nil;

    fileManager = [NSFileManager defaultManager];
    
    // TODO what name?  attach the date, perhaps?
    newFileName = @"New SysEx File";
    newFilePath = [[[[self class] fileDirectoryPath] stringByAppendingPathComponent:newFileName] stringByAppendingPathExtension:SSESysExFileExtension];
    newFilePath = [fileManager uniqueFilenameFromName:newFilePath];

    NS_DURING {
        [fileManager createPathToFile:newFilePath attributes:nil];
    } NS_HANDLER {
        // TODO the above will raise if it fails; need to handle that
        NS_VALUERETURN(nil, SSELibraryEntry*);
    } NS_ENDHANDLER;

    newFileAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithUnsignedLong:SSESysExFileTypeCode], NSFileHFSTypeCode,
        [NSNumber numberWithUnsignedLong:SSEApplicationCreatorCode], NSFileHFSCreatorCode,
        [NSNumber numberWithBool:YES], NSFileExtensionHidden, nil];

    if ([fileManager atomicallyCreateFileAtPath:newFilePath contents:sysexData attributes:newFileAttributes])
        entry = [self addEntryForFile:newFilePath];
    // TODO once again, need to handle the case when this fails

    return entry;
}

- (void)removeEntry:(SSELibraryEntry *)entry;
{
    unsigned int entryIndex;

    entryIndex = [entries indexOfObjectIdenticalTo:entry];
    if (entryIndex != NSNotFound) {
        [entries removeObjectAtIndex:entryIndex];

        [self noteEntryChanged];
    }
}

- (void)noteEntryChanged;
{
    flags.isDirty = YES;
    [self autosave];
    
    [[NSNotificationQueue defaultQueue] enqueueNotificationName:SSELibraryDidChangeNotification object:self postingStyle:NSPostWhenIdle];
}

- (void)autosave;
{
    [self performSelector:@selector(save) withObject:nil afterDelay:0];
}

- (void)save;
{
    NSMutableDictionary *dictionary;
    NSMutableArray *entryDicts;
    unsigned int entryCount, entryIndex;
    NSFileManager *fileManager;
    NSDictionary *fileAttributes;
    
    if (!flags.isDirty)
        return;

    dictionary = [NSMutableDictionary dictionary];
    entryDicts = [NSMutableArray array];

    entryCount = [entries count];
    for (entryIndex = 0; entryIndex < entryCount; entryIndex++) {
        NSDictionary *entryDict;

        entryDict = [[entries objectAtIndex:entryIndex] dictionaryValues];
        if (entryDict)
            [entryDicts addObject:entryDict];
    }

    [dictionary setObject:entryDicts forKey:@"Entries"];

    fileManager = [NSFileManager defaultManager];
    
    NS_DURING {
        [fileManager createPathToFile:libraryFilePath attributes:nil];
    } NS_HANDLER {
        // TODO The above will raise if it fails. Need to tell the user in that case.
    } NS_ENDHANDLER;

    fileAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithUnsignedLong:SSELibraryFileTypeCode], NSFileHFSTypeCode,
        [NSNumber numberWithUnsignedLong:SSEApplicationCreatorCode], NSFileHFSCreatorCode,
        [NSNumber numberWithBool:YES], NSFileExtensionHidden, nil];

    [fileManager atomicallyCreateFileAtPath:libraryFilePath contents:[dictionary xmlPropertyListData] attributes:fileAttributes];    
    // TODO Need to handle the case of the above failing, too
    
    flags.isDirty = NO;
}

- (NSArray *)allowedFileTypes;
{
    return allowedFileTypes;
}

- (SSELibraryFileType)typeOfFileAtPath:(NSString *)filePath;
{
    NSString *fileType;

    if (!filePath || [filePath length] == 0) {
        return SSELibraryFileTypeUnknown;
    }
    
    fileType = [filePath pathExtension];
    if (!fileType || [fileType length] == 0) {
        fileType = NSHFSTypeOfFile(filePath);
    }

    if ([rawSysExFileTypes indexOfObject:fileType] != NSNotFound) {
        return SSELibraryFileTypeRaw;
    } else if ([standardMIDIFileTypes indexOfObject:fileType] != NSNotFound) {
        return SSELibraryFileTypeStandardMIDI;
    } else {
        return SSELibraryFileTypeUnknown;
    }
}

@end


@implementation SSELibrary (Private)

- (NSArray *)_fileTypesFromDocumentTypeDictionary:(NSDictionary *)documentTypeDict;
{
    NSMutableArray *fileTypes;
    NSArray *extensions;
    NSArray *osTypes;

    fileTypes = [NSMutableArray array];

    extensions = [documentTypeDict objectForKey:@"CFBundleTypeExtensions"];
    if (extensions && [extensions isKindOfClass:[NSArray class]]) {
        [fileTypes addObjectsFromArray:extensions];
    }

    osTypes = [documentTypeDict objectForKey:@"CFBundleTypeOSTypes"];
    if (osTypes && [osTypes isKindOfClass:[NSArray class]]) {
        unsigned int osTypeIndex, osTypeCount;

        osTypeCount = [osTypes count];
        for (osTypeIndex = 0; osTypeIndex < osTypeCount; osTypeIndex++) {
            [fileTypes addObject:[NSString stringWithFormat:@"'%@'", [osTypes objectAtIndex:osTypeIndex]]];
        }
    }

    return fileTypes;
}

- (void)_loadEntries;
{
    NSDictionary *libraryDictionary = nil;
    NSArray *entryDicts;
    unsigned int entryDictIndex, entryDictCount;

    NS_DURING {
        libraryDictionary = [NSDictionary dictionaryWithContentsOfFile:libraryFilePath];
    } NS_HANDLER {
        NSLog(@"Error loading library file \"%@\" : %@", libraryFilePath, localException);
        // TODO we can of course do better than this
    } NS_ENDHANDLER;

    entryDicts = [libraryDictionary objectForKey:@"Entries"];
    entryDictCount = [entryDicts count];
    for (entryDictIndex = 0; entryDictIndex < entryDictCount; entryDictIndex++) {
        NSDictionary *entryDict;
        SSELibraryEntry *entry;

        entryDict = [entryDicts objectAtIndex:entryDictIndex];
        entry = [[SSELibraryEntry alloc] initWithLibrary:self dictionary:entryDict];
        [entries addObject:entry];
        [entry release];
    }
}

@end
