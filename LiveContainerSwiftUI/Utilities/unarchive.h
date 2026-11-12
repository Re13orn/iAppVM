#import <Foundation/Foundation.h>

extern int extract(NSString * _Nonnull fileToExtract,
                   NSString * _Nonnull extractionPath,
                   NSProgress * _Nonnull progress);

// Decode one raw XZ stream in memory; never extracts archive paths.
extern NSData * _Nullable iosvmDecodeGadgetXZ(NSData * _Nonnull source, NSError * _Nullable * _Nullable error);
