#import "unarchive.h"

#include "archive.h"
#include "archive_entry.h"

#  import <Foundation/Foundation.h>

static int
copy_data(struct archive *ar, struct archive *aw, NSProgress *progress)
{
  int r;
  const void *buff;
  size_t size;
  la_int64_t offset;

  for (;;) {
    r = archive_read_data_block(ar, &buff, &size, &offset);
    if (r == ARCHIVE_EOF)
      return (ARCHIVE_OK);
    if (r < ARCHIVE_OK) {
      fprintf(stderr, "%s\n", archive_error_string(ar));
      NSLog(@"[iOSVM] extract copy_data failed: %s", archive_error_string(ar));
      return (r);
    }
    r = archive_write_data_block(aw, buff, size, offset);
    if (r < ARCHIVE_OK) {
      fprintf(stderr, "%s\n", archive_error_string(aw));
      return (r);
    }
    progress.completedUnitCount += size;
  }
}

int extract(NSString* fileToExtract, NSString* extractionPath, NSProgress* progress)
{
    struct archive *a;
    struct archive *ext;
    struct archive_entry *entry;
    int flags;
    int r;

    /* Select which attributes we want to restore. */
    flags = ARCHIVE_EXTRACT_TIME;
    flags |= ARCHIVE_EXTRACT_PERM;
    flags |= ARCHIVE_EXTRACT_ACL;
    flags |= ARCHIVE_EXTRACT_FFLAGS;
    // NOTE: ARCHIVE_EXTRACT_SECURE_* flags must NOT be set here.
    // This writer receives absolute output paths (extractionPath + entry
    // name) by design. SECURE_NOABSOLUTEPATHS rejects every entry outright,
    // and SECURE_SYMLINKS walks the absolute path's components and trips over
    // system symlinks (/var -> /private/var on iOS, /tmp on macOS), rejecting
    // every entry as well. Security is enforced by the manual checks below:
    // entries that are symlinks/hardlinks, absolute, or contain ".." are
    // refused before reaching libarchive, so nothing can be written outside
    // the freshly created extraction workspace.

    // Calculate decompressed size
    a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    if ((r = archive_read_open_filename(a, fileToExtract.fileSystemRepresentation, 10240))) {
        NSLog(@"[iOSVM] extract pass1 open failed: %s", archive_error_string(a));
        archive_read_free(a);
        return 1;
    }
    while ((r = archive_read_next_header(a, &entry)) != ARCHIVE_EOF) {
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(a));
        if (r < ARCHIVE_WARN) {
            NSLog(@"[iOSVM] extract pass1 header failed at %s: %s", archive_entry_pathname(entry) ? archive_entry_pathname(entry) : "(null)", archive_error_string(a));
            archive_read_close(a);
            archive_read_free(a);
            return 1;
        }
        progress.totalUnitCount += archive_entry_size(entry);
    }
    archive_read_close(a);
    archive_read_free(a);

    // Re-open the archive and extract
    a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    if ((r = archive_read_open_filename(a, fileToExtract.fileSystemRepresentation, 10240))) {
        NSLog(@"[iOSVM] extract pass2 open failed: %s", archive_error_string(a));
        archive_read_free(a);
        return 1;
    }
    ext = archive_write_disk_new();
    archive_write_disk_set_options(ext, flags);
    archive_write_disk_set_standard_lookup(ext);

    int failed = 0;
    while ((r = archive_read_next_header(a, &entry)) != ARCHIVE_EOF) {
        if (r == ARCHIVE_EOF)
            break;
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(a));
        if (r < ARCHIVE_WARN) {
            NSLog(@"[iOSVM] extract pass2 header failed at %s: %s", archive_entry_pathname(entry) ? archive_entry_pathname(entry) : "(null)", archive_error_string(a));
            failed = 1;
            break;
        }

        NSString* currentFile = [NSString stringWithUTF8String:archive_entry_pathname(entry)];
        // Belt-and-suspenders on top of the SECURE_* options: reject entries
        // with an absolute or traversing name, and reject link/special file
        // entries so the extracted bundle never contains one.
        mode_t entryType = archive_entry_filetype(entry) & AE_IFMT;
        if (currentFile.length == 0 || [currentFile hasPrefix:@"/"] ||
            [[currentFile pathComponents] containsObject:@".."] ||
            entryType == AE_IFLNK || archive_entry_hardlink(entry) ||
            (entryType != AE_IFREG && entryType != AE_IFDIR)) {
            fprintf(stderr, "Refusing unsafe archive entry: %s\n",
                    archive_entry_pathname(entry) ? archive_entry_pathname(entry) : "(null)");
            NSLog(@"[iOSVM] extract refusing unsafe entry: %s (type=%o)",
                  archive_entry_pathname(entry) ? archive_entry_pathname(entry) : "(null)", entryType);
            failed = 1;
            break;
        }
        NSString* fullOutputPath = [extractionPath stringByAppendingPathComponent:currentFile];
        //printf("extracting %@ to %@\n", currentFile, fullOutputPath);
        archive_entry_set_pathname(entry, fullOutputPath.fileSystemRepresentation);

        r = archive_write_header(ext, entry);
        if (r < ARCHIVE_OK) {
            fprintf(stderr, "%s\n", archive_error_string(ext));
            NSLog(@"[iOSVM] extract write_header failed for %@: %s", currentFile, archive_error_string(ext));
            failed = 1;
            break;
        } else if (archive_entry_size(entry) > 0) {
            r = copy_data(a, ext, progress);
            if (r < ARCHIVE_OK)
                fprintf(stderr, "%s\n", archive_error_string(ext));
            if (r < ARCHIVE_WARN) {
                NSLog(@"[iOSVM] extract data copy failed at %s: %s", archive_entry_pathname(entry) ? archive_entry_pathname(entry) : "(null)", archive_error_string(ext));
                failed = 1;
                break;
            }
        }
        r = archive_write_finish_entry(ext);
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(ext));
        if (r < ARCHIVE_WARN) {
            NSLog(@"[iOSVM] extract finish_entry failed at %s: %s", archive_entry_pathname(entry) ? archive_entry_pathname(entry) : "(null)", archive_error_string(ext));
            failed = 1;
            break;
        }
    }
    archive_read_close(a);
    archive_read_free(a);
    archive_write_close(ext);
    archive_write_free(ext);

    if (failed) NSLog(@"[iOSVM] extract ended failed=1 for %@", fileToExtract);
    return failed ? 1 : 0;
}

