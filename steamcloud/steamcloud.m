/* steamcloud.m - Steam Cloud without the Steam app.
 *
 * The Steam app keeps a game's saves in the Steam Cloud, but on a Mac it refuses the save of a Windows-only
 * game. This file talks to Steam's servers directly instead, the way the Steam app itself does:
 *
 *   1. Sign in (once). Plain HTTPS requests to Steam's public sign-in service: we ask for a QR sign-in, the user
 *      scans the code with the Steam mobile app and approves, and Steam hands out a "refresh token" - a login
 *      for the account that is valid for about 7 months. It is kept in the macOS Keychain. The user's password
 *      is never involved.
 *   2. Connect. Steam's servers ("connection managers") accept a WebSocket connection. Every message on it is
 *        4 bytes   message number, with the highest bit set ("the header is a protobuf")
 *        4 bytes   length of the header
 *        header    a CMsgProtoBufHeader: who sends it, which request it belongs to
 *        body      the message itself
 *      All messages are "protobuf" encoded - a simple format of numbered fields, written and read here by hand
 *      (the pb_* functions) because only a dozen messages are needed.
 *      After connecting we say hello, log on with the refresh token, and then send a heartbeat now and then.
 *   3. Cloud calls. A request is sent as message 151 with the call's name in the header ("Cloud.Something#1")
 *      and a request number; the answer comes back as message 147 carrying the same number.
 *
 * The field numbers of all messages are those of the open-source SteamKit project (Resources/Protobufs).
 * Valve does not document this protocol; it can change.
 */
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#include <mach-o/dyld.h>
#include <unistd.h>
#include <zlib.h>
#include "steamcloud.h"

/* message numbers (Steam calls them EMsg) */
enum {
    MSG_MULTI = 1,                  /* several messages packed into one, usually gzip-compressed */
    MSG_JOB_FAILED = 113,           /* "the request you sent could not be delivered" */
    MSG_SERVICE_RESPONSE = 147,     /* the answer to a call */
    MSG_SERVICE_CALL = 151,         /* a call, e.g. Cloud.EnumerateUserFiles#1 */
    MSG_HEARTBEAT = 703,
    MSG_LOG_OFF = 706,
    MSG_LOGON_RESPONSE = 751,
    MSG_LOGGED_OFF = 757,           /* Steam ended the session */
    MSG_LOGON = 5514,
    MSG_SERVICE_CALL_NO_LOGON = 9804,   /* the same, before logging on: only Steam's sign-in service takes these */
    MSG_HELLO = 9805,
};
#define PROTOBUF_FLAG     0x80000000u
#define PROTOCOL_VERSION  65580                     /* what current Steam clients send */
#define LOGON_STEAMID     0x0110000100000000ull     /* "an individual's account on the public Steam, desktop client" - the account itself comes from the token */
#define OS_TYPE_MAC       ((uint32_t)-102)          /* Steam's number for "macOS, version unknown" */
#define ERESULT_OK        1

static void set_error(char *error, size_t size, NSString *text) {
    if (error && size) snprintf(error, size, "%s", text.UTF8String);
}

/* ---------------------------------------------------------------------------------------- protobuf, by hand
 * A message is a row of fields. Each starts with a "tag": (field number << 3) | kind, where kind is
 *   0  a number, 7 bits per byte, lowest first, the top bit of a byte says "more follows" (a "varint")
 *   1  8 bytes (a 64-bit number)
 *   2  a length (varint) followed by that many bytes: a text, raw bytes or a message inside the message
 *   5  4 bytes (a 32-bit number)
 * Fields that are left out have their default value. */
static void pb_raw_varint(NSMutableData *out, uint64_t value) {
    do {
        uint8_t byte = value & 0x7f;
        value >>= 7;
        if (value) byte |= 0x80;
        [out appendBytes:&byte length:1];
    } while (value);
}
static void pb_number(NSMutableData *out, int field, uint64_t value) {
    pb_raw_varint(out, (uint64_t)field << 3);
    pb_raw_varint(out, value);
}
static void pb_fixed64(NSMutableData *out, int field, uint64_t value) {
    pb_raw_varint(out, (uint64_t)field << 3 | 1);
    [out appendBytes:&value length:8];          /* low byte first - true for both Intel and Apple processors */
}
static void pb_bytes(NSMutableData *out, int field, NSData *value) {
    pb_raw_varint(out, (uint64_t)field << 3 | 2);
    pb_raw_varint(out, value.length);
    [out appendData:value];
}
static void pb_string(NSMutableData *out, int field, NSString *value) {
    pb_bytes(out, field, [value dataUsingEncoding:NSUTF8StringEncoding]);
}

/* Reading: pb_next steps to the next field and returns NO at the end (or at damaged data). */
typedef struct {
    const uint8_t *at, *end;
    int field, kind;
    uint64_t number;            /* kinds 0, 1, 5 */
    const uint8_t *bytes;       /* kind 2 */
    size_t length;
} pb_reader;
static pb_reader pb_read(NSData *data) {
    pb_reader r = { .at = data.bytes, .end = (const uint8_t *)data.bytes + data.length };
    return r;
}
static BOOL pb_get_varint(pb_reader *r, uint64_t *value) {
    *value = 0;
    for (int shift = 0; shift < 64 && r->at < r->end; shift += 7) {
        uint8_t byte = *r->at++;
        *value |= (uint64_t)(byte & 0x7f) << shift;
        if (!(byte & 0x80)) return YES;
    }
    return NO;
}
static BOOL pb_next(pb_reader *r) {
    uint64_t tag;
    if (r->at >= r->end || !pb_get_varint(r, &tag)) return NO;
    r->field = (int)(tag >> 3);
    r->kind = tag & 7;
    r->number = 0;
    r->bytes = NULL;
    r->length = 0;
    switch (r->kind) {
        case 0: return pb_get_varint(r, &r->number);
        case 1: if (r->end - r->at < 8) return NO; memcpy(&r->number, r->at, 8); r->at += 8; return YES;
        case 5: if (r->end - r->at < 4) return NO; memcpy(&r->number, r->at, 4); r->at += 4; return YES;
        case 2: {
            uint64_t length;
            if (!pb_get_varint(r, &length) || length > (uint64_t)(r->end - r->at)) return NO;
            r->bytes = r->at;
            r->length = (size_t)length;
            r->at += length;
            return YES;
        }
    }
    return NO;
}
static NSData *pb_data(pb_reader *r) { return [NSData dataWithBytes:r->bytes length:r->length]; }
static NSString *pb_text(pb_reader *r) {
    return [[NSString alloc] initWithBytes:r->bytes length:r->length encoding:NSUTF8StringEncoding] ?: @"";
}

/* ---------------------------------------------------------------------------------------- the saved login
 * One Keychain entry: "<account name>\n<refresh token>".
 *
 * macOS lets the program that made a Keychain entry read it without asking. For any other program - and that
 * includes every new build of this one, because the app has no developer signature - it shows a dialog that
 * wants the Mac password. Nobody should have to see that dialog. So every build keeps its login in an entry of
 * its own (named after the build), reads only that one, and removes the entries of other builds where macOS
 * lets it do so silently. After an update the user signs in again instead. */

/* A name for this build: a fingerprint of the program file itself. It changes exactly when the program does -
 * which is also when macOS starts treating it as a different program.
 * (An earlier version asked the system for the identifier of "the first loaded program part". In the app, which
 * runs as an Intel program through Rosetta, that turned out not to be the app: every build got the same name.) */
static NSString *build_name(void) {
    char path[4096];
    uint32_t size = sizeof path;
    NSData *program = _NSGetExecutablePath(path, &size) == 0 ? [NSData dataWithContentsOfFile:@(path)] : nil;
    if (!program.length) return @"unknown";
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(program.bytes, (CC_LONG)program.length, digest);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < 16; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}
static NSString *keychain_service(void) { return @"local.animalwellloader.steam"; }
static NSDictionary *keychain_query(void) {
    static NSString *account;
    if (!account) {
        account = [@"login-" stringByAppendingString:build_name()];
        if (getenv("STEAMCLOUD_VERBOSE")) fprintf(stderr, "keychain: this build's entry is \"%s\"\n", account.UTF8String);
    }
    return @{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService: keychain_service(),
              (__bridge id)kSecAttrAccount: account };
}

/* Run Keychain calls with macOS's dialogs switched off for this program: a call that would need one fails
 * instead. (We only touch our own entry, which never needs one - this is the safety net.) */
static void without_keychain_dialogs(void (^calls)(void)) {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"       /* old calls, but the only ones that do this */
    Boolean allowed = true;
    SecKeychainGetUserInteractionAllowed(&allowed);
    SecKeychainSetUserInteractionAllowed(false);
    calls();
    SecKeychainSetUserInteractionAllowed(allowed);
    #pragma clang diagnostic pop
}

