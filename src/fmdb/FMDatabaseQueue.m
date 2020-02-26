//
//  FMDatabaseQueue.m
//  fmdb
//
//  Created by August Mueller on 6/22/11.
//  Copyright 2011 Flying Meat Inc. All rights reserved.
//

#import "FMDatabaseQueue.h"
#import "FMDatabase.h"

#if FMDB_SQLITE_STANDALONE
#import <sqlite3/sqlite3.h>
#else
#import <sqlite3.h>
#endif

typedef NS_ENUM(NSInteger, FMDBTransaction) {
    FMDBTransactionExclusive,
    FMDBTransactionDeferred,
    FMDBTransactionImmediate,
};

/*
 
 Note: we call [self retain]; before using dispatch_sync, just incase 
 FMDatabaseQueue is released on another thread and we're in the middle of doing
 something in dispatch_sync
 
 */

/*
 * A key used to associate the FMDatabaseQueue object with the dispatch_queue_t it uses.
 * This in turn is used for deadlock detection by seeing if inDatabase: is called on
 * the queue's dispatch queue, which should not happen and causes a deadlock.
 */
static const void * const kDispatchQueueSpecificKey = &kDispatchQueueSpecificKey;

@interface FMDatabaseQueue () {
    dispatch_queue_t    _queue;
    dispatch_group_t    _group;
    FMDatabase          *_db;
}
@end

@implementation FMDatabaseQueue

+ (instancetype)databaseQueueWithPath:(NSString *)aPath {
    FMDatabaseQueue *q = [[self alloc] initWithPath:aPath];
    
    FMDBAutorelease(q);
    
    return q;
}

+ (instancetype)databaseQueueWithURL:(NSURL *)url {
    return [self databaseQueueWithPath:url.path];
}

+ (instancetype)databaseQueueWithPath:(NSString *)aPath flags:(int)openFlags {
    FMDatabaseQueue *q = [[self alloc] initWithPath:aPath flags:openFlags];
    
    FMDBAutorelease(q);
    
    return q;
}

+ (instancetype)databaseQueueWithURL:(NSURL *)url flags:(int)openFlags {
    return [self databaseQueueWithPath:url.path flags:openFlags];
}

+ (Class)databaseClass {
    return [FMDatabase class];
}

- (instancetype)initWithURL:(NSURL *)url flags:(int)openFlags vfs:(NSString *)vfsName {
    return [self initWithPath:url.path flags:openFlags vfs:vfsName];
}

- (instancetype)initWithPath:(NSString*)aPath flags:(int)openFlags vfs:(NSString *)vfsName {
    self = [super init];
    
    if (self != nil) {
        
        _db = [[[self class] databaseClass] databaseWithPath:aPath];
        FMDBRetain(_db);
        
#if SQLITE_VERSION_NUMBER >= 3005000
        BOOL success = [_db openWithFlags:openFlags vfs:vfsName];
#else
        BOOL success = [_db open];
#endif
        if (!success) {
            NSLog(@"Could not create database queue for path %@", aPath);
            FMDBRelease(self);
            return 0x00;
        }
        
        _path = FMDBReturnRetained(aPath);
        
        _queue = dispatch_queue_create([[NSString stringWithFormat:@"fmdb.%@", self] UTF8String], NULL);
        dispatch_queue_set_specific(_queue, kDispatchQueueSpecificKey, (__bridge void *)self, NULL);
        
        _group = dispatch_group_create();
        _openFlags = openFlags;
        _vfsName = [vfsName copy];
    }
    
    return self;
}

- (instancetype)initWithPath:(NSString *)aPath flags:(int)openFlags {
    return [self initWithPath:aPath flags:openFlags vfs:nil];
}

- (instancetype)initWithURL:(NSURL *)url flags:(int)openFlags {
    return [self initWithPath:url.path flags:openFlags vfs:nil];
}

- (instancetype)initWithURL:(NSURL *)url {
    return [self initWithPath:url.path];
}

- (instancetype)initWithPath:(NSString *)aPath {
    // default flags for sqlite3_open
    return [self initWithPath:aPath flags:SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE vfs:nil];
}

- (instancetype)init {
    return [self initWithPath:nil];
}

- (void)dealloc {
    FMDBRelease(_db);
    FMDBRelease(_path);
    FMDBRelease(_vfsName);
    
    if (_queue) {
        FMDBDispatchQueueRelease(_queue);
        _queue = 0x00;
    }
#if ! __has_feature(objc_arc)
    [super dealloc];
#endif
}

- (void)close {
    FMDBRetain(self);
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 0);
    if (dispatch_group_wait(_group, timeout)) {
         if (_db.logsErrors) NSLog(@"async database closing with pending async operations");
    }
    dispatch_sync(_queue, ^() {
        [self->_db close];
        FMDBRelease(_db);
        self->_db = 0x00;
    });
    FMDBRelease(self);
}