NSData *iosvmDecodeGadgetXZ(NSData *source, NSError **error) {
    struct archive *reader = archive_read_new();
    NSMutableData *result = [NSMutableData data];
    const char *message = "无效的 Gadget XZ 文件";
    BOOL ok = NO;
    if (!reader) goto done;
    archive_read_support_filter_xz(reader);
    archive_read_support_format_raw(reader);
    if (archive_read_open_memory(reader, source.bytes, source.length) != ARCHIVE_OK) goto done;
    struct archive_entry *entry;
    if (archive_read_next_header(reader, &entry) != ARCHIVE_OK || archive_filter_code(reader, 0) != ARCHIVE_FILTER_XZ) goto done;
    unsigned char buffer[65536];
    la_ssize_t count;
    while ((count = archive_read_data(reader, buffer, sizeof(buffer))) > 0) {
        if (result.length + count > 128 * 1024 * 1024) { message = "Gadget 解压后超过 128 MiB"; goto done; }
        [result appendBytes:buffer length:(NSUInteger)count];
    }
    if (count < 0 || result.length == 0 || archive_read_next_header(reader, &entry) != ARCHIVE_EOF) goto done;
    ok = YES;
done:
    if (!ok && error) *error = [NSError errorWithDomain:@"IOSVMGadgetXZ" code:1 userInfo:@{NSLocalizedDescriptionKey:@(message)}];
    if (reader) archive_read_free(reader);
    return ok ? result : nil;
}