/* Remove the logins that other builds of this program left behind - those macOS lets go without asking. */
static void remove_other_builds_logins(void) {
    NSString *mine = keychain_query()[(__bridge id)kSecAttrAccount];
    without_keychain_dialogs(^{
        CFTypeRef found = NULL;
        NSDictionary *all = @{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                               (__bridge id)kSecAttrService: keychain_service(),
                               (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
                               (__bridge id)kSecReturnAttributes: @YES };       /* names only, not the secrets */
        if (SecItemCopyMatching((__bridge CFDictionaryRef)all, &found) != errSecSuccess || !found) return;
        for (NSDictionary *entry in (__bridge_transfer NSArray *)found) {
            NSString *account = entry[(__bridge id)kSecAttrAccount];
            if (![account isKindOfClass:[NSString class]] || [account isEqualToString:mine]) continue;
            /* The modern call (SecItemDelete) refuses another program's entry unless the user confirms in a
             * dialog. The older call pair below removes it without one: finding an entry without asking for its
             * secret needs no permission, and neither does deleting it. */
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            const char *service = keychain_service().UTF8String, *name = account.UTF8String;
            SecKeychainItemRef entry_ref = NULL;
            if (SecKeychainFindGenericPassword(NULL, (UInt32)strlen(service), service, (UInt32)strlen(name), name,
                                               NULL, NULL, &entry_ref) == errSecSuccess && entry_ref) {
                SecKeychainItemDelete(entry_ref);
                CFRelease(entry_ref);
            }
            #pragma clang diagnostic pop
        }
    });
}

/* macOS's own words for a Keychain result number */
static NSString *keychain_problem(OSStatus status) {
    NSString *text = (__bridge_transfer NSString *)SecCopyErrorMessageString(status, NULL);
    return [NSString stringWithFormat:@"%@ (%d)", text ?: @"Keychain error", (int)status];
}
static BOOL load_login(NSString **account, NSString **token);

/* nil = saved (replacing this build's earlier login, if there is one). */
static NSString *save_login(NSString *account, NSString *token) {
    NSData *value = [[NSString stringWithFormat:@"%@\n%@", account, token] dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *item = [keychain_query() mutableCopy];
    item[(__bridge id)kSecAttrLabel] = @"Animal Well Loader - Steam login";
    item[(__bridge id)kSecValueData] = value;
    __block OSStatus status;
    without_keychain_dialogs(^{
        status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
        if (status == errSecDuplicateItem)
            status = SecItemUpdate((__bridge CFDictionaryRef)keychain_query(),
                                   (__bridge CFDictionaryRef)@{ (__bridge id)kSecValueData: value });
    });
    if (status != errSecSuccess) return keychain_problem(status);
    remove_other_builds_logins();
    /* make sure it really is there for us: a login that was "saved" but cannot be read back is no login */
    NSString *saved_token;
    if (!load_login(NULL, &saved_token) || ![saved_token isEqualToString:token]) return @"the Keychain did not give the saved login back";
    return nil;
}
static BOOL load_login(NSString **account, NSString **token) {
    NSMutableDictionary *query = [keychain_query() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    __block CFTypeRef found = NULL;
    __block OSStatus status;
    without_keychain_dialogs(^{ status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &found); });
    if (status != errSecSuccess || !found) return NO;
    NSString *text = [[NSString alloc] initWithData:(__bridge_transfer NSData *)found encoding:NSUTF8StringEncoding];
    NSRange split = [text rangeOfString:@"\n"];
    if (split.location == NSNotFound) return NO;
    if (account) *account = [text substringToIndex:split.location];
    if (token) *token = [text substringFromIndex:split.location + 1];
    return YES;
}

/* Every sign-in adds an entry to the account's list of devices (Steam Guard). So that the list does not grow
 * with each new sign-in, the next sign-in tells Steam which login it replaces. For that the saved login's number
 * is remembered - not in the Keychain (a new build cannot read the old build's entry there) but in the loader's
 * settings: the number alone is of no use to anyone. It is learned at the first logon with a login (Steam says
 * which login a request came from) and forgotten once a new sign-in has replaced that login. */
#define SETTINGS CFSTR("local.animalwellloader")
static uint64_t remembered_login_number(void) {
    NSString *text = (__bridge_transfer NSString *)CFPreferencesCopyAppValue(CFSTR("SteamLoginNumber"), SETTINGS);
    return [text isKindOfClass:[NSString class]] ? strtoull(text.UTF8String, NULL, 10) : 0;
}
static void remember_login_number(uint64_t number) {            /* 0 = forget it */
    CFPreferencesSetAppValue(CFSTR("SteamLoginNumber"),
                             number ? (__bridge CFStringRef)[NSString stringWithFormat:@"%llu", number] : NULL, SETTINGS);
    CFPreferencesAppSynchronize(SETTINGS);
}

int steamcloud_signed_in(char *account_name, size_t size) {
    NSString *account;
    if (!load_login(&account, NULL)) return 0;
    if (account_name && size) snprintf(account_name, size, "%s", account.UTF8String);
    return 1;
}

int steamcloud_other_build_login(void) {
    NSString *mine = keychain_query()[(__bridge id)kSecAttrAccount];
    __block int others = 0;
    without_keychain_dialogs(^{
        CFTypeRef found = NULL;
        NSDictionary *all = @{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                               (__bridge id)kSecAttrService: keychain_service(),
                               (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
                               (__bridge id)kSecReturnAttributes: @YES };       /* names only: needs no permission */
        if (SecItemCopyMatching((__bridge CFDictionaryRef)all, &found) != errSecSuccess || !found) return;
        for (NSDictionary *entry in (__bridge_transfer NSArray *)found) {
            NSString *account = entry[(__bridge id)kSecAttrAccount];
            if ([account isKindOfClass:[NSString class]] && ![account isEqualToString:mine]) others++;
        }
    });
    return others > 0;
}

void steamcloud_sign_out(void) {
    without_keychain_dialogs(^{ SecItemDelete((__bridge CFDictionaryRef)keychain_query()); });
    remove_other_builds_logins();
}

/* ---------------------------------------------------------------------------------------- 1. signing in */

/* One HTTPS request, waited for. Returns the body; *status receives the HTTP status (0 = no answer at all) and
 * *eresult Steam's own result number from the "x-eresult" header (1 = fine). */
static NSData *http_request(NSURLRequest *request, NSInteger *status, int *eresult) {
    __block NSData *body = nil;
    __block NSInteger code = 0;
    __block int result = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && [response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            code = http.statusCode;
            result = [[http valueForHTTPHeaderField:@"x-eresult"] intValue];
            body = data;
        }
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_SEC));
    if (status) *status = code;
    if (eresult) *eresult = result;
    return body;
}

/* A call to Steam's sign-in service: the request message goes up base64-encoded in a form field, the answer
 * comes back as a plain protobuf message. nil = it failed (*problem says how). */
static NSData *auth_call(NSString *method, NSData *message, NSString **problem) {
    NSString *address = [NSString stringWithFormat:@"https://api.steampowered.com/IAuthenticationService/%@/v1/", method];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
    request.HTTPMethod = @"POST";
    NSCharacterSet *plain = [NSCharacterSet alphanumericCharacterSet];
    NSString *encoded = [[message base64EncodedStringWithOptions:0] stringByAddingPercentEncodingWithAllowedCharacters:plain];
    request.HTTPBody = [[@"input_protobuf_encoded=" stringByAppendingString:encoded] dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    NSInteger status;
    int eresult;
    NSData *answer = http_request(request, &status, &eresult);
    if (status == 200 && eresult == ERESULT_OK) return answer ?: [NSData data];
    if (problem) *problem = status == 0 ? @"no answer from Steam (no network?)"
                                        : [NSString stringWithFormat:@"Steam answered %@ with HTTP %ld, result %d", method, (long)status, eresult];
    return nil;
}

static volatile int sign_in_cancelled;
void steamcloud_cancel_sign_in(void) { sign_in_cancelled = 1; }

int steamcloud_sign_in(steamcloud_qr_fn show_qr, void *context, int timeout_seconds, char *error, size_t error_size) {
    @autoreleasepool {
        sign_in_cancelled = 0;
        /* "I want to sign in by QR code, as a Steam client on a Mac" */
        NSString *device = @"Animal Well Loader (Mac)";
        NSMutableData *details = [NSMutableData data];
        pb_string(details, 1, device);                  /* device_friendly_name */
        pb_number(details, 2, 1);                       /* platform_type: 1 = Steam client */
        pb_number(details, 3, (uint64_t)(int64_t)-102); /* os_type: macOS */
        pb_number(details, 4, 1);                       /* gaming_device_type: 1 = desktop computer */
        NSMutableData *begin = [NSMutableData data];
        pb_string(begin, 1, device);
        pb_number(begin, 2, 1);
        pb_bytes(begin, 3, details);
        NSString *problem;
        NSData *answer = auth_call(@"BeginAuthSessionViaQR", begin, &problem);
        if (!answer) { set_error(error, error_size, problem); return 0; }

        uint64_t client_id = 0;
        NSData *request_id = nil;
        NSString *address = nil;
        float interval = 5;
        pb_reader r = pb_read(answer);
        while (pb_next(&r)) {
            if (r.field == 1) client_id = r.number;
            else if (r.field == 2) address = pb_text(&r);
            else if (r.field == 3) request_id = pb_data(&r);
            else if (r.field == 4) { uint32_t bits = (uint32_t)r.number; memcpy(&interval, &bits, 4); }
        }
        if (!address.length || !request_id) { set_error(error, error_size, @"Steam's answer had no QR address"); return 0; }
        show_qr(address.UTF8String, context);

        /* ask "approved yet?" until it is, or the time is up */
        uint64_t replaces = remembered_login_number();      /* the login this sign-in takes the place of, if we know one */
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout_seconds];
        while ([deadline timeIntervalSinceNow] > 0) {
            for (int quarter = 0; quarter < (int)(MAX(1.0f, MIN(interval, 5.0f)) * 4); quarter++) {
                if (sign_in_cancelled) { set_error(error, error_size, @"the sign-in was cancelled"); return 0; }
                usleep(250000);
            }
            NSMutableData *poll = [NSMutableData data];
            pb_number(poll, 1, client_id);
            pb_bytes(poll, 2, request_id);
            if (replaces) pb_fixed64(poll, 3, replaces);    /* token_to_revoke: "cancel that login when you issue the new one" */
            answer = auth_call(@"PollAuthSessionStatus", poll, &problem);
            if (!answer && replaces) { replaces = 0; continue; }       /* in case Steam does not like the number: go on without it */
            if (!answer) { set_error(error, error_size, problem); return 0; }
            NSString *refresh_token = nil, *account = nil;
            r = pb_read(answer);
            while (pb_next(&r)) {
                if (r.field == 1) client_id = r.number;                                 /* the code was replaced */
                else if (r.field == 2) show_qr(pb_text(&r).UTF8String, context);        /* ... by this one */
                else if (r.field == 3) refresh_token = pb_text(&r);
                else if (r.field == 6) account = pb_text(&r);
            }
            if (refresh_token.length) {
                NSString *not_saved = save_login(account ?: @"", refresh_token);
                if (not_saved) {
                    set_error(error, error_size, [@"signed in, but the login could not be saved in the Keychain: " stringByAppendingString:not_saved]);
                    return 0;
                }
                remember_login_number(0);                   /* the old login is replaced; the new one's number is learned at its first logon */
                return 1;
            }
        }
        set_error(error, error_size, @"the sign-in was not approved in time");
        return 0;
    }
}

/* ---------------------------------------------------------------------------------------- 2. the connection */

static NSData *machine_id(void);

/* A request that waits for its answer */
@interface SteamJob : NSObject
@property dispatch_semaphore_t done;
@property int eresult;              /* Steam's result number, 1 = fine */
@property NSData *body;             /* the answer message */
@property NSString *problem;
@end
@implementation SteamJob
- (instancetype)init {
    if ((self = [super init])) { _done = dispatch_semaphore_create(0); _eresult = 2; }
    return self;
}
- (BOOL)wait:(int)seconds {
    return dispatch_semaphore_wait(_done, dispatch_time(DISPATCH_TIME_NOW, seconds * NSEC_PER_SEC)) == 0;
}
@end

@interface SteamConnection : NSObject <NSURLSessionWebSocketDelegate>
@property int lastResult;           /* Steam's result number of the last call (1 = fine, 0 = no answer) */
@end
@implementation SteamConnection {
    NSURLSession *_session;
    NSURLSessionWebSocketTask *_socket;
    SteamJob *_opened;                  /* done when the WebSocket is open (or failed to open) */
    SteamJob *_logon;                   /* done when the answer to the logon arrived */
    NSMutableDictionary<NSNumber *, SteamJob *> *_calls;    /* request number -> the waiting call */
    uint64_t _next_call;
    uint64_t _steamid;                  /* from the logon answer on: who we are ... */
    int32_t _session_id;                /* ... and which session; both go into every later header */
    dispatch_source_t _heartbeat;
    BOOL _logged_on;
}

- (instancetype)init {
    if ((self = [super init])) {
        _calls = [NSMutableDictionary dictionary];
        _steamid = LOGON_STEAMID;
        NSOperationQueue *queue = [[NSOperationQueue alloc] init];      /* incoming messages are handled on it, one at a time */
        queue.maxConcurrentOperationCount = 1;
        _session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]
                                                 delegate:self
                                            delegateQueue:queue];
    }
    return self;
}