- (void)interrupt {
    [[self database] interrupt];
}

- (FMDatabase*)database {
    if (![_db isOpen]) {
        if (!_db) {
           _db = FMDBReturnRetained([[[self class] databaseClass] databaseWithPath:_path]);
        }
        
#if SQLITE_VERSION_NUMBER >= 3005000
        BOOL success = [_db openWithFlags:_openFlags vfs:_vfsName];
#else
        BOOL success = [_db open];
#endif
        if (!success) {
            NSLog(@"FMDatabaseQueue could not reopen database for path %@", _path);
            FMDBRelease(_db);
            _db  = 0x00;
            return 0x00;
        }
    }
    
    return _db;
}

- (void)doWithDatabase:(__attribute__((noescape)) void (^)(FMDatabase *db)) block {

    FMDatabase *db = [self database];
    
    block(db);
    
    if ([db hasOpenResultSets]) {
        NSLog(@"Warning: there is at least one open result set around after performing [FMDatabaseQueue inDatabase:]");
        
#if defined(DEBUG) && DEBUG
        NSSet *openSetCopy = FMDBReturnAutoreleased([[db valueForKey:@"_openResultSets"] copy]);
        for (NSValue *rsInWrappedInATastyValueMeal in openSetCopy) {
            FMResultSet *rs = (FMResultSet *)[rsInWrappedInATastyValueMeal pointerValue];
            NSLog(@"query: '%@'", [rs query]);
        }
#endif
    }
}

- (void)inDatabase:(__attribute__((noescape)) void (^)(FMDatabase *db))block {
#ifndef NDEBUG
    /* Get the currently executing queue (which should probably be nil, but in theory could be another DB queue
     * and then check it against self to make sure we're not about to deadlock. */
    FMDatabaseQueue *currentSyncQueue = (__bridge id)dispatch_get_specific(kDispatchQueueSpecificKey);
    assert(currentSyncQueue != self && "inDatabase: was called reentrantly on the same queue, which would lead to a deadlock");
#endif
    
    FMDBRetain(self);
    
    dispatch_sync(_queue, ^() {
        [self doWithDatabase:block];
    });
    
    FMDBRelease(self);
}


- (void)inDatabaseAsync:(__attribute__((noescape)) void (^)(FMDatabase *db))block {
    FMDBRetain(self);
    
    __weak FMDatabaseQueue* weaker = self;
    dispatch_group_async(_group, _queue, ^() {
        __strong FMDatabaseQueue *stronger = weaker;
        [stronger doWithDatabase:block];
    });
    
    FMDBRelease(self);
}

- (void) doTransaction: (FMDBTransaction) transaction withBlock:(void (^)(FMDatabase *db, BOOL *rollback)) block {
    BOOL shouldRollback = NO;

    switch (transaction) {
        case FMDBTransactionExclusive:
            [[self database] beginTransaction];
            break;
        case FMDBTransactionDeferred:
            [[self database] beginDeferredTransaction];
            break;
        case FMDBTransactionImmediate:
            [[self database] beginImmediateTransaction];
            break;
    }
    
    block([self database], &shouldRollback);
    
    if (shouldRollback) {
        [[self database] rollback];
    }
    else {
        [[self database] commit];
    }
}


- (void)beginTransaction:(FMDBTransaction)transaction withBlock:(void (^)(FMDatabase *db, BOOL *rollback))block {
    FMDBRetain(self);
    dispatch_sync(_queue, ^() {
        [self doTransaction:transaction withBlock:block];
    });
    
    FMDBRelease(self);
}


- (void)beginTransactionAsync:(FMDBTransaction)transaction withBlock:(void (^)(FMDatabase *db, BOOL *rollback))block {
    FMDBRetain(self);
    __weak FMDatabaseQueue* weaker = self;
    dispatch_group_async(_group, _queue, ^() {
        __strong FMDatabaseQueue *stronger = weaker;
        [stronger doTransaction:transaction withBlock:block];
    });
    
    FMDBRelease(self);
}


- (void)inTransaction:(__attribute__((noescape)) void (^)(FMDatabase *db, BOOL *rollback))block {
    [self beginTransaction:FMDBTransactionExclusive withBlock:block];
}

- (void)inTransactionAsync:(__attribute__((noescape)) void (^)(FMDatabase *db, BOOL *rollback))block {
    [self beginTransactionAsync:FMDBTransactionExclusive withBlock:block];
}

- (void)inDeferredTransaction:(__attribute__((noescape)) void (^)(FMDatabase *db, BOOL *rollback))block {
    [self beginTransaction:FMDBTransactionDeferred withBlock:block];
}

