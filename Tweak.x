#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <zlib.h>

#define LOG(fmt, ...) NSLog(@"[VersionPage] " fmt, ##__VA_ARGS__)

#define PREF_DOMAIN CFSTR("com.example.versionpage")

// Apple's catalog of "what's new" documents shown on the Software Update screen.
// Add more catalog URLs here if you need older/seed versions; they're tried in order.
static NSArray<NSString *> *CatalogURLs(void) {
    return @[@"https://mesu.apple.com/assets/com_apple_MobileAsset_SoftwareUpdateDocumentation/com_apple_MobileAsset_SoftwareUpdateDocumentation.xml"];
}

static const void *kMarkKey = &kMarkKey;
static const void *kGestureKey = &kGestureKey;
static const void *kAppliedKey = &kAppliedKey;

#pragma mark - Preferences (edited in Settings > VersionPage)

static NSString *Pref(NSString *key) {
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, PREF_DOMAIN));
    if (![v isKindOfClass:NSString.class]) return nil;
    NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return s.length ? s : nil;
}

static NSString *RealBuild(void) {
    size_t n = 0;
    if (sysctlbyname("kern.osversion", NULL, &n, NULL, 0) != 0 || n == 0) return @"—";
    char *buf = malloc(n);
    NSString *s = @"—";
    if (sysctlbyname("kern.osversion", buf, &n, NULL, 0) == 0) s = [NSString stringWithUTF8String:buf] ?: @"—";
    free(buf);
    return s;
}

static NSString *DisplayVersion(void) { return Pref(@"version") ?: UIDevice.currentDevice.systemVersion; }
static NSString *DisplayBuild(void)   { return Pref(@"build")   ?: RealBuild(); }

#pragma mark - Update notes: download + minimal ZIP reader

static inline uint16_t R16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static inline uint32_t R32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }

