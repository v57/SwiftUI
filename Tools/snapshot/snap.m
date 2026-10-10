// Injected with DYLD_INSERT_LIBRARIES: renders the app's visible windows to PNGs after a delay.
// SNAP_PATH=/tmp/x.png  SNAP_DELAY=4  SNAP_EXIT=1
#import <AppKit/AppKit.h>
static void dumpLayers(NSView *view, int depth) {
    CALayer *l = view.layer;
    if (l && (getenv("SNAP_DUMP_ALL") || !CATransform3DIsIdentity(l.transform) || l.anchorPoint.x != 0 || l.anchorPoint.y != 0))
        fprintf(stderr, "%*s%s frame=%s anchor=(%.2f,%.2f) affine=%d t=[%.2f %.2f %.2f %.2f | %.2f %.2f]\n", depth, "", view.className.UTF8String,
            NSStringFromRect(view.frame).UTF8String, l.anchorPoint.x, l.anchorPoint.y, CATransform3DIsAffine(l.transform),
            l.transform.m11, l.transform.m12, l.transform.m21, l.transform.m22, l.transform.m41, l.transform.m42);
    for (NSView *sub in view.subviews) dumpLayers(sub, depth + 1);
}
__attribute__((constructor)) static void snapInit(void) {
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    NSString *path = env[@"SNAP_PATH"];
    if (!path) return;
    double delay = env[@"SNAP_DELAY"] ? [env[@"SNAP_DELAY"] doubleValue] : 4;
    BOOL quit = [env[@"SNAP_EXIT"] isEqualToString:@"1"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        int index = 0;
        if (env[@"SNAP_DUMP"]) for (NSWindow *w in NSApp.windows) if (w.contentView) dumpLayers(w.contentView, 0);
        for (NSWindow *window in NSApp.windows) {
            if (!window.isVisible || !window.contentView) continue;
            NSView *view = window.contentView.superview ?: window.contentView;
            NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
            if ([env[@"SNAP_MODE"] isEqualToString:@"layer"] && window.contentView.layer) {
                // Composites the layer tree (keeps layer transforms that cacheDisplay drops).
                CALayer *layer = window.contentView.layer;
                NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
                CGContextRef cg = ctx.CGContext;
                [NSGraphicsContext saveGraphicsState];
                NSGraphicsContext.currentContext = ctx;
                [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
                NSRect content = [view convertRect:window.contentView.bounds fromView:window.contentView];
                [[NSColor windowBackgroundColor] setFill];
                NSRectFill(content);
                // AppKit contexts are y-up; layers draw y-down.
                CGContextTranslateCTM(cg, content.origin.x, content.origin.y + content.size.height);
                CGContextScaleCTM(cg, 1, -1);
                [layer renderInContext:cg];
                [NSGraphicsContext restoreGraphicsState];
            } else {
                [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
            }
            NSString *out = index == 0 ? path : [NSString stringWithFormat:@"%@-%d.png", path.stringByDeletingPathExtension, index];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:out atomically:YES];
            index++;
        }
        if (quit) [NSApp terminate:nil];
    });
}