- (void)inDeferredTransactionAsync:(__attribute__((noescape)) void (^)(FMDatabase *db, BOOL *rollback))block {
    [self beginTransactionAsync:FMDBTransactionDeferred withBlock:block];
}

- (void)inExclusiveTransaction:(__attribute__((noescape)) void (^)(FMDatabase *db, BOOL *rollback))block {
    [self beginTransaction:FMDBTransactionExclusive withBlock:block];
}

- (void)inExclusiveTransactionAsync:(__attribute__((noescape)) void (^)(FMDatabase *db, BOOL *rollback))block {
    [self beginTransactionAsync:FMDBTransactionExclusive withBlock:block];
}

- (void)inImmediateTransaction:(__attribute__((noescape)) void (^)(FMDatabase * _Nonnull, BOOL * _Nonnull))block {
    [self beginTransaction:FMDBTransactionImmediate withBlock:block];
}

- (void)inImmediateTransactionAsync:(__attribute__((noescape)) void (^)(FMDatabase * _Nonnull, BOOL * _Nonnull))block {
    [self beginTransactionAsync:FMDBTransactionImmediate withBlock:block];
}

- (void) doSavePoint:(NSError *_Nullable __autoreleasing*) err block: (__attribute__((noescape)) void (^)(FMDatabase *db, BOOL *rollback))block {
    
#if SQLITE_VERSION_NUMBER >= 3007000
    static unsigned long savePointIdx = 0;
    
    NSString *name = [NSString stringWithFormat:@"savePoint%ld", savePointIdx++];
    
    BOOL shouldRollback = NO;
    
    if ([[self database] startSavePointWithName:name error:err]) {
        
        block([self database], &shouldRollback);
        
        if (shouldRollback) {
            // We need to rollback and release this savepoint to remove it
            [[self database] rollbackToSavePointWithName:name error:err];
        }
        [[self database] releaseSavePointWithName:name error:err];
        
    }
#endif
}

- (NSError*)inSavePoint:(__attribute__((noescape)) void (^)(FMDatabase *db, BOOL *rollback))block {
#if SQLITE_VERSION_NUMBER >= 3007000
    __block NSError *err = 0x00;
    FMDBRetain(self);
    dispatch_sync(_queue, ^() {
        [self doSavePoint:&err block:block];
    });
    FMDBRelease(self);
    return err;
#else
    NSString *errorMessage = NSLocalizedStringFromTable(@"Save point functions require SQLite 3.7", @"FMDB", nil);
    if (_db.logsErrors) NSLog(@"%@", errorMessage);
    return [NSError errorWithDomain:@"FMDatabase" code:0 userInfo:@{NSLocalizedDescriptionKey : errorMessage}];
#endif
}

- (NSError*)inSavePointAsync:(__attribute__((noescape)) void (^)(FMDatabase *db, BOOL *rollback))block {
#if SQLITE_VERSION_NUMBER >= 3007000
    __block NSError *err = 0x00;
    FMDBRetain(self);
    __weak FMDatabaseQueue *weaker = self;
    dispatch_group_async(_group, _queue, ^() {
        __strong FMDatabaseQueue *stronger = weaker;
        [stronger doSavePoint:&err block:block];
    });
    FMDBRelease(self);
    return err;
#else
    NSString *errorMessage = NSLocalizedStringFromTable(@"Save point functions require SQLite 3.7", @"FMDB", nil);
    if (_db.logsErrors) NSLog(@"%@", errorMessage);
    return [NSError errorWithDomain:@"FMDatabase" code:0 userInfo:@{NSLocalizedDescriptionKey : errorMessage}];
#endif
}

- (BOOL)checkpoint:(FMDBCheckpointMode)mode error:(NSError * __autoreleasing *)error
{
    return [self checkpoint:mode name:nil logFrameCount:NULL checkpointCount:NULL error:error];
}

- (BOOL)checkpoint:(FMDBCheckpointMode)mode name:(NSString *)name error:(NSError * __autoreleasing *)error
{
    return [self checkpoint:mode name:name logFrameCount:NULL checkpointCount:NULL error:error];
}

- (BOOL)checkpoint:(FMDBCheckpointMode)mode name:(NSString *)name logFrameCount:(int * _Nullable)logFrameCount checkpointCount:(int * _Nullable)checkpointCount error:(NSError * __autoreleasing _Nullable * _Nullable)error
{
    __block BOOL result;
    __block NSError *blockError;
    
    FMDBRetain(self);
    dispatch_sync(_queue, ^() {
        result = [self.database checkpoint:mode name:name logFrameCount:logFrameCount checkpointCount:checkpointCount error:&blockError];
    });
    FMDBRelease(self);
    
    if (error) {
        *error = blockError;
    }
    return result;
}

@end