static NSArray<NSDictionary *> *ZipEntries(NSData *zip) {
    const uint8_t *b = zip.bytes; NSUInteger n = zip.length;
    if (n < 22) return nil;
    NSInteger eocd = -1;
    NSInteger lowest = MAX(0, (NSInteger)n - 22 - 65535);
    for (NSInteger i = (NSInteger)n - 22; i >= lowest; i--) {
        if (R32(b + i) == 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) return nil;
    uint16_t count = R16(b + eocd + 10);
    NSUInteger p = R32(b + eocd + 16);
    NSMutableArray *out = [NSMutableArray array];
    for (uint16_t i = 0; i < count; i++) {
        if (p + 46 > n || R32(b + p) != 0x02014b50) break;
        uint16_t method = R16(b + p + 10);
        uint32_t csize = R32(b + p + 20), usize = R32(b + p + 24);
        uint16_t nl = R16(b + p + 28), el = R16(b + p + 30), cl = R16(b + p + 32);
        uint32_t lho = R32(b + p + 42);
        if (p + 46 + nl > n) break;
        NSString *name = [[NSString alloc] initWithBytes:b + p + 46 length:nl encoding:NSUTF8StringEncoding] ?: @"";
        [out addObject:@{@"name": name, @"method": @(method), @"csize": @(csize), @"usize": @(usize), @"off": @(lho)}];
        p += 46 + nl + el + cl;
    }
    return out;
}

static NSData *ZipRead(NSData *zip, NSDictionary *e) {
    const uint8_t *b = zip.bytes; NSUInteger n = zip.length;
    NSUInteger off = [e[@"off"] unsignedIntegerValue];
    if (off + 30 > n || R32(b + off) != 0x04034b50) return nil;
    NSUInteger start = off + 30 + R16(b + off + 26) + R16(b + off + 28);
    NSUInteger csize = [e[@"csize"] unsignedIntegerValue];
    NSUInteger usize = [e[@"usize"] unsignedIntegerValue];
    int method = [e[@"method"] intValue];
    if (start + csize > n) return nil;
    if (method == 0) return [NSData dataWithBytes:b + start length:csize];
    if (method != 8) return nil;

    NSMutableData *out = [NSMutableData dataWithLength:usize ?: csize * 8];
    z_stream s; memset(&s, 0, sizeof(s));
    s.next_in = (Bytef *)(b + start); s.avail_in = (uInt)csize;
    s.next_out = (Bytef *)out.mutableBytes; s.avail_out = (uInt)out.length;
    if (inflateInit2(&s, -MAX_WBITS) != Z_OK) return nil;
    int r = inflate(&s, Z_FINISH);
    inflateEnd(&s);
    if (r != Z_STREAM_END) return nil;
    out.length = s.total_out;
    return out;
}

static NSArray<NSString *> *LangCandidates(void) {
    NSMutableArray *out = [NSMutableArray array];
    void (^add)(NSString *) = ^(NSString *s) { if (s.length && ![out containsObject:s]) [out addObject:s]; };
    for (NSString *l in NSLocale.preferredLanguages) {
        NSArray *parts = [l componentsSeparatedByString:@"-"];
        NSString *base = parts.firstObject, *region = nil;
        for (NSUInteger i = 1; i < parts.count; i++) if ([parts[i] length] == 2) region = parts[i];
        if (region) add([NSString stringWithFormat:@"%@_%@", base, region]);
        add([l stringByReplacingOccurrencesOfString:@"-" withString:@"_"]);
        add(base);
    }
    add(@"en");
    return out;
}

// Prefer the device language's ReadMe.html (the full notes), then ReadMeSummary.html.
static NSDictionary *PickEntry(NSArray<NSDictionary *> *entries) {
    NSArray *files = @[@"/readme.html", @"/readmesummary.html"];
    for (NSString *lang in LangCandidates()) {
        NSString *dir = [NSString stringWithFormat:@"/%@.lproj/", lang.lowercaseString];
        for (NSString *f in files) {
            for (NSDictionary *e in entries) {
                NSString *n = [@"/" stringByAppendingString:[e[@"name"] lowercaseString]];
                if ([n containsString:dir] && [n hasSuffix:f]) return e;
            }
        }
    }
    for (NSString *f in files) {
        for (NSDictionary *e in entries) {
            NSString *n = [@"/" stringByAppendingString:[e[@"name"] lowercaseString]];
            if ([n hasSuffix:f]) return e;
        }
    }
    return nil;
}

static NSString *NormVer(NSString *v) {
    NSMutableArray *p = [[v componentsSeparatedByString:@"."] mutableCopy];
    while (p.count > 1 && [p.lastObject isEqualToString:@"0"]) [p removeLastObject];
    return [p componentsJoinedByString:@"."];
}

static NSDictionary *FindAsset(NSArray *assets, NSString *ver, NSString *build) {
    NSString *want = NormVer(ver);
    NSString *device = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? @"iPad" : @"iPhone";
    NSDictionary *best = nil; NSInteger bestScore = NSIntegerMin;
    for (NSDictionary *a in assets) {
        if (![a isKindOfClass:NSDictionary.class]) continue;
        NSString *v = a[@"OSVersion"];
        if (![v isKindOfClass:NSString.class] || ![NormVer(v) isEqualToString:want]) continue;
        if (![a[@"__BaseURL"] isKindOfClass:NSString.class] || ![a[@"__RelativePath"] isKindOfClass:NSString.class]) continue;
        NSString *sid = [a[@"SUDocumentationID"] isKindOfClass:NSString.class] ? a[@"SUDocumentationID"] : @"";
        NSInteger score = 0;
        if ([a[@"Device"] isEqual:device]) score += 2;
        if ([a[@"Build"] isEqual:build]) score += 4;
        if ([sid hasSuffix:@"Long"]) score += 1;
        if ([sid hasPrefix:@"TetheredUpdateInfo"]) score -= 8;   // iTunes/Finder text, not the on-device update notes
        if (score > bestScore) { bestScore = score; best = a; }
    }
    return best;
}

static NSString *Tidy(NSString *s) {
    s = [s stringByReplacingOccurrencesOfString:@"\r" withString:@""];
    s = [s stringByReplacingOccurrencesOfString:@"\u2028" withString:@"\n"];
    s = [s stringByReplacingOccurrencesOfString:@"\u00a0" withString:@" "];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\n{3,}" options:0 error:nil];
    s = [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"\n\n"];
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// Must run on the main thread (HTML import uses WebKit).
static NSString *TextFromDocument(NSData *data, NSString *name) {
    NSString *lower = name.lowercaseString;
    if ([lower hasSuffix:@".html"] || [lower hasSuffix:@".htm"]) {
        NSDictionary *opts = @{NSDocumentTypeDocumentAttribute: NSHTMLTextDocumentType,
                               NSCharacterEncodingDocumentAttribute: @(NSUTF8StringEncoding)};
        NSAttributedString *a = [[NSAttributedString alloc] initWithData:data options:opts documentAttributes:nil error:nil];
        return a ? Tidy(a.string) : nil;
    }
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return s ? Tidy(s) : nil;
}

typedef void (^VPNotesDone)(NSString *text, NSString *error);

static NSString *CacheKey(NSString *ver, NSString *build) {
    return [NSString stringWithFormat:@"%@|%@|%@", ver, build, LangCandidates().firstObject];
}
static NSString *CachedNotes(NSString *ver, NSString *build) {
    NSDictionary *d = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"VPNotesCacheV1"];
    return d[CacheKey(ver, build)];
}
static void StoreNotes(NSString *ver, NSString *build, NSString *text) {
    NSMutableDictionary *d = [[NSUserDefaults.standardUserDefaults dictionaryForKey:@"VPNotesCacheV1"] mutableCopy] ?: [NSMutableDictionary dictionary];
    d[CacheKey(ver, build)] = text;
    [NSUserDefaults.standardUserDefaults setObject:d forKey:@"VPNotesCacheV1"];
}

static void FetchNotes(NSString *ver, NSString *build, NSArray<NSString *> *catalogs, NSUInteger idx, VPNotesDone done) {
    if (idx >= catalogs.count) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(nil, @"Update notes aren't available for this version."); });
        return;
    }
    NSURLSession *ses = NSURLSession.sharedSession;
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:catalogs[idx]] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    [[ses dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *r, NSError *err) {
        if (!data) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(nil, @"Couldn't reach Apple's update servers."); });
            return;
        }
        NSDictionary *cat = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
        NSDictionary *asset = [cat isKindOfClass:NSDictionary.class] ? FindAsset(cat[@"Assets"], ver, build) : nil;
        if (!asset) { FetchNotes(ver, build, catalogs, idx + 1, done); return; }

        NSURL *zipURL = [NSURL URLWithString:[asset[@"__BaseURL"] stringByAppendingString:asset[@"__RelativePath"]]];
        LOG(@"downloading notes: %@ (id %@)", zipURL, asset[@"SUDocumentationID"]);
        [[ses dataTaskWithURL:zipURL completionHandler:^(NSData *zdata, NSURLResponse *r2, NSError *e2) {
            NSArray *entries = zdata ? ZipEntries(zdata) : nil;
            NSDictionary *pick = entries ? PickEntry(entries) : nil;
            NSData *doc = pick ? ZipRead(zdata, pick) : nil;
            if (!doc) {
                LOG(@"no readable notes in zip; entries: %@", [entries valueForKey:@"name"]);
                dispatch_async(dispatch_get_main_queue(), ^{ done(nil, zdata ? @"Couldn't read the update notes." : @"Couldn't download the update notes."); });
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *text = TextFromDocument(doc, pick[@"name"]);
                if (text.length) { StoreNotes(ver, build, text); done(text, nil); }
                else done(nil, @"Couldn't read the update notes.");
            });
        }] resume];
    }] resume];
}

