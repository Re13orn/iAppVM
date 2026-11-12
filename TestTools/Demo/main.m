#import <UIKit/UIKit.h>

@interface IOSVMDemoController : UIViewController
@end
@implementation IOSVMDemoController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"iOSVM 测试目标";
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 24;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *label = [UILabel new];
    label.text = @"用于验证原生运行、方法 Hook 和容器文件导出。";
    label.numberOfLines = 0;
    [stack addArrangedSubview:label];
    UIButton *write = [UIButton buttonWithType:UIButtonTypeSystem];
    [write setTitle:@"写入测试文件" forState:UIControlStateNormal];
    [write addTarget:self action:@selector(writeSample) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:write];
    UIButton *present = [UIButton buttonWithType:UIButtonTypeSystem];
    [present setTitle:@"打开新页面（触发 Hook）" forState:UIControlStateNormal];
    [present addTarget:self action:@selector(openPage) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:present];
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];
}
- (void)writeSample {
    NSURL *documents = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] isDirectory:YES];
    NSError *error = nil;
    [NSFileManager.defaultManager createDirectoryAtURL:documents withIntermediateDirectories:YES attributes:nil error:&error];
    NSDictionary *sample = @{@"message": @"iOSVM container smoke test", @"time": @(NSDate.date.timeIntervalSince1970), @"bundle": NSBundle.mainBundle.bundleIdentifier ?: @""};
    NSData *data = [NSJSONSerialization dataWithJSONObject:sample options:NSJSONWritingPrettyPrinted error:&error];
    BOOL written = data && [data writeToURL:[documents URLByAppendingPathComponent:@"iosvm-demo.json"] options:NSDataWritingAtomic error:&error];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:written ? @"写入成功" : @"写入失败" message:written ? @"Documents/iosvm-demo.json" : error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)openPage {
    [self.navigationController pushViewController:[IOSVMDemoController new] animated:YES];
}
@end

@interface IOSVMDemoDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation IOSVMDemoDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[IOSVMDemoController new]];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(IOSVMDemoDelegate.class)); }
}