- (BOOL)open:(NSString *)server {
    _opened = [SteamJob new];
    _socket = [_session webSocketTaskWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"wss://%@/cmsocket/", server]]];
    _socket.maximumMessageSize = 32 << 20;
    [_socket resume];
    [self receive];
    return [_opened wait:6] && _opened.eresult == ERESULT_OK;
}
- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task didOpenWithProtocol:(NSString *)protocol {
    _opened.eresult = ERESULT_OK;
    dispatch_semaphore_signal(_opened.done);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [self lost:error ? error.localizedDescription : @"the connection was closed"];
}

/* The connection is gone: wake everything that still waits. */
- (void)lost:(NSString *)why {
    NSMutableArray<SteamJob *> *waiting = [NSMutableArray array];
    @synchronized (self) {
        [waiting addObjectsFromArray:_calls.allValues];
        [_calls removeAllObjects];
    }
    if (_opened) [waiting addObject:_opened];
    if (_logon) [waiting addObject:_logon];
    for (SteamJob *job in waiting) {
        if (!job.problem) job.problem = why;
        dispatch_semaphore_signal(job.done);
    }
}

- (void)receive {
    __weak SteamConnection *weak = self;
    [_socket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        SteamConnection *me = weak;
        if (!me) return;
        if (error) { [me lost:error.localizedDescription]; return; }
        if (message.type == NSURLSessionWebSocketMessageTypeData) [me packet:message.data];
        [me receive];
    }];
}

/* Send one message. `call_name` and `call_number` are only set for cloud calls. */
- (void)send:(uint32_t)number body:(NSData *)body callName:(NSString *)call_name callNumber:(uint64_t)call_number {
    NSMutableData *header = [NSMutableData data];
    pb_fixed64(header, 1, _steamid);
    pb_number(header, 2, (uint64_t)(int64_t)_session_id);
    if (call_name) {
        pb_fixed64(header, 10, call_number);            /* jobid_source: the answer will carry it back */
        pb_string(header, 12, call_name);               /* target_job_name */
    }
    NSMutableData *packet = [NSMutableData data];
    uint32_t words[2] = { number | PROTOBUF_FLAG, (uint32_t)header.length };
    [packet appendBytes:words length:8];
    [packet appendData:header];
    if (body) [packet appendData:body];
    [_socket sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithData:packet]
       completionHandler:^(NSError *error) { (void)error; }];       /* a failed send shows up as a lost connection */
}

/* One incoming message */
- (void)packet:(NSData *)packet {
    if (packet.length < 8) return;
    uint32_t words[2];
    memcpy(words, packet.bytes, 8);
    if (!(words[0] & PROTOBUF_FLAG) || packet.length < 8 + (size_t)words[1]) return;    /* an old-style message: none we need */
    uint32_t number = words[0] & ~PROTOBUF_FLAG;
    NSData *header = [packet subdataWithRange:NSMakeRange(8, words[1])];
    NSData *body = [packet subdataWithRange:NSMakeRange(8 + words[1], packet.length - 8 - words[1])];

    uint64_t steamid = 0, call_number = ~0ull;
    int32_t session_id = 0;
    int eresult = 2;                    /* the default if the header does not say */
    NSString *message = nil;
    pb_reader r = pb_read(header);
    while (pb_next(&r)) {
        if (r.field == 1) steamid = r.number;
        else if (r.field == 2) session_id = (int32_t)r.number;
        else if (r.field == 11) call_number = r.number;         /* jobid_target */
        else if (r.field == 13) eresult = (int)r.number;
        else if (r.field == 14) message = pb_text(&r);
    }

    switch (number) {
        case MSG_MULTI:
            [self multi:body];
            break;
        case MSG_LOGON_RESPONSE: {
            int result = 2, heartbeat_seconds = 0;
            r = pb_read(body);
            while (pb_next(&r)) {
                if (r.field == 1) result = (int)r.number;
                else if (r.field == 2 && !heartbeat_seconds) heartbeat_seconds = (int)r.number;
                else if (r.field == 3) heartbeat_seconds = (int)r.number;
            }
            if (result == ERESULT_OK) {
                _logged_on = YES;
                _steamid = steamid;
                _session_id = session_id;
                [self startHeartbeat:heartbeat_seconds > 0 ? heartbeat_seconds : 9];
            }
            _logon.eresult = result;
            if (_logon) dispatch_semaphore_signal(_logon.done);
            break;
        }
        case MSG_SERVICE_RESPONSE:
        case MSG_JOB_FAILED: {
            SteamJob *call;
            @synchronized (self) {
                call = _calls[@(call_number)];
                [_calls removeObjectForKey:@(call_number)];
            }
            if (!call) break;
            call.eresult = number == MSG_SERVICE_RESPONSE ? eresult : 2;
            call.body = body;
            call.problem = number == MSG_JOB_FAILED ? @"Steam could not deliver the request" : message;
            dispatch_semaphore_signal(call.done);
            break;
        }
        case MSG_LOGGED_OFF:
            [self lost:@"Steam ended the session"];
            break;
    }
}

/* Message 1: several messages in one. { 1: size when unpacked (0 = not compressed), 2: the packed bytes }.
 * Unpacked it is a row of [4 bytes length][message]. */
- (void)multi:(NSData *)body {
    uint32_t unpacked_size = 0;
    NSData *payload = nil;
    pb_reader r = pb_read(body);
    while (pb_next(&r)) {
        if (r.field == 1) unpacked_size = (uint32_t)r.number;
        else if (r.field == 2) payload = pb_data(&r);
    }
    if (!payload) return;
    if (unpacked_size) {
        NSMutableData *plain = [NSMutableData dataWithLength:unpacked_size];
        z_stream z = { .next_in = (Bytef *)payload.bytes, .avail_in = (uInt)payload.length,
                       .next_out = plain.mutableBytes, .avail_out = unpacked_size };
        if (inflateInit2(&z, 16 + MAX_WBITS) != Z_OK) return;       /* 16 + ...: the data has a gzip header */
        int result = inflate(&z, Z_FINISH);
        inflateEnd(&z);
        if (result != Z_STREAM_END) return;
        payload = plain;
    }
    const uint8_t *at = payload.bytes, *end = at + payload.length;
    while (end - at >= 4) {
        uint32_t length;
        memcpy(&length, at, 4);
        at += 4;
        if (length > (size_t)(end - at)) break;
        [self packet:[NSData dataWithBytes:at length:length]];
        at += length;
    }
}

/* Steam drops a client it does not hear from: send an (empty) heartbeat at the pace Steam asked for. */
- (void)startHeartbeat:(int)seconds {
    _heartbeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(_heartbeat, dispatch_time(DISPATCH_TIME_NOW, seconds * NSEC_PER_SEC), seconds * NSEC_PER_SEC, NSEC_PER_SEC);
    __weak SteamConnection *weak = self;
    dispatch_source_set_event_handler(_heartbeat, ^{
        [weak send:MSG_HEARTBEAT body:nil callName:nil callNumber:0];
    });
    dispatch_resume(_heartbeat);
}