#pragma mark - Row detection helpers

static void CollectLabels(UIView *v, NSMutableArray<UILabel *> *out, int depth) {
    for (UIView *s in v.subviews) {
        if ([s isKindOfClass:UILabel.class]) [out addObject:(UILabel *)s];
        if (depth > 0) CollectLabels(s, out, depth - 1);
    }
}

static NSArray<UILabel *> *CellLabels(UITableViewCell *c) {
    NSMutableArray *a = [NSMutableArray array];
    CollectLabels(c.contentView, a, 3);
    return a;
}

// Is this text the version value (real value, or what we previously put there)?
static BOOL IsValueText(NSString *t, UITableViewCell *c) {
    if (t.length == 0) return NO;
    NSString *real = UIDevice.currentDevice.systemVersion;
    NSString *applied = objc_getAssociatedObject(c, kAppliedKey);
    if ([t isEqualToString:real] || (applied && [t isEqualToString:applied])) return YES;
    return [t hasPrefix:real] && [[t substringFromIndex:real.length] hasPrefix:@" "];
}

static BOOL IsVersionCell(UITableViewCell *c) {
    BOOL hasValue = NO, hasTitle = NO;
    for (UILabel *l in CellLabels(c)) {
        if (l.text.length == 0) continue;
        if (IsValueText(l.text, c)) hasValue = YES; else hasTitle = YES;
    }
    return hasValue && hasTitle;
}

