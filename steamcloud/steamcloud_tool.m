/* steamcloud_tool.m - a command-line test of steamcloud.m (the loader itself does not use this file).
 *
 * Build it from the repository's folder:
 *   clang -fobjc-arc -O2 steamcloud/steamcloud.m steamcloud/steamcloud_tool.m -framework Foundation \
 *         -framework Security -framework AppKit -framework CoreImage -lz -o steamcloud_tool
 *
 *   ./steamcloud_tool signin [--qr-png <file>]   sign in by QR code (shown in the terminal; with --qr-png the
 *                                                code is also written to that picture file each time it changes)
 *   ./steamcloud_tool signin-password            sign in with account name and password, typed into the terminal
 *                                                (for accounts without the Steam mobile app)
 *   ./steamcloud_tool status                     is a login saved?
 *   ./steamcloud_tool list                       connect, log on, list ANIMAL WELL's cloud files
 *   ./steamcloud_tool download <file>            download ANIMAL WELL's cloud save into <file>
 *   ./steamcloud_tool unzip <zip> <file>         (no Steam needed) unpack a zip the way downloads are unpacked
 *   ./steamcloud_tool zip <file> <zip>           (no Steam needed) pack a file the way uploads are packed
 *   ./steamcloud_tool encrypt <modulus hex> <exponent hex> <text>
 *                                                (no Steam needed) encrypt a text the way a password is, as base64
 *   ./steamcloud_tool upload-test                upload a small throwaway file next to the save, download it back,
 *                                                delete it again - the save itself is not touched
 *   ./steamcloud_tool upload <file>              REPLACE ANIMAL WELL's cloud save with <file>
 *   ./steamcloud_tool sync <file> [keep-local|keep-cloud]
 *                                                bring <file> and ANIMAL WELL's cloud save in line (see steamcloud.h);
 *                                                on a conflict nothing happens unless you say which side wins
 *   ./steamcloud_tool same <file>                only look: is <file> the same as the cloud save? If so, remember it
 *   ./steamcloud_tool delete --name <cloud name> remove one cloud file
 * upload, download and sync take  --name <cloud name>  to work on another cloud file than the save (for tests).
 *   ./steamcloud_tool signout                    forget the saved login
 * Set the environment variable STEAMCLOUD_VERBOSE=1 to see whether a download came zipped and how long the login
 * is still valid; with STEAMCLOUD_RENEW_NOW=1 as well, every connect asks Steam for a fresh login.
 */
#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <CommonCrypto/CommonDigest.h>
#include "steamcloud.h"

#define ANIMAL_WELL 813230
#define SAVE_NAME   "%WinAppDataLocalLow%Billy Basso/Animal Well/AnimalWell.sav"     /* the save's name in the cloud */

NSData *steamcloud_unzip(NSData *zip, NSString **problem);      /* in steamcloud.m; not part of its interface */
NSData *steamcloud_zip(NSData *plain);
NSString *steamcloud_encrypt(NSString *text, NSString *modulus_hex, NSString *exponent_hex);
int steamcloud_key_test(const char *account_name);

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

