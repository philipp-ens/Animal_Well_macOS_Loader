/* steamcloud_tool.m - a command-line test of steamcloud.m (the loader itself does not use this file).
 *
 * Build it from the repository's folder:
 *   clang -fobjc-arc -O2 steamcloud/steamcloud.m steamcloud/steamcloud_tool.m -framework Foundation \
 *         -framework Security -framework AppKit -framework CoreImage -lz -o steamcloud_tool
 *
 *   ./steamcloud_tool signin [--qr-png <file>]   sign in by QR code (shown in the terminal; with --qr-png the
 *                                                code is also written to that picture file each time it changes)
 *   ./steamcloud_tool status                     is a login saved?
 *   ./steamcloud_tool list                       connect, log on, list ANIMAL WELL's cloud files
 *   ./steamcloud_tool download <file>            download ANIMAL WELL's cloud save into <file>
 *   ./steamcloud_tool unzip <zip> <file>         (no Steam needed) unpack a zip the way downloads are unpacked
 *   ./steamcloud_tool zip <file> <zip>           (no Steam needed) pack a file the way uploads are packed
 *   ./steamcloud_tool upload-test                upload a small throwaway file next to the save, download it back,
 *                                                delete it again - the save itself is not touched
 *   ./steamcloud_tool upload <file>              REPLACE ANIMAL WELL's cloud save with <file>
 *   ./steamcloud_tool signout                    forget the saved login
 * Set the environment variable STEAMCLOUD_VERBOSE=1 to see whether a download came zipped.
 */
#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <CommonCrypto/CommonDigest.h>
#include "steamcloud.h"

#define ANIMAL_WELL 813230
#define SAVE_NAME   "%WinAppDataLocalLow%Billy Basso/Animal Well/AnimalWell.sav"     /* the save's name in the cloud */

NSData *steamcloud_unzip(NSData *zip, NSString **problem);      /* in steamcloud.m; not part of its interface */
NSData *steamcloud_zip(NSData *plain);