static NSString *CellTitle(UITableViewCell *c) {
    for (UILabel *l in CellLabels(c)) {
        if (l.text.length && !IsValueText(l.text, c)) return l.text;
    }
    return @"Software Version";
}

static UIViewController *OwningVC(UIView *v) {
    UIResponder *r = v;
    while ((r = r.nextResponder)) {
        if ([r isKindOfClass:UIViewController.class]) return (UIViewController *)r;
    }
    return nil;
}

#pragma mark - The expanded page

@interface VPVersionViewController : UITableViewController
@property (nonatomic, copy) NSString *notes;
@end

@implementation VPVersionViewController

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.allowsSelection = NO;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 160;
    [self loadNotes];
}

- (void)loadNotes {
    NSString *ver = DisplayVersion(), *build = DisplayBuild();
    NSString *cached = CachedNotes(ver, build);
    if (cached) { self.notes = cached; return; }
    self.notes = @"Loading update notes…";
    __weak VPVersionViewController *weak = self;
    FetchNotes(ver, build, CatalogURLs(), 0, ^(NSString *text, NSString *error) {
        VPVersionViewController *s = weak;
        if (!s) return;
        s.notes = text ?: error;
        [s.tableView reloadData];
    });
}

- (NSAttributedString *)content {
    NSString *head = [NSString stringWithFormat:@"%@ %@ (%@)\n", UIDevice.currentDevice.systemName, DisplayVersion(), DisplayBuild()];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.paragraphSpacing = 6;
    NSMutableAttributedString *m = [[NSMutableAttributedString alloc] initWithString:head attributes:@{
        NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline],
        NSForegroundColorAttributeName: UIColor.labelColor,
        NSParagraphStyleAttributeName: ps}];
    [m appendAttributedString:[[NSAttributedString alloc] initWithString:self.notes ?: @"" attributes:@{
        NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleBody],
        NSForegroundColorAttributeName: UIColor.labelColor,
        NSParagraphStyleAttributeName: ps}]];
    return m;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 1; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return 1; }
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section { return self.title; }

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [table dequeueReusableCellWithIdentifier:@"vp"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"vp"];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        UITextView *t = [UITextView new];
        t.tag = 1;
        t.editable = NO;
        t.scrollEnabled = NO;
        t.backgroundColor = UIColor.clearColor;
        t.textContainerInset = UIEdgeInsetsZero;
        t.textContainer.lineFragmentPadding = 0;
        t.translatesAutoresizingMaskIntoConstraints = NO;
        [c.contentView addSubview:t];
        [NSLayoutConstraint activateConstraints:@[
            [t.topAnchor constraintEqualToAnchor:c.contentView.topAnchor constant:12],
            [t.bottomAnchor constraintEqualToAnchor:c.contentView.bottomAnchor constant:-12],
            [t.leadingAnchor constraintEqualToAnchor:c.contentView.leadingAnchor constant:16],
            [t.trailingAnchor constraintEqualToAnchor:c.contentView.trailingAnchor constant:-16]]];
    }
    ((UITextView *)[c.contentView viewWithTag:1]).attributedText = [self content];
    return c;
}

