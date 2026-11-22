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
 *   ./steamcloud_tool signout                    forget the saved login
 */
#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#include "steamcloud.h"

#define ANIMAL_WELL 813230

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
        printf("usage: steamcloud_tool signin [--qr-png <file>] | status | list | signout\n");
        return 2;
    }
}
