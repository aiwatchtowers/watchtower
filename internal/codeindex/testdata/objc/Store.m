#import <Foundation/Foundation.h>

#define MAX_SIZE 64

/// Something that can be stored.
@protocol Storable <NSObject>
- (NSString *)key;
@optional
+ (instancetype)empty;
@end

/// How a store is drawn.
typedef NS_ENUM(NSInteger, Shape) {
    ShapeCircle,
    ShapeSquare,
};

/** A key-value store. */
@interface Store : NSObject <Storable>
@property (nonatomic, copy) NSString *name;
@property (nonatomic, readonly) NSUInteger count;
/// Adds a value under a key.
- (void)addValue:(id)value forKey:(NSString *)key;
+ (instancetype)storeWithName:(NSString *)name;
@end

@interface Store (Debug)
- (NSString *)dump;
@end

// The implementation.
@implementation Store {
    NSMutableDictionary *_entries;
}

- (void)addValue:(id)value forKey:(NSString *)key {
    NSString *local = [key copy];
    _entries[local] = value;
}

+ (instancetype)storeWithName:(NSString *)name {
    return [[self alloc] init];
}

- (NSString *)key {
    return self.name;
}

@end

/// Doubles a number.
static int twice(int n) {
    int doubled = n * 2;
    return doubled;
}

struct Point {
    int x;
    int y;
};

NSString *const StoreDidChange = @"StoreDidChange";