/* The first message on a new connection. */
- (void)hello {
    NSMutableData *hello = [NSMutableData data];
    pb_number(hello, 1, PROTOCOL_VERSION);
    [self send:MSG_HELLO body:hello callName:nil callNumber:0];
}
- (uint64_t)steamid { return _steamid; }
- (int)logonResult { return _logon ? _logon.eresult : 2; }     /* Steam's result number of the last logon, 1 = fine */

/* Say hello and log on with the saved login. */
- (BOOL)logOnAs:(NSString *)account token:(NSString *)token problem:(NSString **)problem {
    [self hello];

    NSMutableData *logon = [NSMutableData data];
    pb_number(logon, 1, PROTOCOL_VERSION);
    pb_number(logon, 5, 1771);                  /* client_package_version: what SteamKit sends */
    pb_string(logon, 6, @"english");            /* client_language */
    pb_number(logon, 7, OS_TYPE_MAC);           /* client_os_type */
    pb_number(logon, 8, 1);                     /* should_remember_password: "keep this login valid after the session
                                                   ends". Without it Steam cancels the refresh token once we log off. */
    pb_bytes(logon, 30, machine_id());
    if (account.length) pb_string(logon, 50, account);      /* account_name */
    pb_number(logon, 82, 9);                    /* eresult_sentryfile: 9 = "no such file", an old login scheme we do not use */
    pb_string(logon, 96, @"Mac");               /* machine_name */
    pb_number(logon, 102, 1);                   /* supports_rate_limit_response */
    pb_string(logon, 108, token);               /* access_token: the refresh token goes here */
    _logon = [SteamJob new];
    [self send:MSG_LOGON body:logon callName:nil callNumber:0];
    if (![_logon wait:20]) { *problem = @"Steam did not answer the logon"; return NO; }
    if (_logon.eresult != ERESULT_OK) {
        *problem = _logon.problem ?: [NSString stringWithFormat:@"Steam refused the logon (result %d%@)", _logon.eresult,
                    _logon.eresult == 5 || _logon.eresult == 15 ? @": the saved login is no longer valid, sign in again" :
                    _logon.eresult == 84 ? @": too many attempts, try again later" : @""];
        return NO;
    }
    return YES;
}

/* A call: send the request, wait for the answer. nil = it failed (*problem says how, and the property
 * lastResult has Steam's result number). */
- (NSData *)call:(NSString *)name request:(NSData *)request problem:(NSString **)problem {
    SteamJob *call = [SteamJob new];
    uint64_t number;
    @synchronized (self) {
        number = ++_next_call;
        _calls[@(number)] = call;
    }
    [self send:_logged_on ? MSG_SERVICE_CALL : MSG_SERVICE_CALL_NO_LOGON body:request callName:name callNumber:number];
    if (![call wait:40]) {
        @synchronized (self) { [_calls removeObjectForKey:@(number)]; }
        *problem = [NSString stringWithFormat:@"Steam did not answer %@", name];
        _lastResult = 0;
        return nil;
    }
    _lastResult = call.eresult;
    if (call.eresult != ERESULT_OK) {
        *problem = call.problem.length ? [NSString stringWithFormat:@"%@: %@ (result %d)", name, call.problem, call.eresult]
                                       : [NSString stringWithFormat:@"%@ failed (result %d)", name, call.eresult];
        return nil;
    }
    return call.body ?: [NSData data];
}

- (void)close {
    if (_heartbeat) dispatch_source_cancel(_heartbeat);
    _heartbeat = nil;
    if (_logged_on) {
        [self send:MSG_LOG_OFF body:nil callName:nil callNumber:0];
        usleep(300000);                         /* let the goodbye go out */
    }
    [_socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    [_session invalidateAndCancel];
}

/* Steam wants three ids of the machine with a logon (it only compares them between logons). We send three
 * fingerprints of this Mac's hardware id, in the small binary key-value format Steam uses for it. */
static NSData *machine_id(void) {
    uuid_t host = { 0 };
    struct timespec no_wait = { 0, 0 };
    gethostuuid(host, &no_wait);
    NSMutableData *out = [NSMutableData data];
    [out appendBytes:"\0MessageObject" length:15];      /* 0, name, 0: "a group starts" */
    for (NSString *key in @[ @"BB3", @"FF2", @"3B3" ]) {
        NSMutableData *source = [NSMutableData dataWithBytes:host length:sizeof host];
        [source appendData:[key dataUsingEncoding:NSUTF8StringEncoding]];
        unsigned char digest[CC_SHA1_DIGEST_LENGTH];
        CC_SHA1(source.bytes, (CC_LONG)source.length, digest);
        NSMutableString *hex = [NSMutableString string];
        for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
        [out appendBytes:"\1" length:1];                /* 1: "a text value follows" */
        [out appendData:[key dataUsingEncoding:NSUTF8StringEncoding]];
        [out appendBytes:"\0" length:1];
        [out appendData:[hex dataUsingEncoding:NSUTF8StringEncoding]];
        [out appendBytes:"\0" length:1];
    }
    [out appendBytes:"\10\10" length:2];                /* 8: "the group ends", twice */
    return out;
}
@end

static SteamConnection *connection;

/* Steam's public directory lists the servers to connect to, best first. */
static NSArray<NSString *> *connection_servers(void) {
    NSURL *address = [NSURL URLWithString:@"https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/?cellid=0&cmtype=websockets&format=json"];
    NSInteger status;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:address];
    request.timeoutInterval = 8;                /* without network this must not hold the program up for long */
    NSData *answer = http_request(request, &status, NULL);
    NSMutableArray<NSString *> *servers = [NSMutableArray array];
    if (status != 200 || !answer) return servers;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:answer options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return servers;
    for (NSDictionary *server in json[@"response"][@"serverlist"])
        if ([server[@"type"] isEqual:@"websockets"] && [server[@"endpoint"] isKindOfClass:[NSString class]])
            [servers addObject:server[@"endpoint"]];
    return servers;
}

/* How long a login (a "JWT": three base64 parts separated by dots, the middle one a JSON text) is still valid,
 * in seconds. 0 if that cannot be read. */