static NSString *sha1_hex(NSData *data) {
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static NSString *qr_png_path;

/* macOS can make QR codes itself (Core Image). `scale` is the size of one dot in pixels. */
static NSBitmapImageRep *qr_bitmap(NSString *text, int scale) {
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:[text dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *image = [filter.outputImage imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    return [[NSBitmapImageRep alloc] initWithCIImage:image];
}

static void show_qr(const char *address, void *context) {
    (void)context;
    @autoreleasepool {
        NSString *text = @(address);
        if (qr_png_path) {
            NSData *png = [qr_bitmap(text, 12) representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            [png writeToFile:qr_png_path atomically:YES];
        }
        /* in the terminal: two spaces per dot, black or white background, with a white border around it */
        NSBitmapImageRep *dots = qr_bitmap(text, 1);
        printf("\nScan this with the Steam mobile app (Steam Guard tab, \"Scan a QR code\"):\n\n");
        for (NSInteger y = -1; y <= dots.pixelsHigh; y++) {
            for (NSInteger x = -1; x <= dots.pixelsWide; x++) {
                BOOL dark = NO;
                if (x >= 0 && y >= 0 && x < dots.pixelsWide && y < dots.pixelsHigh)
                    dark = [dots colorAtX:x y:y].brightnessComponent < 0.5;
                fputs(dark ? "\033[40m  " : "\033[47m  ", stdout);
            }
            fputs("\033[0m\n", stdout);
        }
        printf("\n(the code changes about every half minute; a new one is then printed)\n");
        fflush(stdout);
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *command = argc > 1 ? argv[1] : "";
        char error[512] = "", account[256] = "";
        if (!strcmp(command, "signin")) {
            if (argc > 3 && !strcmp(argv[2], "--qr-png")) qr_png_path = @(argv[3]);
            if (!steamcloud_sign_in(show_qr, NULL, 240, error, sizeof error)) { printf("sign-in failed: %s\n", error); return 1; }
            steamcloud_signed_in(account, sizeof account);
            printf("signed in as %s; the login is saved in the Keychain\n", account);
            return 0;
        }
        if (!strcmp(command, "status")) {
            if (steamcloud_signed_in(account, sizeof account)) printf("a login is saved for %s\n", account);
            else printf("no login is saved\n");
            return 0;
        }
        if (!strcmp(command, "signout")) {
            steamcloud_sign_out();
            printf("the saved login was removed\n");
            return 0;
        }
        if (!strcmp(command, "list")) {
            if (!steamcloud_connect(error, sizeof error)) { printf("could not connect: %s\n", error); return 1; }
            printf("connected and logged on\n");
            static steamcloud_file files[64];
            int count = steamcloud_list(ANIMAL_WELL, files, 64, error, sizeof error);
            if (count < 0) printf("listing failed: %s\n", error);
            else printf("%d cloud file(s) for app %d\n", count, ANIMAL_WELL);
            for (int i = 0; i < count && i < 64; i++) {
                time_t when = (time_t)files[i].time;
                char date[32];
                strftime(date, sizeof date, "%Y-%m-%d %H:%M:%S", localtime(&when));
                printf("  \"%s\"\n      %u bytes, changed %s, platforms %s, sha1 %s\n",
                       files[i].name, files[i].size, date, files[i].platforms, files[i].sha1);
            }
            steamcloud_disconnect();
            return count < 0;
        }
        if (!strcmp(command, "download") && argc > 2) {
            if (!steamcloud_connect(error, sizeof error)) { printf("could not connect: %s\n", error); return 1; }
            printf("connected and logged on\n");
            size_t size = 0;
            uint8_t *contents = steamcloud_download(ANIMAL_WELL, SAVE_NAME, &size, error, sizeof error);
            steamcloud_disconnect();
            if (!contents) { printf("download failed: %s\n", error); return 1; }
            NSData *data = [NSData dataWithBytesNoCopy:contents length:size freeWhenDone:YES];
            if (![data writeToFile:@(argv[2]) atomically:YES]) { printf("could not write %s\n", argv[2]); return 1; }
            printf("downloaded %zu bytes into %s\n  sha1 %s (checked against Steam's)\n", size, argv[2], sha1_hex(data).UTF8String);
            return 0;
        }
        if (!strcmp(command, "zip") && argc > 3) {
            NSData *plain = [NSData dataWithContentsOfFile:@(argv[2])];
            NSData *zip = plain ? steamcloud_zip(plain) : nil;
            if (!zip) { printf("zip failed\n"); return 1; }
            [zip writeToFile:@(argv[3]) atomically:YES];
            printf("packed %zu bytes into %zu\n", (size_t)plain.length, (size_t)zip.length);
            return 0;
        }
        if (!strcmp(command, "upload-test")) {
            const char *name = "%WinAppDataLocalLow%Billy Basso/Animal Well/loader_upload_test.txt";
            NSMutableString *text = [NSMutableString string];
            for (int i = 0; i < 400; i++) [text appendFormat:@"line %d of a throwaway test file from the Animal Well macOS loader\n", i];
            NSData *sent = [text dataUsingEncoding:NSUTF8StringEncoding];
            if (!steamcloud_connect(error, sizeof error)) { printf("could not connect: %s\n", error); return 1; }
            printf("connected and logged on\n");
            int ok = steamcloud_upload(ANIMAL_WELL, name, sent.bytes, sent.length, (uint64_t)time(NULL), STEAMCLOUD_WINDOWS, error, sizeof error);
            printf("upload of %zu bytes: %s\n", (size_t)sent.length, ok ? "ok" : error);
            static steamcloud_file files[64];
            int count = steamcloud_list(ANIMAL_WELL, files, 64, error, sizeof error);
            for (int i = 0; i < count && i < 64; i++)
                printf("  in the cloud: \"%s\", %u bytes, platforms %s, sha1 %s\n", files[i].name, files[i].size, files[i].platforms, files[i].sha1);
            if (ok) {
                size_t size = 0;
                uint8_t *back = steamcloud_download(ANIMAL_WELL, name, &size, error, sizeof error);
                if (!back) printf("download back failed: %s\n", error);
                else printf("downloaded back %zu bytes: %s\n", size, size == sent.length && !memcmp(back, sent.bytes, size) ? "identical to what was sent" : "DIFFERENT from what was sent");
                free(back);
                printf("delete: %s\n", steamcloud_delete(ANIMAL_WELL, name, error, sizeof error) ? "ok" : error);
                count = steamcloud_list(ANIMAL_WELL, files, 64, error, sizeof error);
                printf("%d cloud file(s) left\n", count);
                for (int i = 0; i < count && i < 64; i++) printf("  in the cloud: \"%s\", sha1 %s\n", files[i].name, files[i].sha1);
            }
            steamcloud_disconnect();
            return !ok;
        }
        if (!strcmp(command, "upload") && argc > 2) {
            NSData *save = [NSData dataWithContentsOfFile:@(argv[2])];
            NSDate *changed = [[NSFileManager defaultManager] attributesOfItemAtPath:@(argv[2]) error:nil].fileModificationDate;
            if (!save || !changed) { printf("cannot read %s\n", argv[2]); return 1; }
            if (!steamcloud_connect(error, sizeof error)) { printf("could not connect: %s\n", error); return 1; }
            printf("connected and logged on\n");
            int ok = steamcloud_upload(ANIMAL_WELL, SAVE_NAME, save.bytes, save.length, (uint64_t)changed.timeIntervalSince1970,
                                       STEAMCLOUD_WINDOWS, error, sizeof error);
            steamcloud_disconnect();
            if (!ok) { printf("upload failed: %s\n", error); return 1; }
            printf("uploaded %zu bytes as the cloud save\n  sha1 %s\n", (size_t)save.length, sha1_hex(save).UTF8String);
            return 0;
        }
        if (!strcmp(command, "unzip") && argc > 3) {
            NSData *zip = [NSData dataWithContentsOfFile:@(argv[2])];
            NSString *problem = nil;
            NSData *plain = zip ? steamcloud_unzip(zip, &problem) : nil;
            if (!plain) { printf("unzip failed: %s\n", zip ? problem.UTF8String : "cannot read the file"); return 1; }
            [plain writeToFile:@(argv[3]) atomically:YES];
            printf("unpacked %zu bytes, sha1 %s\n", (size_t)plain.length, sha1_hex(plain).UTF8String);
            return 0;
        }
        printf("usage: steamcloud_tool signin [--qr-png <file>] | status | list | download <file> | upload-test | upload <file> |\n                             zip <file> <zip> | unzip <zip> <file> | signout\n");
        return 2;
    }
}