/* Steam Guard, for a sign-in with a password: ask in the terminal */
static int confirm_in_terminal(steamcloud_confirmation kind, const char *hint, char *code, size_t code_size, void *context) {
    (void)context;
    if (kind == STEAMCLOUD_APPROVE_IN_APP) { printf("Approve the sign-in in the Steam mobile app ...\n"); return 1; }
    if (kind == STEAMCLOUD_APPROVE_BY_EMAIL) { printf("Steam emailed you a link (%s): open it to approve the sign-in ...\n", hint); return 1; }
    printf(kind == STEAMCLOUD_CODE_FROM_EMAIL ? "Steam emailed you a code. %s\nCode: " : "Type the code from the Steam mobile app (Steam Guard). %s\nCode: ", hint);
    fflush(stdout);
    if (!fgets(code, (int)code_size, stdin)) return 0;
    code[strcspn(code, "\r\n")] = 0;
    return code[0] != 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *cloud_name = SAVE_NAME;
        BOOL name_given = NO;
        for (int i = 1; i + 1 < argc; i++)
            if (!strcmp(argv[i], "--name")) {           /* take "--name <cloud name>" out of the arguments */
                cloud_name = argv[i + 1];
                name_given = YES;
                memmove(&argv[i], &argv[i + 2], (size_t)(argc - i - 2) * sizeof *argv);
                argc -= 2;
                break;
            }
        const char *command = argc > 1 ? argv[1] : "";
        char error[512] = "", account[256] = "";
        if (!strcmp(command, "signin")) {
            if (argc > 3 && !strcmp(argv[2], "--qr-png")) qr_png_path = @(argv[3]);
            if (!steamcloud_sign_in(show_qr, NULL, 240, error, sizeof error)) { printf("sign-in failed: %s\n", error); return 1; }
            steamcloud_signed_in(account, sizeof account);
            printf("signed in as %s; the login is saved in the Keychain\n", account);
            return 0;
        }
        if (!strcmp(command, "signin-password")) {
            char name[256] = "";
            printf("Steam account name (the login name, not the profile name): ");
            fflush(stdout);
            if (!fgets(name, sizeof name, stdin)) return 1;
            name[strcspn(name, "\r\n")] = 0;
            char *password = getpass("Password (not shown while you type): ");
            int ok = steamcloud_sign_in_password(name, password, confirm_in_terminal, NULL, 300, error, sizeof error);
            memset(password, 0, strlen(password));          /* do not leave it lying in memory */
            if (!ok) { printf("sign-in failed: %s\n", error); return 1; }
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
            uint8_t *contents = steamcloud_download(ANIMAL_WELL, cloud_name, &size, error, sizeof error);
            steamcloud_disconnect();
            if (!contents) { printf("download failed: %s\n", error); return 1; }
            NSData *data = [NSData dataWithBytesNoCopy:contents length:size freeWhenDone:YES];
            if (![data writeToFile:@(argv[2]) atomically:YES]) { printf("could not write %s\n", argv[2]); return 1; }
            printf("downloaded %zu bytes into %s\n  sha1 %s (checked against Steam's)\n", size, argv[2], sha1_hex(data).UTF8String);
            return 0;
        }
        if (!strcmp(command, "key-test") && argc > 2) return !steamcloud_key_test(argv[2]);
        if (!strcmp(command, "encrypt") && argc > 4) {
            NSString *encrypted = steamcloud_encrypt(@(argv[4]), @(argv[2]), @(argv[3]));
            printf("%s\n", encrypted ? encrypted.UTF8String : "encrypt failed");
            return encrypted == nil;
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
            int ok = steamcloud_upload(ANIMAL_WELL, cloud_name, save.bytes, save.length, (uint64_t)changed.timeIntervalSince1970,
                                       STEAMCLOUD_WINDOWS, error, sizeof error);
            steamcloud_disconnect();
            if (!ok) { printf("upload failed: %s\n", error); return 1; }
            printf("uploaded %zu bytes as \"%s\"\n  sha1 %s\n", (size_t)save.length, cloud_name, sha1_hex(save).UTF8String);
            return 0;
        }
        if (!strcmp(command, "sync") && argc > 2) {
            steamcloud_choice choice = argc > 3 && !strcmp(argv[3], "keep-local") ? STEAMCLOUD_KEEP_LOCAL
                                     : argc > 3 && !strcmp(argv[3], "keep-cloud") ? STEAMCLOUD_KEEP_CLOUD : STEAMCLOUD_ASK;
            if (!steamcloud_connect(error, sizeof error)) { printf("could not connect: %s\n", error); return 1; }
            steamcloud_conflict conflict = { 0 };
            steamcloud_sync_result result = steamcloud_sync(ANIMAL_WELL, cloud_name, argv[2], STEAMCLOUD_WINDOWS, choice, &conflict, error, sizeof error);
            steamcloud_disconnect();
            switch (result) {
                case STEAMCLOUD_SYNC_FAILED: printf("sync failed: %s\n", error); return 1;
                case STEAMCLOUD_IN_SYNC:     printf("in sync: nothing to do\n"); return 0;
                case STEAMCLOUD_DOWNLOADED:  printf("downloaded: the local file now is the cloud's\n"); return 0;
                case STEAMCLOUD_UPLOADED:    printf("uploaded: the cloud file now is the local one\n"); return 0;
                case STEAMCLOUD_CONFLICT: {
                    char local_date[32], cloud_date[32];
                    time_t local_time = (time_t)conflict.local_time, cloud_time = (time_t)conflict.cloud_time;
                    strftime(local_date, sizeof local_date, "%Y-%m-%d %H:%M:%S", localtime(&local_time));
                    strftime(cloud_date, sizeof cloud_date, "%Y-%m-%d %H:%M:%S", localtime(&cloud_time));
                    printf("conflict: both sides changed. Nothing was touched.\n  local file changed %s\n  cloud file changed %s\n"
                           "  run again with keep-local or keep-cloud\n", local_date, cloud_date);
                    return 3;
                }
            }
        }
        if (!strcmp(command, "same") && argc > 2) {
            if (!steamcloud_connect(error, sizeof error)) { printf("could not connect: %s\n", error); return 1; }
            int same = steamcloud_remember_if_same(ANIMAL_WELL, cloud_name, argv[2], error, sizeof error);
            steamcloud_disconnect();
            printf(same ? "the same: remembered\n" : "not the same (or one side is missing): nothing remembered %s\n", error);
            return 0;
        }
        if (!strcmp(command, "delete")) {
            if (!name_given) { printf("say which file: delete --name <cloud name>\n"); return 2; }
            if (!steamcloud_connect(error, sizeof error)) { printf("could not connect: %s\n", error); return 1; }
            int ok = steamcloud_delete(ANIMAL_WELL, cloud_name, error, sizeof error);
            steamcloud_disconnect();
            printf("delete of \"%s\": %s\n", cloud_name, ok ? "ok" : error);
            return !ok;
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
        printf("usage: steamcloud_tool signin [--qr-png <file>] | signin-password | status | list | download <file> | upload <file> |\n                             sync <file> [keep-local|keep-cloud] | same <file> | delete --name <cloud name> |\n                             upload-test |\n                             zip <file> <zip> | unzip <zip> <file> | signout\n");
        return 2;
    }
}