static NSTimeInterval login_seconds_left(NSString *token) {
    NSArray<NSString *> *parts = [token componentsSeparatedByString:@"."];
    if (parts.count < 2) return 0;
    NSString *base64 = [[parts[1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
                                  stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (base64.length % 4) base64 = [base64 stringByAppendingString:@"="];
    NSData *json = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    NSDictionary *claims = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    if (![claims isKindOfClass:[NSDictionary class]] || ![claims[@"exp"] isKindOfClass:[NSNumber class]]) return 0;
    return [claims[@"exp"] doubleValue] - [NSDate date].timeIntervalSince1970;
}

/* A login lasts about 7 months. In its last 30 days, ask Steam for a fresh one (as the Steam app does), so that
 * someone who keeps playing never has to sign in again. Steam decides whether it hands one out.
 * For testing: STEAMCLOUD_RENEW_NOW=1 asks at every connect, STEAMCLOUD_VERBOSE=1 prints what happened. */
static void renew_login_if_due(SteamConnection *steam, NSString *account, NSString *token) {
    BOOL verbose = getenv("STEAMCLOUD_VERBOSE") != NULL, now = getenv("STEAMCLOUD_RENEW_NOW") != NULL;
    NSTimeInterval left = login_seconds_left(token);
    if (verbose) fprintf(stderr, "login: valid for %.0f more days\n", left / 86400);
    if (!now && (left <= 0 || left > 30 * 86400)) return;
    NSMutableData *request = [NSMutableData data];
    pb_string(request, 1, token);                       /* refresh_token */
    pb_fixed64(request, 2, steam.steamid);
    pb_number(request, 3, 1);                           /* renewal_type: 1 = "give me a new refresh token if it is time" */
    NSString *problem;
    NSData *answer = [steam call:@"Authentication.GenerateAccessTokenForApp#1" request:request problem:&problem];
    NSString *fresh = nil;
    if (answer) {
        pb_reader r = pb_read(answer);
        while (pb_next(&r)) if (r.field == 2) fresh = pb_text(&r);
    }
    BOOL saved = fresh.length && ![fresh isEqualToString:token] && !save_login(account, fresh);
    if (saved) remember_login_number(0);                /* a new login: its number is learned at the next logon */
    if (verbose) fprintf(stderr, "login renewal: %s\n", !answer ? problem.UTF8String :
                         saved ? "Steam issued a new login; it is saved" : "Steam answered, without a new login (not due yet)");
}

/* Learn the number of the login we are logged on with (see remembered_login_number): Steam's list of the
 * account's logins says which one the request came from. With STEAMCLOUD_VERBOSE=1 it also prints how many
 * logins of this program the account has - for testing that a new sign-in replaces the old one. */
static void learn_login_number(SteamConnection *steam) {
    BOOL verbose = getenv("STEAMCLOUD_VERBOSE") != NULL;
    if (remembered_login_number() && !verbose) return;
    NSString *problem;
    NSData *answer = [steam call:@"Authentication.EnumerateTokens#1" request:[NSData data] problem:&problem];
    if (!answer) { if (verbose) fprintf(stderr, "logins: could not list them - %s\n", problem.UTF8String); return; }
    uint64_t this_one = 0;
    int all = 0, ours = 0;
    pb_reader r = pb_read(answer);
    while (pb_next(&r)) {
        if (r.field == 2) this_one = r.number;          /* requesting_token */
        if (r.field != 1) continue;                     /* 1: one login { 2: its description, ... } */
        all++;
        pb_reader t = pb_read(pb_data(&r));
        while (pb_next(&t)) if (t.field == 2 && [pb_text(&t) isEqualToString:@"Animal Well Loader (Mac)"]) ours++;
    }
    if (this_one) remember_login_number(this_one);
    if (verbose) fprintf(stderr, "logins: the account has %d, of which %d are \"Animal Well Loader (Mac)\"%s\n", all, ours,
                         this_one ? "" : "; Steam did not say which one this is");
}

static int login_rejected;              /* see steamcloud_login_rejected */
int steamcloud_login_rejected(void) { return login_rejected; }

int steamcloud_connect(char *error, size_t error_size) {
    @autoreleasepool {
        if (connection) return 1;
        login_rejected = 0;
        NSString *account, *token;
        if (!load_login(&account, &token)) { set_error(error, error_size, @"not signed in"); return 0; }
        NSArray<NSString *> *servers = connection_servers();
        if (!servers.count) { set_error(error, error_size, @"could not get Steam's server list (no network?)"); return 0; }
        NSString *problem = @"no server accepted the connection";
        for (NSUInteger i = 0; i < servers.count && i < 3; i++) {
            SteamConnection *attempt = [SteamConnection new];
            if (![attempt open:servers[i]]) { [attempt close]; continue; }
            if ([attempt logOnAs:account token:token problem:&problem]) {
                connection = attempt;
                learn_login_number(attempt);
                renew_login_if_due(attempt, account, token);
                return 1;
            }
            /* 5 = "invalid password", 15 = "access denied" */
            login_rejected = attempt.logonResult == 5 || attempt.logonResult == 15;
            [attempt close];
            break;                              /* the server answered: another one would say the same */
        }
        set_error(error, error_size, problem);
        return 0;
    }
}

void steamcloud_disconnect(void) {
    [connection close];
    connection = nil;
}

/* ---------------------------------------------------------------------------------------- 3. cloud calls */

int steamcloud_list(uint32_t appid, steamcloud_file *files, int max_files, char *error, size_t error_size) {
    @autoreleasepool {
        if (!connection) { set_error(error, error_size, @"not connected"); return -1; }
        NSMutableData *request = [NSMutableData data];
        pb_number(request, 1, appid);
        pb_number(request, 2, 1);               /* extended_details: checksum and platforms too */
        pb_number(request, 3, 500);             /* count: at most this many */
        NSString *problem;
        NSData *answer = [connection call:@"Cloud.EnumerateUserFiles#1" request:request problem:&problem];
        if (!answer) { set_error(error, error_size, problem); return -1; }

        int count = 0;
        pb_reader r = pb_read(answer);
        while (pb_next(&r)) {
            if (r.field != 1) continue;                 /* 1: one file (a message inside the message) */
            if (count < max_files) {
                steamcloud_file *file = &files[count];
                memset(file, 0, sizeof *file);
                NSMutableArray<NSString *> *platforms = [NSMutableArray array];
                pb_reader f = pb_read(pb_data(&r));
                while (pb_next(&f)) {
                    if (f.field == 3) snprintf(file->name, sizeof file->name, "%s", pb_text(&f).UTF8String);
                    else if (f.field == 4) file->time = f.number;
                    else if (f.field == 5) file->size = (uint32_t)f.number;
                    else if (f.field == 9) [platforms addObject:pb_text(&f)];
                    else if (f.field == 10) snprintf(file->sha1, sizeof file->sha1, "%s", pb_text(&f).lowercaseString.UTF8String);
                }
                snprintf(file->platforms, sizeof file->platforms, "%s", [platforms componentsJoinedByString:@","].UTF8String);
            }
            count++;
        }
        return count;
    }
}

/* Steam stores most cloud files packed, as an ordinary zip archive with one file in it. This takes that one
 * file out. A zip archive ends with a "directory" that says where each file starts and how it is packed, so we
 * read from the end: end record -> directory entry -> the file's own header -> its data.
 * (Not static only so that steamcloud_tool.m can test it.) */
NSData *steamcloud_unzip(NSData *zip, NSString **problem) {
    const uint8_t *bytes = zip.bytes;
    size_t length = zip.length;
    #define U16(at) ((uint32_t)bytes[at] | (uint32_t)bytes[(at) + 1] << 8)
    #define U32(at) (U16(at) | U16((at) + 2) << 16)
    *problem = @"the downloaded file is not a zip archive";
    if (length < 22) return nil;
    size_t end = length - 22;                           /* the end record: 22 bytes, plus maybe a comment after it */
    while (U32(end) != 0x06054b50) {
        if (end == 0 || length - end > 22 + 65535) return nil;
        end--;
    }
    size_t entry = U32(end + 16);                       /* where the directory starts = its first entry */
    if (entry + 46 > length || U32(entry) != 0x02014b50) return nil;
    uint32_t method = U16(entry + 10), packed_size = U32(entry + 20), plain_size = U32(entry + 24);
    size_t header = U32(entry + 42);                    /* where the file's own header is */
    if (header + 30 > length || U32(header) != 0x04034b50) return nil;
    size_t data = header + 30 + U16(header + 26) + U16(header + 28);       /* after its name and extra field */
    if (getenv("STEAMCLOUD_VERBOSE"))
        fprintf(stderr, "zip: entry \"%.*s\", method %u, flags 0x%x, made by version %u, %u -> %u bytes, %u entr%s\n",
                (int)U16(header + 26), (const char *)bytes + header + 30, method, U16(header + 6), U16(entry + 4),
                packed_size, plain_size, U16(end + 10), U16(end + 10) == 1 ? "y" : "ies");
    if (data > length || packed_size > length - data) return nil;
    #undef U16
    #undef U32

    if (method == 0) return [zip subdataWithRange:NSMakeRange(data, packed_size)];      /* stored as it is */
    *problem = @"the downloaded zip archive uses a packing method this program does not know";
    if (method != 8) return nil;                        /* 8 = "deflate", what everyone uses */
    NSMutableData *plain = [NSMutableData dataWithLength:plain_size];
    z_stream z = { .next_in = (Bytef *)bytes + data, .avail_in = packed_size,
                   .next_out = plain.mutableBytes, .avail_out = plain_size };
    *problem = @"the downloaded zip archive is damaged";
    if (inflateInit2(&z, -MAX_WBITS) != Z_OK) return nil;       /* negative: bare deflate data, no header */
    int result = inflate(&z, Z_FINISH);
    inflateEnd(&z);
    if (result != Z_STREAM_END || z.total_out != plain_size) return nil;
    *problem = nil;
    return plain;
}

uint8_t *steamcloud_download(uint32_t appid, const char *name, size_t *size, char *error, size_t error_size) {
    @autoreleasepool {
        if (!connection) { set_error(error, error_size, @"not connected"); return NULL; }
        /* 1. ask Steam where the file is. The answer is not the file but a one-time web address for it. */
        NSMutableData *request = [NSMutableData data];
        pb_number(request, 1, appid);
        pb_string(request, 2, @(name));
        NSString *problem;
        NSData *answer = [connection call:@"Cloud.ClientFileDownload#1" request:request problem:&problem];
        if (!answer) { set_error(error, error_size, problem); return NULL; }

        uint32_t stored_size = 0, plain_size = 0;
        BOOL https = NO, encrypted = NO;
        NSString *host = nil, *path = nil;
        NSData *sha1 = nil;
        NSMutableArray<NSArray<NSString *> *> *headers = [NSMutableArray array];
        pb_reader r = pb_read(answer);
        while (pb_next(&r)) {
            if (r.field == 2) stored_size = (uint32_t)r.number;         /* file_size: as stored, maybe packed */
            else if (r.field == 3) plain_size = (uint32_t)r.number;     /* raw_file_size: unpacked */
            else if (r.field == 4) sha1 = pb_data(&r);                  /* sha_file: of the unpacked contents */
            else if (r.field == 7) host = pb_text(&r);
            else if (r.field == 8) path = pb_text(&r);
            else if (r.field == 9) https = r.number != 0;
            else if (r.field == 11) encrypted = r.number != 0;
            else if (r.field == 10) {                                   /* a header to send along: { 1: name, 2: value } */
                NSString *header_name = @"", *value = @"";
                pb_reader h = pb_read(pb_data(&r));
                while (pb_next(&h)) {
                    if (h.field == 1) header_name = pb_text(&h);
                    else if (h.field == 2) value = pb_text(&h);
                }
                [headers addObject:@[ header_name, value ]];
            }
        }
        if (!host.length || !path.length) { set_error(error, error_size, @"Steam gave no download address"); return NULL; }
        if (encrypted) { set_error(error, error_size, @"the cloud file is encrypted, which this program cannot read"); return NULL; }

        /* 2. fetch it */
        NSString *address = [NSString stringWithFormat:@"%@://%@%@", https ? @"https" : @"http", host, path];
        NSMutableURLRequest *fetch = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
        for (NSArray<NSString *> *header in headers) [fetch setValue:header[1] forHTTPHeaderField:header[0]];
        NSInteger status;
        NSData *contents = http_request(fetch, &status, NULL);
        if (status != 200 || !contents) {
            set_error(error, error_size, [NSString stringWithFormat:@"the download failed (HTTP %ld)", (long)status]);
            return NULL;
        }

        /* 3. unpack it if Steam stored it packed, then check that it is what Steam says it is */
        if (getenv("STEAMCLOUD_VERBOSE"))
            fprintf(stderr, "download: %u bytes as stored, %u bytes unpacked, got %lu bytes%s\n", stored_size, plain_size,
                    (unsigned long)contents.length, stored_size != plain_size ? " (zipped)" : " (not zipped)");
        if (stored_size != plain_size) {
            contents = steamcloud_unzip(contents, &problem);
            if (!contents) { set_error(error, error_size, problem); return NULL; }
        }
        unsigned char digest[CC_SHA1_DIGEST_LENGTH];
        CC_SHA1(contents.bytes, (CC_LONG)contents.length, digest);
        if (contents.length != plain_size || (sha1.length == sizeof digest && memcmp(sha1.bytes, digest, sizeof digest))) {
            set_error(error, error_size, @"the downloaded file does not match Steam's size or checksum");
            return NULL;
        }
        uint8_t *out = malloc(contents.length ? contents.length : 1);
        memcpy(out, contents.bytes, contents.length);
        *size = contents.length;
        return out;
    }
}

/* ---------------------------------------------------------------------------------------- uploading */

/* Pack `plain` the way Steam does for the cloud: a zip archive with one file in it, named "z".
 * Layout: the file's header, its packed data, the directory (one entry), the end record.
 * (Not static only so that steamcloud_tool.m can test it.) */
NSData *steamcloud_zip(NSData *plain) {
    NSMutableData *packed = [NSMutableData dataWithLength:compressBound((uLong)plain.length)];
    z_stream z = { .next_in = (Bytef *)plain.bytes, .avail_in = (uInt)plain.length,
                   .next_out = packed.mutableBytes, .avail_out = (uInt)packed.length };
    if (deflateInit2(&z, Z_BEST_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK) return nil;
    int result = deflate(&z, Z_FINISH);                 /* negative window bits: bare deflate data, as zip wants it */
    deflateEnd(&z);
    if (result != Z_STREAM_END) return nil;
    packed.length = z.total_out;

    uint32_t checksum = (uint32_t)crc32(0, plain.bytes, (uInt)plain.length);
    uint32_t packed_size = (uint32_t)packed.length, plain_size = (uint32_t)plain.length;
    NSMutableData *zip = [NSMutableData data];
    void (^u16)(uint16_t) = ^(uint16_t v) { [zip appendBytes:&v length:2]; };
    void (^u32)(uint32_t) = ^(uint32_t v) { [zip appendBytes:&v length:4]; };
    /* the part that the file's header and its directory entry have in common */
    void (^common)(void) = ^{
        u16(20);                        /* version needed to unpack: 2.0 */
        u16(0);                         /* flags: none */
        u16(8);                         /* method: deflate */
        u16(0); u16(0x21);              /* time 0:00, date 1 January 1980 (the format's earliest) */
        u32(checksum); u32(packed_size); u32(plain_size);
        u16(1);                         /* length of the name */
        u16(0);                         /* length of the extra field */
    };
    u32(0x04034b50); common();                          /* the file's header ... */
    [zip appendBytes:"z" length:1];                     /* ... its name ... */
    [zip appendData:packed];                            /* ... its data */
    uint32_t directory = (uint32_t)zip.length;
    u32(0x02014b50); u16(20); common();                 /* the directory entry (made by version 2.0) */
    u16(0); u16(0); u16(0);                             /* no comment, disk 0, no internal attributes */
    u32(0);                                             /* no external attributes */
    u32(0);                                             /* the file's header is at the very start */
    [zip appendBytes:"z" length:1];
    uint32_t directory_size = (uint32_t)zip.length - directory;
    u32(0x06054b50); u16(0); u16(0); u16(1); u16(1);    /* the end record: one disk, one entry */
    u32(directory_size); u32(directory); u16(0);
    return zip;
}

/* Steam wants changes to cloud files wrapped in a "batch": begin, the changes, complete. */
static uint64_t begin_batch(uint32_t appid, NSString *upload, NSString *delete, NSString **problem) {
    NSMutableData *request = [NSMutableData data];
    pb_number(request, 1, appid);
    pb_string(request, 2, @"Mac");                      /* machine_name */
    if (upload) pb_string(request, 3, upload);          /* files_to_upload */
    if (delete) pb_string(request, 4, delete);          /* files_to_delete */
    uint64_t client_id;
    arc4random_buf(&client_id, sizeof client_id);
    pb_number(request, 5, client_id >> 1);              /* client_id: any number of our own */
    NSData *answer = [connection call:@"Cloud.BeginAppUploadBatch#1" request:request problem:problem];
    if (!answer) return 0;
    uint64_t batch = 0;
    pb_reader r = pb_read(answer);
    while (pb_next(&r)) if (r.field == 1) batch = r.number;
    if (!batch) *problem = @"Steam gave no batch number";
    return batch;
}
static void complete_batch(uint32_t appid, uint64_t batch, BOOL ok) {
    NSMutableData *request = [NSMutableData data];
    pb_number(request, 1, appid);
    pb_number(request, 2, batch);
    pb_number(request, 3, ok ? ERESULT_OK : 2);         /* batch_eresult: 1 = it all worked, 2 = it failed */
    NSString *ignored;
    [connection call:@"Cloud.CompleteAppUploadBatchBlocking#1" request:request problem:&ignored];
}

int steamcloud_upload(uint32_t appid, const char *name, const uint8_t *contents, size_t size, uint64_t time,
                      uint32_t platforms, char *error, size_t error_size) {
    @autoreleasepool {
        if (!connection) { set_error(error, error_size, @"not connected"); return 0; }
        NSData *plain = [NSData dataWithBytes:contents length:size];
        unsigned char digest[CC_SHA1_DIGEST_LENGTH];
        CC_SHA1(plain.bytes, (CC_LONG)plain.length, digest);
        NSData *sha1 = [NSData dataWithBytes:digest length:sizeof digest];      /* always of the unpacked contents */
        NSData *stored = steamcloud_zip(plain);
        if (!stored || stored.length >= plain.length) stored = plain;           /* packing did not help: send it as it is */

        NSString *problem;
        uint64_t batch = begin_batch(appid, @(name), nil, &problem);
        if (!batch) { set_error(error, error_size, problem); return 0; }

        /* 1. announce the file. Steam answers with where to send the bytes (one or more "blocks"). */
        NSMutableData *request = [NSMutableData data];
        pb_number(request, 1, appid);
        pb_number(request, 2, stored.length);           /* file_size: as stored */
        pb_number(request, 3, plain.length);            /* raw_file_size: unpacked - differs when it is zipped */
        pb_bytes(request, 4, sha1);                     /* file_sha */
        pb_number(request, 5, time);                    /* time_stamp */
        pb_string(request, 6, @(name));
        pb_number(request, 7, platforms);               /* platforms_to_sync */
        pb_number(request, 13, batch);                  /* upload_batch_id */
        NSData *answer = [connection call:@"Cloud.ClientBeginFileUpload#1" request:request problem:&problem];
        if (!answer) { complete_batch(appid, batch, NO); set_error(error, error_size, problem); return 0; }

        /* 2. send the bytes */
        BOOL sent = YES;
        pb_reader r = pb_read(answer);
        while (sent && pb_next(&r)) {
            if (r.field == 1 && r.number) { problem = @"Steam wants the file encrypted, which this program cannot do"; sent = NO; }
            if (r.field != 2) continue;                 /* 2: one block */
            NSString *host = nil, *path = nil;
            BOOL https = NO;
            int method = 4;
            uint64_t offset = 0, length = 0;
            NSData *explicit_body = nil;
            NSMutableURLRequest *put = [[NSMutableURLRequest alloc] init];
            pb_reader b = pb_read(pb_data(&r));
            while (pb_next(&b)) {
                if (b.field == 1) host = pb_text(&b);
                else if (b.field == 2) path = pb_text(&b);
                else if (b.field == 3) https = b.number != 0;
                else if (b.field == 4) method = (int)b.number;
                else if (b.field == 6) offset = b.number;
                else if (b.field == 7) length = b.number;
                else if (b.field == 8) explicit_body = pb_data(&b);     /* "send exactly these bytes instead" */
                else if (b.field == 5) {                                /* a header to send along: { 1: name, 2: value } */
                    NSString *header_name = @"", *value = @"";
                    pb_reader h = pb_read(pb_data(&b));
                    while (pb_next(&h)) {
                        if (h.field == 1) header_name = pb_text(&h);
                        else if (h.field == 2) value = pb_text(&h);
                    }
                    [put setValue:value forHTTPHeaderField:header_name];
                }
            }
            if (!host.length || offset + length > stored.length) { problem = @"Steam's upload instructions make no sense"; sent = NO; break; }
            put.URL = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@%@", https ? @"https" : @"http", host, path ?: @""]];
            put.HTTPMethod = method == 1 ? @"GET" : method == 3 ? @"POST" : @"PUT";    /* Steam's numbers; uploads use PUT (4) */
            put.HTTPBody = explicit_body.length ? explicit_body : [stored subdataWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)length)];
            NSInteger status;
            http_request(put, &status, NULL);
            if (status < 200 || status > 299) {
                problem = [NSString stringWithFormat:@"sending the file failed (HTTP %ld)", (long)status];
                sent = NO;
            }
        }

        /* 3. tell Steam how it went. Only now does the new file replace the old one. */
        request = [NSMutableData data];
        pb_number(request, 1, sent);                    /* transfer_succeeded */
        pb_number(request, 2, appid);
        pb_bytes(request, 3, sha1);
        pb_string(request, 4, @(name));
        NSString *commit_problem;
        answer = [connection call:@"Cloud.ClientCommitFileUpload#1" request:request problem:&commit_problem];
        BOOL committed = NO;
        if (answer) {
            r = pb_read(answer);
            while (pb_next(&r)) if (r.field == 1) committed = r.number != 0;
        }
        BOOL ok = sent && committed;
        complete_batch(appid, batch, ok);
        if (!ok) set_error(error, error_size, !sent ? problem : commit_problem ?: @"Steam did not accept the uploaded file");
        return ok;
    }
}

int steamcloud_delete(uint32_t appid, const char *name, char *error, size_t error_size) {
    @autoreleasepool {
        if (!connection) { set_error(error, error_size, @"not connected"); return 0; }
        NSString *problem;
        uint64_t batch = begin_batch(appid, nil, @(name), &problem);
        if (!batch) { set_error(error, error_size, problem); return 0; }
        NSMutableData *request = [NSMutableData data];
        pb_number(request, 1, appid);
        pb_string(request, 2, @(name));
        pb_number(request, 4, batch);                   /* upload_batch_id */
        BOOL ok = [connection call:@"Cloud.ClientDeleteFile#1" request:request problem:&problem] != nil;
        complete_batch(appid, batch, ok);
        if (!ok) set_error(error, error_size, problem);
        return ok;
    }
}

/* ---------------------------------------------------------------------------------------- syncing */

static NSString *sha1_hex(NSData *data) {
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

/* What the cloud has under `cloud_name`: its checksum (nil if there is no such file) and when it was changed.
 * The listing has both, so nothing needs downloading just to compare. NO = the listing failed. */
static BOOL cloud_file(uint32_t appid, const char *cloud_name, NSString **sha1, uint64_t *time, char *error, size_t error_size) {
    enum { MAX_FILES = 512 };
    steamcloud_file *files = calloc(MAX_FILES, sizeof *files);
    int count = steamcloud_list(appid, files, MAX_FILES, error, error_size);
    *sha1 = nil;
    *time = 0;
    for (int i = 0; i < count && i < MAX_FILES; i++)
        if (!strcmp(files[i].name, cloud_name)) { *sha1 = @(files[i].sha1); *time = files[i].time; }
    free(files);
    return count >= 0;
}

steamcloud_sync_result steamcloud_sync(uint32_t appid, const char *cloud_name, const char *local_file, uint32_t platforms,
                                       steamcloud_choice choice, steamcloud_conflict *conflict,
                                       char *error, size_t error_size) {
    @autoreleasepool {
        if (!connection) { set_error(error, error_size, @"not connected"); return STEAMCLOUD_SYNC_FAILED; }
        NSFileManager *disk = [NSFileManager defaultManager];
        NSString *path = @(local_file);
        NSString *memory_path = [path stringByAppendingString:@".cloudsync"];   /* the checksum both sides had after the last sync */

        /* the local side */
        NSData *local = [NSData dataWithContentsOfFile:path];
        NSString *local_sha = local ? sha1_hex(local) : nil;
        NSDate *local_changed = [disk attributesOfItemAtPath:path error:nil].fileModificationDate;
        NSString *remembered = [[NSString stringWithContentsOfFile:memory_path encoding:NSUTF8StringEncoding error:nil]
                                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (remembered.length != 40) remembered = nil;

        /* the cloud side */
        NSString *cloud_sha = nil;
        uint64_t cloud_time = 0;
        if (!cloud_file(appid, cloud_name, &cloud_sha, &cloud_time, error, error_size)) return STEAMCLOUD_SYNC_FAILED;

        /* which way? */
        BOOL upload = NO, download = NO, was_conflict = NO;
        if (!local && !cloud_sha) return STEAMCLOUD_IN_SYNC;            /* no file on either side: nothing to sync yet */
        else if (!cloud_sha) upload = YES;
        else if (!local) download = YES;
        else if ([local_sha isEqualToString:cloud_sha]) {
            [local_sha writeToFile:memory_path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return STEAMCLOUD_IN_SYNC;
        }
        else if ([local_sha isEqualToString:remembered]) download = YES;       /* only the cloud changed */
        else if ([cloud_sha isEqualToString:remembered]) upload = YES;         /* only the local file changed */
        else {
            was_conflict = YES;
            if (choice == STEAMCLOUD_ASK) {
                if (conflict) {
                    conflict->local_time = (uint64_t)local_changed.timeIntervalSince1970;
                    conflict->cloud_time = cloud_time;
                }
                return STEAMCLOUD_CONFLICT;
            }
            upload = choice == STEAMCLOUD_KEEP_LOCAL;
            download = !upload;
        }

        if (download || was_conflict) {                 /* in a conflict the cloud's version is fetched either way: to use it or to keep it */
            size_t size = 0;
            uint8_t *bytes = steamcloud_download(appid, cloud_name, &size, error, error_size);
            if (!bytes) return STEAMCLOUD_SYNC_FAILED;
            NSData *cloud = [NSData dataWithBytesNoCopy:bytes length:size freeWhenDone:YES];
            if (upload) {                               /* the local file wins: keep what the cloud had */
                if (![cloud writeToFile:[path stringByAppendingString:@".cloud-version"] atomically:YES]) {
                    set_error(error, error_size, @"could not keep a copy of the cloud's version; nothing was uploaded");
                    return STEAMCLOUD_SYNC_FAILED;
                }
            } else {
                if (local) {                            /* keep what is about to be replaced */
                    NSString *kept = [path stringByAppendingString:@".before-download"];
                    [disk removeItemAtPath:kept error:nil];
                    if (![disk copyItemAtPath:path toPath:kept error:nil]) {
                        set_error(error, error_size, @"could not keep a copy of the local file; nothing was replaced");
                        return STEAMCLOUD_SYNC_FAILED;
                    }
                }
                if (![cloud writeToFile:path atomically:YES]) {
                    set_error(error, error_size, @"could not write the downloaded file");
                    return STEAMCLOUD_SYNC_FAILED;
                }
                /* give it the time it was changed, not the time of the download */
                [disk setAttributes:@{ NSFileModificationDate: [NSDate dateWithTimeIntervalSince1970:cloud_time] } ofItemAtPath:path error:nil];
                [sha1_hex(cloud) writeToFile:memory_path atomically:YES encoding:NSUTF8StringEncoding error:nil];
                return STEAMCLOUD_DOWNLOADED;
            }
        }
        if (!steamcloud_upload(appid, cloud_name, local.bytes, local.length, (uint64_t)local_changed.timeIntervalSince1970,
                               platforms, error, error_size))
            return STEAMCLOUD_SYNC_FAILED;
        [local_sha writeToFile:memory_path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return STEAMCLOUD_UPLOADED;
    }
}

int steamcloud_remember_if_same(uint32_t appid, const char *cloud_name, const char *local_file,
                                char *error, size_t error_size) {
    @autoreleasepool {
        if (!connection) { set_error(error, error_size, @"not connected"); return 0; }
        NSString *path = @(local_file);
        NSData *local = [NSData dataWithContentsOfFile:path];
        NSString *cloud_sha;
        uint64_t cloud_time;
        if (!local || !cloud_file(appid, cloud_name, &cloud_sha, &cloud_time, error, error_size)) return 0;
        NSString *local_sha = sha1_hex(local);
        if (![local_sha isEqualToString:cloud_sha]) return 0;
        [local_sha writeToFile:[path stringByAppendingString:@".cloudsync"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return 1;
    }
}

/* ---------------------------------------------------------------------------------------- signing in with a password
 * For people without the Steam mobile app. The steps, all as calls over a connection that is not logged on:
 *   1. ask Steam for its public key for this account
 *   2. send the account name and the password, encrypted with that key (only Steam can read it)
 *   3. if the account has Steam Guard: pass on the code the user got by email or reads from the mobile app,
 *      or wait until they approved in the app
 *   4. ask for the result: the same refresh token a QR sign-in gives. The password is not kept anywhere. */

static NSData *hex_bytes(NSString *hex) {
    NSMutableData *bytes = [NSMutableData data];
    if (hex.length % 2) hex = [@"0" stringByAppendingString:hex];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        unsigned value = 0;
        [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&value];
        uint8_t byte = (uint8_t)value;
        [bytes appendBytes:&byte length:1];
    }
    return bytes;
}

/* Steam gives its key as two big numbers (hex). macOS wants them as a "DER" structure:
 *   30 <length> { 02 <length> <modulus>  02 <length> <exponent> }       (30 = a sequence, 02 = a whole number) */
static void der_length(NSMutableData *out, NSUInteger length) {
    uint8_t bytes[3] = { 0x82, (uint8_t)(length >> 8), (uint8_t)length };
    if (length < 128) [out appendBytes:&bytes[2] length:1];
    else [out appendBytes:bytes length:3];
}
static NSData *der_number(NSData *big) {
    const uint8_t *bytes = big.bytes;
    NSUInteger skip = 0;
    while (skip + 1 < big.length && bytes[skip] == 0) skip++;           /* no leading zeros ... */
    NSMutableData *out = [NSMutableData dataWithBytes:"\2" length:1];
    /* ... except one if the top bit is set (else it would mean "negative"). "!= 0" matters: in an Intel program
     * a BOOL is a small signed number, and 0x80 put into one is -128, not 1 - which then spoiled the length below. */
    BOOL pad = (bytes[skip] & 0x80) != 0;
    der_length(out, big.length - skip + pad);
    if (pad) [out appendBytes:"\0" length:1];
    [out appendBytes:bytes + skip length:big.length - skip];
    return out;
}
/* -> the text, RSA-encrypted with Steam's key, as base64. nil if macOS cannot do it.
 * (Not static only so that steamcloud_tool.m can test it.) */
NSString *steamcloud_encrypt(NSString *text, NSString *modulus_hex, NSString *exponent_hex) {
    NSMutableData *numbers = [NSMutableData dataWithData:der_number(hex_bytes(modulus_hex))];
    [numbers appendData:der_number(hex_bytes(exponent_hex))];
    NSMutableData *der = [NSMutableData dataWithBytes:"\x30" length:1];
    der_length(der, numbers.length);
    [der appendData:numbers];
    NSDictionary *kind = @{ (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
                            (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic };
    SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)der, (__bridge CFDictionaryRef)kind, NULL);
    if (!key) return nil;
    NSData *encrypted = (__bridge_transfer NSData *)SecKeyCreateEncryptedData(key, kSecKeyAlgorithmRSAEncryptionPKCS1,
                            (__bridge CFDataRef)[text dataUsingEncoding:NSUTF8StringEncoding], NULL);
    CFRelease(key);
    return [encrypted base64EncodedStringWithOptions:0];
}

int steamcloud_sign_in_password(const char *account_name, const char *password, steamcloud_confirm_fn confirm, void *context,
                                int timeout_seconds, char *error, size_t error_size) {
    @autoreleasepool {
        sign_in_cancelled = 0;
        /* a connection of its own, not logged on */
        SteamConnection *steam = nil;
        NSArray<NSString *> *servers = connection_servers();
        for (NSUInteger i = 0; i < servers.count && i < 3 && !steam; i++) {
            SteamConnection *attempt = [SteamConnection new];
            if ([attempt open:servers[i]]) steam = attempt;
            else [attempt close];
        }
        if (!steam) { set_error(error, error_size, @"could not connect to Steam (no network?)"); return 0; }
        [steam hello];
        int signed_in = 0;
        NSString *problem = nil;
        do {                                            /* one pass; "break" = give up with `problem` */
            /* 1. Steam's key for this account */
            NSMutableData *request = [NSMutableData data];
            pb_string(request, 1, @(account_name));
            NSData *answer = [steam call:@"Authentication.GetPasswordRSAPublicKey#1" request:request problem:&problem];
            if (!answer) break;
            NSString *modulus = nil, *exponent = nil;
            uint64_t key_time = 0;
            pb_reader r = pb_read(answer);
            while (pb_next(&r)) {
                if (r.field == 1) modulus = pb_text(&r);
                else if (r.field == 2) exponent = pb_text(&r);
                else if (r.field == 3) key_time = r.number;
            }
            NSString *encrypted = modulus.length && exponent.length ? steamcloud_encrypt(@(password), modulus, exponent) : nil;
            if (!encrypted) { problem = @"could not encrypt the password for Steam"; break; }

            /* 2. account name + encrypted password */
            NSString *device = @"Animal Well Loader (Mac)";
            NSMutableData *details = [NSMutableData data];
            pb_string(details, 1, device);
            pb_number(details, 2, 1);                       /* platform_type: 1 = Steam client */
            pb_number(details, 3, (uint64_t)(int64_t)-102); /* os_type: macOS */
            pb_number(details, 4, 1);                       /* gaming_device_type: 1 = desktop computer */
            request = [NSMutableData data];
            pb_string(request, 1, device);
            pb_string(request, 2, @(account_name));
            pb_string(request, 3, encrypted);
            pb_number(request, 4, key_time);                /* encryption_timestamp: which key it was encrypted with */
            pb_number(request, 5, 1);                       /* remember_login */
            pb_number(request, 6, 1);                       /* platform_type */
            pb_number(request, 7, 1);                       /* persistence: 1 = a login that lasts */
            pb_string(request, 8, @"Client");               /* website_id: what the Steam client says */
            pb_bytes(request, 9, details);
            answer = [steam call:@"Authentication.BeginAuthSessionViaCredentials#1" request:request problem:&problem];
            if (!answer) {
                if (steam.lastResult == 5) problem = @"Steam says the account name or the password is wrong";
                else if (steam.lastResult == 84) problem = @"too many sign-in attempts - Steam asks you to wait a while";
                break;
            }
            uint64_t client_id = 0, steamid = 0;
            NSData *request_id = nil;
            float interval = 5;
            int kind = 0, kind_rank = 0;                    /* the way of confirming we take, of those Steam offers */
            NSString *hint = @"";
            r = pb_read(answer);
            while (pb_next(&r)) {
                if (r.field == 1) client_id = r.number;
                else if (r.field == 2) request_id = pb_data(&r);
                else if (r.field == 3) { uint32_t bits = (uint32_t)r.number; memcpy(&interval, &bits, 4); }
                else if (r.field == 5) steamid = r.number;
                else if (r.field == 4) {                    /* allowed_confirmations: { 1: kind, 2: a hint such as the email's domain } */
                    int offered = 0;
                    NSString *message = @"";
                    pb_reader c = pb_read(pb_data(&r));
                    while (pb_next(&c)) {
                        if (c.field == 1) offered = (int)c.number;
                        else if (c.field == 2) message = pb_text(&c);
                    }
                    /* Steam usually offers several at once - for an account with the mobile app both "type the app's
                     * code" and "approve in the app", and it sends the approval request to the phone either way. Take
                     * the one that asks least of the user: approving in the app, then a code from the app, then a code
                     * by email, then a link by email; "none" (1) only if it is all there is. */
                    static const int rank[6] = { 0, 1, 3, 4, 5, 2 };
                    if (offered >= 1 && offered <= 5 && rank[offered] > kind_rank) { kind = offered; kind_rank = rank[offered]; hint = message; }
                }
            }
            if (!request_id) { problem = @"Steam's answer made no sense"; break; }

            /* 3. Steam Guard. kind 1 = the account has none: nothing to do. */
            BOOL stop = NO;
            if (kind == STEAMCLOUD_APPROVE_IN_APP || kind == STEAMCLOUD_APPROVE_BY_EMAIL) {
                if (!confirm(kind, hint.UTF8String, NULL, 0, context)) stop = YES;
            } else if (kind == STEAMCLOUD_CODE_FROM_EMAIL || kind == STEAMCLOUD_CODE_FROM_APP) {
                for (int attempt = 0; ; attempt++) {
                    char code[64] = "";
                    if (!confirm(kind, attempt ? "That code was not right." : hint.UTF8String, code, sizeof code, context)) { stop = YES; break; }
                    request = [NSMutableData data];
                    pb_number(request, 1, client_id);
                    pb_fixed64(request, 2, steamid);
                    pb_string(request, 3, [@(code) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
                    pb_number(request, 4, kind);            /* code_type */
                    if ([steam call:@"Authentication.UpdateAuthSessionWithSteamGuardCode#1" request:request problem:&problem]) break;
                    BOOL wrong_code = steam.lastResult == 65 || steam.lastResult == 88;      /* Steam's numbers for "that code is wrong" */
                    if (!wrong_code || attempt == 2) { if (wrong_code) problem = @"the Steam Guard code was wrong three times"; stop = YES; break; }
                }
            } else if (kind != 1) {
                problem = @"this account uses a way of confirming a sign-in that this program does not know";
                stop = YES;
            }
            if (stop) { if (!problem) problem = @"the sign-in was cancelled"; break; }

            /* 4. the result */
            uint64_t replaces = remembered_login_number();  /* the login this sign-in takes the place of, if we know one */
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout_seconds];
            problem = @"the sign-in was not confirmed in time";
            while (!signed_in && [deadline timeIntervalSinceNow] > 0) {
                request = [NSMutableData data];
                pb_number(request, 1, client_id);
                pb_bytes(request, 2, request_id);
                if (replaces) pb_fixed64(request, 3, replaces);     /* token_to_revoke */
                NSString *poll_problem;
                answer = [steam call:@"Authentication.PollAuthSessionStatus#1" request:request problem:&poll_problem];
                if (!answer && replaces) { replaces = 0; continue; }       /* in case Steam does not like the number: go on without it */
                if (!answer) { problem = poll_problem; break; }
                NSString *refresh_token = nil, *account = nil;
                r = pb_read(answer);
                while (pb_next(&r)) {
                    if (r.field == 1) client_id = r.number;
                    else if (r.field == 3) refresh_token = pb_text(&r);
                    else if (r.field == 6) account = pb_text(&r);
                }
                if (refresh_token.length) {
                    NSString *not_saved = save_login(account.length ? account : @(account_name), refresh_token);
                    if (not_saved) problem = [@"signed in, but the login could not be saved in the Keychain: " stringByAppendingString:not_saved];
                    else { signed_in = 1; remember_login_number(0); }
                    break;
                }
                BOOL cancelled = NO;
                for (int quarter = 0; quarter < (int)(MAX(1.0f, MIN(interval, 5.0f)) * 4) && !cancelled; quarter++) {
                    cancelled = sign_in_cancelled != 0;
                    usleep(250000);
                }
                if (cancelled) { problem = @"the sign-in was cancelled"; break; }
            }
        } while (0);
        [steam close];
        if (!signed_in) set_error(error, error_size, problem ?: @"the sign-in failed");
        return signed_in;
    }
}

/* A test of the first step of the password sign-in: fetch Steam's key for an account name and encrypt a dummy
 * text with it. No password is involved and nothing is signed in. (Only for steamcloud_tool.m.) */
int steamcloud_key_test(const char *account_name) {
    @autoreleasepool {
        SteamConnection *steam = nil;
        NSArray<NSString *> *servers = connection_servers();
        for (NSUInteger i = 0; i < servers.count && i < 3 && !steam; i++) {
            SteamConnection *attempt = [SteamConnection new];
            if ([attempt open:servers[i]]) steam = attempt;
            else [attempt close];
        }
        if (!steam) { printf("could not connect\n"); return 0; }
        [steam hello];
        NSMutableData *request = [NSMutableData data];
        pb_string(request, 1, @(account_name));
        NSString *problem = nil;
        NSData *answer = [steam call:@"Authentication.GetPasswordRSAPublicKey#1" request:request problem:&problem];
        [steam close];
        if (!answer) { printf("the key request failed: %s (result %d)\n", problem.UTF8String, steam.lastResult); return 0; }
        printf("answer: %lu bytes; fields:", (unsigned long)answer.length);
        NSString *modulus = nil, *exponent = nil;
        pb_reader r = pb_read(answer);
        while (pb_next(&r)) {
            printf(" %d(kind %d, %lu bytes)", r.field, r.kind, (unsigned long)r.length);
            if (r.field == 1) modulus = pb_text(&r);
            else if (r.field == 2) exponent = pb_text(&r);
        }
        printf("\nmodulus: %lu hex digits, exponent: \"%s\"\n", (unsigned long)modulus.length, exponent.UTF8String ?: "(none)");
        NSString *encrypted = modulus.length && exponent.length ? steamcloud_encrypt(@"a dummy text", modulus, exponent) : nil;
        printf("encryption: %s\n", encrypted ? "ok" : "FAILED");
        return encrypted != nil;
    }
}