@end

#pragma mark - Tap handling

@interface VPTapHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
@end

@implementation VPTapHandler
+ (instancetype)shared {
    static VPTapHandler *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [self new]; });
    return s;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    return [g.view isKindOfClass:UITableViewCell.class] && IsVersionCell((UITableViewCell *)g.view);
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o {
    return YES;
}
- (void)tapped:(UITapGestureRecognizer *)g {
    UITableViewCell *cell = (UITableViewCell *)g.view;
    if (![cell isKindOfClass:UITableViewCell.class] || !IsVersionCell(cell)) return;

    UIViewController *vc = OwningVC(cell);
    UINavigationController *nav = vc.navigationController;
    LOG(@"version row tapped in %@ (nav=%@)", NSStringFromClass(vc.class), nav);
    if (!nav) return;

    UIView *flash = [[UIView alloc] initWithFrame:cell.bounds];
    flash.backgroundColor = [UIColor.systemGrayColor colorWithAlphaComponent:0.3];
    flash.userInteractionEnabled = NO;
    [cell addSubview:flash];
    [UIView animateWithDuration:0.35 animations:^{ flash.alpha = 0; } completion:^(BOOL f) { [flash removeFromSuperview]; }];

    VPVersionViewController *page = [VPVersionViewController new];
    page.title = CellTitle(cell);
    [nav pushViewController:page animated:YES];
}
@end

#pragma mark - Hook

%hook UITableViewCell

- (void)layoutSubviews {
    %orig;

    BOOL match = IsVersionCell(self);
    BOOL marked = [objc_getAssociatedObject(self, kMarkKey) boolValue];

    if (match) {
        if (self.accessoryType != UITableViewCellAccessoryDisclosureIndicator || self.accessoryView) {
            self.accessoryView = nil;
            self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }

        // Show the user's chosen version in the row (blank = real version).
        NSString *shown = DisplayVersion();
        for (UILabel *l in CellLabels(self)) {
            if (!IsValueText(l.text, self)) continue;
            if (![l.text isEqualToString:shown]) { l.text = shown; [self setNeedsLayout]; }
            objc_setAssociatedObject(self, kAppliedKey, shown, OBJC_ASSOCIATION_COPY_NONATOMIC);
            break;
        }

        if (!marked) {
            objc_setAssociatedObject(self, kMarkKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            LOG(@"found version cell: '%@'", CellTitle(self));
        }
        if (!objc_getAssociatedObject(self, kGestureKey)) {
            UITapGestureRecognizer *g = [[UITapGestureRecognizer alloc] initWithTarget:VPTapHandler.shared action:@selector(tapped:)];
            g.cancelsTouchesInView = NO;
            g.delegate = VPTapHandler.shared;
            [self addGestureRecognizer:g];
            objc_setAssociatedObject(self, kGestureKey, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else if (marked) {
        // cell got reused for a different row: undo our change
        objc_setAssociatedObject(self, kMarkKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kAppliedKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        self.accessoryType = UITableViewCellAccessoryNone;
    }
}

%end
